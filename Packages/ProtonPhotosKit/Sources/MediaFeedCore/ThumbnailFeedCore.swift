import Foundation
import MediaByteCache
import MediaDecodingCore
import PhotosCore

public struct ThumbnailFeedCoreConfiguration: Sendable, Equatable {
    public let targetPixels: CGFloat
    public let downloadConcurrencyLimit: Int
    public let initialDownloadConcurrency: Int
    public let minimumDownloadConcurrency: Int
    public let batchSize: Int
    public let decodedMemoryBudgetBytes: Int
    public let maxConcurrentDecodes: Int
    public let priorityQueueLimit: Int
    public let sequentialScanLimit: Int
    public let visibleQuietWindow: TimeInterval
    public let crawlBackoffSeconds: TimeInterval
    public let downloadTimeoutSeconds: Double

    public init(
        targetPixels: CGFloat = 320,
        downloadConcurrencyLimit: Int = 4,
        initialDownloadConcurrency: Int? = nil,
        minimumDownloadConcurrency: Int = 1,
        batchSize: Int = 8,
        decodedMemoryBudgetBytes: Int = 128 * 1024 * 1024,
        maxConcurrentDecodes: Int = 2,
        priorityQueueLimit: Int = 600,
        sequentialScanLimit: Int = 128,
        visibleQuietWindow: TimeInterval = 0.25,
        crawlBackoffSeconds: TimeInterval = 5,
        downloadTimeoutSeconds: Double = 20
    ) {
        let downloadLimit = max(1, downloadConcurrencyLimit)
        let minimum = min(max(1, minimumDownloadConcurrency), downloadLimit)
        let initial = initialDownloadConcurrency ?? max(minimum, downloadLimit / 2)
        self.targetPixels = max(1, targetPixels)
        self.downloadConcurrencyLimit = downloadLimit
        self.initialDownloadConcurrency = min(max(minimum, initial), downloadLimit)
        self.minimumDownloadConcurrency = minimum
        self.batchSize = max(1, batchSize)
        self.decodedMemoryBudgetBytes = max(1, decodedMemoryBudgetBytes)
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
        self.priorityQueueLimit = max(1, priorityQueueLimit)
        self.sequentialScanLimit = max(1, sequentialScanLimit)
        self.visibleQuietWindow = max(0, visibleQuietWindow)
        self.crawlBackoffSeconds = max(0, crawlBackoffSeconds)
        self.downloadTimeoutSeconds = max(0.1, downloadTimeoutSeconds)
    }
}

/// Universal thumbnail pipeline core.
///
/// Owns platform-independent feed behavior: disk/network decisions, priority ordering, background crawl,
/// adaptive download concurrency, decoded `CGImage` residency, and diagnostics. Platform targets adapt
/// `DecodedThumbnail` to their presentation image type outside this module.
public actor ThumbnailFeedCore {
    private nonisolated let cache: ThumbnailCache
    private nonisolated let loader: ThumbnailBatchLoader
    private nonisolated let onDecoded: @Sendable (PhotoUID, DecodedThumbnail) -> Void
    private nonisolated let decoded: DecodedThumbnailCache
    private nonisolated let diskPresence = DiskPresenceCache()
    private nonisolated let configuration: ThumbnailFeedCoreConfiguration

    private var priority: [PhotoUID] = []
    private var priorityByUID: [PhotoUID: ThumbnailPriority] = [:]
    private var sequential: [PhotoUID] = []
    private var sequentialIndex = 0
    private var workersRunning = false
    private var workerTask: Task<Void, Never>?
    private var interactionActive = false
    private var decodeInFlight = 0
    private var downloadInFlight = 0
    private var lastErrors: [String] = []
    private var prefetchEnabled = true
    private var prefetchPaused = false
    private var checkpointKey: String?
    private var prefetchCompleted = 0
    private var prefetchFailed = 0
    private var prefetchFailedTimeout = 0
    private var prefetchFailedBatchError = 0
    private var prefetchFailedItemError = 0
    private var prefetchFailedUnreported = 0
    private var prefetchDiskHit = 0
    private var prefetchDownloadStarted = 0
    private var prefetchDownloadCompleted = 0
    private var prefetchDecodeStarted = 0
    private var prefetchDecodeCompleted = 0
    /// UIDs whose thumbnail the backend refused per item (e.g. "no thumbnail"). Quarantined so the
    /// crawl doesn't re-request them every batch; cleared by `startPrefetch` so a fresh crawl
    /// (new session, timeline refresh) retries them exactly once.
    private nonisolated let unfetchable = UnfetchableThumbnailBox()
    private var skippedUnfetchable = 0
    private var lastRepassPercent = -1.0
    /// Cursor + one-shot completion flag for the BOUNDED end-of-crawl disk-coverage re-scan
    /// (`advanceDiskCoverageScan`). Reset per crawl in `startPrefetch`.
    private var coverageScanCursor = 0
    private var coverageSettled = false
    /// Single-flight guard for `runCoverageRefresh` (only one worker runs the coverage refresh; the rest idle)
    /// + a per-crawl count of refreshes actually started, so a test can prove one refresh runs, not N.
    private var coverageRefreshInFlight = false
    private var coverageRefreshStarts = 0
    /// How many coverage refreshes ran an actual chunked `cache.has` sweep (vs. settling from the tracker's
    /// already-known state). Lets a test prove the redundant full re-scan is skipped when `DiskPresenceCache`
    /// already knows coverage.
    private var coverageFullScans = 0
    private var targetConcurrency = 2
    private var activeDownloaders = 0
    private var aimdSuccessStreak = 0

    private nonisolated let clock: @Sendable () -> Date
    /// Last visible-demand timestamp. Held in a `nonisolated`, lock-guarded box (not actor state) SO THAT
    /// `noteVisibleDemand` can record demand WITHOUT queuing behind the crawl on the serial actor — the crawl
    /// workers read it `nonisolated` too, so they back off the instant a viewport goes live even while one of
    /// them is mid-scan. If this were actor state the demand signal would starve on the same queue as the
    /// `warmDecoded` it is meant to unblock (the cold-start bug).
    private nonisolated let lastDemand = LastDemandBox()
    private var crawlBackoffUntil: Date?

    /// Fired (on the feed actor) after a background download batch lands thumbnails on disk while a viewport is
    /// live — the "images available" arrival signal a grid host subscribes to so it re-warms the still-missing
    /// visible cells (decoding the just-arrived bytes disk→RAM) and redraws, WITHOUT needing a scroll nudge.
    /// This is the platform-neutral analogue of the macOS `MetalGridDataSource.onImagesAvailable` wake: the
    /// crawl worker stores network arrivals to disk only, so without this signal a host that has gone idle (or
    /// whose visible warm set is unchanged) never learns the bytes arrived. Set once by the platform adapter.
    private var onImagesAvailable: (@Sendable () -> Void)?

    public init(
        cache: ThumbnailCache,
        loader: ThumbnailBatchLoader,
        configuration: ThumbnailFeedCoreConfiguration = ThumbnailFeedCoreConfiguration(),
        clock: @escaping @Sendable () -> Date = { Date() },
        onDecoded: @escaping @Sendable (PhotoUID, DecodedThumbnail) -> Void = { _, _ in }
    ) {
        self.cache = cache
        self.loader = loader
        self.configuration = configuration
        self.clock = clock
        self.onDecoded = onDecoded
        self.decoded = DecodedThumbnailCache(costLimit: configuration.decodedMemoryBudgetBytes)
        targetConcurrency = configuration.initialDownloadConcurrency
    }

    /// Subscribe to the "images available" arrival wake (see `onImagesAvailable`). The callback fires on the feed
    /// actor whenever a background download batch delivers thumbnails to disk while a viewport is recently live;
    /// the host hops to its own actor and redraws / re-warms. Idempotent — set once per feed lifetime.
    public func setOnImagesAvailable(_ callback: (@Sendable () -> Void)?) {
        onImagesAvailable = callback
    }

    /// A generous "a live viewport is (or was very recently) waiting on content" gate for the arrival wake: wide
    /// enough to span a slow network delivery (bounded by the download timeout), so a tile that lands seconds
    /// after its warm still wakes the grid, yet closed when no viewport has demanded anything recently, so a
    /// purely background crawl (user not looking) never spins the host's display loop.
    private nonisolated func hostArrivalWakeIsLive(now: Date) -> Bool {
        guard let last = lastDemand.get() else { return false }
        return now.timeIntervalSince(last) < configuration.downloadTimeoutSeconds + 5
    }

    /// Governor-driven memory-pressure response for the decoded-thumbnail RAM tier. `scale` lowers the
    /// cost budget (evicting LRU entries down to it); `purge` drops everything held now (the UIKit
    /// `didReceiveMemoryWarning` / critical semantic). `nonisolated` + internally lock-guarded, so the
    /// governor calls it without hopping the feed actor (never blocks visible-tile decodes). Restoring
    /// `scale: 1.0, purge: false` returns the full budget. The disk tier is untouched - nothing is lost,
    /// only re-decoded on demand.
    public nonisolated func applyDecodedMemoryPressure(scale: Double, purge: Bool) {
        let clamped = min(1, max(0, scale))
        decoded.setCostLimit(max(1, Int(Double(configuration.decodedMemoryBudgetBytes) * clamped)))
        if purge { decoded.removeAll() }
    }

    public func cachedDecoded(for uid: PhotoUID) -> DecodedThumbnail? {
        if let cached = decoded.image(for: uid) {
            PhotoDiagnostics.shared.increment("thumb.ramDecodedHit")
            return cached
        }
        PhotoDiagnostics.shared.increment("thumb.ramDecodeMiss")
        PhotoDiagnostics.shared.recordDiskReadDuringPinch()
        if let data = cache.diskData(for: uid) {
            diskPresence.set(uid, present: true)
            PhotoDiagnostics.shared.increment("thumb.diskCacheHit")
            guard let image = decode(data, for: uid) else { return nil }
            storeDecoded(image, for: uid, decodePixelCap: Int(configuration.targetPixels))
            return image
        }
        diskPresence.set(uid, present: false)
        PhotoDiagnostics.shared.increment("thumb.diskCacheMiss")
        return nil
    }

    public nonisolated func memoryDecoded(for uid: PhotoUID) -> DecodedThumbnail? {
        decoded.image(for: uid)
    }

    /// True when the RAM tier holds this UID but at a decode cap materially below `pixels` — i.e. a warm
    /// at `pixels` would actually produce a sharper image. False when the entry is absent (that is the
    /// ordinary missing-tile path) or already adequate, so a settled render loop that keys retry work on
    /// this can never spin on a source-limited image.
    public nonisolated func decodedNeedsSharperSource(_ uid: PhotoUID, forPixels pixels: Int) -> Bool {
        decoded.needsSharperDecode(for: uid, requestedPixels: pixels)
    }

    /// The pixel cap a warm request actually decodes at: the feed's configured target is the floor (the
    /// crawl/viewer baseline), a positive request can only raise it. `0` = "no size opinion".
    private func effectiveDecodePixels(for request: ThumbnailRequest) -> CGFloat {
        request.pixelSize > 0 ? max(CGFloat(request.pixelSize), configuration.targetPixels) : configuration.targetPixels
    }

    public nonisolated func isKnownUnfetchable(_ uid: PhotoUID) -> Bool {
        unfetchable.contains(uid)
    }

    public func cacheState(for request: ThumbnailRequest, gpuTextureResident: Bool = false) -> ThumbnailCacheTierState {
        let diskThumbnail = cache.has(request.uid)
        diskPresence.set(request.uid, present: diskThumbnail)
        return ThumbnailCacheTierState(
            knownInTimeline: true,
            diskThumbnail: diskThumbnail,
            ramDecoded: decoded.contains(request.uid),
            gpuTexture: gpuTextureResident
        )
    }

    public func requestPriority(_ uid: PhotoUID, priority requestedPriority: ThumbnailPriority = .visibleNow) {
        if requestedPriority != .idleLibraryCrawl { lastDemand.set(clock()) }
        PhotoDiagnostics.shared.recordDiskPresenceCheckDuringPinch()
        let diskHit = cache.hasUsableDiskData(uid)
        diskPresence.set(uid, present: diskHit)
        guard !diskHit else {
            PhotoDiagnostics.shared.increment("thumb.diskCacheHit")
            return
        }
        PhotoDiagnostics.shared.increment("thumb.diskCacheMiss")
        if let existing = priorityByUID[uid] {
            if requestedPriority < existing {
                priorityByUID[uid] = requestedPriority
                PhotoDiagnostics.shared.increment("thumb.priorityUpgrade")
            }
            return
        }
        priority.append(uid)
        priorityByUID[uid] = requestedPriority
        if priority.count > configuration.priorityQueueLimit {
            let dropCount = priority.count - configuration.priorityQueueLimit
            for uid in priority[0 ..< dropCount] { priorityByUID.removeValue(forKey: uid) }
            priority.removeFirst(dropCount)
        }
        startWorkers()
    }

    public func hasRecentVisibleDemand(within: TimeInterval = 2.0) -> Bool {
        guard let last = lastDemand.get() else { return false }
        return clock().timeIntervalSince(last) < within
    }

    /// Records that a viewport is live WITHOUT enqueuing or decoding anything — a single lock-guarded clock
    /// write, `nonisolated` so it never queues on the serial actor. The per-frame warm path calls this the
    /// instant the first visible cells are known, so the background crawl's `recentDemand` gate (`takeBatch` /
    /// the end-of-list coverage re-scan) backs its filesystem scanning off immediately and yields the actor to
    /// the visible decode — instead of the crawl only learning of demand once `warmDecoded` itself reaches the
    /// actor, the very call the crawl is starving on a cold start.
    public nonisolated func noteVisibleDemand() {
        lastDemand.set(clock())
    }

    public func hasPendingThumbnailWork() -> Bool {
        guard prefetchEnabled else { return false }
        return !priority.isEmpty || sequentialIndex < sequential.count
    }

    public func warmDecoded(
        _ requests: [ThumbnailRequest],
        priority requestedPriority: ThumbnailPriority,
        limit: Int
    ) async -> WarmDecodedResult {
        let targets = Array(requests.prefix(max(0, limit)))
        lastDemand.set(clock())
        var alreadyDecoded = 0
        var decodedFromDisk = 0
        var queuedNetwork = 0
        var missing = 0
        let mainThreadDecodeCount = 0
        var needDecode: [(uid: PhotoUID, pixels: CGFloat, isUpgrade: Bool)] = []
        needDecode.reserveCapacity(targets.count)
        for request in targets {
            // Size-aware skip: "already decoded" only counts when the cached entry's decode cap is adequate
            // for THIS request (shared `ThumbnailDecodeUpgradePolicy` hysteresis). A materially larger ask
            // re-decodes the same UID sharper, in place — this is what lets a zoomed-in grid level sharpen
            // tiles that were first decoded for a denser level.
            let pixels = effectiveDecodePixels(for: request)
            if decoded.hasAdequateEntry(for: request.uid, requestedPixels: Int(pixels)) {
                PhotoDiagnostics.shared.increment("thumb.ramDecodedHit")
                alreadyDecoded += 1
            } else {
                needDecode.append((request.uid, pixels, decoded.contains(request.uid)))
            }
        }
        if !needDecode.isEmpty {
            let cache = self.cache
            let lanes = max(1, min(needDecode.count, configuration.maxConcurrentDecodes))
            let outcomes = await withTaskGroup(of: DecodedTile.self) { group -> [DecodedTile] in
                var iterator = needDecode.makeIterator()
                func addNext() {
                    guard let (uid, maxPixels, isUpgrade) = iterator.next() else { return }
                    group.addTask {
                        guard let data = PhotoPerformanceSignposts.mediaFeed.interval("feed.decrypt", {
                            cache.diskData(for: uid)
                        }) else {
                            return DecodedTile(uid: uid, decoded: nil, diskHadData: false, durationMs: 0,
                                               decodePixelCap: Int(maxPixels), isUpgrade: isUpgrade)
                        }
                        let start = Date()
                        let decoded = PhotoPerformanceSignposts.mediaFeed.interval("feed.decode") {
                            ThumbnailImageDecoder.downsample(data, maxPixelSize: maxPixels)
                        }
                        return DecodedTile(
                            uid: uid,
                            decoded: decoded,
                            diskHadData: true,
                            durationMs: Date().timeIntervalSince(start) * 1000,
                            decodePixelCap: Int(maxPixels),
                            isUpgrade: isUpgrade
                        )
                    }
                }
                for _ in 0 ..< lanes { addNext() }
                var results: [DecodedTile] = []
                results.reserveCapacity(needDecode.count)
                for await tile in group {
                    results.append(tile)
                    addNext()
                }
                return results
            }
            for tile in outcomes {
                PhotoDiagnostics.shared.increment("thumb.ramDecodeMiss")
                if tile.diskHadData {
                    diskPresence.set(tile.uid, present: true)
                    PhotoDiagnostics.shared.increment("thumb.diskCacheHit")
                    prefetchDecodeStarted += 1
                    PhotoDiagnostics.shared.recordDecodeStarted(queueDepth: 0)
                    if let image = tile.decoded {
                        storeDecoded(image, for: tile.uid, decodePixelCap: tile.decodePixelCap)
                        if tile.isUpgrade { PhotoDiagnostics.shared.increment("thumb.decodedUpgrade") }
                        prefetchDecodeCompleted += 1
                        PhotoDiagnostics.shared.recordDecodeCompleted(durationMs: tile.durationMs, queueDepth: 0)
                        decodedFromDisk += 1
                    } else {
                        missing += 1
                        PhotoDiagnostics.shared.increment("thumb.diskDecodeFailed")
                        PhotoDiagnostics.shared.recordDecodeFailed(queueDepth: 0)
                        recordError("decode failed for \(Self.key(tile.uid))")
                    }
                } else if PhotoPerformanceSignposts.mediaFeed.interval("feed.decrypt", {
                    cache.hasUsableDiskData(tile.uid)
                }) {
                    diskPresence.set(tile.uid, present: true)
                    PhotoDiagnostics.shared.increment("thumb.diskCacheHit")
                    missing += 1
                } else {
                    diskPresence.set(tile.uid, present: false)
                    PhotoDiagnostics.shared.increment("thumb.diskCacheMiss")
                    requestPriority(tile.uid, priority: requestedPriority)
                    queuedNetwork += 1
                }
            }
        }
        return WarmDecodedResult(
            requested: targets.count,
            alreadyDecoded: alreadyDecoded,
            decodedFromDisk: decodedFromDisk,
            queuedNetwork: queuedNetwork,
            missing: missing,
            mainThreadDecodeCount: mainThreadDecodeCount
        )
    }

    public func warmDecoded(_ uids: [PhotoUID], limit: Int = 160) async -> WarmDecodedResult {
        await warmDecoded(
            uids.map { ThumbnailRequest(uid: $0, pixelSize: Int(configuration.targetPixels)) },
            priority: .zoomAnchorAndFocusRow,
            limit: limit
        )
    }

    public func decoded(for uid: PhotoUID) async -> DecodedThumbnail? {
        if let image = cachedDecoded(for: uid) { return image }
        // Visible tiles re-request on every appearance; once the backend has said "no thumbnail"
        // for this crawl, don't burn a network round-trip per visibility.
        if unfetchable.contains(uid) {
            PhotoDiagnostics.shared.increment("thumb.unfetchableShortCircuit")
            return nil
        }
        let box = ByteBox()
        PhotoDiagnostics.shared.recordNetworkRequestDuringPinch()
        let result = await loader.loadThumbnails(for: [uid]) { loadedUID, data in
            if loadedUID == uid { box.set(data) }
        }
        guard let data = box.value else {
            if let reason = result.itemErrors[uid] {
                unfetchable.insert(uid)
                recordError("thumbnail refused for \(Self.key(uid)): \(reason)")
            } else if let reason = result.batchError {
                recordError("thumbnail fetch failed for \(Self.key(uid)): \(reason)")
            }
            return nil
        }
        cache.storeToDisk(data, for: uid)
        diskPresence.set(uid, present: true)
        guard let image = decode(data, for: uid) else { return nil }
        storeDecoded(image, for: uid, decodePixelCap: Int(configuration.targetPixels))
        return image
    }

    public func startPrefetch(_ uids: [PhotoUID]) {
        guard prefetchEnabled else { return }
        sequential = uids
        checkpointKey = Self.checkpointKey(for: uids)
        sequentialIndex = checkpointKey.flatMap { UserDefaults.standard.object(forKey: $0) as? Int } ?? 0
        sequentialIndex = min(max(sequentialIndex, 0), sequential.count)
        diskPresence.beginTracking(uids)
        unfetchable.removeAll()   // a fresh crawl retries backend-refused items exactly once
        lastRepassPercent = -1.0
        coverageScanCursor = 0
        coverageSettled = false
        coverageRefreshInFlight = false
        coverageRefreshStarts = 0
        coverageFullScans = 0
        startWorkers()
    }

    public func stopPrefetch() {
        workerTask?.cancel()
        workersRunning = false
        priority.removeAll()
        priorityByUID.removeAll()
        sequential.removeAll()
    }

    public func setPrefetchEnabled(_ enabled: Bool) {
        prefetchEnabled = enabled
        if !enabled { stopPrefetch() }
    }

    public func pausePrefetch() {
        prefetchPaused = true
    }

    public func resumePrefetch() {
        prefetchPaused = false
        startWorkers()
    }

    public func setUserInteractionActive(_ active: Bool) {
        interactionActive = active
    }

    public struct PrefetchStatus: Sendable, Equatable {
        public let enabled: Bool
        public let paused: Bool
        public let diskThumbnailCoverageFraction: Double
        public let diskThumbnailTotal: Int
        public let currentQueueLength: Int
        public let downloadsInFlight: Int
        public let decodesInFlight: Int
        public let lastErrors: [String]
        public let cacheSizeBytes: Int64
        public let diskFileCount: Int
        public let activeJobs: Int
        public let completed: Int
        public let failed: Int
        /// Classified breakdown of `failed` (their sum equals `failed`).
        public let failedTimeout: Int
        public let failedBatchError: Int
        public let failedItemError: Int
        public let failedUnreported: Int
        public let diskHit: Int
        public let downloadStarted: Int
        public let downloadCompleted: Int
        public let decodeStarted: Int
        public let decodeCompleted: Int
        /// Items currently quarantined because the backend refused them per item this crawl.
        public let unfetchableCount: Int
        public let skippedUnfetchable: Int
        public let pausedReason: String
    }

    public func prefetchStatus() -> PrefetchStatus {
        let coverage = diskPresence.coverage()
        let pausedReason: String
        if !prefetchEnabled {
            pausedReason = "disabled"
        } else if prefetchPaused {
            pausedReason = "manual"
        } else if interactionActive {
            pausedReason = "interaction"
        } else {
            pausedReason = "none"
        }
        return PrefetchStatus(
            enabled: prefetchEnabled,
            paused: prefetchPaused || interactionActive,
            diskThumbnailCoverageFraction: coverage.percent,
            diskThumbnailTotal: coverage.total,
            currentQueueLength: priority.count + max(0, sequential.count - sequentialIndex),
            downloadsInFlight: downloadInFlight,
            decodesInFlight: decodeInFlight,
            lastErrors: lastErrors,
            cacheSizeBytes: 0,
            diskFileCount: coverage.present,
            activeJobs: downloadInFlight + decodeInFlight,
            completed: prefetchCompleted,
            failed: prefetchFailed,
            failedTimeout: prefetchFailedTimeout,
            failedBatchError: prefetchFailedBatchError,
            failedItemError: prefetchFailedItemError,
            failedUnreported: prefetchFailedUnreported,
            diskHit: prefetchDiskHit,
            downloadStarted: prefetchDownloadStarted,
            downloadCompleted: prefetchDownloadCompleted,
            decodeStarted: prefetchDecodeStarted,
            decodeCompleted: prefetchDecodeCompleted,
            unfetchableCount: unfetchable.count,
            skippedUnfetchable: skippedUnfetchable,
            pausedReason: pausedReason
        )
    }

    private func startWorkers() {
        guard !workersRunning else { return }
        workersRunning = true
        workerTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< self.configuration.downloadConcurrencyLimit {
                    group.addTask { await self.worker() }
                }
            }
            await self.workersStopped()
        }
    }

    private func workersStopped() {
        workersRunning = false
        if !priority.isEmpty || sequentialIndex < sequential.count { startWorkers() }
    }

    private func worker() async {
        while !Task.isCancelled {
            let chunk = takeBatch()
            if chunk.isEmpty {
                if priority.isEmpty && sequentialIndex >= sequential.count {
                    // Coverage already verified for this crawl → nothing left to do.
                    if coverageSettled { return }
                    // Never re-scan while a viewport is actively warming (recent visible demand) — it would
                    // compete for the serial actor with the visible decode that demand represents. Idle; the
                    // scan resumes once demand quiets.
                    if recentVisibleDemand() {
                        try? await Task.sleep(for: .milliseconds(150))
                        continue
                    }
                    // SINGLE-FLIGHT: exactly one worker runs the end-of-crawl coverage refresh; the rest idle
                    // (staying available for a demand burst) rather than each scanning. Combined with the
                    // chunked, demand-aborting `runCoverageRefresh`, this means one bounded refresh per drain,
                    // never a stampede of N full-library scans on the serial actor.
                    guard !coverageRefreshInFlight else {
                        try? await Task.sleep(for: .milliseconds(150))
                        continue
                    }
                    coverageRefreshInFlight = true
                    let outcome = await runCoverageRefresh()
                    coverageRefreshInFlight = false
                    switch outcome {
                    case .aborted:
                        continue                       // a viewport went live → go service it; coverage retries when quiet
                    case .recrawl:
                        sequentialIndex = 0
                        coverageScanCursor = 0
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    case .settled:
                        coverageSettled = true         // ≥99.5% (or no longer improving) → stop re-scanning this crawl
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            while activeDownloaders >= targetConcurrency, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
            }
            if Task.isCancelled { return }
            activeDownloaders += 1
            downloadInFlight += chunk.count
            prefetchDownloadStarted += chunk.count
            PhotoDiagnostics.shared.recordNetworkRequestDuringPinch()
            let snapshot = await Self.loadBatch(
                chunk,
                loader: loader,
                cache: cache,
                diskPresence: diskPresence,
                seconds: configuration.downloadTimeoutSeconds
            )
            activeDownloaders = max(0, activeDownloaders - 1)
            downloadInFlight = max(0, downloadInFlight - chunk.count)
            let completed = snapshot.delivered.count
            prefetchCompleted += completed
            prefetchDownloadCompleted += completed
            let undelivered = chunk.filter { !snapshot.delivered.contains($0) }
            prefetchFailed += undelivered.count
            var networkSuspect = false   // batch/timeout/unreported failures point at transport, not content
            switch snapshot.resolution {
            case .timedOut:
                prefetchFailedTimeout += undelivered.count
                networkSuspect = true
                recordError("thumbnail batch timed out after \(configuration.downloadTimeoutSeconds)s (\(completed)/\(chunk.count) delivered)")
            case let .finished(result):
                if let batchError = result.batchError {
                    prefetchFailedBatchError += undelivered.count
                    networkSuspect = true
                    recordError("thumbnail batch failed (\(completed)/\(chunk.count) delivered): \(batchError)")
                } else if !undelivered.isEmpty {
                    let refused = undelivered.filter { result.itemErrors[$0] != nil }
                    prefetchFailedItemError += refused.count
                    unfetchable.formUnion(refused)
                    if let first = refused.first, let reason = result.itemErrors[first] {
                        recordError("thumbnail refused for \(refused.count) item(s), e.g. \(Self.key(first)): \(reason)")
                    }
                    let unreported = undelivered.count - refused.count
                    prefetchFailedUnreported += unreported
                    if unreported > 0 {
                        networkSuspect = true
                        recordError("thumbnail batch missing \(unreported)/\(chunk.count) with no reported reason")
                    }
                }
            }
            if completed == 0, !chunk.isEmpty {
                crawlBackoffUntil = clock().addingTimeInterval(configuration.crawlBackoffSeconds)
                if networkSuspect {
                    targetConcurrency = max(configuration.minimumDownloadConcurrency, targetConcurrency / 2)
                }
                aimdSuccessStreak = 0
            } else if completed > 0 {
                aimdSuccessStreak += 1
                if aimdSuccessStreak >= 4 {
                    aimdSuccessStreak = 0
                    targetConcurrency = min(configuration.downloadConcurrencyLimit, targetConcurrency + 1)
                }
            }
            if let checkpointKey, sequentialIndex > 0 {
                UserDefaults.standard.set(sequentialIndex, forKey: checkpointKey)
            }
            // Arrival wake: bytes just landed on disk. If a viewport is (recently) live, tell the host so it
            // re-warms the still-missing visible cells (disk→RAM) and redraws — closing the "black until the
            // user scrolls a nudge further" gap, since the crawl worker only stores to disk and never decodes.
            if completed > 0, hostArrivalWakeIsLive(now: clock()) {
                onImagesAvailable?()
            }
            emitPrefetchSummary()
        }
    }

    private enum BatchResolution: Sendable {
        case finished(ThumbnailBatchLoadResult)
        case timedOut
    }

    private struct BatchSnapshot: Sendable {
        let delivered: Set<PhotoUID>
        let resolution: BatchResolution
    }

    /// Runs one loader batch against a real wall-clock timeout. The loader await is not
    /// cancellable (the SDK's FFI continuation ignores task cancellation), so on timeout the
    /// loader is left running detached: late deliveries still land in the disk cache (a later
    /// pass counts them as disk hits), but counters snapshot exactly once here - an item is
    /// either delivered-by-resolution or failed, never both.
    private nonisolated static func loadBatch(
        _ chunk: [PhotoUID],
        loader: ThumbnailBatchLoader,
        cache: ThumbnailCache,
        diskPresence: DiskPresenceCache,
        seconds: Double
    ) async -> BatchSnapshot {
        let delivered = UIDSetBox()
        let loaderTask = Task {
            await loader.loadThumbnails(for: chunk) { uid, data in
                cache.storeToDisk(data, for: uid)
                diskPresence.set(uid, present: true)
                delivered.insert(uid)
            }
        }
        let resolution: BatchResolution = await withCheckedContinuation { continuation in
            let once = OnceFlag()
            let timeoutTask = Task {
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                if once.claim() { continuation.resume(returning: .timedOut) }
            }
            Task {
                let result = await loaderTask.value
                if once.claim() {
                    timeoutTask.cancel()
                    continuation.resume(returning: .finished(result))
                }
            }
        }
        return BatchSnapshot(delivered: delivered.snapshot, resolution: resolution)
    }

    private func takeBatch() -> [PhotoUID] {
        var out: [PhotoUID] = []
        while out.count < configuration.batchSize, !priority.isEmpty {
            let bestIndex = priority.indices.min {
                let lhs = priorityByUID[priority[$0]] ?? .idleLibraryCrawl
                let rhs = priorityByUID[priority[$1]] ?? .idleLibraryCrawl
                if lhs != rhs { return lhs < rhs }
                return $0 > $1
            } ?? priority.index(before: priority.endIndex)
            let uid = priority.remove(at: bestIndex)
            priorityByUID.removeValue(forKey: uid)
            if unfetchable.contains(uid) {
                skippedUnfetchable += 1
                continue
            }
            PhotoDiagnostics.shared.recordDiskPresenceCheckDuringPinch()
            let diskHit = cache.has(uid)
            diskPresence.set(uid, present: diskHit)
            if !diskHit {
                out.append(uid)
            } else {
                prefetchDiskHit += 1
            }
        }

        let now = clock()
        let backingOff = crawlBackoffUntil.map { now < $0 } ?? false
        guard !interactionActive, !prefetchPaused, prefetchEnabled, !recentVisibleDemand(now: now), !backingOff else { return out }

        var scannedThisCall = 0
        while out.count < configuration.batchSize,
              sequentialIndex < sequential.count,
              scannedThisCall < configuration.sequentialScanLimit {
            scannedThisCall += 1
            let uid = sequential[sequentialIndex]
            sequentialIndex += 1
            if unfetchable.contains(uid) {
                skippedUnfetchable += 1
                continue
            }
            let diskHit = cache.has(uid)
            diskPresence.set(uid, present: diskHit)
            if !diskHit && !out.contains(uid) {
                out.append(uid)
            } else {
                prefetchDiskHit += 1
            }
        }
        return out
    }

    /// Whether a viewport has demanded thumbnails within the quiet window. `nonisolated` (reads the lock-guarded
    /// demand box), so the crawl can consult it mid-scan without touching actor state.
    private nonisolated func recentVisibleDemand(now: Date? = nil) -> Bool {
        guard let last = lastDemand.get() else { return false }
        return (now ?? clock()).timeIntervalSince(last) < configuration.visibleQuietWindow
    }

    /// Bound on `cache.has` stats performed per `advanceDiskCoverageScan` invocation - the ceiling on how long
    /// one end-of-crawl coverage step can hold the serial actor. Small enough that a visible warm decode never
    /// waits behind more than this many filesystem stats.
    private static let coverageScanChunk = 512

    /// Advances the end-of-crawl disk-coverage re-scan by ONE bounded chunk of `cache.has` stats, returning the
    /// refreshed coverage ONLY when a full pass just completed (else `nil` — "call again"). Bounded so it can
    /// never hold the serial actor for an O(library) scan, and it bails to `nil` the instant a viewport goes
    /// live, so it can never starve a visible warm decode. Workers share `coverageScanCursor`, so together they
    /// complete one pass in bounded steps; no single worker runs a full scan.
    private func advanceDiskCoverageScan() -> (present: Int, total: Int, percent: Double)? {
        var scanned = 0
        while coverageScanCursor < sequential.count, scanned < Self.coverageScanChunk {
            if recentVisibleDemand() { return nil }
            let uid = sequential[coverageScanCursor]
            diskPresence.set(uid, present: cache.has(uid))
            coverageScanCursor += 1
            scanned += 1
        }
        guard coverageScanCursor >= sequential.count else { return nil }   // pass not finished yet
        coverageScanCursor = 0
        return diskPresence.coverage()
    }

    private enum CoverageRefreshOutcome { case settled, recrawl, aborted }

    /// Runs the end-of-crawl disk-coverage refresh to completion, in bounded `advanceDiskCoverageScan` chunks
    /// that yield the serial actor between them and abort the instant a viewport goes live. Invoked SINGLE-FLIGHT
    /// (guarded by `coverageRefreshInFlight`), so exactly one runs per drain regardless of worker count - it can
    /// never hold the actor for an O(library) scan, be multiplied by the worker count, or starve a visible warm
    /// decode. Emits one `[ThumbCoverage]` line at start and one at finish (never per item).
    private func runCoverageRefresh() async -> CoverageRefreshOutcome {
        let startedAt = clock()
        coverageRefreshStarts += 1
        emitCoverage("refreshStart", scanned: 0, coverage: diskPresence.coverage(), startedAt: startedAt, reason: "-")
        // Known-state fast path: if the incremental tracker already reports (near) complete coverage from this
        // session's crawling, settle WITHOUT a full `cache.has` sweep — it would be redundant background I/O.
        // The tracker only counts UIDs it has POSITIVELY seen present, so this can never falsely report "warm"
        // from incomplete knowledge; a real scan runs only when knowledge is incomplete (e.g. a checkpoint
        // resume left early items unscanned) and might reveal missing items to re-crawl.
        let known = diskPresence.coverage()
        if known.percent >= 0.995 {
            emitCoverage("refreshDone", scanned: 0, coverage: known, startedAt: startedAt, reason: "trackerComplete")
            return .settled
        }
        coverageFullScans += 1
        coverageScanCursor = 0
        while true {
            if recentVisibleDemand() {
                emitCoverage("refreshAbortVisibleDemand", scanned: coverageScanCursor,
                             coverage: diskPresence.coverage(), startedAt: startedAt, reason: "visibleDemand")
                return .aborted
            }
            guard let coverage = advanceDiskCoverageScan() else {
                try? await Task.sleep(for: .milliseconds(1))   // one chunk done (or bailed) → yield the actor
                continue
            }
            let recrawl = coverage.percent < 0.995 && coverage.percent > lastRepassPercent + 0.01
            if recrawl { lastRepassPercent = coverage.percent }
            emitCoverage("refreshDone", scanned: coverage.total, coverage: coverage, startedAt: startedAt,
                         reason: recrawl ? "recrawl" : "settled")
            return recrawl ? .recrawl : .settled
        }
    }

    private func emitCoverage(_ event: String, scanned: Int, coverage: (present: Int, total: Int, percent: Double),
                              startedAt: Date, reason: String) {
        PhotoDiagnostics.shared.emit("ThumbCoverage", [
            "event": event,
            "scanned": "\(scanned)",
            "total": "\(coverage.total)",
            "present": "\(coverage.present)",
            "durationMs": "\(Int(clock().timeIntervalSince(startedAt) * 1000))",
            "workers": "\(configuration.downloadConcurrencyLimit)",
            "reason": reason,
        ])
    }

    private func decode(_ data: Data, for uid: PhotoUID) -> DecodedThumbnail? {
        prefetchDecodeStarted += 1
        decodeInFlight += 1
        PhotoDiagnostics.shared.recordDecodeStarted(queueDepth: decodeInFlight)
        let start = Date()
        let image = PhotoPerformanceSignposts.mediaFeed.interval("feed.decode") {
            ThumbnailImageDecoder.downsample(data, maxPixelSize: configuration.targetPixels)
        }
        let durationMs = Date().timeIntervalSince(start) * 1000
        decodeInFlight = max(0, decodeInFlight - 1)
        if let image {
            prefetchDecodeCompleted += 1
            PhotoDiagnostics.shared.recordDecodeCompleted(durationMs: durationMs, queueDepth: decodeInFlight)
            return image
        }
        PhotoDiagnostics.shared.increment("thumb.diskDecodeFailed")
        PhotoDiagnostics.shared.recordDecodeFailed(queueDepth: decodeInFlight)
        recordError("decode failed for \(Self.key(uid))")
        return nil
    }

    private func storeDecoded(_ image: DecodedThumbnail, for uid: PhotoUID, decodePixelCap: Int) {
        decoded.set(image, for: uid, decodePixelCap: decodePixelCap)
        onDecoded(uid, image)
    }

    private func recordError(_ message: String) {
        lastErrors.append(message)
        if lastErrors.count > 10 { lastErrors.removeFirst(lastErrors.count - 10) }
    }

    private func emitPrefetchSummary() {
        let pausedReason: String
        if !prefetchEnabled {
            pausedReason = "disabled"
        } else if prefetchPaused {
            pausedReason = "manual"
        } else if interactionActive {
            pausedReason = "interaction"
        } else {
            pausedReason = "none"
        }
        PhotoDiagnostics.shared.emit("ThumbPrefetch", [
            "enabled": "\(prefetchEnabled)",
            "queueDepth": "\(priority.count + max(0, sequential.count - sequentialIndex))",
            "activeJobs": "\(downloadInFlight + decodeInFlight)",
            "completed": "\(prefetchCompleted)",
            "failed": "\(prefetchFailed)",
            "failedTimeout": "\(prefetchFailedTimeout)",
            "failedBatchError": "\(prefetchFailedBatchError)",
            "failedItemError": "\(prefetchFailedItemError)",
            "failedUnreported": "\(prefetchFailedUnreported)",
            "unfetchable": "\(unfetchable.count)",
            "skippedUnfetchable": "\(skippedUnfetchable)",
            "diskHit": "\(prefetchDiskHit)",
            "downloadStarted": "\(prefetchDownloadStarted)",
            "downloadCompleted": "\(prefetchDownloadCompleted)",
            "decodeStarted": "\(prefetchDecodeStarted)",
            "decodeCompleted": "\(prefetchDecodeCompleted)",
            "pausedReason": pausedReason,
            "lastError": lastErrors.last ?? "-",
        ], throttleSeconds: 1.0)
    }

    private static func key(_ uid: PhotoUID) -> NSString {
        "\(uid.volumeID)~\(uid.nodeID)" as NSString
    }

    private static func checkpointKey(for uids: [PhotoUID]) -> String {
        let first = uids.first.map { "\($0.volumeID)~\($0.nodeID)" } ?? "empty"
        let last = uids.last.map { "\($0.volumeID)~\($0.nodeID)" } ?? "empty"
        let raw = "\(uids.count)-\(first)-\(last)"
        let cleaned = raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return "ProtonPhotos.thumbnailPrefetch." + String(cleaned.prefix(180))
    }
}

#if DEBUG
extension ThumbnailFeedCore {
    /// Test seam (DEBUG only): seed the crawl's sequential list and run exactly ONE end-of-crawl coverage-scan
    /// step, returning how many `cache.has` stats it performed. Proves the re-scan is incremental — one
    /// actor-held step can never scan the whole library (the cold-start starvation risk this guards against).
    func coverageScanStepStatCountForTesting(seeding uids: [PhotoUID]) -> Int {
        sequential = uids
        coverageScanCursor = 0
        _ = advanceDiskCoverageScan()
        // The cursor starts at 0 and advances one bounded chunk per call (it only wraps to 0 after a FULL pass,
        // which for a >chunk library can't happen in one call), so it IS the stat count for this step: 0 when a
        // live viewport aborted before the first stat, else the chunk size.
        return coverageScanCursor
    }

    /// Test seam (DEBUG only): how many end-of-crawl coverage refreshes have actually STARTED this crawl.
    /// Proves single-flight — one refresh per drain, not one per worker.
    func coverageRefreshStartCountForTesting() -> Int { coverageRefreshStarts }

    /// Test seam (DEBUG only): how many coverage refreshes ran a real chunked `cache.has` sweep (vs. settling
    /// from the tracker's known state). Proves the redundant full re-scan is skipped when coverage is known.
    func coverageFullScanCountForTesting() -> Int { coverageFullScans }
}
#endif

/// Cost-bounded, `PhotoUID`-keyed decoded-thumbnail RAM tier (replaces `NSCache<NSString, …>`). The hot
/// render read path (`ThumbnailFeedCore.memoryDecoded`) no longer builds an `NSString` key per lookup — it
/// hashes the `PhotoUID` directly (stable identity; NO index/string re-keying, so no wrong-thumbnail risk).
/// Byte-costed by `DecodedThumbnail.decodedCostBytes`, O(1) move-to-front LRU eviction, and one internal
/// lock so the nonisolated render reads, the feed actor's stores, and the memory governor all touch it
/// without an actor hop. Platform-universal (no AppKit/UIKit/Foundation-cache dependency beyond `NSLock`).
/// `internal` (not `private`) only so `@testable` tests can assert eviction/cost/pressure behavior directly.
final class DecodedThumbnailCache: @unchecked Sendable {
    private final class Node {
        let uid: PhotoUID
        var image: DecodedThumbnail
        var cost: Int
        /// The pixel cap this entry was decoded under (NOT the achieved image size — a source-limited
        /// image records the cap it was given, so repeating the same ask never re-decodes).
        var decodePixelCap: Int
        var prev: Node?
        var next: Node?
        init(uid: PhotoUID, image: DecodedThumbnail, cost: Int, decodePixelCap: Int) {
            self.uid = uid; self.image = image; self.cost = cost; self.decodePixelCap = decodePixelCap
        }
    }

    private let lock = NSLock()
    private var map: [PhotoUID: Node] = [:]
    private var head: Node?   // most-recently used
    private var tail: Node?   // least-recently used → evicted first
    private var totalCost = 0
    private var costLimit: Int

    init(costLimit: Int) {
        self.costLimit = max(1, costLimit)
    }

    /// Hot render read: look up and promote to most-recently-used. Nil on miss.
    func image(for uid: PhotoUID) -> DecodedThumbnail? {
        lock.lock(); defer { lock.unlock() }
        guard let node = map[uid] else { return nil }
        moveToFront(node)
        return node.image
    }

    /// Membership check WITHOUT promoting (diagnostics / "already decoded" checks).
    func contains(_ uid: PhotoUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return map[uid] != nil
    }

    /// True when an entry exists AND its decode cap is adequate for `requestedPixels` (shared
    /// `ThumbnailDecodeUpgradePolicy` hysteresis) — the size-aware "already decoded" test.
    func hasAdequateEntry(for uid: PhotoUID, requestedPixels: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let node = map[uid] else { return false }
        return !ThumbnailDecodeUpgradePolicy.needsSharperDecode(
            cachedDecodePixels: node.decodePixelCap, requestedPixels: requestedPixels)
    }

    /// True ONLY when an entry exists but was decoded under a materially smaller cap than
    /// `requestedPixels`. Absent entries return false (they are the ordinary missing-tile path).
    func needsSharperDecode(for uid: PhotoUID, requestedPixels: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let node = map[uid] else { return false }
        return ThumbnailDecodeUpgradePolicy.needsSharperDecode(
            cachedDecodePixels: node.decodePixelCap, requestedPixels: requestedPixels)
    }

    /// Insert or replace, adjusting the running cost, then evict LRU entries until within budget. The
    /// just-set entry is never evicted here unless it ALONE exceeds the budget (then it is kept and the
    /// cache stays transiently over budget until a later set/limit-change reclaims it).
    /// Replacement keeps the LARGER decode: concurrent warms from two grids at different levels can race
    /// the same UID, and the small decode landing last must not undo the sharp one already paid for.
    func set(_ image: DecodedThumbnail, for uid: PhotoUID, decodePixelCap: Int) {
        let cap = max(1, decodePixelCap)
        let cost = max(0, image.decodedCostBytes)
        lock.lock(); defer { lock.unlock() }
        if let node = map[uid] {
            guard cap >= node.decodePixelCap else {
                moveToFront(node)
                return
            }
            totalCost += cost - node.cost
            node.image = image
            node.cost = cost
            node.decodePixelCap = cap
            moveToFront(node)
        } else {
            let node = Node(uid: uid, image: image, cost: cost, decodePixelCap: cap)
            map[uid] = node
            insertAtFront(node)
            totalCost += cost
        }
        evictToBudget(keeping: uid)
    }

    func setCostLimit(_ bytes: Int) {
        lock.lock(); defer { lock.unlock() }
        costLimit = max(1, bytes)
        evictToBudget(keeping: nil)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        map.removeAll(keepingCapacity: true)
        head = nil
        tail = nil
        totalCost = 0
    }

    // MARK: - Intrusive doubly-linked-list ops (caller holds `lock`)

    private func insertAtFront(_ node: Node) {
        node.prev = nil
        node.next = head
        head?.prev = node
        head = node
        if tail == nil { tail = node }
    }

    private func unlink(_ node: Node) {
        node.prev?.next = node.next
        node.next?.prev = node.prev
        if head === node { head = node.next }
        if tail === node { tail = node.prev }
        node.prev = nil
        node.next = nil
    }

    private func moveToFront(_ node: Node) {
        guard head !== node else { return }
        unlink(node)
        insertAtFront(node)
    }

    private func evictToBudget(keeping uid: PhotoUID?) {
        while totalCost > costLimit, let victim = tail, victim.uid != uid {
            unlink(victim)
            map[victim.uid] = nil
            totalCost -= victim.cost
        }
    }

    #if DEBUG
    /// Test seam: current entry count + running cost, for eviction/budget assertions.
    func snapshotForTesting() -> (count: Int, cost: Int) {
        lock.lock(); defer { lock.unlock() }
        return (map.count, totalCost)
    }
    #endif
}

private final class UnfetchableThumbnailBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<PhotoUID> = []

    var count: Int {
        lock.withLock { ids.count }
    }

    func contains(_ uid: PhotoUID) -> Bool {
        lock.withLock { ids.contains(uid) }
    }

    func insert(_ uid: PhotoUID) {
        lock.withLock { _ = ids.insert(uid) }
    }

    func formUnion<S: Sequence>(_ sequence: S) where S.Element == PhotoUID {
        lock.withLock { ids.formUnion(sequence) }
    }

    func removeAll() {
        lock.withLock { ids.removeAll(keepingCapacity: true) }
    }
}

private struct DecodedTile: @unchecked Sendable {
    let uid: PhotoUID
    let decoded: DecodedThumbnail?
    let diskHadData: Bool
    let durationMs: Double
    let decodePixelCap: Int
    let isUpgrade: Bool
}

private final class ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?

    func set(_ data: Data) {
        lock.withLock { bytes = data }
    }

    var value: Data? {
        lock.withLock { bytes }
    }
}

private final class UIDSetBox: @unchecked Sendable {
    private let lock = NSLock()
    private var uids: Set<PhotoUID> = []

    func insert(_ uid: PhotoUID) {
        lock.withLock { _ = uids.insert(uid) }
    }

    var snapshot: Set<PhotoUID> {
        lock.withLock { uids }
    }
}

/// One-shot claim used to resolve the loader-vs-timeout race exactly once.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.withLock {
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

/// Lock-guarded last-visible-demand timestamp, shared between the actor's methods and the `nonisolated`
/// crawl reads. Lets `noteVisibleDemand` record demand without an actor hop (so it can't starve behind the
/// crawl it is meant to pause).
private final class LastDemandBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?

    func set(_ date: Date) {
        lock.withLock { value = date }
    }

    func get() -> Date? {
        lock.withLock { value }
    }
}

/// Tracks disk-presence of thumbnails for the crawl-coverage percentage. Keyed directly by `PhotoUID` (the
/// stable (volumeID, nodeID) domain identity) rather than an interpolated `"vol~node"` string: it drops one
/// `String`/NSString allocation on every disk probe in the crawl hot path (`set` is called per probe), and
/// removes a latent aliasing bug where two distinct UIDs whose fields straddle the `~` separator would have
/// collided into one key. `internal` (not `private`) only so the re-key is directly unit-testable.
final class DiskPresenceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PhotoUID: Bool] = [:]
    private var trackedKeys: Set<PhotoUID> = []
    private var trackedTotal = 0
    private var trackedPresent = 0

    func beginTracking(_ uids: [PhotoUID]) {
        lock.withLock {
            trackedKeys = Set(uids)
            trackedTotal = uids.count
            trackedPresent = uids.reduce(0) { count, uid in
                count + (values[uid] == true ? 1 : 0)
            }
        }
    }

    func set(_ uid: PhotoUID, present: Bool) {
        lock.withLock {
            let old = values[uid]
            values[uid] = present
            guard trackedKeys.contains(uid), old != present else { return }
            if present {
                trackedPresent += 1
            } else if old == true {
                trackedPresent = max(0, trackedPresent - 1)
            }
        }
    }

    func coverage() -> (present: Int, total: Int, percent: Double) {
        lock.withLock {
            guard trackedTotal > 0 else { return (0, 0, 1) }
            let present = min(trackedPresent, trackedTotal)
            return (present, trackedTotal, Double(present) / Double(trackedTotal))
        }
    }
}
