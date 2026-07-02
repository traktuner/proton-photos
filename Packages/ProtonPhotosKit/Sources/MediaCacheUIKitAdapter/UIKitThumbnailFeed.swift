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
    private nonisolated(unsafe) let imageWrappers = NSCache<NSString, UIImage>()

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
        self.core = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: configuration,
            clock: clock,
            onDecoded: { uid, decoded in
                // Same DB-backed dimension pipeline as the macOS feed — batched, off this path.
                dimensions?.record(uid, width: decoded.pixelWidth, height: decoded.pixelHeight)
            }
        )
        imageWrappers.countLimit = 256
        imageWrappers.totalCostLimit = UIKitMediaCachePolicy.wrapperRAMBudgetBytes()
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
        if let image = imageWrappers.object(forKey: key) { return image }
        guard let decoded = core.memoryDecoded(for: uid) else { return nil }
        let image = UIKitThumbnailImageDecoder.image(from: decoded)
        imageWrappers.setObject(image, forKey: key, cost: decoded.decodedCostBytes)
        return image
    }

    public nonisolated func memoryCGImage(for uid: PhotoUID) -> CGImage? {
        core.memoryDecoded(for: uid)?.image
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
        if let image = imageWrappers.object(forKey: key) { return image }
        let image = UIKitThumbnailImageDecoder.image(from: decoded)
        imageWrappers.setObject(image, forKey: key, cost: decoded.decodedCostBytes)
        return image
    }

    private static func key(_ uid: PhotoUID) -> NSString {
        "\(uid.volumeID)~\(uid.nodeID)" as NSString
    }
}
#endif
