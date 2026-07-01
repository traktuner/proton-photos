import Foundation
import PhotosCore

/// App-facing album operations. UI binds to this, never to the SDK/HTTP layer. Shares its method set
/// with the `AlbumBackend` data seam via `AlbumOperations`; this facade adds input validation and a
/// normalized `AlbumError` surface on top of an injected backend.
public protocol AlbumManaging: AlbumOperations {}

/// Default implementation over an injected `AlbumBackend`. Validates input and normalizes errors so
/// every UI/caller sees the same `AlbumError` surface regardless of which backend is wired.
public actor AlbumsRepository: AlbumManaging {
    private let backend: any AlbumBackend

    public init(backend: any AlbumBackend) {
        self.backend = backend
    }

    public nonisolated var capabilities: AlbumCapabilities { backend.capabilities }

    public func listAlbums() async throws -> [AlbumSummary] {
        guard backend.capabilities.canList else {
            throw AlbumError.unsupported(operation: "List albums", gap: "no album listing backend is wired")
        }
        return try await backend.listAlbums()
    }

    public func createAlbum(name: String) async throws -> AlbumID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AlbumError.backend(L10n.string("error.album_name_empty"))
        }
        guard backend.capabilities.canCreate else {
            throw AlbumError.unsupported(
                operation: "Create album",
                gap: "the wired album backend has no SDK-backed album create operation yet"
            )
        }
        return try await backend.createAlbum(name: trimmed)
    }

    public func addPhotos(_ photoUIDs: [PhotoUID], to albumID: AlbumID) async throws {
        guard !photoUIDs.isEmpty else { return }
        guard backend.capabilities.canAddPhotos else {
            throw AlbumError.unsupported(
                operation: "Add to album",
                gap: "the wired album backend has no SDK-backed album photo attachment operation yet"
            )
        }
        try await backend.addPhotos(photoUIDs, to: albumID)
    }

    public func setAlbumCover(albumID: AlbumID, photoUID: PhotoUID) async throws {
        guard backend.capabilities.canSetCover else {
            throw AlbumError.unsupported(
                operation: "Set album cover",
                gap: "the wired album backend exposes no album-cover write"
            )
        }
        try await backend.setAlbumCover(albumID: albumID, photoUID: photoUID)
    }
}
