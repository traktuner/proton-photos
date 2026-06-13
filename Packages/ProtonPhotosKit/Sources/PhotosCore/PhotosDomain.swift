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

/// Authentication lifecycle, abstracted away from the concrete fork mechanism.
public protocol AuthenticationService: Sendable {
    var isSignedIn: Bool { get async }
    func currentAccountEmail() async -> String?
    func signOut() async
}
