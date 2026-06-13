import Foundation
import AppKit
import ProtonAuth

/// Root application state + composition. Owns the session lifecycle and wires the
/// concrete service implementations into the feature modules.
@MainActor
@Observable
final class AppModel {
    enum AuthState: Equatable {
        case checking
        case signedOut(error: String?)
        case authenticating(status: String)
        case signedIn(ProtonSession)
    }

    private(set) var auth: AuthState = .checking

    private let store = SessionKeychainStore()
    private let authenticator = ProtonForkAuthenticator()
    private var signInTask: Task<Void, Never>?

    /// Restore a persisted session on launch.
    func bootstrap() {
        if let session = store.load() {
            auth = .signedIn(session)
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
                    openURL: { url in
                        Task { @MainActor in NSWorkspace.shared.open(url) }
                    },
                    onProgress: { progress in
                        Task { @MainActor [weak self] in self?.apply(progress) }
                    }
                )
                store.save(session)
                auth = .signedIn(session)
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
        store.clear()
        auth = .signedOut(error: nil)
    }

    private func apply(_ progress: ProtonForkAuthenticator.Progress) {
        switch progress {
        case .requestingLink:
            auth = .authenticating(status: "Requesting sign-in link…")
        case .waitingForBrowser:
            auth = .authenticating(status: "Waiting for you to sign in in your browser…")
        case .finalizing:
            auth = .authenticating(status: "Finishing sign-in…")
        }
    }
}
