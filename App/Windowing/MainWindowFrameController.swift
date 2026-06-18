import AppKit
import PhotosCore

/// Persists + restores the main window's frame across launches (Deliverable 6). We drive this
/// manually (rather than `setFrameAutosaveName`) so restoration always runs through
/// `WindowFramePolicy` — which validates the saved frame against the *current* screens and re-centres
/// safely if the old display is gone — and so the save/restore math stays unit-testable. System
/// state restoration is disabled on the window to avoid a double-restore fighting ours.
@MainActor
final class MainWindowFrameController {
    private let key = AppSettingsKey.mainWindowFrame
    private let defaultSize: CGSize
    private weak var window: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var restored = false

    init(defaultSize: CGSize) { self.defaultSize = defaultSize }

    func attach(to window: NSWindow) {
        guard self.window !== window else { return }
        detach()
        self.window = window
        window.isRestorable = false
        restoreFrame(into: window)

        let nc = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification] {
            observers.append(nc.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.save() }
            })
        }
    }

    private func detach() {
        let nc = NotificationCenter.default
        observers.forEach(nc.removeObserver)
        observers.removeAll()
    }

    private func restoreFrame(into window: NSWindow) {
        guard !restored else { return }
        restored = true
        guard let saved = UserDefaults.standard.string(forKey: key), !saved.isEmpty else { return }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let valid = WindowFramePolicy.validate(NSRectFromString(saved), screens: screens, fallbackSize: defaultSize)
        window.setFrame(valid, display: true)
    }

    private func save() {
        guard let window else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: key)
    }
}
