import SwiftUI
import DesignSystem

@main
struct ProtonPhotosApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 720, minHeight: 480)
                .preferredColorScheme(.dark)
                .task { model.bootstrap() }
        }
        .defaultSize(width: 1080, height: 720)
    }
}

struct RootView: View {
    let model: AppModel

    var body: some View {
        switch model.auth {
        case .checking:
            ProtonLoadingView()
        case .signedOut, .authenticating:
            LoginView(model: model)
        case .signedIn:
            signedIn
        }
    }

    @ViewBuilder private var signedIn: some View {
        switch model.backend {
        case let .ready(backend):
            MainView(model: model, backend: backend)
        case let .failed(message):
            BackendErrorView(message: message, retry: { model.retryBackend() }, signOut: { model.signOut() })
        case .preparing, .idle:
            ProtonLoadingView(caption: "Building your library…")
        }
    }
}

private struct BackendErrorView: View {
    let message: String
    let retry: () -> Void
    let signOut: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.icloud")
                .font(.system(size: 42))
                .foregroundStyle(ProtonColor.warning)
            Text("Couldn’t open your library")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ProtonColor.textNorm)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(ProtonColor.textWeak)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button("Retry", action: retry).buttonStyle(.proton).frame(width: 120)
                Button("Sign out", action: signOut)
                    .buttonStyle(.plain)
                    .foregroundStyle(ProtonColor.textHint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
    }
}
