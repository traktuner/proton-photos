import ProtonAuth
import ProtonCoreCryptoPatchedGoImplementation
import SwiftUI
import UIKit

/// Owns the Proton auth lifecycle for the iOS/iPadOS app. This is a thin platform shell over the shared
/// `ProtonAuthController` — the same controller macOS drives — so auth behavior is not forked per platform.
@MainActor
final class MobileSessionModel: ObservableObject {
    static let signInPrompt = String(localized: "auth.sign_in_prompt")

    @Published private(set) var session: ProtonSession?
    @Published private(set) var isSigningIn = false
    @Published private(set) var statusText = MobileSessionModel.signInPrompt
    @Published private(set) var errorText: String?

    let sessionStore = SessionKeychainStore()
    private let authController: ProtonAuthController

    init() {
        injectDefaultCryptoImplementation()
        self.authController = ProtonAuthController(
            store: sessionStore,
            authenticator: ProtonForkAuthenticator(config: .externalDriveProtonPhotos)
        )
        apply(authController.bootstrap())
    }

    func signIn() {
        authController.signIn(
            openURL: { url in
                Task { @MainActor in UIApplication.shared.open(url) }
            },
            onStateChange: { [weak self] state in
                self?.apply(state)
            }
        )
    }

    func signOut() {
        apply(authController.signOut())
    }

    private func apply(_ state: ProtonAuthState) {
        switch state {
        case .checking:
            session = nil
            isSigningIn = false
            errorText = nil
            statusText = String(localized: "auth.checking_session")
        case let .signedOut(error):
            session = nil
            isSigningIn = false
            errorText = error
            statusText = error == nil ? Self.signInPrompt : String(localized: "auth.sign_in_failed")
        case let .authenticating(progress):
            session = nil
            isSigningIn = true
            errorText = nil
            statusText = Self.label(for: progress)
        case let .signedIn(session):
            self.session = session
            isSigningIn = false
            errorText = nil
            statusText = String(localized: "auth.signed_in")
        }
    }

    private static func label(for progress: ProtonForkAuthenticator.Progress) -> String {
        switch progress {
        case .requestingLink: String(localized: "auth.requesting_link")
        case .waitingForBrowser: String(localized: "auth.waiting_for_browser")
        case .finalizing: String(localized: "auth.finalizing")
        }
    }
}
