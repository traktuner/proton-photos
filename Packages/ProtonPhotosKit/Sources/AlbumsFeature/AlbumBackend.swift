import Foundation
import PhotosCore

/// The album operation surface, declared once and shared by the app-facing `AlbumManaging` facade and
/// the `AlbumBackend` data seam. The two protocols are deliberately distinct roles (validated facade vs
/// raw backend), but their method set is identical — refining this base keeps them in lockstep without
/// duplicating signatures.
public protocol AlbumOperations: Sendable {
    var capabilities: AlbumCapabilities { get }

    func listAlbums() async throws -> [AlbumSummary]
    func createAlbum(name: String) async throws -> AlbumID
    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws
    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws
}

/// The seam between `AlbumsFeature` and the concrete data layer (Proton SDK / direct HTTP).
///
/// The app implements this once (over `DriveSession` + the SDK). The feature module never imports the
/// SDK, so albums can be reasoned about, tested, and re-wired without touching networking/crypto.
///
/// Backends that can't perform an operation must `throw AlbumError.unsupported(...)` — they must not
/// return a misleading success. `capabilities` lets the UI hide/disable unavailable actions up front.
public protocol AlbumBackend: AlbumOperations {}
