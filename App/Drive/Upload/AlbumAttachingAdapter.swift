import Foundation
import PhotosCore
import AlbumsFeature
import UploadCore

/// Bridges `AlbumsFeature.AlbumManaging` to `UploadCore.AlbumAttaching`, so the upload queue can do
/// "create-then-add-then-cover" without `UploadCore` ever depending on `AlbumsFeature`. Each feature
/// stays independently removable; this small app-side shim is the only thing that knows about both.
struct AlbumAttachingAdapter: AlbumAttaching {
    let albums: any AlbumManaging

    func resolveAlbum(for target: UploadDestination.Target) async throws -> String? {
        switch target {
        case .library:
            return nil
        case let .existingAlbum(id, _):
            // Fail fast (before any upload) if we can't actually add — never orphan photos in the library.
            guard albums.capabilities.canAddPhotos else {
                throw AlbumError.unsupported(
                    operation: "Add to album",
                    gap: "adding a photo re-encrypts its content key to the album key, which isn’t implemented"
                )
            }
            return id
        case let .newAlbum(name):
            return try await albums.createAlbum(name: name)   // throws `.unsupported` if creation isn't wired
        }
    }

    func addPhoto(_ uid: PhotoUID, to albumID: String) async throws {
        try await albums.addPhotos([uid], to: albumID)
    }

    func setCover(albumID: String, photo: PhotoUID) async throws {
        try await albums.setAlbumCover(albumID: albumID, photoUID: photo)
    }
}
