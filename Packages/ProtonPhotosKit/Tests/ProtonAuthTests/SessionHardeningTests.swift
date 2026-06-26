import Foundation
import Testing
@testable import ProtonAuth

/// Session secrets must never have a plaintext developer bypass. Tokens and the key password are always
/// stored in the macOS Keychain.
@Suite("Session secret hardening")
struct SessionHardeningTests {
    @Test func noDeveloperPlaintextSessionSwitchExists() {
        #expect(ProcessInfo.processInfo.environment["PROTONPHOTOS_DEV_PLAINTEXT_SESSION"] == nil)
    }

    @Test func roundTripsThroughKeychain() {
        // Use a unique service so the test never collides with a real stored session.
        let store = SessionKeychainStore(service: "me.protonphotos.mac.session.tests-\(UUID().uuidString)")
        let session = ProtonSession(uid: "uid-test", accessToken: "at", refreshToken: "rt", keyPassword: "kp")
        store.save(session)
        defer { store.clear() }

        #expect(store.load() == session)
        store.clear()
        #expect(store.load() == nil)
    }
}
