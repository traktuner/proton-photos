import Foundation
import PhotosCore
import ProtonCoreCryptoGoInterface
import UniformTypeIdentifiers

enum StreamingError: Error { case noRevision, noXAttr }

/// One block's fetch info + its position in the *cleartext* file (from XAttr block sizes), so the
/// resource loader can map a requested byte range to the blocks it needs.
struct VideoBlock: Sendable {
    let index: Int           // 1-based revision block index (matches the cache key + ClearBlock)
    let url: String          // BareURL (with token) or a pre-signed full URL
    let token: String?       // storage token for the `pm-storage-token` header; nil if `url` is pre-signed
    let clearOffset: Int     // byte offset of this block in the decrypted file
    let clearSize: Int       // decrypted byte length of this block
}

/// Everything needed to serve a streaming video: the item uid (cache key), total size, the per-block
/// map, the content session key, and the content UTI. The session key is a gopenpgp object reused
/// across block decrypts.
final class PreparedVideo: @unchecked Sendable {
    let uid: PhotoUID
    let totalSize: Int
    let contentTypeUTI: String
    let blocks: [VideoBlock]
    let sessionKey: CryptoSessionKey
    /// Pure range→slice mapper (cleartext coordinates) shared with the resource loader.
    let blockMap: VideoBlockMap
    private let byIndex: [Int: VideoBlock]

    init(uid: PhotoUID, totalSize: Int, contentTypeUTI: String, blocks: [VideoBlock], sessionKey: CryptoSessionKey) {
        self.uid = uid
        self.totalSize = totalSize
        self.contentTypeUTI = contentTypeUTI
        self.blocks = blocks
        self.sessionKey = sessionKey
        self.blockMap = VideoBlockMap(
            blocks: blocks.map { ClearBlock(index: $0.index, clearOffset: $0.clearOffset, clearSize: $0.clearSize) },
            totalSize: totalSize
        )
        self.byIndex = Dictionary(blocks.map { ($0.index, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func block(at index: Int) -> VideoBlock? { byIndex[index] }
}

/// Resolves the Drive key chain for a file and prepares its block map for streaming. Caches the
/// share key and node keys, so opening successive videos in the same library only costs the
/// per-file link + revision fetch. All network goes through the authed `DriveSession`.
actor PhotoVideoStreamSource {
    private let session: DriveSession
    private let crypto: DriveCrypto
    private let shareID: String

    private var shareKey: UnlockableKey?
    private var nodeKeyCache: [String: UnlockableKey] = [:]

    init(session: DriveSession, crypto: DriveCrypto, shareID: String) {
        self.session = session
        self.crypto = crypto
        self.shareID = shareID
    }

    /// Resolves keys + block map for the file `uid`. Throws `.notAVideo` cheaply (before any key
    /// derivation) if the link isn't a video, so the viewer can fall back to the image path.
    func prepare(uid: PhotoUID) async throws -> PreparedVideo {
        let prepared = try await prepareAnyFile(uid: uid)
        guard prepared.contentTypeUTI.hasPrefix("public.movie")
                || prepared.contentTypeUTI.hasPrefix("public.video")
                || prepared.contentTypeUTI == "com.apple.quicktime-movie"
                || UTType(prepared.contentTypeUTI)?.conforms(to: .movie) == true else {
            throw VideoStreamError.notAVideo
        }
        return prepared
    }

    /// Decrypts the original into RAM without persisting app-owned plaintext. Used by image viewing and
    /// explicit user exports; videos normally use the range-streaming path above.
    func originalData(uid: PhotoUID, onProgress: @Sendable (Double) -> Void) async throws -> Data {
        let prepared = try await prepareAnyFile(uid: uid)
        var out = Data()
        out.reserveCapacity(prepared.totalSize)
        let total = max(prepared.totalSize, 1)
        onProgress(0)
        for block in prepared.blocks.sorted(by: { $0.index < $1.index }) {
            try Task.checkCancellation()
            let encrypted = try await encryptedBlockData(block)
            let clear = try crypto.decryptBlock(encrypted, sessionKey: prepared.sessionKey)
            out.append(clear.prefix(block.clearSize))
            onProgress(min(1, Double(out.count) / Double(total)))
        }
        if out.count > prepared.totalSize {
            out.removeSubrange(prepared.totalSize..<out.count)
        }
        onProgress(1)
        return out
    }

    private func prepareAnyFile(uid: PhotoUID) async throws -> PreparedVideo {
        let linkID = uid.nodeID
        let link = try await fetchLink(linkID)
        guard let fp = link.fileProperties, let rev = fp.activeRevision else { throw StreamingError.noRevision }

        let nodeKey = try await nodeKey(for: link)
        let sessionKey = try crypto.contentSessionKey(contentKeyPacketBase64: fp.contentKeyPacket, node: nodeKey)

        let (blockInfos, revXAttr) = try await fetchRevisionBlocks(linkID: linkID, revID: rev.id)
        guard let xattrArmored = link.xAttr ?? revXAttr else { throw StreamingError.noXAttr }
        let xattrData = try crypto.decryptXAttr(xattrArmored, node: nodeKey)
        let xattr = try JSONDecoder().decode(XAttrBody.self, from: xattrData)

        var blocks: [VideoBlock] = []
        var offset = 0
        for info in blockInfos.sorted(by: { $0.index < $1.index }) {
            let clearSize = xattr.common.blockSizes.indices.contains(info.index - 1)
                ? xattr.common.blockSizes[info.index - 1] : 0
            let bare = info.bareURL
            blocks.append(VideoBlock(
                index: info.index,
                url: bare ?? info.url ?? "",
                token: bare != nil ? info.token : nil,
                clearOffset: offset,
                clearSize: clearSize
            ))
            offset += clearSize
        }
        // Prefer the authoritative total from XAttr; fall back to the summed block sizes.
        let total = xattr.common.size > 0 ? xattr.common.size : offset
        let uti = UTType(mimeType: link.mimeType ?? "") ?? .data
        return PreparedVideo(uid: uid, totalSize: total, contentTypeUTI: uti.identifier,
                             blocks: blocks, sessionKey: sessionKey)
    }

    /// Encrypted bytes for one block — called by the resource loader on demand.
    func encryptedBlockData(_ block: VideoBlock) async throws -> Data {
        try await session.fetchBlock(url: block.url, token: block.token)
    }

    /// Fully downloads the clip's ENCRYPTED blocks into the shared range cache (no plaintext written anywhere),
    /// so a later streaming play serves entirely from local encrypted bytes. Used for Live Photo motion, which
    /// must be 100% loaded before hover/click plays it. Idempotent: skips blocks already cached.
    func prefetchEncrypted(uid: PhotoUID) async throws {
        let prepared = try await prepare(uid: uid)
        for block in prepared.blocks where VideoByteRangeCache.shared.encryptedBlock(uid: prepared.uid, block: block.index) == nil {
            try Task.checkCancellation()
            let encrypted = try await encryptedBlockData(block)
            VideoByteRangeCache.shared.store(uid: prepared.uid, block: block.index, encrypted: encrypted)
        }
    }

    /// Decrypted file metadata for the info panel: filename (decrypted with the parent node key),
    /// MIME type, size, and the XAttr (dimensions, device, duration, GPS).
    func fileMetadata(linkID: String) async throws -> (filename: String?, mimeType: String?, size: Int?, xattr: ExtendedAttributes?) {
        let link = try await fetchLink(linkID)
        let fileKey = try await nodeKey(for: link)

        var filename: String?
        if let name = link.name, let parentID = link.parentLinkID, !parentID.isEmpty {
            let parentLink = try await fetchLink(parentID)
            let parentKey = try await nodeKey(for: parentLink)
            filename = try? crypto.decryptName(name, parent: parentKey)
        }
        var xattr: ExtendedAttributes?
        if let xa = link.xAttr, let data = try? crypto.decryptXAttr(xa, node: fileKey) {
            xattr = try? JSONDecoder().decode(ExtendedAttributes.self, from: data)
        }
        return (filename, link.mimeType, link.size, xattr)
    }

    /// Decrypts a node's name (used for album titles) with its parent node key.
    func nodeName(linkID: String) async throws -> String? {
        let link = try await fetchLink(linkID)
        guard let name = link.name, let parentID = link.parentLinkID, !parentID.isEmpty else { return nil }
        let parentLink = try await fetchLink(parentID)
        let parentKey = try await nodeKey(for: parentLink)
        return try? crypto.decryptName(name, parent: parentKey)
    }

    // MARK: - Key chain

    private func nodeKey(for link: LinkBody) async throws -> UnlockableKey {
        if let cached = nodeKeyCache[link.linkID] { return cached }
        let parent: UnlockableKey
        if let parentID = link.parentLinkID, !parentID.isEmpty {
            let parentLink = try await fetchLink(parentID)
            parent = try await nodeKey(for: parentLink)
        } else {
            parent = try await shareKeyUnlockable()   // root node: parent key is the ShareKey
        }
        let key = try crypto.unlockNode(key: link.nodeKey, passphrase: link.nodePassphrase, parent: parent)
        nodeKeyCache[link.linkID] = key
        return key
    }

    private func shareKeyUnlockable() async throws -> UnlockableKey {
        if let shareKey { return shareKey }
        let boot = try await session.getJSON("/drive/shares/\(shareID)", as: ShareBootstrap.self)
        let key = try crypto.unlockShare(key: boot.key, passphrase: boot.passphrase)
        shareKey = key
        return key
    }

    // MARK: - Endpoints

    private func fetchLink(_ linkID: String) async throws -> LinkBody {
        try await session.getJSON("/drive/shares/\(shareID)/links/\(linkID)", as: LinkResponse.self).link
    }

    /// Pages through the revision's blocks (FromBlockIndex is 1-based) until all are collected.
    private func fetchRevisionBlocks(linkID: String, revID: String) async throws -> ([BlockInfo], String?) {
        var all: [BlockInfo] = []
        var xattr: String?
        var from = 1
        let pageSize = 500
        while true {
            let path = "/drive/shares/\(shareID)/files/\(linkID)/revisions/\(revID)?FromBlockIndex=\(from)&PageSize=\(pageSize)"
            let revision = try await session.getJSON(path, as: RevisionResponse.self).revision
            if xattr == nil { xattr = revision.xAttr }
            all.append(contentsOf: revision.blocks)
            guard revision.blocks.count == pageSize, let last = revision.blocks.map(\.index).max() else { break }
            from = last + 1
        }
        return (all, xattr)
    }
}

// MARK: - Wire models (PascalCase JSON)

private struct ShareBootstrap: Decodable {
    let key: String
    let passphrase: String
    enum CodingKeys: String, CodingKey { case key = "Key", passphrase = "Passphrase" }
}

private struct LinkResponse: Decodable {
    let link: LinkBody
    enum CodingKeys: String, CodingKey { case link = "Link" }
}

struct LinkBody: Decodable {
    let linkID: String
    let parentLinkID: String?
    let name: String?
    let mimeType: String?
    let size: Int?
    let nodeKey: String
    let nodePassphrase: String
    let xAttr: String?
    let fileProperties: FileProperties?

    struct FileProperties: Decodable {
        let contentKeyPacket: String
        let activeRevision: ActiveRevision?
        struct ActiveRevision: Decodable {
            let id: String
            enum CodingKeys: String, CodingKey { case id = "ID" }
        }
        enum CodingKeys: String, CodingKey {
            case contentKeyPacket = "ContentKeyPacket", activeRevision = "ActiveRevision"
        }
    }
    enum CodingKeys: String, CodingKey {
        case linkID = "LinkID", parentLinkID = "ParentLinkID", name = "Name", mimeType = "MIMEType",
             size = "Size", nodeKey = "NodeKey", nodePassphrase = "NodePassphrase", xAttr = "XAttr",
             fileProperties = "FileProperties"
    }
}

/// Decrypted XAttr (extended attributes) — Proton stores a device string + dimensions + duration +
/// GPS, but no full EXIF (no aperture/ISO/lens). Field names match Proton's exact PascalCase JSON.
struct ExtendedAttributes: Decodable {
    let common: Common?
    let location: Location?
    let camera: Camera?
    let media: Media?
    enum CodingKeys: String, CodingKey {
        case common = "Common", location = "Location", camera = "Camera", media = "Media"
    }
    struct Common: Decodable {
        let modificationTime: String?
        let size: Int?
        enum CodingKeys: String, CodingKey { case modificationTime = "ModificationTime", size = "Size" }
    }
    struct Location: Decodable {
        let latitude: Double?
        let longitude: Double?
        enum CodingKeys: String, CodingKey { case latitude = "Latitude", longitude = "Longitude" }
    }
    struct Camera: Decodable {
        let device: String?
        let orientation: Int?
        enum CodingKeys: String, CodingKey { case device = "Device", orientation = "Orientation" }
    }
    struct Media: Decodable {
        let width: Int?
        let height: Int?
        let duration: Double?
        enum CodingKeys: String, CodingKey { case width = "Width", height = "Height", duration = "Duration" }
    }
}

private struct RevisionResponse: Decodable {
    let revision: RevisionBody
    enum CodingKeys: String, CodingKey { case revision = "Revision" }
    struct RevisionBody: Decodable {
        let blocks: [BlockInfo]
        let xAttr: String?
        enum CodingKeys: String, CodingKey { case blocks = "Blocks", xAttr = "XAttr" }
    }
}

struct BlockInfo: Decodable {
    let index: Int
    let bareURL: String?
    let url: String?
    let token: String?
    enum CodingKeys: String, CodingKey {
        case index = "Index", bareURL = "BareURL", url = "URL", token = "Token"
    }
}

private struct XAttrBody: Decodable {
    let common: Common
    struct Common: Decodable {
        let size: Int
        let blockSizes: [Int]
        enum CodingKeys: String, CodingKey { case size = "Size", blockSizes = "BlockSizes" }
    }
    enum CodingKeys: String, CodingKey { case common = "Common" }
}
