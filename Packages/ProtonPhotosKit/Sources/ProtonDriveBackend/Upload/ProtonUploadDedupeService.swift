import CryptoKit
import Foundation
import UploadCore

// MARK: - Photos share context

/// What the dedupe service needs to know about the photos share, provided by the bridge (which
/// already discovers and caches it for every other feature).
struct PhotosShareContext: Sendable {
    let volumeID: String
    let shareID: String
    let rootLinkID: String
}

// MARK: - HMAC

/// The Proton photo identity HMAC: HMAC-SHA256 over the message's UTF-8 bytes, keyed with the
/// decrypted photos-root hash key, lowercase hex - byte-identical to the reference clients
/// (CommonCrypto there, CryptoKit here; the algorithm is the same).
enum ProtonPhotoHMAC {
    static func hex(message: String, key: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key))
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Duplicate service

enum ProtonUploadDedupeError: LocalizedError {
    /// The photos root link carried no `FolderProperties.NodeHashKey` - without it no
    /// Proton-compatible identity can be computed, so dedupe (and upload preflight) must fail
    /// rather than guess.
    case missingRootHashKey

    var errorDescription: String? {
        switch self {
        case .missingRootHashKey: "The photo library's hash key is unavailable."
        }
    }
}

/// `UploadDuplicateChecking` over the real Proton account: resolves and caches the photos-root
/// hash key through the Drive key chain (share key → root node key → decrypted `NodeHashKey`),
/// computes the identity HMACs, and queries the find-duplicates endpoint.
///
/// Privacy: never logs names, hashes, or key material - only counts.
actor ProtonUploadDedupeService: UploadDuplicateChecking {
    private let session: DriveSession
    private let crypto: DriveCrypto
    private let contentIndexStore: any UploadRemoteContentIndexStore
    private let contextProvider: @Sendable () async throws -> PhotosShareContext

    private struct Material: Sendable {
        let context: PhotosShareContext
        let rootKey: UnlockableKey
        let hashKey: Data
        let epoch: String
    }

    private var material: Material?
    private var materialTask: Task<Material, any Error>?
    private var remoteContentIndexTask: Task<Void, any Error>?
    private var remoteContentIndexGeneration = 0
    private var lastRemoteContentRefreshAt: Date?
    private static let remoteContentIndexLifetime: TimeInterval = 15
    /// Four metadata requests overlap network latency without producing the unbounded request fan-out
    /// used by the reference client. Decryption and the transactional store update remain serialized.
    private static let remoteMetadataRequestConcurrency = 4
    private static let remoteMetadataWindow = UploadDedupePipeline.protonDuplicateBatchSize * remoteMetadataRequestConcurrency

    init(
        session: DriveSession,
        crypto: DriveCrypto,
        contentIndexStore: any UploadRemoteContentIndexStore,
        contextProvider: @Sendable @escaping () async throws -> PhotosShareContext
    ) {
        self.session = session
        self.crypto = crypto
        self.contentIndexStore = contentIndexStore
        self.contextProvider = contextProvider
    }

    // MARK: UploadDuplicateChecking

    func nameHash(forCorrectedName name: String) async throws -> String {
        ProtonPhotoHMAC.hex(message: name, key: try await resolveMaterial().hashKey)
    }

    func nameHashes(forCorrectedNames names: [String]) async throws -> [String] {
        let key = try await resolveMaterial().hashKey
        return names.map { ProtonPhotoHMAC.hex(message: $0, key: key) }
    }

    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String {
        ProtonPhotoHMAC.hex(message: sha1Hex, key: try await resolveMaterial().hashKey)
    }

    func hashKeyEpoch() async throws -> String {
        try await resolveMaterial().epoch
    }

    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        let context = try await resolveMaterial().context
        let entries = try await session.findPhotoDuplicates(volumeID: context.volumeID, nameHashes: nameHashes)
        DebugLog.log("[Dedupe] duplicates query hashes=\(nameHashes.count) matches=\(entries.count)")
        return entries.map { entry in
            RemotePhotoDuplicate(
                nameHash: entry.hash,
                contentHash: entry.contentHash,
                linkState: entry.linkState.flatMap(RemotePhotoDuplicate.LinkState.init(rawValue:)),
                linkID: entry.linkID,
                clientUID: entry.clientUID
            )
        }
    }

    func findDuplicate(contentHash: String) async throws -> RemotePhotoDuplicate? {
        let material = try await resolveMaterial()
        try await refreshRemoteContentIndex(material: material)
        guard let record = contentIndexStore.remoteContentRecord(
            contentHash: contentHash,
            hashKeyEpoch: material.epoch
        ) else {
            guard !contentIndexStore.hasUnresolvedRemoteContent(hashKeyEpoch: material.epoch) else {
                throw UploadError.backend(
                    "Remote duplicate index contains photos without SHA-1 metadata"
                )
            }
            return nil
        }
        return RemotePhotoDuplicate(
            nameHash: "",
            contentHash: contentHash,
            linkState: .active,
            linkID: record.remoteLinkID
        )
    }

    func findRemoteAssetProofs(
        for identities: [UploadBackupExternalIdentity]
    ) async throws -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        guard !identities.isEmpty else { return [:] }
        let material = try await resolveMaterial()
        try await refreshRemoteContentIndex(material: material)
        return contentIndexStore.remoteAssetRecords(
            for: identities,
            hashKeyEpoch: material.epoch
        )
    }

    func invalidateCachedRemoteState() async {
        remoteContentIndexGeneration += 1
        lastRemoteContentRefreshAt = nil
        remoteContentIndexTask?.cancel()
        remoteContentIndexTask = nil
    }

    func recordUploaded(contentHash: String, remoteLinkID: String) async {
        guard let material = try? await resolveMaterial() else { return }
        _ = contentIndexStore.upsertRemoteContentRecord(UploadRemoteContentIndexRecord(
            contentHash: contentHash,
            hashKeyEpoch: material.epoch,
            remoteLinkID: remoteLinkID
        ))
    }

    // MARK: Key material

    /// Share bootstrap + root link fetch + key-chain decryption, resolved once and cached for the
    /// service's lifetime (the bridge is rebuilt on sign-in, so the cache can't outlive the
    /// account). Coalesced behind a task so concurrent first calls resolve once.
    private func resolveMaterial() async throws -> Material {
        if let material { return material }
        if let materialTask { return try await materialTask.value }
        let session = self.session
        let crypto = self.crypto
        let contextProvider = self.contextProvider
        let task = Task { () -> Material in
            let context = try await contextProvider()
            let bootstrap = try await session.getJSON("/drive/shares/\(context.shareID)", as: DedupeShareBootstrap.self)
            let shareKey = try crypto.unlockShare(key: bootstrap.key, passphrase: bootstrap.passphrase)
            let response = try await session.getJSON(
                "/drive/shares/\(context.shareID)/links/\(context.rootLinkID)",
                as: DedupeRootLinkResponse.self
            )
            guard let armoredHashKey = response.link.folderProperties?.nodeHashKey else {
                throw ProtonUploadDedupeError.missingRootHashKey
            }
            let nodeKey = try crypto.unlockNode(
                key: response.link.nodeKey,
                passphrase: response.link.nodePassphrase,
                parent: shareKey
            )
            let hashKey = Data(try crypto.decryptNodeHashKey(armoredHashKey, node: nodeKey).utf8)
            // Irreversible fingerprint for manifest validity - never the key itself.
            let epoch = SHA256.hash(data: hashKey).prefix(8).map { String(format: "%02x", $0) }.joined()
            DebugLog.log("[Dedupe] photos root hash key resolved (epoch \(epoch))")
            return Material(context: context, rootKey: nodeKey, hashKey: hashKey, epoch: epoch)
        }
        materialTask = task
        defer { materialTask = nil }
        do {
            let resolved = try await task.value
            material = resolved
            return resolved
        } catch {
            DebugLog.log("[Dedupe] hash key resolution FAILED - \(error)")
            throw error
        }
    }

    // MARK: Remote content index

    private func refreshRemoteContentIndex(material: Material) async throws {
        if let lastRemoteContentRefreshAt,
           Date().timeIntervalSince(lastRemoteContentRefreshAt) < Self.remoteContentIndexLifetime {
            return
        }
        if let remoteContentIndexTask { return try await remoteContentIndexTask.value }

        let session = self.session
        let crypto = self.crypto
        let store = self.contentIndexStore
        let generation = remoteContentIndexGeneration
        let task = Task {
            if let checkpoint = store.remoteContentIndexCheckpoint(hashKeyEpoch: material.epoch),
               store.hasRemoteAssetIndexCheckpoint(hashKeyEpoch: material.epoch) {
                try await Self.applyRemoteEvents(
                    from: checkpoint,
                    material: material,
                    session: session,
                    crypto: crypto,
                    store: store
                )
            } else {
                try await Self.rebuildRemoteContentIndex(
                    material: material,
                    session: session,
                    crypto: crypto,
                    store: store
                )
            }
        }
        remoteContentIndexTask = task
        do {
            try await task.value
            guard remoteContentIndexGeneration == generation else { throw CancellationError() }
            remoteContentIndexTask = nil
            lastRemoteContentRefreshAt = Date()
        } catch {
            if remoteContentIndexGeneration == generation { remoteContentIndexTask = nil }
            throw error
        }
    }

    private static func rebuildRemoteContentIndex(
        material: Material,
        session: DriveSession,
        crypto: DriveCrypto,
        store: any UploadRemoteContentIndexStore
    ) async throws {
        let eventID = try await session.latestVolumeEventID(volumeID: material.context.volumeID)
        let photos = try await session.fetchPhotosList(volumeID: material.context.volumeID)
        let ids = Array(Set(photos.flatMap { photo in
            [photo.linkID] + photo.relatedPhotos.map(\.linkID)
        }))
        var rows = RemoteContentIndexRows()
        for start in stride(from: 0, to: ids.count, by: remoteMetadataWindow) {
            try Task.checkCancellation()
            let window = Array(ids[start ..< min(start + remoteMetadataWindow, ids.count)])
            let links = try await fetchLinks(
                ids: window,
                shareID: material.context.shareID,
                session: session
            )
            rows.merge(try makeIndexRows(
                links: links,
                expectedActiveFileIDs: Set(window),
                material: material,
                crypto: crypto
            ))
        }
        rows.remoteAssetRecords = RemotePhotoAssetProofBuilder.records(
            photos: photos,
            externalIdentitiesByLinkID: rows.externalIdentitiesByLinkID,
            hashKeyEpoch: material.epoch
        )
        let checkpoint = UploadRemoteContentIndexCheckpoint(eventID: eventID, refreshedAt: Date())
        guard store.replaceRemoteContentIndex(
            rows.records,
            remoteAssetRecords: rows.remoteAssetRecords,
            unresolvedRemoteLinkIDs: rows.unresolvedLinkIDs,
            hashKeyEpoch: material.epoch,
            checkpoint: checkpoint
        ) else {
            throw UploadError.backend("Remote duplicate index could not be saved")
        }
        DebugLog.log(
            "[Dedupe] remote content index rebuilt records=\(rows.records.count) "
                + "unresolved=\(rows.unresolvedLinkIDs.count)"
        )
    }

    private static func applyRemoteEvents(
        from checkpoint: UploadRemoteContentIndexCheckpoint,
        material: Material,
        session: DriveSession,
        crypto: DriveCrypto,
        store: any UploadRemoteContentIndexStore
    ) async throws {
        var eventID = checkpoint.eventID
        while true {
            try Task.checkCancellation()
            let page = try await session.fetchVolumeEvents(
                volumeID: material.context.volumeID,
                since: eventID
            )
            if page.requiresRefresh {
                try await rebuildRemoteContentIndex(
                    material: material,
                    session: session,
                    crypto: crypto,
                    store: store
                )
                return
            }

            let relevant = page.events.filter { event in
                event.eventType == 0
                    || event.contextShareID == material.context.shareID
            }
            let removedIDs = Array(Set(relevant.map(\.linkID)))
            let activeFileIDs = Set(relevant.compactMap { event -> String? in
                guard event.eventType != 0 else { return nil }
                if let type = event.linkType, type != 2 { return nil }
                if let state = event.linkState, state != 1 { return nil }
                return event.linkID
            })
            let links = try await fetchLinks(
                ids: Array(activeFileIDs),
                shareID: material.context.shareID,
                session: session
            )
            let rows = try makeIndexRows(
                links: links,
                expectedActiveFileIDs: activeFileIDs,
                material: material,
                crypto: crypto
            )
            let next = UploadRemoteContentIndexCheckpoint(eventID: page.eventID, refreshedAt: Date())
            guard store.applyRemoteContentIndexChanges(
                upserting: rows.records,
                upsertingRemoteAssetRecords: rows.remoteAssetRecords,
                unresolvedRemoteLinkIDs: rows.unresolvedLinkIDs,
                removingRemoteLinkIDs: removedIDs,
                hashKeyEpoch: material.epoch,
                checkpoint: next
            ) else {
                throw UploadError.backend("Remote duplicate index changes could not be saved")
            }
            eventID = page.eventID
            if !page.hasMore { return }
        }
    }

    private static func fetchLinks(
        ids: [String],
        shareID: String,
        session: DriveSession
    ) async throws -> [String: AlbumPhotoLinkBody] {
        guard !ids.isEmpty else { return [:] }
        let chunks = stride(from: 0, to: ids.count, by: UploadDedupePipeline.protonDuplicateBatchSize).map { start in
            Array(ids[start ..< min(start + UploadDedupePipeline.protonDuplicateBatchSize, ids.count)])
        }
        var links: [String: AlbumPhotoLinkBody] = [:]
        links.reserveCapacity(ids.count)

        try await withThrowingTaskGroup(of: [AlbumPhotoLinkBody].self) { group in
            var nextChunk = 0

            func submitNext() {
                guard nextChunk < chunks.count else { return }
                let chunk = chunks[nextChunk]
                nextChunk += 1
                group.addTask {
                    try Task.checkCancellation()
                    return try await session.fetchPhotoLinksMetadata(shareID: shareID, linkIDs: chunk)
                }
            }

            for _ in 0 ..< min(Self.remoteMetadataRequestConcurrency, chunks.count) {
                submitNext()
            }
            while let batch = try await group.next() {
                for link in batch {
                    if let id = link.linkID { links[id] = link }
                }
                submitNext()
            }
        }
        return links
    }

    private struct RemoteContentIndexRows {
        var records: [UploadRemoteContentIndexRecord] = []
        var remoteAssetRecords: [UploadRemoteAssetIndexRecord] = []
        var unresolvedLinkIDs: [String] = []
        var externalIdentitiesByLinkID: [String: UploadBackupExternalIdentity] = [:]

        mutating func merge(_ other: Self) {
            records.append(contentsOf: other.records)
            unresolvedLinkIDs.append(contentsOf: other.unresolvedLinkIDs)
            externalIdentitiesByLinkID.merge(other.externalIdentitiesByLinkID) { _, new in new }
        }
    }

    private static func makeIndexRows(
        links: [String: AlbumPhotoLinkBody],
        expectedActiveFileIDs: Set<String>,
        material: Material,
        crypto: DriveCrypto
    ) throws -> RemoteContentIndexRows {
        let fractionalDateFormatter = ISO8601DateFormatter()
        fractionalDateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let standardDateFormatter = ISO8601DateFormatter()
        standardDateFormatter.formatOptions = [.withInternetDateTime]
        func parseDate(_ value: String) -> Date? {
            fractionalDateFormatter.date(from: value) ?? standardDateFormatter.date(from: value)
        }

        var records: [UploadRemoteContentIndexRecord] = []
        records.reserveCapacity(expectedActiveFileIDs.count)
        var unresolved: [String] = []
        var externalIdentitiesByLinkID: [String: UploadBackupExternalIdentity] = [:]
        externalIdentitiesByLinkID.reserveCapacity(expectedActiveFileIDs.count)
        for id in expectedActiveFileIDs {
            try Task.checkCancellation()
            guard let link = links[id] else {
                throw UploadError.backend("Remote duplicate metadata response is incomplete")
            }
            guard link.type == nil || link.type == 2,
                  link.state == nil || link.state == 1 else {
                continue
            }
            guard let nodeKey = link.nodeKey, let nodePassphrase = link.nodePassphrase else {
                throw UploadError.backend("Remote photo key metadata is incomplete")
            }
            guard let armoredXAttr = link.xAttr ?? link.fileProperties?.activeRevision?.xAttr else {
                unresolved.append(id)
                continue
            }
            let fileKey = try crypto.unlockNode(
                key: nodeKey,
                passphrase: nodePassphrase,
                parent: material.rootKey
            )
            let data = try crypto.decryptXAttr(armoredXAttr, node: fileKey)
            let attributes = try JSONDecoder().decode(DedupeXAttr.self, from: data)
            if let iOSPhotos = attributes.iOSPhotos,
               let cloudID = iOSPhotos.iCloudID,
               !cloudID.isEmpty,
               let rawDate = iOSPhotos.modificationTime,
               let modificationDate = parseDate(rawDate) {
                externalIdentitiesByLinkID[id] = UploadBackupExternalIdentity(
                    identifier: cloudID,
                    modificationDate: modificationDate
                )
            }
            guard let sha1 = attributes.common?.digests?.sha1?.lowercased(), !sha1.isEmpty else {
                unresolved.append(id)
                continue
            }
            records.append(UploadRemoteContentIndexRecord(
                contentHash: ProtonPhotoHMAC.hex(message: sha1, key: material.hashKey),
                hashKeyEpoch: material.epoch,
                remoteLinkID: id
            ))
        }

        return RemoteContentIndexRows(
            records: records,
            unresolvedLinkIDs: unresolved,
            externalIdentitiesByLinkID: externalIdentitiesByLinkID
        )
    }

}

// MARK: - Wire models (PascalCase JSON)

private struct DedupeShareBootstrap: Decodable {
    let key: String
    let passphrase: String
    enum CodingKeys: String, CodingKey { case key = "Key", passphrase = "Passphrase" }
}

private struct DedupeRootLinkResponse: Decodable {
    let link: Link
    enum CodingKeys: String, CodingKey { case link = "Link" }

    struct Link: Decodable {
        let nodeKey: String
        let nodePassphrase: String
        let folderProperties: FolderProperties?
        enum CodingKeys: String, CodingKey {
            case nodeKey = "NodeKey", nodePassphrase = "NodePassphrase", folderProperties = "FolderProperties"
        }

        struct FolderProperties: Decodable {
            let nodeHashKey: String?
            enum CodingKeys: String, CodingKey { case nodeHashKey = "NodeHashKey" }
        }
    }
}

// MARK: - Duplicates endpoint (DriveSession)

/// One row of `DuplicateHashes` from the find-duplicates endpoint. `linkState`: 0 = draft,
/// 1 = active, 2 = trashed, absent = deleted.
struct PhotoDuplicateEntry: Decodable {
    let hash: String
    let contentHash: String?
    let linkState: Int?
    let clientUID: String?
    let linkID: String?
    enum CodingKeys: String, CodingKey {
        case hash = "Hash", contentHash = "ContentHash", linkState = "LinkState",
             clientUID = "ClientUID", linkID = "LinkID"
    }
}

private struct PhotoDuplicatesResponse: Decodable {
    let duplicateHashes: [PhotoDuplicateEntry]?
    enum CodingKeys: String, CodingKey { case duplicateHashes = "DuplicateHashes" }
}

extension DriveSession {
    /// Queries which of `nameHashes` already exist in the photo volume - the Proton duplicate
    /// check. Callers batch to Proton's request size (150); this sends ONE request.
    func findPhotoDuplicates(volumeID: String, nameHashes: [String]) async throws -> [PhotoDuplicateEntry] {
        guard !nameHashes.isEmpty else { return [] }
        let data = try await send(
            "/drive/volumes/\(volumeID)/photos/duplicates",
            method: "POST",
            body: ["NameHashes": nameHashes]
        )
        return (try JSONDecoder().decode(PhotoDuplicatesResponse.self, from: data)).duplicateHashes ?? []
    }
}
