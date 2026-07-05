import CryptoKit
import Foundation
import PhotosCore

// MARK: - Attach requests / outcomes

/// One photo to attach to an album. `sha1Hex` (from the upload identity manifest) lets the service
/// compute the album-context `ContentHash` without fetching + decrypting the photo's XAttr; when
/// nil the service falls back to the XAttr digest, and omits `ContentHash` if neither exists.
struct AlbumAttachRequestItem: Sendable, Equatable {
    let uid: PhotoUID
    let sha1Hex: String?

    init(uid: PhotoUID, sha1Hex: String? = nil) {
        self.uid = uid
        self.sha1Hex = sha1Hex
    }
}

/// Per-photo outcome of an add-to-album batch. `alreadyMember` (Proton "already exists") counts as
/// success for sync purposes - re-running a sync converges instead of erroring.
enum AlbumAttachItemOutcome: Sendable, Equatable {
    case attached
    case alreadyMember
    case failed(code: Int?, message: String)
}

struct AlbumAttachResult: Sendable {
    var outcomes: [String: AlbumAttachItemOutcome] = [:]   // keyed by photo link id

    var attachedCount: Int { outcomes.values.filter { $0 == .attached }.count }
    var alreadyMemberCount: Int { outcomes.values.filter { $0 == .alreadyMember }.count }
    var failedCount: Int {
        outcomes.values.filter { if case .failed = $0 { true } else { false } }.count
    }
    var firstFailureMessage: String? {
        for value in outcomes.values { if case let .failed(_, message) = value { return message } }
        return nil
    }
}

enum ProtonAlbumWriteError: LocalizedError {
    /// The account exposes no usable address key to sign with - album writes cannot proceed.
    case noSigningKey
    /// The photos root carried no hash key - no Proton-compatible name hash can be computed.
    case missingRootHashKey
    /// The album link carried no decryptable hash key - photos cannot be hashed into it.
    case missingAlbumHashKey
    /// The create-album response did not contain the new album's link id.
    case malformedCreateResponse

    var errorDescription: String? {
        switch self {
        case .noSigningKey: "No signing key is available for this account."
        case .missingRootHashKey: "The photo library's hash key is unavailable."
        case .missingAlbumHashKey: "The album's hash key is unavailable."
        case .malformedCreateResponse: "The server response for the new album was incomplete."
        }
    }
}

// MARK: - Service

/// Album WRITE operations over direct REST + clean-room Proton node crypto: create an album
/// (fresh node key + hash key, name encrypted to the photos root) and add EXISTING photos to an
/// album (re-encrypt each photo's name + passphrase to the album key; no media bytes move).
///
/// Semantics verified against the Proton web client's photos API and the Drive key helpers; the
/// GPL iOS app was consulted as a behavioral reference only - no code, names, or structure copied.
///
/// Privacy: never logs names, hashes, passphrases, or key material - only counts and error codes.
actor ProtonAlbumWriteService {
    private let session: DriveSession
    private let crypto: DriveCrypto
    private let contextProvider: @Sendable () async throws -> PhotosShareContext

    /// Proton's documented add-multiple ceiling ("never lower than 10").
    static let addBatchSize = 10
    /// The web client's chunk size for `links/fetch_metadata`.
    private static let metadataBatchSize = 150

    private struct RootMaterial {
        let context: PhotosShareContext
        let rootKey: UnlockableKey
        let rootHashKey: Data
        let signer: DriveCryptoSigner
    }

    private struct AlbumMaterial {
        let key: UnlockableKey
        let hashKey: Data
    }

    private var rootMaterial: RootMaterial?
    private var rootMaterialTask: Task<RootMaterial, any Error>?
    private var albumMaterials: [String: AlbumMaterial] = [:]

    init(
        session: DriveSession,
        crypto: DriveCrypto,
        contextProvider: @Sendable @escaping () async throws -> PhotosShareContext
    ) {
        self.session = session
        self.crypto = crypto
        self.contextProvider = contextProvider
    }

    // MARK: Create

    /// Creates an album named `name` in the photos volume and returns its link id. The caller has
    /// already validated/trimmed the name (`AlbumsRepository`).
    func createAlbum(name: String) async throws -> String {
        let material = try await resolveRootMaterial()

        let passphrase = try crypto.randomBase64Token()
        let nodeKeyArmored = try crypto.generateLockedNodeKey(passphrase: passphrase)
        let albumKey = UnlockableKey(armored: nodeKeyArmored, passphrase: passphrase)
        let (nodePassphrase, nodePassphraseSignature) = try crypto.encryptWithDetachedSignature(
            text: passphrase, to: material.rootKey, signer: material.signer
        )
        let hashKeyToken = try crypto.randomBase64Token()
        let nodeHashKey = try crypto.encryptAndSign(text: hashKeyToken, to: albumKey, signer: material.signer)
        let encryptedName = try crypto.encryptAndSign(text: name, to: material.rootKey, signer: material.signer)
        let nameHash = ProtonPhotoHMAC.hex(message: name, key: material.rootHashKey)

        let albumLinkID = try await session.createAlbum(
            volumeID: material.context.volumeID,
            link: [
                "Name": encryptedName,
                "Hash": nameHash,
                "NodePassphrase": nodePassphrase,
                "NodePassphraseSignature": nodePassphraseSignature,
                "SignatureEmail": material.signer.email,
                "NodeKey": nodeKeyArmored,
                "NodeHashKey": nodeHashKey,
            ]
        )
        albumMaterials[albumLinkID] = AlbumMaterial(key: albumKey, hashKey: Data(hashKeyToken.utf8))
        DebugLog.log("[AlbumWrite] album created ✓")
        return albumLinkID
    }

    // MARK: Add photos

    /// Adds existing photos to `albumID`, re-encrypting their link metadata to the album key.
    /// Returns per-photo outcomes; throws only for whole-request failures (auth/network/album
    /// material) - per-item failures are reported, never masked.
    func attach(_ items: [AlbumAttachRequestItem], albumID: String) async throws -> AlbumAttachResult {
        var result = AlbumAttachResult()
        guard !items.isEmpty else { return result }
        let material = try await resolveRootMaterial()
        let album = try await resolveAlbumMaterial(albumID: albumID, root: material)

        // Bulk link metadata (name + passphrase are needed for the album-context re-encryption).
        var links: [String: AlbumPhotoLinkBody] = [:]
        let ids = items.map(\.uid.nodeID)
        for chunk in stride(from: 0, to: ids.count, by: Self.metadataBatchSize)
            .map({ Array(ids[$0 ..< min($0 + Self.metadataBatchSize, ids.count)]) }) {
            for link in try await session.fetchPhotoLinksMetadata(shareID: material.context.shareID, linkIDs: chunk) {
                if let id = link.linkID { links[id] = link }
            }
        }

        var payloads: [(linkID: String, payload: [String: Any])] = []
        for item in items {
            let linkID = item.uid.nodeID
            guard let link = links[linkID], let armoredName = link.name,
                  let nodeKey = link.nodeKey, let nodePassphrase = link.nodePassphrase else {
                result.outcomes[linkID] = .failed(code: nil, message: "link metadata unavailable")
                continue
            }
            do {
                let clearName = try crypto.decryptName(armoredName, parent: material.rootKey)
                let clearPassphrase = try crypto.decryptPassphrase(nodePassphrase, parent: material.rootKey)
                let newName = try crypto.encryptAndSign(text: clearName, to: album.key, signer: material.signer)
                let newPassphrase = try crypto.encrypt(text: clearPassphrase, to: album.key)
                var payload: [String: Any] = [
                    "LinkID": linkID,
                    "Name": newName,
                    "Hash": ProtonPhotoHMAC.hex(message: clearName, key: album.hashKey),
                    "NodePassphrase": newPassphrase,
                    "NameSignatureEmail": material.signer.email,
                ]
                if let sha1 = try await resolveSHA1Hex(
                    item: item, link: link, nodeKey: nodeKey, nodePassphrase: nodePassphrase, root: material.rootKey
                ) {
                    payload["ContentHash"] = ProtonPhotoHMAC.hex(message: sha1, key: album.hashKey)
                }
                payloads.append((linkID, payload))
            } catch {
                result.outcomes[linkID] = .failed(code: nil, message: "re-encryption failed")
            }
        }

        for chunk in stride(from: 0, to: payloads.count, by: Self.addBatchSize)
            .map({ Array(payloads[$0 ..< min($0 + Self.addBatchSize, payloads.count)]) }) {
            try Task.checkCancellation()
            let responses = try await session.addToAlbum(
                volumeID: material.context.volumeID,
                albumLinkID: albumID,
                albumData: chunk.map(\.payload)
            )
            let byLinkID = Dictionary(responses.map { ($0.linkID ?? "", $0) }, uniquingKeysWith: { a, _ in a })
            for (linkID, _) in chunk {
                guard let item = byLinkID[linkID] else {
                    // No per-item echo: HTTP layer enforced 2xx, count as attached.
                    result.outcomes[linkID] = .attached
                    continue
                }
                let code = item.response?.code
                if code == nil || code == 1000 {
                    result.outcomes[linkID] = .attached
                } else if code == 2500 {
                    result.outcomes[linkID] = .alreadyMember
                } else {
                    result.outcomes[linkID] = .failed(code: code, message: item.response?.error ?? "code \(code ?? -1)")
                }
            }
        }
        DebugLog.log("[AlbumWrite] attach n=\(items.count) ok=\(result.attachedCount) member=\(result.alreadyMemberCount) failed=\(result.failedCount)")
        return result
    }

    /// The link ids of the album's current MAIN photos (related Live Photo parts stay nested).
    func childMainLinkIDs(albumID: String) async throws -> Set<String> {
        let material = try await resolveRootMaterial()
        let entries = try await session.fetchAlbumPhotos(volumeID: material.context.volumeID, albumLinkID: albumID)
        return Set(entries.map(\.linkID))
    }

    // MARK: SHA1 resolution (for ContentHash)

    private func resolveSHA1Hex(
        item: AlbumAttachRequestItem,
        link: AlbumPhotoLinkBody,
        nodeKey: String,
        nodePassphrase: String,
        root: UnlockableKey
    ) async throws -> String? {
        if let sha1 = item.sha1Hex, !sha1.isEmpty { return sha1.lowercased() }
        // Fallback: the SHA1 digest Proton clients store in the (revision) XAttr.
        guard let armoredXAttr = link.xAttr ?? link.fileProperties?.activeRevision?.xAttr else { return nil }
        guard let photoKey = try? crypto.unlockNode(key: nodeKey, passphrase: nodePassphrase, parent: root),
              let data = try? crypto.decryptXAttr(armoredXAttr, node: photoKey),
              let digest = (try? JSONDecoder().decode(AlbumXAttrDigests.self, from: data))?.common?.digests?.sha1,
              !digest.isEmpty else {
            return nil
        }
        return digest.lowercased()
    }

    // MARK: Key material

    private func resolveRootMaterial() async throws -> RootMaterial {
        if let rootMaterial { return rootMaterial }
        if let rootMaterialTask { return try await rootMaterialTask.value }
        let session = self.session
        let crypto = self.crypto
        let contextProvider = self.contextProvider
        let task = Task { () -> RootMaterial in
            let context = try await contextProvider()
            let bootstrap = try await session.getJSON(
                "/drive/shares/\(context.shareID)", as: AlbumShareBootstrap.self
            )
            let shareKey = try crypto.unlockShare(key: bootstrap.key, passphrase: bootstrap.passphrase)
            let rootLink = try await session.getJSON(
                "/drive/shares/\(context.shareID)/links/\(context.rootLinkID)", as: AlbumRootLinkResponse.self
            )
            guard let armoredHashKey = rootLink.link.folderProperties?.nodeHashKey else {
                throw ProtonAlbumWriteError.missingRootHashKey
            }
            let rootKey = try crypto.unlockNode(
                key: rootLink.link.nodeKey, passphrase: rootLink.link.nodePassphrase, parent: shareKey
            )
            let rootHashKey = Data(try crypto.decryptNodeHashKey(armoredHashKey, node: rootKey).utf8)
            guard let signer = crypto.signer(preferredAddressID: bootstrap.addressID) else {
                throw ProtonAlbumWriteError.noSigningKey
            }
            DebugLog.log("[AlbumWrite] root material resolved ✓")
            return RootMaterial(context: context, rootKey: rootKey, rootHashKey: rootHashKey, signer: signer)
        }
        rootMaterialTask = task
        defer { rootMaterialTask = nil }
        let resolved = try await task.value
        rootMaterial = resolved
        return resolved
    }

    /// Album key + decrypted hash key: from the create-path cache when we just made the album,
    /// otherwise fetched + decrypted from the album link (albums are children of the photos root,
    /// so their passphrase decrypts with the root key - same chain the album title decryption uses).
    private func resolveAlbumMaterial(albumID: String, root: RootMaterial) async throws -> AlbumMaterial {
        if let cached = albumMaterials[albumID] { return cached }
        let response = try await session.getJSON(
            "/drive/shares/\(root.context.shareID)/links/\(albumID)", as: AlbumLinkResponse.self
        )
        let link = response.link
        guard let armoredHashKey = link.folderProperties?.nodeHashKey ?? link.albumProperties?.nodeHashKey else {
            throw ProtonAlbumWriteError.missingAlbumHashKey
        }
        let albumKey = try crypto.unlockNode(key: link.nodeKey, passphrase: link.nodePassphrase, parent: root.rootKey)
        let hashKey = Data(try crypto.decryptNodeHashKey(armoredHashKey, node: albumKey).utf8)
        let material = AlbumMaterial(key: albumKey, hashKey: hashKey)
        albumMaterials[albumID] = material
        return material
    }
}

// MARK: - Wire models (PascalCase JSON)

private struct AlbumShareBootstrap: Decodable {
    let key: String
    let passphrase: String
    let addressID: String?
    enum CodingKeys: String, CodingKey {
        case key = "Key", passphrase = "Passphrase", addressID = "AddressID"
    }
}

private struct AlbumRootLinkResponse: Decodable {
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

private struct AlbumLinkResponse: Decodable {
    let link: Link
    enum CodingKeys: String, CodingKey { case link = "Link" }
    struct Link: Decodable {
        let nodeKey: String
        let nodePassphrase: String
        let folderProperties: HashKeyProps?
        let albumProperties: HashKeyProps?
        enum CodingKeys: String, CodingKey {
            case nodeKey = "NodeKey", nodePassphrase = "NodePassphrase",
                 folderProperties = "FolderProperties", albumProperties = "AlbumProperties"
        }
        struct HashKeyProps: Decodable {
            let nodeHashKey: String?
            enum CodingKeys: String, CodingKey { case nodeHashKey = "NodeHashKey" }
        }
    }
}

/// Tolerant link body for the attach path: single missing fields become per-item failures rather
/// than failing the whole batch decode (same posture as the trash listing DTO).
struct AlbumPhotoLinkBody: Decodable {
    let linkID: String?
    let name: String?
    let nodeKey: String?
    let nodePassphrase: String?
    let xAttr: String?
    let fileProperties: FileProps?
    struct FileProps: Decodable {
        let activeRevision: Revision?
        struct Revision: Decodable {
            let xAttr: String?
            enum CodingKeys: String, CodingKey { case xAttr = "XAttr" }
        }
        enum CodingKeys: String, CodingKey { case activeRevision = "ActiveRevision" }
    }
    enum CodingKeys: String, CodingKey {
        case linkID = "LinkID", name = "Name", nodeKey = "NodeKey",
             nodePassphrase = "NodePassphrase", xAttr = "XAttr", fileProperties = "FileProperties"
    }
}

private struct AlbumXAttrDigests: Decodable {
    let common: Common?
    enum CodingKeys: String, CodingKey { case common = "Common" }
    struct Common: Decodable {
        let digests: Digests?
        enum CodingKeys: String, CodingKey { case digests = "Digests" }
        struct Digests: Decodable {
            let sha1: String?
            enum CodingKeys: String, CodingKey { case sha1 = "SHA1" }
        }
    }
}

// MARK: - Endpoints (DriveSession)

/// One per-item echo of the add-multiple multistatus body.
struct AlbumAddItemResponse: Decodable {
    let linkID: String?
    let response: Status?
    struct Status: Decodable {
        let code: Int?
        let error: String?
        enum CodingKeys: String, CodingKey { case code = "Code", error = "Error" }
    }
    enum CodingKeys: String, CodingKey { case linkID = "LinkID", response = "Response" }
}

private struct AlbumAddResponse: Decodable {
    let responses: [AlbumAddItemResponse]?
    enum CodingKeys: String, CodingKey { case responses = "Responses" }
}

private struct AlbumCreateResponse: Decodable {
    let album: Album?
    enum CodingKeys: String, CodingKey { case album = "Album" }
    struct Album: Decodable {
        let link: Link?
        enum CodingKeys: String, CodingKey { case link = "Link" }
        struct Link: Decodable {
            let linkID: String?
            enum CodingKeys: String, CodingKey { case linkID = "LinkID" }
        }
    }
}

private struct AlbumLinksMetadataResponse: Decodable {
    let links: [AlbumPhotoLinkBody]?
    enum CodingKeys: String, CodingKey { case links = "Links" }
}

extension DriveSession {
    /// `POST /drive/photos/volumes/{volumeID}/albums` - creates an album node, returns its link id.
    func createAlbum(volumeID: String, link: [String: Any]) async throws -> String {
        let data = try await send(
            "/drive/photos/volumes/\(volumeID)/albums",
            method: "POST",
            body: ["Locked": false, "Link": link]
        )
        guard let linkID = (try? JSONDecoder().decode(AlbumCreateResponse.self, from: data))?.album?.link?.linkID,
              !linkID.isEmpty else {
            throw ProtonAlbumWriteError.malformedCreateResponse
        }
        return linkID
    }

    /// `POST /drive/photos/volumes/{volumeID}/albums/{albumLinkID}/add-multiple` - MULTISTATUS
    /// batch (HTTP 200 with per-item codes). Callers pass at most
    /// `ProtonAlbumWriteService.addBatchSize` entries and MUST inspect the per-item responses.
    func addToAlbum(volumeID: String, albumLinkID: String, albumData: [[String: Any]]) async throws -> [AlbumAddItemResponse] {
        guard !albumData.isEmpty else { return [] }
        let data = try await send(
            "/drive/photos/volumes/\(volumeID)/albums/\(albumLinkID)/add-multiple",
            method: "POST",
            body: ["AlbumData": albumData]
        )
        return (try? JSONDecoder().decode(AlbumAddResponse.self, from: data))?.responses ?? []
    }

    /// `POST /drive/shares/{shareID}/links/fetch_metadata` with the attach path's tolerant DTO.
    /// Callers chunk to the web client's metadata batch size (150).
    func fetchPhotoLinksMetadata(shareID: String, linkIDs: [String]) async throws -> [AlbumPhotoLinkBody] {
        guard !linkIDs.isEmpty else { return [] }
        let data = try await send(
            "/drive/shares/\(shareID)/links/fetch_metadata", method: "POST", body: ["LinkIDs": linkIDs]
        )
        return (try JSONDecoder().decode(AlbumLinksMetadataResponse.self, from: data)).links ?? []
    }
}
