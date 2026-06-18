import Foundation

enum UploadUITrigger: String {
    case toolbar
    case menu
}

/// Notifications posted by the File-menu / toolbar upload commands (which live in the App scene) and
/// observed by `MainView` (which owns the upload coordinator + can present panels).
extension Notification.Name {
    static let protonPhotosUploadPhotos = Notification.Name("ProtonPhotos.uploadPhotos")
    static let protonPhotosUploadFolder = Notification.Name("ProtonPhotos.uploadFolder")
    static let protonPhotosShowUploadQueue = Notification.Name("ProtonPhotos.showUploadQueue")
    static let protonPhotosRefreshLibrary = Notification.Name("ProtonPhotos.refreshLibrary")
}

func uploadCommandUserInfo(trigger: UploadUITrigger) -> [AnyHashable: Any] {
    ["trigger": trigger.rawValue]
}

func uploadTrigger(from notification: Notification) -> UploadUITrigger {
    guard let raw = notification.userInfo?["trigger"] as? String,
          let trigger = UploadUITrigger(rawValue: raw) else {
        return .menu
    }
    return trigger
}
