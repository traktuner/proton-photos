import ProtonAuth
import ProtonCoreCryptoPatchedGoImplementation
import SwiftUI
import UIKit

/// Owns the Proton auth lifecycle for the iOS/iPadOS app. This is a thin platform shell over the shared
/// `ProtonAuthController` — the same controller macOS drives — so auth behavior is not forked per platform.
@MainActor
final class MobileSessionModel: ObservableObject {
    /// Natural-English copy is used directly as the localization key so the UI always shows real text (and a
    /// String Catalog can translate it later) — never an internal identifier.
    static let signInPrompt = String(localized: "Sign in with your Proton account to see your photos.")

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
            statusText = String(localized: "Checking your session…")
        case let .signedOut(error):
            session = nil
            isSigningIn = false
            errorText = error
            statusText = error == nil ? Self.signInPrompt : String(localized: "Sign-in failed.")
        case let .authenticating(progress):
            session = nil
            isSigningIn = true
            errorText = nil
            statusText = Self.label(for: progress)
        case let .signedIn(session):
            self.session = session
            isSigningIn = false
            errorText = nil
            statusText = String(localized: "Signed in.")
        }
    }

    private static func label(for progress: ProtonForkAuthenticator.Progress) -> String {
        switch progress {
        case .requestingLink: String(localized: "Requesting a sign-in link…")
        case .waitingForBrowser: String(localized: "Complete sign-in in Safari…")
        case .finalizing: String(localized: "Finalizing your session…")
        }
    }
}
