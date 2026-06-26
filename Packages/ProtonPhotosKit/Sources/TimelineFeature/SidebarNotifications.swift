import Foundation

public extension Notification.Name {
    /// Posted by the app shell (menu / shortcut) to toggle the sidebar; observed by the main view.
    static let protonPhotosToggleSidebar = Notification.Name("ProtonPhotos.toggleSidebar")
}
