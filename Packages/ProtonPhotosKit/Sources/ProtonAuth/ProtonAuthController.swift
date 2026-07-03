import Foundation

public protocol ProtonSessionStorage: Sendable {
    func load() -> ProtonSession?
    func save(_ session: ProtonSession)
    func clear()
}

extension SessionKeychainStore: ProtonSessionStorage {}

public protocol ProtonAuthenticating: Sendable {
    func authenticate(
        openURL: @escaping @Sendable (URL) -> Void,
        onProgress: @escaping @Sendable (ProtonForkAuthenticator.Progress) -> Void
    ) async throws -> ProtonSession
}

extension ProtonForkAuthenticator: ProtonAuthenticating {}

public enum ProtonAuthState: Equatable, Sendable {
    case checking
    case signedOut(error: String?)
    case authenticating(ProtonForkAuthenticator.Progress)
    case signedIn(ProtonSession)

    public var session: ProtonSession? {
        guard case let .signedIn(session) = self else { return nil }
        return session
    }
}

/// Platform-neutral session lifecycle around Proton's fork-auth flow.
///
/// UI targets provide only the platform browser opener and presentation strings. Token/key-password
/// persistence, fork progress, cancellation, and state transitions stay shared across macOS, iOS, and iPadOS.
@MainActor
public final class ProtonAuthController {
    public private(set) var state: ProtonAuthState = .checking

    private let store: any ProtonSessionStorage
    private let authenticator: any ProtonAuthenticating
    private var signInTask: Task<Void, Never>?

    public init(
        store: any ProtonSessionStorage = SessionKeychainStore(),
        authenticator: any ProtonAuthenticating
    ) {
        self.store = store
        self.authenticator = authenticator
    }

    public var currentSession: ProtonSession? {
        state.session
    }

    @discardableResult
    public func bootstrap() -> ProtonAuthState {
        if let session = store.load() {
            // Re-save once under the current app signature. This migrates older debug Keychain items whose
            // ACL was bound to a previous local build identity, without introducing any plaintext fallback.
            store.save(session)
            return setState(.signedIn(session))
        }
        return setState(.signedOut(error: nil))
    }

    public func signIn(
        openURL: @escaping @Sendable (URL) -> Void,
        onStateChange: @escaping @MainActor (ProtonAuthState) -> Void = { _ in }
    ) {
        signInTask?.cancel()
        setState(.authenticating(.requestingLink), notify: onStateChange)
        signInTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let session = try await authenticator.authenticate(
                    openURL: openURL,
                    onProgress: { progress in
                        Task { @MainActor [weak self] in
                            self?.setState(.authenticating(progress), notify: onStateChange)
                        }
                    }
                )
                try Task.checkCancellation()
                store.save(session)
                signInTask = nil
                setState(.signedIn(session), notify: onStateChange)
            } catch is CancellationError {
                signInTask = nil
                setState(.signedOut(error: nil), notify: onStateChange)
            } catch {
                signInTask = nil
                setState(.signedOut(error: Self.message(for: error)), notify: onStateChange)
            }
        }
    }

    @discardableResult
    public func cancelSignIn() -> ProtonAuthState {
        signInTask?.cancel()
        signInTask = nil
        return setState(.signedOut(error: nil))
    }

    @discardableResult
    public func signOut() -> ProtonAuthState {
        signInTask?.cancel()
        signInTask = nil
        store.clear()
        return setState(.signedOut(error: nil))
    }

    @discardableResult
    private func setState(
        _ newState: ProtonAuthState,
        notify: (@MainActor (ProtonAuthState) -> Void)? = nil
    ) -> ProtonAuthState {
        state = newState
        notify?(newState)
        return newState
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
