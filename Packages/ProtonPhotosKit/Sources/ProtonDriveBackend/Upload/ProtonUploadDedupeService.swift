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
    private let contextProvider: @Sendable () async throws -> PhotosShareContext

    private struct Material {
        let context: PhotosShareContext
        let hashKey: Data
        let epoch: String
    }

    private var material: Material?
    private var materialTask: Task<Material, any Error>?

    init(
        session: DriveSession,
        crypto: DriveCrypto,
        contextProvider: @Sendable @escaping () async throws -> PhotosShareContext
    ) {
        self.session = session
        self.crypto = crypto
        self.contextProvider = contextProvider
    }

    // MARK: UploadDuplicateChecking

    func nameHash(forCorrectedName name: String) async throws -> String {
        ProtonPhotoHMAC.hex(message: name, key: try await resolveMaterial().hashKey)
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
            return Material(context: context, hashKey: hashKey, epoch: epoch)
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
