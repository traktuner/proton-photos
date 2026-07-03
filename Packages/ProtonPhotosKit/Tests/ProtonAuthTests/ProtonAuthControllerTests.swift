import Foundation
import Testing
@testable import ProtonAuth

@Suite("Shared auth lifecycle")
struct ProtonAuthControllerTests {
    @MainActor
    @Test func bootstrapRestoresAndResavesPersistedSession() {
        let session = ProtonSession(uid: "uid-restored", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
        let store = FakeSessionStore(initial: session)
        let controller = ProtonAuthController(store: store, authenticator: FakeAuthenticator(session: session))

        #expect(controller.bootstrap() == .signedIn(session))
        #expect(controller.currentSession == session)
        #expect(store.savedSessions() == [session])
    }

    @MainActor
    @Test func signInPublishesProgressPersistsSessionAndOpensURL() async {
        let session = ProtonSession(uid: "uid-signed-in", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
        let signInURL = URL(string: "https://account.proton.me/desktop/login")!
        let store = FakeSessionStore()
        let openedURL = URLRecorder()
        let controller = ProtonAuthController(
            store: store,
            authenticator: FakeAuthenticator(
                session: session,
                signInURL: signInURL,
                progress: [.waitingForBrowser, .finalizing]
            )
        )
        var states: [ProtonAuthState] = []

        controller.signIn(
            openURL: { url in
                Task { await openedURL.record(url) }
            },
            onStateChange: { state in
                states.append(state)
            }
        )

        #expect(await waitUntil { controller.state == .signedIn(session) })
        #expect(await openedURL.value() == signInURL)
        #expect(store.savedSessions() == [session])
        #expect(states.contains(.authenticating(.requestingLink)))
        #expect(states.contains(.authenticating(.waitingForBrowser)))
        #expect(states.contains(.authenticating(.finalizing)))
        #expect(states.last == .signedIn(session))
    }

    @MainActor
    @Test func signInFailurePublishesSignedOutErrorWithoutSaving() async {
        let store = FakeSessionStore()
        let controller = ProtonAuthController(
            store: store,
            authenticator: FakeAuthenticator(error: FakeAuthError.offline)
        )

        controller.signIn(openURL: { _ in })

        #expect(await waitUntil {
            if case .signedOut(error: "offline") = controller.state { return true }
            return false
        })
        #expect(store.savedSessions().isEmpty)
    }

    @MainActor
    @Test func signOutClearsSharedStore() {
        let session = ProtonSession(uid: "uid-out", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
        let store = FakeSessionStore(initial: session)
        let controller = ProtonAuthController(store: store, authenticator: FakeAuthenticator(session: session))
        _ = controller.bootstrap()

        #expect(controller.signOut() == .signedOut(error: nil))
        #expect(controller.currentSession == nil)
        #expect(store.clearCount() == 1)
    }
}

@MainActor
private func waitUntil(_ predicate: @escaping () -> Bool) async -> Bool {
    for _ in 0 ..< 100 {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}

private final class FakeSessionStore: ProtonSessionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ProtonSession?
    private var saved: [ProtonSession] = []
    private var clears = 0

    init(initial: ProtonSession? = nil) {
        stored = initial
    }

    func load() -> ProtonSession? {
        lock.withLock { stored }
    }

    func save(_ session: ProtonSession) {
        lock.withLock {
            stored = session
            saved.append(session)
        }
    }

    func clear() {
        lock.withLock {
            stored = nil
            clears += 1
        }
    }

    func savedSessions() -> [ProtonSession] {
        lock.withLock { saved }
    }

    func clearCount() -> Int {
        lock.withLock { clears }
    }
}

private struct FakeAuthenticator: ProtonAuthenticating {
    let session: ProtonSession
    let signInURL: URL
    let progress: [ProtonForkAuthenticator.Progress]
    let error: Error?

    init(
        session: ProtonSession = ProtonSession(uid: "uid", accessToken: "at", refreshToken: "rt", keyPassword: "kp"),
        signInURL: URL = URL(string: "https://account.proton.me/desktop/login")!,
        progress: [ProtonForkAuthenticator.Progress] = [],
        error: Error? = nil
    ) {
        self.session = session
        self.signInURL = signInURL
        self.progress = progress
        self.error = error
    }

    func authenticate(
        openURL: @escaping @Sendable (URL) -> Void,
        onProgress: @escaping @Sendable (ProtonForkAuthenticator.Progress) -> Void
    ) async throws -> ProtonSession {
        if let error { throw error }
        openURL(signInURL)
        for progress in progress {
            onProgress(progress)
            await Task.yield()
        }
        return session
    }
}

private actor URLRecorder {
    private var recorded: URL?

    func record(_ url: URL) {
        recorded = url
    }

    func value() -> URL? {
        recorded
    }
}

private enum FakeAuthError: LocalizedError {
    case offline

    var errorDescription: String? {
        "offline"
    }
}
