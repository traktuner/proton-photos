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
    /// Optional cache-first + persisting override for the ORIGINAL-bytes fallback path. Injected by the host
    /// app (which owns the encrypted originals cache) as a closure, so this adapter stays decoupled from the
    /// cache layer (`MediaByteCache` deliberately sits outside this target — see `CoreArchitectureGateTests`).
    /// When present, seeding/reuse of the E2EE originals cache happens inside the closure; when nil the store
    /// falls back to `media.originalData` exactly as before.
    private let originalDataOverride: (@Sendable (PhotoUID) async throws -> Data)?
    private let cache = WrapperImageCache<CachedDisplayImage>(countLimit: 8, costLimitBytes: 48 * 1024 * 1024)
    /// The page currently on screen — the one entry a `.minimal` purge keeps. `displayImage` is called for
    /// the CURRENT page only (`ViewerImageLoadPolicy` gates neighbours), so recording it here is exact.
    private var currentPageUID: PhotoUID?

    public init(
        thumbnailProvider: @escaping (PhotoUID) -> UIImage?,
        media: (any FullMediaProvider)?,
        originalDataOverride: (@Sendable (PhotoUID) async throws -> Data)? = nil
    ) {
        self.thumbnailProvider = thumbnailProvider
        self.media = media
        self.originalDataOverride = originalDataOverride
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
        // A hit is valid only if the entry was DECODED with at least this request's pixel cap — an entry decoded
        // against a transient tiny cap (e.g. mid zoom-open transition) must not satisfy a full-screen request,
        // or the stamp-sized decode would be served as the page's final image.
        if let cached = cache.image(forKey: key), cached.decodedCap >= maxPixelSize {
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
                // Cache-first + persisting when the host injected an override; otherwise the plain provider.
                if let originalDataOverride {
                    data = try await originalDataOverride(uid)
                } else {
                    data = try await media.originalData(for: uid)
                }
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
        cache.set(CachedDisplayImage(image: image, source: source, cost: cost, decodedCap: maxPixelSize), forKey: key, cost: cost)
        if Self.verbose {
            Self.logger.notice("""
            [ViewerPerf] display ready uid=\(Self.short(uid), privacy: .public) source=\(source, privacy: .public) \
            px=\(Int(px.width))x\(Int(px.height)) fetchMs=\(String(format: "%.0f", fetchMs), privacy: .public) \
            decodeMs=\(String(format: "%.0f", decodeMs), privacy: .public) bytes=\(data.count)
            """)
        }
        return DisplayImage(image: image, source: source)
    }

    /// The full-resolution ORIGINAL image for `uid`, decoded BOUNDED to `maxPixelSize` (the same screen cap the
    /// preview uses), off the main thread and cached. This is the FINAL quality tier — the iOS parallel to the
    /// macOS viewer (`PhotoViewerModel`), which likewise decodes the original after the preview. Without it the
    /// viewer settled on the mid-size `preview` derivative (~1920px) and never reached the source resolution
    /// ("no high-res"). Fetches via the injected originals override (E2EE originals cache, so a re-open is instant)
    /// when present, else `media.originalData`. Honors Task cancellation, so a swiped-away page's in-flight
    /// original never sets a stale image, and it UPGRADES the same cache entry the preview wrote — so a
    /// `.minimal` memory purge keeps the on-screen (now full-res) image, and a later `displayImage` reuses it
    /// instead of re-fetching. Returns nil (caller keeps the preview/thumbnail) when the fetch or decode fails.
    public func originalImage(for uid: PhotoUID, maxPixelSize: Int) async -> DisplayImage? {
        currentPageUID = uid
        let key = Self.key(uid)
        // Already at (or beyond) original quality for this page — reuse, never re-fetch the full bytes. Both the
        // dedicated original path and the preview's original-bytes fallback decode to the same screen cap.
        // Same decodedCap gate as `displayImage`: an "original" decoded against a transient tiny cap is NOT done.
        if let cached = cache.image(forKey: key), cached.source == "original" || cached.source == "originalFallback",
           cached.decodedCap >= maxPixelSize {
            return DisplayImage(image: cached.image, source: cached.source)
        }

        let fetchStart = CACurrentMediaTime()
        let data: Data
        do {
            // Cache-first + persisting when the host injected an override; otherwise the plain provider.
            if let originalDataOverride {
                data = try await originalDataOverride(uid)
            } else if let media {
                data = try await media.originalData(for: uid)
            } else {
                return nil
            }
        } catch {
            if Self.verbose {
                Self.logger.notice("[ViewerPerf] original fetch fail uid=\(Self.short(uid), privacy: .public) error=\(String(describing: error), privacy: .public)")
            }
            return nil
        }
        if Task.isCancelled { return nil }
        let fetchMs = (CACurrentMediaTime() - fetchStart) * 1000

        let decodeStart = CACurrentMediaTime()
        let image = await Task.detached(priority: .userInitiated) {
            UIKitViewerImageAdapter.image(from: data, maxPixelSize: maxPixelSize)
        }.value
        if Task.isCancelled { return nil }
        guard let image else {
            if Self.verbose {
                Self.logger.notice("[ViewerPerf] original decode fail uid=\(Self.short(uid), privacy: .public)")
            }
            return nil
        }
        let decodeMs = (CACurrentMediaTime() - decodeStart) * 1000
        let px = image.size.applying(CGAffineTransform(scaleX: image.scale, y: image.scale))
        let cost = Int(px.width * px.height) * 4
        cache.set(CachedDisplayImage(image: image, source: "original", cost: cost, decodedCap: maxPixelSize), forKey: key, cost: cost)
        if Self.verbose {
            Self.logger.notice("""
            [ViewerPerf] original ready uid=\(Self.short(uid), privacy: .public) \
            px=\(Int(px.width))x\(Int(px.height)) fetchMs=\(String(format: "%.0f", fetchMs), privacy: .public) \
            decodeMs=\(String(format: "%.0f", decodeMs), privacy: .public) bytes=\(data.count)
            """)
        }
        return DisplayImage(image: image, source: "original")
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
    /// The `maxPixelSize` this entry was DECODED against. A cache hit is valid only for requests at or below
    /// this cap — see the guards in `displayImage`/`originalImage`.
    let decodedCap: Int

    init(image: UIImage, source: String, cost: Int, decodedCap: Int) {
        self.image = image
        self.source = source
        self.cost = cost
        self.decodedCap = decodedCap
    }
}
#endif
