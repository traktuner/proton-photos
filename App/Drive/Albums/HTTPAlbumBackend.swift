import Foundation
import PhotosCore
import AlbumsFeature

/// `AlbumBackend` over the app's existing direct-HTTP album reads.
///
/// Listing works (the app already paginates `/drive/photos/volumes/{vol}/albums` and decrypts the
/// titles). Writes — create, add-photo, set-cover — are **not** implemented: the Proton Swift SDK has
/// no album API, and the HTTP writes require album-node encryption (generating an album node key,
/// encrypting the name + hash key, and re-encrypting each photo's content key to the album key) that
/// this app's `DriveCrypto` (decrypt-only) can't yet do. Those operations report `.unsupported` with
/// the exact gap rather than faking success or silently dropping to a library-only upload.
struct HTTPAlbumBackend: AlbumBackend {
    /// Supplied by the bridge: the already-decrypted album list the sidebar uses.
    let listProvider: @Sendable () async throws -> [AlbumSummary]

    var capabilities: AlbumCapabilities { .readOnly }

    func listAlbums() async throws -> [AlbumSummary] {
        try await listProvider()
    }

    func createAlbum(name: String) async throws -> AlbumID {
        throw AlbumError.unsupported(
            operation: "Create album",
            gap: "the Proton Swift SDK exposes no album API and album-node encryption (key + name + hash-key) isn’t implemented"
        )
    }

    func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws {
        throw AlbumError.unsupported(
            operation: "Add to album",
            gap: "adding a photo re-encrypts its content key to the album key, which isn’t implemented"
        )
    }

    func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws {
        throw AlbumError.unsupported(
            operation: "Set album cover",
            gap: "no SDK album-cover API and no encrypted-write HTTP path exists yet"
        )
    }
}
