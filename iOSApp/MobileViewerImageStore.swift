import os
import PhotosCore

/// Debug-only viewer loading diagnostics for the app-side viewer pages. The display-image store itself
/// (fetch → bounded decode → cache, plus its memory-pressure behavior) is the shared
/// `UIKitViewerImageStore` in `PhotoViewerUIKitAdapter`.
enum MobileViewerLog {
    static let logger = Logger(subsystem: "me.protonphotos.ios", category: "ViewerPerf")
    #if DEBUG
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    static func short(_ uid: PhotoUID) -> String { String(uid.nodeID.suffix(6)) }
}
