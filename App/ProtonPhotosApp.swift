import SwiftUI
import AppKit
import DesignSystem
import TimelineFeature

@main
struct ProtonPhotosApp: App {
    @NSApplicationDelegateAdaptor(ProtonPhotosAppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    init() {
        // `.help(...)` tooltips use AppKit's initial hover delay, which defaults to ~1–2 s. SwiftUI exposes no
        // per-view delay, so we shorten it APP-WIDE: 400 ms keeps tooltips snappy (e.g. the library-preparing
        // pill's live percent) without firing on every incidental pass over a control.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 400])
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 720, minHeight: 480)
                .background(WindowConfigurator())
                .launchVeil(active: model.isPreparing)
                .task { model.bootstrap() }
        }
        .defaultSize(width: 1080, height: 720)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .newItem) {
                Button("menu.upload_photos") {
                    NotificationCenter.default.post(
                        name: .protonPhotosUploadPhotos,
                        object: nil,
                        userInfo: uploadCommandUserInfo(trigger: .menu)
                    )
                }
                .keyboardShortcut("u", modifiers: [.command])
                Button("menu.upload_folder") {
                    NotificationCenter.default.post(
                        name: .protonPhotosUploadFolder,
                        object: nil,
                        userInfo: uploadCommandUserInfo(trigger: .menu)
                    )
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()
                Button("menu.show_uploads") {
                    NotificationCenter.default.post(
                        name: .protonPhotosShowUploadQueue,
                        object: nil,
                        userInfo: uploadCommandUserInfo(trigger: .menu)
                    )
                }
            }
            CommandGroup(after: .sidebar) {
                Button("menu.toggle_sidebar") {
                    NotificationCenter.default.post(name: .protonPhotosToggleSidebar, object: nil)
                }
                .keyboardShortcut("s", modifiers: [.command, .option])
                Button("menu.refresh_library") {
                    NotificationCenter.default.post(name: .protonPhotosRefreshLibrary, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        // Native macOS Settings window -> "Proton Photos > Einstellungen..." (Command-,).
        Settings {
            SettingsView(uploadCoordinator: model.facade?.uploadCoordinator, signOut: { model.signOut() })
        }

    }
}

final class ProtonPhotosAppDelegate: NSObject, NSApplicationDelegate {
    private let singleInstanceGuard = SingleInstanceGuard()

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard singleInstanceGuard.acquire() else {
            NSApp.terminate(nil)
            return
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            sender.windows.first?.makeKeyAndOrderFront(nil)
        }
        return true
    }
}

/// Makes the window title bar transparent + full-size, so content (the photo grid) extends up under
/// the translucent Liquid-Glass toolbar - you see photos scroll through behind it, like Apple Photos.
/// Also installs the frame save/restore controller.
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

// MARK: - Launch veil
//
// While the app is preparing the session/library, the WHOLE window becomes a frosted, behind-window
// Liquid-Glass surface you see straight through to the desktop / other windows - the app shell is not drawn
// behind it. When preparation finishes, the veil quickly crossfades to reveal the real library window.

private extension View {
    /// Covers the whole window with the frosted launch veil while `active`, holds it for a brief anti-flicker
    /// minimum, then crossfades it away to reveal the real UI.
    func launchVeil(active: Bool) -> some View { modifier(LaunchVeilModifier(active: active)) }
}

private struct LaunchVeilModifier: ViewModifier {
    let active: Bool

    @State private var visible = true
    @State private var appearedAt = Date()
    @State private var dismissScheduled = false
    private let minShown: Double = 0.5
    /// Safety net: never trap the user behind the veil if preparation hangs (e.g. an offline/stalled first
    /// load that never reaches loaded/empty/failed). After this it fades regardless, revealing the UI behind.
    private let maxShown: Double = 8

    func body(content: Content) -> some View {
        content
            // Make the window non-opaque while the veil shows, so the behind-window frost reveals the desktop.
            .background(WindowTransparency(transparent: visible))
            .overlay {
                if visible {
                    FrostedGlassBackground()
                        .overlay { LoadingMark().frame(width: 64, height: 64) }
                        .ignoresSafeArea()
                        .transition(.opacity)
                }
            }
            .onAppear {
                // A window born already-ready (a second window, or relaunch after the library loaded) must
                // never go transparent - only veil when there is genuinely something to prepare.
                if !active { visible = false; dismissScheduled = true }
                scheduleDismissIfReady()
                if visible { scheduleHardDismiss() }
            }
            .onChange(of: active) { _, nowActive in
                if nowActive {
                    // A fresh preparation cycle (e.g. sign-out → re-login) re-raises the veil.
                    dismissScheduled = false
                    appearedAt = Date()
                    withAnimation(.easeIn(duration: 0.2)) { visible = true }
                    scheduleHardDismiss()
                } else {
                    scheduleDismissIfReady()
                }
            }
    }

    /// Once preparation has finished, keep the veil for the remainder of `minShown` (anti-flicker) and then
    /// crossfade it out. Runs at most once.
    private func scheduleDismissIfReady() {
        guard visible, !dismissScheduled, !active else { return }
        dismissScheduled = true
        let remaining = max(0, minShown - Date().timeIntervalSince(appearedAt))
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
            withAnimation(.easeOut(duration: 0.3)) { visible = false }
        }
    }

    private func scheduleHardDismiss() {
        DispatchQueue.main.asyncAfter(deadline: .now() + maxShown) {
            if visible { withAnimation(.easeOut(duration: 0.3)) { visible = false } }
        }
    }
}

/// Toggles the host window's opacity. While `transparent`, the window is non-opaque with a clear backing so a
/// behind-window `NSVisualEffectView` can show the desktop; otherwise the window's original (opaque) backing
/// is restored. The original values are captured once so the real library window is left exactly as it was.
private struct WindowTransparency: NSViewRepresentable {
    let transparent: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let transparent = self.transparent
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            let coordinator = context.coordinator
            if !coordinator.captured {
                coordinator.originalOpaque = window.isOpaque
                coordinator.originalBackground = window.backgroundColor
                coordinator.captured = true
            }
            if transparent {
                window.isOpaque = false
                window.backgroundColor = .clear
            } else {
                window.isOpaque = coordinator.originalOpaque
                window.backgroundColor = coordinator.originalBackground ?? .windowBackgroundColor
            }
        }
    }

    @MainActor final class Coordinator {
        var captured = false
        var originalOpaque = true
        var originalBackground: NSColor?
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
                ProtonLoadingView(caption: String(localized: "loading.building_library"))
            }
        case let .failed(message):
            BackendErrorView(message: message, retry: { model.retryBackend() }, signOut: { model.signOut() })
        case .preparing, .idle:
            ProtonLoadingView(caption: String(localized: "loading.building_library"))
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
            Text("error.library_open_failed")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(ProtonColor.textNorm)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(ProtonColor.textWeak)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 10) {
                Button("action.retry", action: retry).buttonStyle(.glassProminent).frame(width: 120)
                Button("action.sign_out", action: signOut)
                    .buttonStyle(.plain)
                    .foregroundStyle(ProtonColor.textHint)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ProtonColor.backgroundNorm)
    }
}
