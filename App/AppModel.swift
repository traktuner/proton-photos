import Foundation
import AppKit
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
    private var backendTask: Task<Void, Never>?

    init() {
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
        authController.signIn(
            openURL: { url in Task { @MainActor in NSWorkspace.shared.open(url) } },
            onStateChange: { [weak self] state in
                self?.apply(state, prepareBackendOnSignedIn: true)
            }
        )
    }

    func cancelSignIn() {
        apply(authController.cancelSignIn(), prepareBackendOnSignedIn: false)
    }

    func signOut() {
        backendTask?.cancel()
        backend = .idle
        backupController?.stopSync()
        backupController = nil
        photoBackupController?.stopSync()
        photoBackupController = nil
        facade = nil
        libraryReady = false
        // FULL PURGE: sign-out must leave nothing tied to the account on disk. Erase the encrypted
        // thumbnail/preview/originals blobs + their account cache key and the streamed video blocks, the
        // encrypted account-data cache, AND the SDK metadata SQLite stores (entities + timeline). The
        // Settings "Delete Offline Cache" button is deliberately NARROWER (cached media only, keeps the key,
        // stays signed in) - do not converge the two.
        OfflineLibraryManager.shared.purgeOnSignOut()
        if let session = authController.currentSession {
            ProtonDriveBackendFactory.purgeLocalAccountData(
                uid: session.uid,
                policy: .standard(libraryDatabasePolicy: ProtonDriveBackendPolicy.desktopLibraryDatabasePolicy)
            )
        }
        apply(authController.signOut(), prepareBackendOnSignedIn: false)
    }

    func retryBackend() {
        if case let .signedIn(session) = auth { prepareBackend(session) }
    }

    private func prepareBackend(_ session: ProtonSession) {
        backendTask?.cancel()
        libraryReady = false           // a fresh build isn't ready until its first library load lands
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
                photoBackupController = PhotoLibraryBackupController(
                    configuration: .init(
                        accountDataDirectory: client.accountDataDirectory,
                        databasePolicy: client.accountDatabasePolicy
                    ),
                    identityResolver: client.uploadIdentityResolver,
                    uploader: client.photoUploader
                )
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
