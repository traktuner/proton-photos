import Foundation
import AppKit
import PhotosCore
import ProtonAuth
import ProtonCoreCryptoPatchedGoImplementation

typealias PhotosBackend = PhotosRepository & ThumbnailProvider & ThumbnailBatchLoader & FullMediaProvider & VideoStreamProvider & PhotoMetadataProvider & PhotoLibraryProvider & FavoritesProvider & TrashProvider & LibraryStatsProvider

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

    private let store = SessionKeychainStore()
    private let authenticator = ProtonForkAuthenticator()
    private var signInTask: Task<Void, Never>?
    private var backendTask: Task<Void, Never>?

    init() {
        // Wire ProtonCore's CryptoGo to the patched GopenPGP implementation before any crypto runs.
        injectDefaultCryptoImplementation()
    }

    /// Restore a persisted session on launch.
    func bootstrap() {
        if let session = store.load() {
            // Re-save once under the current app signature. This migrates older debug Keychain items whose
            // ACL was bound to a previous local build identity, without introducing any plaintext fallback.
            store.save(session)
            auth = .signedIn(session)
            prepareBackend(session)
        } else {
            auth = .signedOut(error: nil)
        }
    }

    func signIn() {
        signInTask?.cancel()
        auth = .authenticating(status: "Requesting sign-in link…")
        signInTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try await authenticator.authenticate(
                    openURL: { url in Task { @MainActor in NSWorkspace.shared.open(url) } },
                    onProgress: { progress in Task { @MainActor [weak self] in self?.apply(progress) } }
                )
                store.save(session)
                auth = .signedIn(session)
                prepareBackend(session)
            } catch is CancellationError {
                auth = .signedOut(error: nil)
            } catch {
                auth = .signedOut(error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    func cancelSignIn() {
        signInTask?.cancel()
        signInTask = nil
        auth = .signedOut(error: nil)
    }

    func signOut() {
        backendTask?.cancel()
        backend = .idle
        facade = nil
        // Erase the account's encrypted thumbnail/preview blobs + any legacy cache keys and streamed video
        // blocks before dropping the session, so nothing decryptable is left for the signed-out account.
        OfflineLibraryManager.shared.purgeOnSignOut()
        store.clear()
        auth = .signedOut(error: nil)
    }

    func retryBackend() {
        if case let .signedIn(session) = auth { prepareBackend(session) }
    }

    private func prepareBackend(_ session: ProtonSession) {
        backendTask?.cancel()
        // Install the per-account encrypted-cache key derived from the restored session (and purge any legacy
        // plaintext cache) before the grid renders or the crawl begins.
        OfflineLibraryManager.shared.configure(session: session)
        backend = .preparing("Building your library…")
        backendTask = Task { [weak self] in
            guard let self else { return }
            do {
                let bridge = try await DriveSDKBridge(session: session, store: store)
                SDKCapabilities.current.log()
                facade = ProtonClientFacade.make(bridge: bridge)
                backend = .ready(bridge)
            } catch is CancellationError {
                // ignore
            } catch {
                DebugLog.log("backend prepare FAILED: \(error)")
                backend = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
        }
    }

    private func apply(_ progress: ProtonForkAuthenticator.Progress) {
        switch progress {
        case .requestingLink: auth = .authenticating(status: "Requesting sign-in link…")
        case .waitingForBrowser: auth = .authenticating(status: "Waiting for you to sign in in your browser…")
        case .finalizing: auth = .authenticating(status: "Finishing sign-in…")
        }
    }
}
