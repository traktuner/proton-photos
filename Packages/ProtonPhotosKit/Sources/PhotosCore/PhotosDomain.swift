import Foundation

// MARK: - Identifiers

/// SDK-agnostic photo identifier (mirrors the SDK's volume/node pair).
public struct PhotoUID: Hashable, Sendable, Codable {
    public let volumeID: String
    public let nodeID: String
    public init(volumeID: String, nodeID: String) {
        self.volumeID = volumeID
        self.nodeID = nodeID
    }
}

// MARK: - Models

/// One item on the photo timeline. Kept intentionally lightweight - heavy data
/// (full image/video) is loaded lazily through the providers below.
public struct PhotoItem: Identifiable, Hashable, Sendable, Codable {
    public let uid: PhotoUID
    public let captureTime: Date
    public let mediaType: String        // e.g. "image/jpeg", "video/quicktime"
    public let isLivePhoto: Bool
    /// For a Live Photo, the node ID (same volume) of the paired video file.
    public let relatedVideoID: String?
    public let durationSeconds: Double?  // for videos
    /// Proton's server-side smart tags when the current backend path exposes them. SDK timeline enumeration
    /// can omit these; callers must treat this as enrichment, not the source of all truth.
    public let tags: Set<PhotoTag>
    /// Link IDs of every photo in the same burst/series, in presentation order. Empty means either
    /// "not a burst" or "the backend path has not enriched this item yet"; callers that need the full
    /// group should ask `BurstGroupProvider` on demand.
    public let burstMemberIDs: [String]

    public var id: PhotoUID { uid }

    public var isVideo: Bool { mediaType.hasPrefix("video/") }
    public var isBurstCandidate: Bool { tags.contains(.bursts) || burstMemberIDs.count > 1 }

    /// The paired video's identifier, for Live Photo playback.
    public var relatedVideoUID: PhotoUID? {
        relatedVideoID.map { PhotoUID(volumeID: uid.volumeID, nodeID: $0) }
    }

    /// Stable UIDs for all known members of this burst/series.
    public var burstMemberUIDs: [PhotoUID] {
        burstMemberIDs.map { PhotoUID(volumeID: uid.volumeID, nodeID: $0) }
    }

    public init(
        uid: PhotoUID,
        captureTime: Date,
        mediaType: String,
        isLivePhoto: Bool = false,
        relatedVideoID: String? = nil,
        durationSeconds: Double? = nil,
        tags: Set<PhotoTag> = [],
        burstMemberIDs: [String] = []
    ) {
        self.uid = uid
        self.captureTime = captureTime
        self.mediaType = mediaType
        self.isLivePhoto = isLivePhoto
        self.relatedVideoID = relatedVideoID
        self.durationSeconds = durationSeconds
        self.tags = tags
        self.burstMemberIDs = burstMemberIDs
    }

    private enum CodingKeys: String, CodingKey {
        case uid, captureTime, mediaType, isLivePhoto, relatedVideoID, durationSeconds, tags, burstMemberIDs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decode(PhotoUID.self, forKey: .uid)
        captureTime = try container.decode(Date.self, forKey: .captureTime)
        mediaType = try container.decode(String.self, forKey: .mediaType)
        isLivePhoto = try container.decodeIfPresent(Bool.self, forKey: .isLivePhoto) ?? false
        relatedVideoID = try container.decodeIfPresent(String.self, forKey: .relatedVideoID)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        tags = try container.decodeIfPresent(Set<PhotoTag>.self, forKey: .tags) ?? []
        burstMemberIDs = try container.decodeIfPresent([String].self, forKey: .burstMemberIDs) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(uid, forKey: .uid)
        try container.encode(captureTime, forKey: .captureTime)
        try container.encode(mediaType, forKey: .mediaType)
        try container.encode(isLivePhoto, forKey: .isLivePhoto)
        try container.encodeIfPresent(relatedVideoID, forKey: .relatedVideoID)
        try container.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try container.encode(tags, forKey: .tags)
        try container.encode(burstMemberIDs, forKey: .burstMemberIDs)
    }
}

/// A date-grouped run of photos, like the macOS Photos app day/month headers.
public struct TimelineSection: Identifiable, Sendable, Codable {
    public let id: String          // stable key, e.g. "2026-06-13"
    public let date: Date
    public let title: String
    public var items: [PhotoItem]

    public init(id: String, date: Date, title: String, items: [PhotoItem]) {
        self.id = id
        self.date = date
        self.title = title
        self.items = items
    }
}

// MARK: - Provider protocols (implemented by the SDK glue in the app target)

/// Source of timeline metadata.
public protocol PhotosRepository: Sendable {
    func loadTimeline() async throws -> [TimelineSection]
    /// Last-known timeline persisted to disk, for instant startup (nil if none). `loadTimeline()`
    /// then refreshes in the background - stale-while-revalidate, so there's no spinner on relaunch.
    func cachedTimeline() async -> [TimelineSection]?
}

public extension PhotosRepository {
    func cachedTimeline() async -> [TimelineSection]? { nil }
}

/// Loads thumbnail image bytes for a photo (small grid preview).
public protocol ThumbnailProvider: Sendable {
    func thumbnail(for uid: PhotoUID) async throws -> Data
}

/// How one `loadThumbnails` batch disposed of every uid that did NOT stream back through
/// `onLoaded`. The feed uses this to classify (and account for) undelivered items instead of
/// collapsing every failure into an unexplained "0/N".
public struct ThumbnailBatchLoadResult: Sendable, Equatable {
    /// The whole call failed (transport/session/SDK error) before or while streaming. Undelivered
    /// items in the batch failed for this reason.
    public let batchError: String?
    /// Failures the backend reported per item (uid → short reason), e.g. "no thumbnail" or a
    /// decrypt error. These are authoritative answers, not transport problems.
    public let itemErrors: [PhotoUID: String]

    public init(batchError: String? = nil, itemErrors: [PhotoUID: String] = [:]) {
        self.batchError = batchError
        self.itemErrors = itemErrors
    }

    /// The loader finished normally and reported no failures (items it didn't deliver are simply unknown).
    public static let delivered = ThumbnailBatchLoadResult()
}

/// Bulk thumbnail loading - streams results as the SDK decrypts/downloads them, so the whole
/// library can be filled in the background as fast as the connection allows. Returns a per-batch
/// disposition so callers can explain (and stop retrying) items the backend refused.
public protocol ThumbnailBatchLoader: Sendable {
    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult
}

/// Loads full-resolution original bytes without creating an app-owned plaintext cache file.
public protocol FullMediaProvider: Sendable {
    /// Larger preview image bytes (shown immediately in the viewer before the original arrives).
    func preview(for uid: PhotoUID) async throws -> Data
    /// Decrypts the original into RAM, reporting progress (0…1). Callers that export may write these bytes
    /// only to a user-selected destination; the app must not persist plaintext originals in its own cache/temp dirs.
    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data
}

public extension FullMediaProvider {
    func originalData(for uid: PhotoUID) async throws -> Data {
        try await originalData(for: uid, onProgress: { _ in })
    }
}

/// Optional metadata provider for Proton burst/series groups. The viewer calls this lazily only when
/// an item is tagged/enriched as a burst candidate, so the main timeline path stays fast and SDK-agnostic.
public protocol BurstGroupProvider: Sendable {
    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem]
}

/// Authentication lifecycle, abstracted away from the concrete fork mechanism.
public protocol AuthenticationService: Sendable {
    var isSignedIn: Bool { get async }
    func currentAccountEmail() async -> String?
    func signOut() async
}
