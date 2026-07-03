import Foundation
import MediaCacheUIKitAdapter
import os
import PhotosCore
import PhotoViewerUIKitAdapter
import QuartzCore
import UIKit

/// os_log diagnostics for the viewer's staged loading, at `.notice` so a plain `log stream` capture (no
/// `--level debug`) separates viewer fetch/decode/display stalls from grid work. Low volume — per page action,
/// never per frame.
enum MobileViewerLog {
    static let logger = Logger(subsystem: "me.protonphotos.ios", category: "ViewerPerf")

    static func short(_ uid: PhotoUID) -> String { String(uid.nodeID.suffix(6)) }
}

/// Bounded, shared image loader for the full-screen viewer pages — the iOS surface of the shared
/// ``ViewerImageLoadPolicy``.
///
/// It shows the grid thumbnail instantly, then loads a mid-size `preview` (NOT the full original) decoded to a
/// screen-bounded size OFF the main thread, and caches it. It never decodes a full original just because a page
/// appeared during a swipe, and the cache is small + cost-limited (~48 MB) so back-and-forth paging reuses work
/// without growing memory without bound.
@MainActor
final class MobileViewerImageStore {
    private let feed: UIKitThumbnailFeed?
    private let media: (any FullMediaProvider)?
    private let cache = NSCache<NSString, UIImage>()

    init(feed: UIKitThumbnailFeed?, media: (any FullMediaProvider)?) {
        self.feed = feed
        self.media = media
        cache.countLimit = 8
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    /// The instant grid thumbnail (already decoded in the feed's RAM tier), or nil.
    func thumbnail(for uid: PhotoUID) -> UIImage? { feed?.memoryImage(for: uid) }

    /// The bounded mid-size DISPLAY image for `uid`: cache → else fetch `preview` + bounded off-main decode, cached.
    /// Returns nil (caller keeps the thumbnail) on failure. Honors Task cancellation, so a swiped-away page's
    /// in-flight decode never sets a stale image.
    func displayImage(for uid: PhotoUID, maxPixelSize: Int) async -> UIImage? {
        let key = Self.key(uid)
        if let cached = cache.object(forKey: key) { return cached }
        guard let media else { return nil }

        let fetchStart = CACurrentMediaTime()
        MobileViewerLog.logger.notice("[ViewerPerf] preview fetch start uid=\(MobileViewerLog.short(uid), privacy: .public)")
        let data: Data
        do {
            data = try await media.preview(for: uid)
        } catch {
            MobileViewerLog.logger.notice("[ViewerPerf] preview fetch fail uid=\(MobileViewerLog.short(uid), privacy: .public)")
            return nil
        }
        if Task.isCancelled {
            MobileViewerLog.logger.notice("[ViewerPerf] preview cancelled uid=\(MobileViewerLog.short(uid), privacy: .public)")
            return nil
        }
        let fetchMs = (CACurrentMediaTime() - fetchStart) * 1000

        let decodeStart = CACurrentMediaTime()
        let image = await Task.detached(priority: .userInitiated) {
            UIKitViewerImageAdapter.image(from: data, maxPixelSize: maxPixelSize)
        }.value
        if Task.isCancelled { return nil }
        guard let image else {
            MobileViewerLog.logger.notice("[ViewerPerf] decode fail uid=\(MobileViewerLog.short(uid), privacy: .public)")
            return nil
        }
        let decodeMs = (CACurrentMediaTime() - decodeStart) * 1000
        let px = image.size.applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
        cache.setObject(image, forKey: key, cost: Int(px.width * px.height) * 4)
        MobileViewerLog.logger.notice("""
        [ViewerPerf] preview ready uid=\(MobileViewerLog.short(uid), privacy: .public) \
        px=\(Int(px.width))x\(Int(px.height)) fetchMs=\(String(format: "%.0f", fetchMs), privacy: .public) \
        decodeMs=\(String(format: "%.0f", decodeMs), privacy: .public) bytes=\(data.count)
        """)
        return image
    }

    private static func key(_ uid: PhotoUID) -> NSString { "\(uid.volumeID)~\(uid.nodeID)" as NSString }
}
