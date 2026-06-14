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

/// One item on the photo timeline. Kept intentionally lightweight — heavy data
/// (full image/video) is loaded lazily through the providers below.
public struct PhotoItem: Identifiable, Hashable, Sendable {
    public let uid: PhotoUID
    public let captureTime: Date
    public let mediaType: String        // e.g. "image/jpeg", "video/quicktime"
    public let isLivePhoto: Bool
    public let durationSeconds: Double?  // for videos

    public var id: PhotoUID { uid }

    public var isVideo: Bool { mediaType.hasPrefix("video/") }

    public init(
        uid: PhotoUID,
        captureTime: Date,
        mediaType: String,
        isLivePhoto: Bool = false,
        durationSeconds: Double? = nil
    ) {
        self.uid = uid
        self.captureTime = captureTime
        self.mediaType = mediaType
        self.isLivePhoto = isLivePhoto
        self.durationSeconds = durationSeconds
    }
}

/// A date-grouped run of photos, like the macOS Photos app day/month headers.
public struct TimelineSection: Identifiable, Sendable {
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
}

/// Loads thumbnail image bytes for a photo (small grid preview).
public protocol ThumbnailProvider: Sendable {
    func thumbnail(for uid: PhotoUID) async throws -> Data
}

/// Bulk thumbnail loading — streams results as the SDK decrypts/downloads them, so the whole
/// library can be filled in the background as fast as the connection allows.
public protocol ThumbnailBatchLoader: Sendable {
    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async
}

/// Loads the full-resolution image/video file for a photo to a local URL (for the viewer).
public protocol FullMediaProvider: Sendable {
    /// Larger preview image bytes (shown immediately in the viewer before the original arrives).
    func preview(for uid: PhotoUID) async throws -> Data
    /// Downloads the original file to a temporary URL.
    func downloadOriginal(for uid: PhotoUID) async throws -> URL
}

/// Authentication lifecycle, abstracted away from the concrete fork mechanism.
public protocol AuthenticationService: Sendable {
    var isSignedIn: Bool { get async }
    func currentAccountEmail() async -> String?
    func signOut() async
}
