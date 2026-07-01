import AppKit
import Foundation
import MediaByteCache
import MediaCacheCore
import MediaDecodingCore
import MediaFeedCore
import PhotosCore

/// macOS thumbnail feed adapter.
///
/// `ThumbnailFeedCore` owns the universal feed behavior: priority, prefetch, disk/network decisions, adaptive
/// concurrency, decoded `CGImage` residency, and diagnostics. This facade preserves the existing macOS `NSImage`
/// API for Timeline, Viewer, and Filmstrip while keeping AppKit outside the shared feed core.
public actor ThumbnailFeed {
    public typealias PrefetchStatus = ThumbnailFeedCore.PrefetchStatus

    private nonisolated let core: ThumbnailFeedCore
    private nonisolated(unsafe) let imageWrappers = NSCache<NSString, NSImage>()

    public init(
        cache: ThumbnailCache,
        loader: ThumbnailBatchLoader,
        aspects: AspectRegistry,
        targetPixels: CGFloat = 320,
        concurrency: Int = 10,
        batch: Int = 8,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        let configuration = ThumbnailFeedCoreConfiguration(
            targetPixels: targetPixels,
            downloadConcurrencyLimit: concurrency,
            initialDownloadConcurrency: max(2, concurrency / 2),
            minimumDownloadConcurrency: 2,
            batchSize: batch,
            decodedMemoryBudgetBytes: Self.decodedRAMBudgetBytes(),
            maxConcurrentDecodes: max(1, ProcessInfo.processInfo.activeProcessorCount),
            priorityQueueLimit: 600,
            sequentialScanLimit: 128,
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
                aspects.record(uid, aspect: decoded.aspectRatio)
            }
        )
        imageWrappers.countLimit = 512
        imageWrappers.totalCostLimit = Self.wrapperRAMBudgetBytes()
    }

    static func decodedRAMBudgetBytes() -> Int {
        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        let floor = 256.0 * 1024 * 1024
        let ceiling = 20.0 * 1024 * 1024 * 1024
        return Int(min(max(physical * 0.15, floor), ceiling))
    }

    static func wrapperRAMBudgetBytes() -> Int {
        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        let floor = 16.0 * 1024 * 1024
        let ceiling = 96.0 * 1024 * 1024
        return Int(min(max(physical * 0.005, floor), ceiling))
    }

    static func decodedCost(_ image: NSImage) -> Int {
        MacThumbnailImageDecoder.decodedCost(image)
    }

    public func cachedImage(for uid: PhotoUID) async -> NSImage? {
        guard let decoded = await core.cachedDecoded(for: uid) else { return nil }
        return image(for: decoded, uid: uid)
    }

    public nonisolated func memoryImage(for uid: PhotoUID) -> NSImage? {
        let key = Self.key(uid)
        if let image = imageWrappers.object(forKey: key) { return image }
        guard let decoded = core.memoryDecoded(for: uid) else { return nil }
        let image = MacThumbnailImageDecoder.image(from: decoded)
        imageWrappers.setObject(image, forKey: key, cost: decoded.decodedCostBytes)
        return image
    }

    public nonisolated func memoryCGImage(for uid: PhotoUID) -> CGImage? {
        core.memoryDecoded(for: uid)?.image
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

    public func warmDecoded(_ uids: [PhotoUID], limit: Int = 160) async -> WarmDecodedResult {
        await core.warmDecoded(uids, limit: limit)
    }

    public func image(for uid: PhotoUID) async -> NSImage? {
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

    private func image(for decoded: DecodedThumbnail, uid: PhotoUID) -> NSImage {
        let key = Self.key(uid)
        if let image = imageWrappers.object(forKey: key) { return image }
        let image = MacThumbnailImageDecoder.image(from: decoded)
        imageWrappers.setObject(image, forKey: key, cost: decoded.decodedCostBytes)
        return image
    }

    private static func key(_ uid: PhotoUID) -> NSString {
        "\(uid.volumeID)~\(uid.nodeID)" as NSString
    }
}
