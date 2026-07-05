import SwiftUI
import AppKit
import DesignSystemCore

// MARK: - Loading veil building blocks (macOS)
//
// A native, macOS-style "launch veil" for the brief initial library/session preparation - NOT a branded
// splash and NOT an opaque/black screen. The model is Apple's own startup veil: the whole window becomes a
// frosted Liquid-Glass surface that you see straight through to the desktop / other windows behind it (the
// app shell is NOT drawn yet), with a small semi-transparent mark breathing in the center; once the library
// is ready the veil quickly fades into the real UI.
//
//   • `FrostedGlassBackground` - a behind-window `NSVisualEffectView` (sees the desktop through a
//                                transparent window). The window must be non-opaque for the desktop to show.
//   • `LoadingMark`            - lives in `DesignSystemCore` (pure SwiftUI, shared with iOS); this adapter
//                                owns only the genuinely-AppKit frosted surface behind it.
//
// The window-transparency toggle + min-on-screen + crossfade-out live next to the app's window setup, where
// the `NSWindow` is owned.

/// Behind-window frosted glass. With the host window made non-opaque, this samples and blurs whatever is
/// *behind the window* - the desktop and other apps - for a true frosted-glass veil (Liquid-Glass material,
/// public AppKit API, never an opaque rectangle).
public struct FrostedGlassBackground: NSViewRepresentable {
    private let material: NSVisualEffectView.Material

    public init(material: NSVisualEffectView.Material = .fullScreenUI) {
        self.material = material
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow      // sample the desktop behind a transparent window, not app content
        view.material = material
        view.state = .active                   // stay frosted even when the window is inactive
        return view
    }

    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}
