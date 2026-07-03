import Foundation
import PhotosCore
import AlbumsFeature

/// `AlbumBackend` over the app's existing direct-HTTP album reads.
///
/// Listing + SET-COVER work via direct REST (the set-cover write is just a cleartext `CoverLinkID` PUT, no
/// crypto). Create + add-photo are still **not** implemented: those HTTP writes require album-node encryption
/// (generating an album node key, encrypting the name + hash key, and re-encrypting each photo's content key to
/// the album key) that this app's `DriveCrypto` (decrypt-only) can't yet do - they report `.unsupported` with the
/// exact gap rather than faking success.
struct HTTPAlbumBackend: AlbumBackend {
    /// Supplied by the bridge: the already-decrypted album list the sidebar uses.
    let listProvider: @Sendable () async throws -> [AlbumSummary]
    /// Supplied by the bridge: PUT the album's cover to an already-uploaded photo (cleartext LinkID, no crypto).
    let setCoverProvider: @Sendable (AlbumID, PhotoUID) async throws -> Void

    /// List + set-cover via direct REST; create/add still need album-node write crypto (not yet implemented).
    var capabilities: AlbumCapabilities { .httpReadAndCover }

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
        try await setCoverProvider(albumID, photoUID)
    }
}
