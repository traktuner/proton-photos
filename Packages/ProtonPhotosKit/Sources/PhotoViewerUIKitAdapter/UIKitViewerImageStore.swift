#if canImport(UIKit) && !os(watchOS)
import Foundation
import MediaCacheCore
import os
import PhotosCore
import QuartzCore
import UIKit

/// Bounded, shared image loader for the full-screen viewer pages — the iOS surface of the shared
/// ``ViewerImageLoadPolicy``, now owned by the UIKit viewer adapter so every host app shares one
/// implementation (and its memory-pressure behavior) instead of re-rolling it per app target.
///
/// It shows the grid thumbnail instantly (via the injected provider, so this module never depends on a
/// concrete feed type), then loads a mid-size `preview` decoded to a screen-bounded size OFF the main
/// thread, and caches it. If Proton has no preview for the item, the current page falls back to original
/// bytes but still decodes only to the same screen-bounded display size. It never decodes a full original
/// just because a page appeared during a swipe, and the cache is small + cost-limited (~48 MB) so
/// back-and-forth paging reuses work without growing memory without bound.
///
/// Memory pressure: `applyMemoryPressure` scales the cache's cost ceiling on the `.reduced` tier and, on
/// the `.minimal` tier, purges every page EXCEPT the one currently on screen — the viewer stays visually
/// intact while its transient RAM drops to a single bounded image. Closing the viewer releases the store
/// (and with it the whole cache), preserving the existing teardown behavior.
@MainActor
public final class UIKitViewerImageStore {
    public struct DisplayImage {
        public let image: UIImage
        public let source: String
    }

    private static let logger = Logger(subsystem: "me.protonphotos.ios", category: "ViewerPerf")
    #if DEBUG
    private static let verbose = true
    #else
    private static let verbose = false
    #endif

    private let thumbnailProvider: (PhotoUID) -> UIImage?
    private let media: (any FullMediaProvider)?
    private let cache = WrapperImageCache<CachedDisplayImage>(countLimit: 8, costLimitBytes: 48 * 1024 * 1024)
    /// The page currently on screen — the one entry a `.minimal` purge keeps. `displayImage` is called for
    /// the CURRENT page only (`ViewerImageLoadPolicy` gates neighbours), so recording it here is exact.
    private var currentPageUID: PhotoUID?

    public init(
        thumbnailProvider: @escaping (PhotoUID) -> UIImage?,
        media: (any FullMediaProvider)?
    ) {
        self.thumbnailProvider = thumbnailProvider
        self.media = media
    }

    /// The instant grid thumbnail (already decoded in the feed's RAM tier), or nil.
    public func thumbnail(for uid: PhotoUID) -> UIImage? {
        thumbnailProvider(uid)
    }

    /// Governor-driven memory-pressure response. `scale` lowers the display cache's cost ceiling; `purge`
    /// drops every page EXCEPT the current one, so the on-screen image never blanks under a memory warning.
    /// One `[ViewerPerf]` line per invocation — the governor only calls on tier CHANGES, so no log spam.
    public func applyMemoryPressure(scale: Double, purge: Bool) {
        let clamped = min(1, max(0, scale))
        let scaledLimit = Int(Double(cache.nominalCostLimitBytes) * clamped)
        if purge {
            let keptKey = currentPageUID.map(Self.key)
            let keptCost = keptKey.flatMap { cache.image(forKey: $0)?.cost } ?? 0
            // Floor the shrunken limit at the kept page's cost so the on-screen entry survives its own
            // re-insert even at scale 0 — "keep only what is currently essential", which this page IS.
            cache.setCostLimit(max(scaledLimit, keptCost))
            cache.purge(keeping: keptKey, keptCost: keptCost)       // drop all non-visible pages
        } else {
            cache.setCostLimit(scaledLimit)
        }
        Self.logger.notice("""
        [ViewerPerf] cache pressure scale=\(String(format: "%.2f", scale), privacy: .public) \
        purge=\(purge) keptCurrent=\(self.currentPageUID != nil) \
        limitMB=\(self.cache.currentCostLimitBytes / 1_048_576)
        """)
    }

    /// The bounded DISPLAY image for `uid`: cache → preview bytes → original-bytes fallback, then bounded off-main
    /// decode, cached. Returns nil (caller keeps the thumbnail) only when both fetch paths fail or decode fails.
    /// Honors Task cancellation, so a swiped-away page's in-flight decode never sets a stale image.
    public func displayImage(for uid: PhotoUID, maxPixelSize: Int) async -> DisplayImage? {
        currentPageUID = uid
        let key = Self.key(uid)
        if let cached = cache.image(forKey: key) {
            return DisplayImage(image: cached.image, source: cached.source)
        }
        guard let media else { return nil }

        let fetchStart = CACurrentMediaTime()
        if Self.verbose {
            Self.logger.notice("[ViewerPerf] preview fetch start uid=\(Self.short(uid), privacy: .public)")
        }
        let data: Data
        let source: String
        do {
            data = try await media.preview(for: uid)
            source = "preview"
        } catch {
            if Self.verbose {
                Self.logger.notice("[ViewerPerf] preview fetch fail uid=\(Self.short(uid), privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
            guard !Task.isCancelled else {
                if Self.verbose {
                    Self.logger.notice("[ViewerPerf] preview cancelled uid=\(Self.short(uid), privacy: .public)")
                }
                return nil
            }
            if Self.verbose {
                Self.logger.notice("[ViewerPerf] original fallback fetch start uid=\(Self.short(uid), privacy: .public)")
            }
            do {
                data = try await media.originalData(for: uid)
                source = "originalFallback"
            } catch {
                if Self.verbose {
                    Self.logger.notice("[ViewerPerf] original fallback fail uid=\(Self.short(uid), privacy: .public) error=\(String(describing: error), privacy: .public)")
                }
                return nil
            }
        }
        if Task.isCancelled {
            if Self.verbose {
                Self.logger.notice("[ViewerPerf] display fetch cancelled uid=\(Self.short(uid), privacy: .public)")
            }
            return nil
        }
        let fetchMs = (CACurrentMediaTime() - fetchStart) * 1000

        let decodeStart = CACurrentMediaTime()
        let image = await Task.detached(priority: .userInitiated) {
            UIKitViewerImageAdapter.image(from: data, maxPixelSize: maxPixelSize)
        }.value
        if Task.isCancelled { return nil }
        guard let image else {
            if Self.verbose {
                Self.logger.notice("[ViewerPerf] decode fail uid=\(Self.short(uid), privacy: .public)")
            }
            return nil
        }
        let decodeMs = (CACurrentMediaTime() - decodeStart) * 1000
        let px = image.size.applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
        let cost = Int(px.width * px.height) * 4
        cache.set(CachedDisplayImage(image: image, source: source, cost: cost), forKey: key, cost: cost)
        if Self.verbose {
            Self.logger.notice("""
            [ViewerPerf] display ready uid=\(Self.short(uid), privacy: .public) source=\(source, privacy: .public) \
            px=\(Int(px.width))x\(Int(px.height)) fetchMs=\(String(format: "%.0f", fetchMs), privacy: .public) \
            decodeMs=\(String(format: "%.0f", decodeMs), privacy: .public) bytes=\(data.count)
            """)
        }
        return DisplayImage(image: image, source: source)
    }

    private static func key(_ uid: PhotoUID) -> NSString {
        "\(uid.volumeID)~\(uid.nodeID)" as NSString
    }

    private static func short(_ uid: PhotoUID) -> String {
        String(uid.nodeID.suffix(6))
    }
}

private final class CachedDisplayImage {
    let image: UIImage
    let source: String
    let cost: Int

    init(image: UIImage, source: String, cost: Int) {
        self.image = image
        self.source = source
        self.cost = cost
    }
}
#endif
