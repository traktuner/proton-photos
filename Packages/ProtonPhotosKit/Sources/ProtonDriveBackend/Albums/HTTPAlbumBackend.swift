import Foundation
import PhotosCore
import AlbumsFeature

/// `AlbumBackend` over the app's direct-HTTP album operations.
///
/// Listing + set-cover were always REST-backed; create + add-photos are now implemented through
/// `ProtonAlbumWriteService` (album-node write crypto + the photos album endpoints). The service
/// providers stay injected closures so a future official SDK album-write adapter can replace this
/// backend without touching `AlbumCore` or any UI.
struct HTTPAlbumBackend: AlbumBackend {
    /// Supplied by the bridge: the already-decrypted album list the sidebar uses.
    let listProvider: @Sendable () async throws -> [AlbumSummary]
    /// Supplied by the bridge: PUT the album's cover to an already-uploaded photo (cleartext LinkID, no crypto).
    let setCoverProvider: @Sendable (AlbumID, PhotoUID) async throws -> Void
    /// Album write service: create-album crypto + REST.
    let createProvider: @Sendable (String) async throws -> AlbumID
    /// Album write service: add existing photos (re-encrypted link metadata, no media re-upload).
    /// Must throw when ANY photo fails to attach - callers must never mistake a partial add for success.
    let addProvider: @Sendable ([PhotoUID], AlbumID) async throws -> Void

    var capabilities: AlbumCapabilities {
        AlbumCapabilities(canList: true, canCreate: true, canAddPhotos: true, canSetCover: true)
    }

    func listAlbums() async throws -> [AlbumSummary] {
        try await listProvider()
    }

    func createAlbum(name: String) async throws -> AlbumID {
        try await createProvider(name)
    }

    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws {
        try await addProvider(photoUIDs, albumID)
    }

    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws {
        try await setCoverProvider(albumID, photoUID)
    }
}
