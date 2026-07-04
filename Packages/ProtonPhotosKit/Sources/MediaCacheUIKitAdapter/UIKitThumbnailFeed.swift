#if canImport(UIKit)
import Foundation
import MediaByteCache
import MediaCacheCore
import MediaDecodingCore
import MediaFeedCore
import PhotosCore
import UIKit

/// iOS/iPadOS thumbnail feed adapter.
///
/// `ThumbnailFeedCore` remains the universal cache/feed implementation. This facade only adapts decoded
/// `CGImage` residency to `UIImage` and injects conservative mobile RAM/concurrency policy.
public actor UIKitThumbnailFeed {
    public typealias PrefetchStatus = ThumbnailFeedCore.PrefetchStatus

    private nonisolated let core: ThumbnailFeedCore
    private nonisolated let imageWrappers: WrapperImageCache<UIImage>

    public init(
        cache: ThumbnailCache,
        loader: ThumbnailBatchLoader,
        dimensions: PhotoDimensionCoalescer? = nil,
        targetPixels: CGFloat = 320,
        concurrency: Int = UIKitMediaCachePolicy.downloadConcurrencyLimit(),
        batch: Int = 6,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let configuration = ThumbnailFeedCoreConfiguration(
            targetPixels: targetPixels,
            downloadConcurrencyLimit: concurrency,
            initialDownloadConcurrency: max(1, concurrency / 2),
            minimumDownloadConcurrency: 1,
            batchSize: batch,
            decodedMemoryBudgetBytes: UIKitMediaCachePolicy.decodedRAMBudgetBytes(),
            maxConcurrentDecodes: UIKitMediaCachePolicy.maxConcurrentDecodes(),
            priorityQueueLimit: 360,
            sequentialScanLimit: 80,
            visibleQuietWindow: 0.25,
            crawlBackoffSeconds: 5,
            downloadTimeoutSeconds: 20
        )
        let wrappers = WrapperImageCache<UIImage>(
            countLimit: 256,
            costLimitBytes: UIKitMediaCachePolicy.wrapperRAMBudgetBytes()
        )
        imageWrappers = wrappers
        self.core = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: configuration,
            clock: clock,
            onDecoded: { uid, decoded in
                // Same DB-backed dimension pipeline as the macOS feed - batched, off this path.
                dimensions?.record(uid, width: decoded.pixelWidth, height: decoded.pixelHeight)
                // A (re)decode may have replaced the CGImage with a sharper one; drop the stale UIImage
                // wrapper so viewer/map consumers rebuild from the current decoded tier on next read.
                wrappers.remove(forKey: Self.key(uid))
            }
        )
    }

    /// Governor-driven memory-pressure response for BOTH iOS RAM tiers this adapter owns: the UIImage
    /// wrappers here and the shared decoded-CGImage tier in the core. `scale` lowers each cost limit;
    /// `purge` drops held images now. `nonisolated` + thread-safe caches, so the governor never hops this
    /// actor. Nothing is lost — wrappers rebuild from the decoded tier, decodes from the encrypted disk tier.
    public nonisolated func applyMemoryPressure(scale: Double, purge: Bool) {
        imageWrappers.applyMemoryPressure(scale: scale, purge: purge)
        core.applyDecodedMemoryPressure(scale: scale, purge: purge)
    }

    public static func decodedCost(_ image: UIImage) -> Int {
        UIKitThumbnailImageDecoder.decodedCost(image)
    }

    public func cachedImage(for uid: PhotoUID) async -> UIImage? {
        guard let decoded = await core.cachedDecoded(for: uid) else { return nil }
        return image(for: decoded, uid: uid)
    }

    public nonisolated func memoryImage(for uid: PhotoUID) -> UIImage? {
        let key = Self.key(uid)
        if let image = imageWrappers.image(forKey: key) { return image }
        guard let decoded = core.memoryDecoded(for: uid) else { return nil }
        let image = UIKitThumbnailImageDecoder.image(from: decoded)
        imageWrappers.set(image, forKey: key, cost: decoded.decodedCostBytes)
        return image
    }

    public nonisolated func memoryCGImage(for uid: PhotoUID) -> CGImage? {
        core.memoryDecoded(for: uid)?.image
    }

    /// See `ThumbnailFeedCore.decodedNeedsSharperSource` — true only for a present-but-undersized RAM decode.
    public nonisolated func decodedNeedsSharperSource(_ uid: PhotoUID, forPixels pixels: Int) -> Bool {
        core.decodedNeedsSharperSource(uid, forPixels: pixels)
    }

    /// Subscribe to the shared feed's "images available" arrival wake (see `ThumbnailFeedCore.onImagesAvailable`).
    /// Fire-and-forget so the grid host can wire it synchronously from `makeUIView`/`configure`; the callback then
    /// fires on the feed actor whenever a background download lands thumbnails on disk while a viewport is live.
    public nonisolated func setOnImagesAvailable(_ callback: @escaping @Sendable () -> Void) {
        Task { await core.setOnImagesAvailable(callback) }
    }

    public nonisolated func isKnownUnfetchable(_ uid: PhotoUID) -> Bool {
        core.isKnownUnfetchable(uid)
    }

    public func cacheState(for request: ThumbnailRequest, gpuTextureResident: Bool = false) async -> ThumbnailCacheTierState {
        await core.cacheState(for: request, gpuTextureResident: gpuTextureResident)
    }

    public func requestPriority(_ uid: PhotoUID, priority requestedPriority: ThumbnailPriority = .visibleNow) async {
        await core.requestPriority(uid, priority: requestedPriority)
    }

    public func hasRecentVisibleDemand(within: TimeInterval = 2.0) async -> Bool {
        await core.hasRecentVisibleDemand(within: within)
    }

    public func hasPendingThumbnailWork() async -> Bool {
        await core.hasPendingThumbnailWork()
    }

    /// Visible-only pressure (priority queue / live viewport demand) - excludes the whole-library
    /// sequential fill. The Map's GPS crawl yields on this, never on full crawl completion.
    public func hasVisibleThumbnailPressure() async -> Bool {
        await core.hasVisibleThumbnailPressure()
    }

    public func warmDecoded(
        _ requests: [ThumbnailRequest],
        priority requestedPriority: ThumbnailPriority,
        limit: Int
    ) async -> WarmDecodedResult {
        await core.warmDecoded(requests, priority: requestedPriority, limit: limit)
    }

    public func warmDecoded(_ uids: [PhotoUID], limit: Int = 120) async -> WarmDecodedResult {
        await core.warmDecoded(uids, limit: limit)
    }

    public func image(for uid: PhotoUID) async -> UIImage? {
        guard let decoded = await core.decoded(for: uid) else { return nil }
        return image(for: decoded, uid: uid)
    }

    public func startPrefetch(_ uids: [PhotoUID]) async {
        await core.startPrefetch(uids)
    }

    public func stopPrefetch() async {
        await core.stopPrefetch()
    }

    public func setPrefetchEnabled(_ enabled: Bool) async {
        await core.setPrefetchEnabled(enabled)
    }

    public func pausePrefetch() async {
        await core.pausePrefetch()
    }

    public func resumePrefetch() async {
        await core.resumePrefetch()
    }

    public func setUserInteractionActive(_ active: Bool) async {
        await core.setUserInteractionActive(active)
    }

    public func prefetchStatus() async -> PrefetchStatus {
        await core.prefetchStatus()
    }

    private func image(for decoded: DecodedThumbnail, uid: PhotoUID) -> UIImage {
        let key = Self.key(uid)
        if let image = imageWrappers.image(forKey: key) { return image }
        let image = UIKitThumbnailImageDecoder.image(from: decoded)
        imageWrappers.set(image, forKey: key, cost: decoded.decodedCostBytes)
        return image
    }

    private static func key(_ uid: PhotoUID) -> NSString {
        "\(uid.volumeID)~\(uid.nodeID)" as NSString
    }
}
#endif
