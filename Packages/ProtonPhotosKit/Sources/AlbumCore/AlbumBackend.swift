import Foundation
import PhotosCore

/// The album operation surface, declared once and shared by the app-facing `AlbumManaging` facade and
/// the `AlbumBackend` data seam. The two protocols are deliberately distinct roles (validated facade
/// vs raw backend), but their method set is identical; refining this base keeps them in lockstep
/// without duplicating signatures.
public protocol AlbumOperations: Sendable {
    var capabilities: AlbumCapabilities { get }

    func listAlbums() async throws -> [AlbumSummary]
    func createAlbum(name: String) async throws -> AlbumID
    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws
    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws
}

/// The seam between universal album code and the concrete data layer (future Proton SDK album API,
/// direct HTTP, or tests). Core never imports the SDK, so album writes can become available by wiring
/// a new backend without touching UI or upload orchestration.
///
/// Backends that cannot perform an operation must throw `AlbumError.unsupported(...)`; they must not
/// return a misleading success. `capabilities` lets UI hide/disable unavailable actions up front.
public protocol AlbumBackend: AlbumOperations {}
