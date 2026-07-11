import Foundation
import AppKit
import MediaFeedCore
import MLSearchAppleAdapter
import MLSearchCore
import PhotoLibraryBackupAdapter
import PhotosCore
import ProtonAuth
import ProtonDriveBackend
import ProtonCoreCryptoPatchedGoImplementation

/// Root application state + composition. Owns the session lifecycle and builds the SDK-backed
/// services once the user is signed in.
@MainActor
@Observable
final class AppModel {
    enum AuthState: Equatable {
        case checking
        case signedOut(error: String?)
        case authenticating(status: String)
        case signedIn(ProtonSession)
    }

    enum BackendState {
        case idle
        case preparing(String)
        case ready(any PhotosBackend)
        case failed(String)
    }

    private(set) var auth: AuthState = .checking
    private(set) var backend: BackendState = .idle
    /// High-level client composition (uploads + albums), built alongside the backend.
    private(set) var facade: ProtonClientFacade?
    /// macOS folder-backup composition over the universal sync core. Lives exactly as long as the
    /// facade (per-account stores).
    private(set) var backupController: FolderBackupController?
    /// Photos-library backup: the SHARED cross-platform controller from the PhotoKit adapter,
    /// composed with this account's dedupe pipeline and uploader.
    private(set) var photoBackupController: PhotoLibraryBackupController?
    /// Local-album → Proton-album sync: the SHARED cross-platform controller, composed with this
    /// account's dedupe pipeline, uploader, and the backend's album write service.
    private(set) var albumSyncController: AlbumSyncController?
    /// Bumped after album sync creates or mutates Proton albums. Views use it only to refresh
    /// visible album lists; sync correctness lives in the shared controller.
    private(set) var albumCatalogRevision = 0
    /// Smart Search (on-device semantic search): the SHARED cross-platform controller over the
    /// universal lifecycle actor. Built lazily by `configureSmartSearch` once the account feed
    /// and timeline exist; every lifecycle decision stays in MLSearchCore.
    private(set) var smartSearch: MLSmartSearchController?
    @ObservationIgnored private var smartSearchMemoryRegistration: MemoryPressureRegistration?
    @ObservationIgnored private let smartSearchAssets = MLAssetUniverse()
    /// The most recent ordered Smart Search shutdown; sign-out awaits it before purging.
    @ObservationIgnored private var smartSearchShutdownTask: Task<Void, Never>?
    @ObservationIgnored private let signOutBarrier = AccountSignOutBarrier()
    /// True once the signed-in library has finished its first load (loaded / empty / failed). Drives the
    /// launch veil, which lifts only after the real grid is ready to be revealed. Reset on sign-out and on a
    /// fresh backend build so a new session shows the veil again.
    private(set) var libraryReady = false

    /// The launch veil covers the whole window while the app is still preparing the session/library (the
    /// initial auth check, the backend build, or the first library load) - but NOT once a presentable
    /// terminal state is reached (the login screen, a backend error, or a loaded library).
    var isPreparing: Bool {
        switch auth {
        case .checking:
            return true
        case .signedOut, .authenticating:
            return false
        case .signedIn:
            switch backend {
            case .idle, .preparing:
                return true
            case .failed:
                return false
            case .ready:
                return facade == nil || !libraryReady
            }
        }
    }

    /// Called by the main UI once the timeline has settled (loaded / empty / failed) so the launch veil fades.
    func markLibraryReady() { libraryReady = true }

    private let sessionStore: SessionKeychainStore
    private let authController: ProtonAuthController
    private let photoBackupScheduler = MacPhotoBackupScheduler()
    private var backendTask: Task<Void, Never>?

    init() {
        // Finish a sign-out interrupted after credentials were cleared but before disk cleanup.
        BackupLocalDataPurge.purgeIfSignOutRequested()
        let store = SessionKeychainStore()
        self.sessionStore = store
        self.authController = ProtonAuthController(
            store: store,
            authenticator: ProtonForkAuthenticator(config: .externalDriveProtonPhotos)
        )
        // Wire ProtonCore's CryptoGo to the patched GopenPGP implementation before any crypto runs.
        injectDefaultCryptoImplementation()
    }

    /// Restore a persisted session on launch.
    func bootstrap() {
        apply(authController.bootstrap(), prepareBackendOnSignedIn: true)
    }

    func signIn() {
        guard !signOutBarrier.isRunning else { return }
        authController.signIn(
            openURL: { url in Task { @MainActor in NSWorkspace.shared.open(url) } },
            onStateChange: { [weak self] state in
                self?.apply(state, prepareBackendOnSignedIn: true)
            }
        )
    }

    func cancelSignIn() {
        guard !signOutBarrier.isRunning else { return }
        apply(authController.cancelSignIn(), prepareBackendOnSignedIn: false)
    }

    func signOut() {
        guard !signOutBarrier.isRunning else { return }
        BackupLocalDataPurge.requestPurgeOnSignOut()
        let session = authController.currentSession
        let signedOutState = authController.signOut()
        auth = .checking
        let backendShutdown = backendTask
        backendTask?.cancel()
        backendTask = nil
        backend = .idle
        let smartSearchShutdown = stopSmartSearch()
        backupController?.stopSync()
        backupController = nil
        photoBackupController?.stopSync()
        photoBackupScheduler.invalidate()
        photoBackupController = nil
        albumSyncController?.stopSync()
        albumSyncController = nil
        albumCatalogRevision = 0
        facade = nil
        libraryReady = false
        signOutBarrier.begin { [self] in
            await backendShutdown?.value
            await smartSearchShutdown?.value
            OfflineLibraryManager.shared.purgeOnSignOut()
            if let session {
                ProtonDriveBackendFactory.purgeLocalAccountData(
                    uid: session.uid,
                    policy: .standard(libraryDatabasePolicy: ProtonDriveBackendPolicy.desktopLibraryDatabasePolicy)
                )
            }
            BackupLocalDataPurge.purgeIfSignOutRequested()
            apply(signedOutState, prepareBackendOnSignedIn: false)
        }
    }

    func retryBackend() {
        if case let .signedIn(session) = auth { prepareBackend(session) }
    }

    /// Stop Smart Search and return the ordered-shutdown task. Consecutive stops chain, so a
    /// later awaiter always sees every previous lifecycle fully torn down.
    @discardableResult
    private func stopSmartSearch() -> Task<Void, Never>? {
        let lifecycle = smartSearch?.lifecycleActor
        smartSearch = nil
        smartSearchAssets.replace(with: [])
        smartSearchMemoryRegistration?.end()
        smartSearchMemoryRegistration = nil
        guard let lifecycle else { return smartSearchShutdownTask }
        let previous = smartSearchShutdownTask
        let task = Task {
            await previous?.value
            await lifecycle.shutdown()
        }
        smartSearchShutdownTask = task
        return task
    }

    /// Builds the Smart Search stack once the account feed and timeline exist (MainView calls
    /// this from its attach path). Idempotent per backend build; composition only — every
    /// lifecycle decision lives in the shared Core actor.
    func configureSmartSearch(
        feedCore: ThumbnailFeedCore,
        assetUIDs: [PhotoUID]
    ) {
        guard AppleSmartSearchBootstrap.featureAvailability() == .available,
              smartSearch == nil,
              let session = authController.currentSession,
              let facade else { return }
        smartSearchAssets.replace(with: assetUIDs)
        #if DEBUG
        let allowsDeveloperModels = true
        #else
        let allowsDeveloperModels = false
        #endif
        let lifecycle = AppleSmartSearchBootstrap.makeLifecycle(
            accountDirectory: facade.accountDataDirectory,
            accountUID: session.uid,
            keyPassword: session.keyPassword,
            feed: feedCore,
            assetsProvider: { [smartSearchAssets] in smartSearchAssets.snapshot() },
            allowsDeveloperModels: allowsDeveloperModels,
            databasePolicy: facade.accountDatabasePolicy
        )
        smartSearch = MLSmartSearchController(lifecycle: lifecycle)
        // Under memory pressure the search stack drops cached vector blocks and unloads the
        // CoreML model; both rebuild on demand.
        smartSearchMemoryRegistration?.end()
        smartSearchMemoryRegistration = MemoryPressureGovernor.shared.register { tier in
            guard tier.requiresImmediatePurge else { return }
            Task { await lifecycle.releaseMemory() }
        }
    }

    func updateSmartSearchAssets(_ uids: [PhotoUID]) {
        smartSearchAssets.replace(with: uids)
        smartSearch?.noteLibraryChanged()
    }

    private func prepareBackend(_ session: ProtonSession) {
        backendTask?.cancel()
        libraryReady = false           // a fresh build isn't ready until its first library load lands
        stopSmartSearch()              // rebuilt against the fresh backend's feed/timeline
        // Install the per-account encrypted-cache key derived from the restored session (and purge any legacy
        // plaintext cache) before the grid renders or the crawl begins.
        OfflineLibraryManager.shared.configure(session: session)
        backend = .preparing(String(localized: "loading.building_library"))
        backendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await ProtonDriveBackendFactory.makeFacade(
                    session: session,
                    store: sessionStore,
                    policy: .standard(libraryDatabasePolicy: ProtonDriveBackendPolicy.desktopLibraryDatabasePolicy)
                )
                facade = client
                backupController = FolderBackupController(facade: client)
                let photoBackup = PhotoLibraryBackupController(
                    configuration: .init(
                        accountDataDirectory: client.accountDataDirectory,
                        databasePolicy: client.accountDatabasePolicy
                    ),
                    identityResolver: client.uploadIdentityResolver,
                    uploader: client.photoUploader
                )
                photoBackupController = photoBackup
                photoBackupScheduler.configure(controller: photoBackup)
                let albumSync = AlbumSyncController(
                    configuration: .init(
                        accountDataDirectory: client.accountDataDirectory,
                        databasePolicy: client.accountDatabasePolicy
                    ),
                    identityResolver: client.uploadIdentityResolver,
                    uploader: client.photoUploader,
                    remoteOps: client.albumSyncRemoteOps
                )
                albumSync.setRemoteAlbumsChangedHandler { [weak self] in
                    self?.albumCatalogRevision &+= 1
                }
                albumSyncController = albumSync
                await client.uploadCoordinator.start()
                backend = .ready(client.backend)
                // Start coordinating cache footprint with system memory pressure / thermal state now
                // that the account-configured caches exist. Idempotent across backend rebuilds.
                AppMemoryPressureCoordinator.shared.install()
            } catch is CancellationError {
                // ignore
            } catch {
                DebugLog.log("backend prepare FAILED: \(error)")
                backend = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func apply(_ state: ProtonAuthState, prepareBackendOnSignedIn: Bool) {
        switch state {
        case .checking:
            auth = .checking
        case let .signedOut(error):
            auth = .signedOut(error: error)
        case let .authenticating(progress):
            auth = .authenticating(status: Self.localizedStatus(for: progress))
        case let .signedIn(session):
            auth = .signedIn(session)
            BackupLocalDataPurge.cancelPurgeRequest()   // never purge a now-active account
            if prepareBackendOnSignedIn {
                prepareBackend(session)
            }
        }
    }

    private static func localizedStatus(for progress: ProtonForkAuthenticator.Progress) -> String {
        switch progress {
        case .requestingLink: String(localized: "auth.requesting_signin_link")
        case .waitingForBrowser: String(localized: "auth.waiting_for_browser")
        case .finalizing: String(localized: "auth.finishing_signin")
        }
    }
}
