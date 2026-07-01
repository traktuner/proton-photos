import Foundation
import PhotosCore

// MARK: - Identifiers

/// A Proton photo album identifier (the album's link id within its volume).
public typealias AlbumID = String

// MARK: - Models

/// Lightweight album description for listing/selection UIs.
public struct AlbumSummary: Identifiable, Sendable, Equatable {
    public let id: AlbumID
    public let title: String
    public let photoCount: Int
    /// The link id of the photo currently used as the album cover, if any.
    public let coverPhotoID: String?

    public init(id: AlbumID, title: String, photoCount: Int, coverPhotoID: String?) {
        self.id = id
        self.title = title
        self.photoCount = photoCount
        self.coverPhotoID = coverPhotoID
    }

    /// Bridges the existing `PhotosCore.PhotoAlbum` (used by the sidebar) into an `AlbumSummary`.
    public init(_ album: PhotoAlbum) {
        self.init(
            id: album.id,
            title: album.title,
            photoCount: album.photoCount,
            coverPhotoID: album.coverLinkID
        )
    }
}

// MARK: - Capabilities

/// Which album operations the wired backend can actually perform. Drives UI gating and honest
/// "unsupported" messaging; nothing is faked.
public struct AlbumCapabilities: Sendable, Equatable {
    public var canList: Bool
    public var canCreate: Bool
    public var canAddPhotos: Bool
    public var canSetCover: Bool

    public init(canList: Bool, canCreate: Bool, canAddPhotos: Bool, canSetCover: Bool) {
        self.canList = canList
        self.canCreate = canCreate
        self.canAddPhotos = canAddPhotos
        self.canSetCover = canSetCover
    }

    /// Read-only: list works, writes are not supported.
    public static let readOnly = AlbumCapabilities(
        canList: true,
        canCreate: false,
        canAddPhotos: false,
        canSetCover: false
    )

    /// The current wired direct-HTTP album backend: listing + set-cover work; create/add need
    /// album-node write crypto or a future official SDK album-write adapter. Single source of truth
    /// shared by the backend and the `[SDKCapabilities]` diagnostic so they cannot drift apart.
    public static let httpReadAndCover = AlbumCapabilities(
        canList: true,
        canCreate: false,
        canAddPhotos: false,
        canSetCover: true
    )
}

// MARK: - Errors

/// Surfaced when an album operation cannot be completed. `.unsupported` is the explicit,
/// user-visible signal for "the wired backend cannot honestly perform this operation" - never a
/// crash, never silently downgraded to a library-only upload.
public enum AlbumError: LocalizedError, Equatable {
    /// The operation is not implemented by the wired backend. `operation`/`gap` are developer-facing
    /// diagnostics and are deliberately not surfaced in `errorDescription`.
    case unsupported(operation: String, gap: String)
    case backend(String)

    public var errorDescription: String? {
        switch self {
        case .unsupported:
            L10n.string("error.album_action_unavailable")
        case let .backend(message):
            message
        }
    }
}
