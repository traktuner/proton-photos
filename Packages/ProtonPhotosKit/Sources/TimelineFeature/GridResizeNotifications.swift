import Foundation

// App-shell ↔ timeline notifications. Extracted from the (deleted) legacy grid-resize stabilizer; the
// Metal grid relayouts natively in `layout()`, so the resize hint currently has no consumer in the grid
// (it stays for the app shell's sidebar drag/toggle bracketing and as a stable public surface).

public extension Notification.Name {
    /// Posted by the app shell to bracket a sidebar drag / toggle. `userInfo`: `reason` (raw
    /// `GridResizeReason`), `phase` ("begin" / "change" / "end").
    static let protonPhotosGridResizeHint = Notification.Name("ProtonPhotos.gridResizeHint")
    /// Posted by the app shell (menu / shortcut) to toggle the sidebar; observed by the main view.
    static let protonPhotosToggleSidebar = Notification.Name("ProtonPhotos.toggleSidebar")
}

/// Why the grid is being resized. Drives the app shell's resize-hint logging; the grid itself relayouts
/// natively regardless of the reason.
public enum GridResizeReason: String, Sendable, Equatable {
    case windowResize
    case sidebarDrag
    case sidebarToggle
}
