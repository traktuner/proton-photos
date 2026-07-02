import Foundation
import PhotosCore
import AlbumsFeature
import UploadCore
import UploadFeature

/// High-level, app-facing composition of the Proton clients. Built once the SDK bridge is ready and
/// owned by `AppModel`. The UI binds to the feature objects here (uploads, albums) - never to the SDK.
///
/// This is the single seam where the concrete `DriveSDKBridge` (SDK/HTTP) is wired into the pure
/// feature modules, so features can be added/removed without touching the rest of the app.
@MainActor
final class ProtonClientFacade {
    /// Existing timeline/thumbnail/download/etc. surface (unchanged).
    let backend: any PhotosBackend
    /// Album listing + (currently unsupported) writes.
    let albums: AlbumsRepository
    /// Upload queue/state-machine.
    let uploads: UploadManager
    /// Main-actor observable the upload UI binds to.
    let uploadCoordinator: UploadCoordinator

    private init(
        backend: any PhotosBackend,
        albums: AlbumsRepository,
        uploads: UploadManager,
        uploadCoordinator: UploadCoordinator
    ) {
        self.backend = backend
        self.albums = albums
        self.uploads = uploads
        self.uploadCoordinator = uploadCoordinator
    }

    static func make(bridge: DriveSDKBridge) -> ProtonClientFacade {
        // Albums: list + set-cover via the bridge's direct REST; create/add still report unsupported.
        let albumBackend = HTTPAlbumBackend(
            listProvider: { try await bridge.albums().map(AlbumSummary.init) },
            setCoverProvider: { albumID, photoUID in try await bridge.setAlbumCover(albumID: albumID, photoUID: photoUID) }
        )
        let albumsRepo = AlbumsRepository(backend: albumBackend)

        // Uploads: pure manager over the SDK uploader (the bridge) + the album-attaching shim.
        let attaching = AlbumAttachingAdapter(albums: albumsRepo)
        let manager = UploadManager(uploader: bridge, albums: attaching, maxConcurrent: 3)

        let coordinator = UploadCoordinator(
            manager: manager,
            uploadCapabilities: bridge.capabilities,
            canCreateAlbum: albumsRepo.capabilities.canCreate,
            canAddToAlbum: albumsRepo.capabilities.canAddPhotos,
            canSetAlbumCover: albumsRepo.capabilities.canSetCover
        )

        return ProtonClientFacade(backend: bridge, albums: albumsRepo,
                                  uploads: manager, uploadCoordinator: coordinator)
    }
}
