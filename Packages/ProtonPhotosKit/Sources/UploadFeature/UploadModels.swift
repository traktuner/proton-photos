import Foundation
import PhotosCore

// MARK: - Identifiers

/// Stable identity of one item in the upload queue.
public typealias UploadQueueItemID = UUID

// MARK: - Destination

/// Where a batch of uploads should land. Photos always upload to the Proton photo library first
/// (that's all the SDK supports); album membership is applied afterwards via `AlbumAttaching`.
public struct UploadDestination: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// Upload to the photo library only — no album.
        case library
        /// Add to an existing album after upload.
        case existingAlbum(id: String, title: String)
        /// Create the named album, then add uploaded photos to it.
        case newAlbum(name: String)
    }

    /// How to pick the album cover once the batch completes.
    public enum Cover: Sendable, Equatable {
        case unchanged
        case firstUploaded
        case specific(PhotoUID)
    }

    public var target: Target
    public var cover: Cover

    public init(target: Target, cover: Cover = .unchanged) {
        self.target = target
        self.cover = cover
    }

    public static let library = UploadDestination(target: .library)

    /// True when the destination involves an album (and therefore needs `AlbumAttaching` wired).
    public var usesAlbum: Bool {
        if case .library = target { return false }
        return true
    }

    /// Human-readable one-line summary for the destination UI.
    public var summary: String {
        switch target {
        case .library: return "Photo Library"
        case let .existingAlbum(_, title): return "Album “\(title)”"
        case let .newAlbum(name): return "New album “\(name)”"
        }
    }
}

// MARK: - Item state machine

/// The lifecycle of a single queued upload. Transitions are enforced by `UploadManager`.
public enum UploadItemState: Sendable, Equatable {
    case queued
    case preparing          // building thumbnails / reading attributes
    case hashing            // computing the content hash
    case uploading(progress: Double)
    case finalizing         // upload done, applying album membership
    case completed
    case failed(message: String)
    case cancelled
    case paused

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    public var isActive: Bool {
        switch self {
        case .preparing, .hashing, .uploading, .finalizing: return true
        default: return false
        }
    }

    /// Short label for the queue UI.
    public var label: String {
        switch self {
        case .queued: return "Queued"
        case .preparing: return "Preparing…"
        case .hashing: return "Hashing…"
        case let .uploading(p): return "Uploading \(Int(p * 100))%"
        case .finalizing: return "Finishing…"
        case .completed: return "Done"
        case let .failed(message): return "Failed — \(message)"
        case .cancelled: return "Cancelled"
        case .paused: return "Paused"
        }
    }
}

// MARK: - Queue item snapshot

/// An immutable snapshot of a queue item, handed to the UI. `UploadManager` owns the mutable truth.
public struct UploadItem: Identifiable, Sendable, Equatable {
    public let id: UploadQueueItemID
    /// Enqueue order — preserved across snapshots so the list never reshuffles.
    public let ordinal: Int
    public let fileURL: URL
    public let displayName: String
    public let mediaType: String
    public let byteCount: Int64
    public var state: UploadItemState
    /// The uploaded photo's identifier once the library upload succeeds (set before album add).
    public var uploadedUID: PhotoUID?
    /// Set when the file uploaded to the library but a later step (album add / cover) failed — the
    /// photo is NOT lost; the failure is recoverable by retrying just the album step.
    public var partialSuccess: Bool

    public init(
        id: UploadQueueItemID,
        ordinal: Int,
        fileURL: URL,
        displayName: String,
        mediaType: String,
        byteCount: Int64,
        state: UploadItemState = .queued,
        uploadedUID: PhotoUID? = nil,
        partialSuccess: Bool = false
    ) {
        self.id = id
        self.ordinal = ordinal
        self.fileURL = fileURL
        self.displayName = displayName
        self.mediaType = mediaType
        self.byteCount = byteCount
        self.state = state
        self.uploadedUID = uploadedUID
        self.partialSuccess = partialSuccess
    }
}

// MARK: - Completion event

/// Emitted as soon as the backend reports a successfully-created library node. Album finalization may
/// still run afterwards, but the asset is safe to look for in the main timeline at this point.
public struct UploadCompletedEvent: Identifiable, Sendable, Equatable {
    public let id: UploadQueueItemID
    public let uploadedUID: PhotoUID
    public let displayName: String
    public let destination: UploadDestination
    public let resolvedAlbumID: String?
    public let completedAt: Date

    public init(
        id: UploadQueueItemID,
        uploadedUID: PhotoUID,
        displayName: String,
        destination: UploadDestination,
        resolvedAlbumID: String?,
        completedAt: Date
    ) {
        self.id = id
        self.uploadedUID = uploadedUID
        self.displayName = displayName
        self.destination = destination
        self.resolvedAlbumID = resolvedAlbumID
        self.completedAt = completedAt
    }
}

// MARK: - Aggregate counts

/// Roll-up of the queue, mirrored into the `[UploadQueue]` log line.
public struct UploadQueueStats: Sendable, Equatable {
    public var queued = 0
    public var active = 0
    public var completed = 0
    public var failed = 0
    public var cancelled = 0
    public var paused = 0
    public var concurrency = 0

    public init() {}

    public var total: Int { queued + active + completed + failed + cancelled + paused }

    public var totalProgress: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    public var summaryText: String {
        "\(completed) completed · \(active) active · \(failed) failed"
    }
}

// MARK: - Queue presentation

public enum UploadQueueRowAction: Sendable, Hashable {
    case cancel
    case pause
    case resume
    case retry
}

public enum UploadQueuePresentation {
    public static func rowActions(for item: UploadItem, capabilities: UploadBackendCapabilities) -> [UploadQueueRowAction] {
        switch item.state {
        case .failed, .cancelled:
            return [.retry]
        case .queued, .preparing, .hashing, .uploading:
            return capabilities.supportsPauseResume ? [.pause, .cancel] : [.cancel]
        case .paused:
            return [.resume]
        case .completed, .finalizing:
            return []
        }
    }

    public static func canClearFinished(_ stats: UploadQueueStats) -> Bool {
        stats.completed + stats.failed + stats.cancelled > 0
    }
}

// MARK: - Upload request (per file, library-only)

/// The library-upload payload for one file. The album/cover orchestration lives in `UploadManager`;
/// this is purely what the SDK needs to push bytes into the photo library.
public struct PhotoUploadRequest: Sendable {
    public let queueItemID: UploadQueueItemID
    public let cancellationToken: UUID
    public let fileURL: URL
    public let name: String
    public let mediaType: String
    public let fileSize: Int64
    public let captureTime: Date
    public let modificationDate: Date
    public let tags: [Int]

    public init(
        queueItemID: UploadQueueItemID,
        cancellationToken: UUID,
        fileURL: URL,
        name: String,
        mediaType: String,
        fileSize: Int64,
        captureTime: Date,
        modificationDate: Date,
        tags: [Int]
    ) {
        self.queueItemID = queueItemID
        self.cancellationToken = cancellationToken
        self.fileURL = fileURL
        self.name = name
        self.mediaType = mediaType
        self.fileSize = fileSize
        self.captureTime = captureTime
        self.modificationDate = modificationDate
        self.tags = tags
    }
}

// MARK: - Errors

public enum UploadError: LocalizedError, Equatable {
    case unsupportedFile(String)
    case fileMissing(String)
    case permissionDenied(String)
    case backend(String)
    case albumStep(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFile(name): "“\(name)” isn’t a supported photo or video."
        case let .fileMissing(name): "“\(name)” could not be found."
        case let .permissionDenied(name): "No permission to read “\(name)”."
        case let .backend(message): message
        case let .albumStep(message): "Uploaded, but album step failed: \(message)"
        case .cancelled: "Cancelled."
        }
    }
}
