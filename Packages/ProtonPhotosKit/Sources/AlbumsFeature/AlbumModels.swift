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
        self.init(id: album.id, title: album.title,
                  photoCount: album.photoCount, coverPhotoID: album.coverLinkID)
    }
}

/// Records that a photo belongs to an album — returned by add operations so callers can reconcile.
public struct AlbumPhotoMembership: Sendable, Equatable {
    public let albumID: AlbumID
    public let photoUID: PhotoUID

    public init(albumID: AlbumID, photoUID: PhotoUID) {
        self.albumID = albumID
        self.photoUID = photoUID
    }
}

// MARK: - Capabilities

/// Which album operations the wired backend can actually perform. Drives UI gating and honest
/// "unsupported" messaging — nothing is faked.
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

    /// Read-only: list works (direct HTTP), writes are not yet supported.
    public static let readOnly = AlbumCapabilities(
        canList: true, canCreate: false, canAddPhotos: false, canSetCover: false
    )
}

// MARK: - Errors

/// Surfaced when an album operation can't be completed. `.unsupported` is the explicit, user-visible
/// signal for "the SDK has no album API and no encrypted-write HTTP path exists yet" — never a crash,
/// never silently downgraded to a library-only upload.
public enum AlbumError: LocalizedError, Equatable {
    /// The operation isn't implemented by the wired backend; `gap` names the exact missing capability.
    case unsupported(operation: String, gap: String)
    case notFound(AlbumID)
    case backend(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupported(operation, gap):
            "“\(operation)” isn’t available yet: \(gap)"
        case let .notFound(id):
            "Album \(id) was not found."
        case let .backend(message):
            message
        }
    }
}
