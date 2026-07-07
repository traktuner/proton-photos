import Foundation
import PhotosCore
import AlbumsFeature
import AlbumSyncCore
import UploadCore

/// High-level, app-facing composition of the Proton clients. Built once the SDK bridge is ready and
/// owned by `AppModel`. The UI binds to the feature objects here (uploads, albums) - never to the SDK.
///
/// This is the single seam where the concrete `DriveSDKBridge` (SDK/HTTP) is wired into the pure
/// feature modules, so features can be added/removed without touching the rest of the app.
@MainActor
public final class ProtonClientFacade {
    /// Existing timeline/thumbnail/download/etc. surface (unchanged).
    public let backend: any PhotosBackend
    /// Album listing + (currently unsupported) writes.
    public let albums: AlbumsRepository
    /// Upload queue/state-machine.
    public let uploads: UploadManager
    /// Main-actor observable the upload UI binds to.
    public let uploadCoordinator: UploadCoordinator
    /// The raw upload transport (the SDK bridge) for the backup sync runner - shares the exact
    /// upload semantics with the manual queue.
    public let photoUploader: any PhotoUploading
    /// The ONE dedupe resolver for this account, shared by manual uploads and backup sync so both
    /// see the same manifest and remote duplicate view. If the manifest database cannot open,
    /// the bridge supplies a fail-closed resolver; uploads must never silently run without dedupe.
    public let uploadIdentityResolver: (any UploadIdentityResolving)?
    /// Per-account data directory (holds `library-v1.sqlite` + upload manifests). Backup sync
    /// stores live here too, so the sign-out purge covers them wholesale.
    public let accountDataDirectory: URL
    /// SQLite tuning for account-scoped stores opened by feature composition.
    public let accountDatabasePolicy: LibraryDatabasePolicy
    /// Remote album operations for the universal album sync engine (create / children / attach) -
    /// backed by the album write service; swappable for a future SDK adapter.
    public let albumSyncRemoteOps: any AlbumSyncRemoteAlbumOps

    private init(
        backend: any PhotosBackend,
        albums: AlbumsRepository,
        uploads: UploadManager,
        uploadCoordinator: UploadCoordinator,
        photoUploader: any PhotoUploading,
        uploadIdentityResolver: (any UploadIdentityResolving)?,
        accountDataDirectory: URL,
        accountDatabasePolicy: LibraryDatabasePolicy,
        albumSyncRemoteOps: any AlbumSyncRemoteAlbumOps
    ) {
        self.backend = backend
        self.albums = albums
        self.uploads = uploads
        self.uploadCoordinator = uploadCoordinator
        self.photoUploader = photoUploader
        self.uploadIdentityResolver = uploadIdentityResolver
        self.accountDataDirectory = accountDataDirectory
        self.accountDatabasePolicy = accountDatabasePolicy
        self.albumSyncRemoteOps = albumSyncRemoteOps
    }

    static func make(bridge: DriveSDKBridge) -> ProtonClientFacade {
        // Albums: list + set-cover via the bridge's direct REST; create/add via the album write
        // service (album-node crypto + photos album endpoints).
        let albumWrite = bridge.makeAlbumWriteService()
        let albumBackend = HTTPAlbumBackend(
            listProvider: { try await bridge.albums().map(AlbumSummary.init) },
            setCoverProvider: { albumID, photoUID in try await bridge.setAlbumCover(albumID: albumID, photoUID: photoUID) },
            createProvider: { name in try await albumWrite.createAlbum(name: name) },
            addProvider: { photoUIDs, albumID in
                let result = try await albumWrite.attach(
                    photoUIDs.map { AlbumAttachRequestItem(uid: $0) }, albumID: albumID
                )
                if result.failedCount > 0 {
                    throw AlbumError.backend(result.firstFailureMessage ?? "add to album failed")
                }
            }
        )
        let albumsRepo = AlbumsRepository(backend: albumBackend)

        // Uploads: pure manager over the SDK uploader (the bridge) + the album-attaching shim +
        // the universal dedupe pipeline (hash → duplicate check → skip/upload), so every upload
        // path shares ONE duplicate semantic.
        let attaching = AlbumAttachingAdapter(albums: albumsRepo)
        // ONE pipeline instance for the whole account: manual uploads and backup sync must share
        // the manifest and the cached remote duplicate view, or their skip decisions could drift.
        let identityResolver = bridge.makeUploadIdentityResolver()
        let manager = UploadManager(
            uploader: bridge,
            albums: attaching,
            identityResolver: identityResolver,
            maxConcurrent: 3
        )

        let coordinator = UploadCoordinator(
            manager: manager,
            uploadCapabilities: bridge.capabilities,
            canCreateAlbum: albumsRepo.capabilities.canCreate,
            canAddToAlbum: albumsRepo.capabilities.canAddPhotos,
            canSetAlbumCover: albumsRepo.capabilities.canSetCover
        )

        return ProtonClientFacade(
            backend: bridge,
            albums: albumsRepo,
            uploads: manager,
            uploadCoordinator: coordinator,
            photoUploader: bridge,
            uploadIdentityResolver: identityResolver,
            accountDataDirectory: bridge.uploadManifestURL.deletingLastPathComponent(),
            accountDatabasePolicy: bridge.uploadManifestPolicy,
            albumSyncRemoteOps: ProtonAlbumSyncRemoteOps(
                service: albumWrite,
                listProvider: { try await bridge.albums().map(AlbumSummary.init) }
            )
        )
    }
}
