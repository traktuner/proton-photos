import SwiftUI
import AppKit
import DesignSystem
import GridZoomV3
import TimelineFeature

@main
struct ProtonPhotosApp: App {
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 720, minHeight: 480)
                .preferredColorScheme(.dark)
                .background(WindowConfigurator())
                .task { model.bootstrap() }
        }
        .defaultSize(width: 1080, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Upload Photos…") {
                    NotificationCenter.default.post(
                        name: .protonPhotosUploadPhotos,
                        object: nil,
                        userInfo: uploadCommandUserInfo(trigger: .menu)
                    )
                }
                .keyboardShortcut("u", modifiers: [.command])
                Button("Upload Folder…") {
                    NotificationCenter.default.post(
                        name: .protonPhotosUploadFolder,
                        object: nil,
                        userInfo: uploadCommandUserInfo(trigger: .menu)
                    )
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()
                Button("Show Uploads") {
                    NotificationCenter.default.post(
                        name: .protonPhotosShowUploadQueue,
                        object: nil,
                        userInfo: uploadCommandUserInfo(trigger: .menu)
                    )
                }
            }
            CommandGroup(after: .sidebar) {
                Button("Toggle Sidebar") {
                    NotificationCenter.default.post(name: .protonPhotosToggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Button("Refresh Library") {
                    NotificationCenter.default.post(name: .protonPhotosRefreshLibrary, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            // Debug ▸ open the isolated Grid-Zoom V3 prototype (synthetic tiles, no Proton data).
            CommandMenu("Debug") {
                Button("GridZoom V3 Lab…") { openWindow(id: GridZoomV3WindowID) }
                    .keyboardShortcut("g", modifiers: [.command, .option, .shift])
            }
        }

        // Native macOS Settings window → "ProtonPhotos ▸ Einstellungen…" (⌘,).
        Settings {
            SettingsView()
        }

        // Dev: live animation-tuning panel (opened from MainView at launch).
        Window("Animation Tuning", id: "anim-tuning") {
            TuningView()
        }
        .defaultSize(width: 340, height: 460)
        .defaultPosition(.topTrailing)

        // Dev: isolated Grid-Zoom V3 prototype lab (Debug ▸ GridZoom V3 Lab… / ⌥⇧⌘G).
        Window("GridZoom V3 Lab", id: GridZoomV3WindowID) {
            GridZoomV3Lab()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1100, height: 760)
    }
}

let GridZoomV3WindowID = "gridzoom-v3-lab"

/// Makes the window title bar transparent + full-size, so content (the photo grid) extends up under
/// the translucent Liquid-Glass toolbar — you see photos scroll through behind it, like Apple Photos.
/// Also installs the frame save/restore controller (Deliverable 6).
private struct WindowConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window, context.coordinator) }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { configure(nsView.window, context.coordinator) }
    }
    private func configure(_ window: NSWindow?, _ coordinator: Coordinator) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.titleVisibility = .hidden
        coordinator.frameController.attach(to: window)
    }

    @MainActor final class Coordinator {
        let frameController = MainWindowFrameController(defaultSize: CGSize(width: 1080, height: 720))
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
        case .ready:
            if let facade = model.facade {
                MainView(model: model, facade: facade)
            } else {
                ProtonLoadingView(caption: "Building your library…")
            }
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
                Button("Retry", action: retry).buttonStyle(.glassProminent).frame(width: 120)
                Button("Sign out", action: signOut)
                    .buttonStyle(.plain)
                    .foregroundStyle(ProtonColor.textHint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
    }
}
