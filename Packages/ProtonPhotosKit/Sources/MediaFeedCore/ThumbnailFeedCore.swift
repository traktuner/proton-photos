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
    private nonisolated(unsafe) let decoded = NSCache<NSString, DecodedThumbnailBox>()
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
    /// (`advanceDiskCoverageScan`). Workers share the cursor so together they complete one pass in bounded
    /// chunks; none holds the serial actor for an O(library) scan. Reset per crawl in `startPrefetch`.
    private var coverageScanCursor = 0
    private var coverageSettled = false
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
        decoded.totalCostLimit = configuration.decodedMemoryBudgetBytes
        targetConcurrency = configuration.initialDownloadConcurrency
    }

    /// Governor-driven memory-pressure response for the decoded-thumbnail RAM tier. `scale` lowers the
    /// NSCache cost limit (future decodes are bounded smaller); `purge` drops everything held now (the
    /// UIKit `didReceiveMemoryWarning` / critical semantic). `nonisolated` + thread-safe NSCache, so the
    /// governor calls it without hopping the feed actor (never blocks visible-tile decodes). Restoring
    /// `scale: 1.0, purge: false` returns the full budget. The disk tier is untouched - nothing is lost,
    /// only re-decoded on demand.
    public nonisolated func applyDecodedMemoryPressure(scale: Double, purge: Bool) {
        let clamped = min(1, max(0, scale))
        decoded.totalCostLimit = max(1, Int(Double(configuration.decodedMemoryBudgetBytes) * clamped))
        if purge { decoded.removeAllObjects() }
    }

    public func cachedDecoded(for uid: PhotoUID) -> DecodedThumbnail? {
        let key = Self.key(uid)
        if let cached = decoded.object(forKey: key)?.value {
            PhotoDiagnostics.shared.increment("thumb.ramDecodedHit")
            return cached
        }
        PhotoDiagnostics.shared.increment("thumb.ramDecodeMiss")
        PhotoDiagnostics.shared.recordDiskReadDuringPinch()
        if let data = cache.diskData(for: uid) {
            diskPresence.set(uid, present: true)
            PhotoDiagnostics.shared.increment("thumb.diskCacheHit")
            guard let image = decode(data, for: uid) else { return nil }
            storeDecoded(image, for: uid)
            return image
        }
        diskPresence.set(uid, present: false)
        PhotoDiagnostics.shared.increment("thumb.diskCacheMiss")
        return nil
    }

    public nonisolated func memoryDecoded(for uid: PhotoUID) -> DecodedThumbnail? {
        decoded.object(forKey: Self.key(uid))?.value
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
            ramDecoded: decoded.object(forKey: Self.key(request.uid)) != nil,
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
        var needDecode: [PhotoUID] = []
        needDecode.reserveCapacity(targets.count)
        for request in targets {
            if decoded.object(forKey: Self.key(request.uid)) != nil {
                PhotoDiagnostics.shared.increment("thumb.ramDecodedHit")
                alreadyDecoded += 1
            } else {
                needDecode.append(request.uid)
            }
        }
        if !needDecode.isEmpty {
            let cache = self.cache
            let maxPixels = configuration.targetPixels
            let lanes = max(1, min(needDecode.count, configuration.maxConcurrentDecodes))
            let outcomes = await withTaskGroup(of: DecodedTile.self) { group -> [DecodedTile] in
                var iterator = needDecode.makeIterator()
                func addNext() {
                    guard let uid = iterator.next() else { return }
                    group.addTask {
                        guard let data = PhotoPerformanceSignposts.mediaFeed.interval("feed.decrypt", {
                            cache.diskData(for: uid)
                        }) else {
                            return DecodedTile(uid: uid, decoded: nil, diskHadData: false, durationMs: 0)
                        }
                        let start = Date()
                        let decoded = PhotoPerformanceSignposts.mediaFeed.interval("feed.decode") {
                            ThumbnailImageDecoder.downsample(data, maxPixelSize: maxPixels)
                        }
                        return DecodedTile(
                            uid: uid,
                            decoded: decoded,
                            diskHadData: true,
                            durationMs: Date().timeIntervalSince(start) * 1000
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
                        storeDecoded(image, for: tile.uid)
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
        storeDecoded(image, for: uid)
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
                    // Refresh disk coverage in a BOUNDED chunk of stats (never an O(library) actor hold), so a
                    // full re-scan — even with every worker reaching the end together — can never starve a
                    // visible warm decode. `nil` = the pass isn't finished (or it bailed to a live viewport):
                    // yield the actor and continue it on a later iteration.
                    guard let coverage = advanceDiskCoverageScan() else {
                        try? await Task.sleep(for: .milliseconds(15))
                        continue
                    }
                    if coverage.percent < 0.995, coverage.percent > lastRepassPercent + 0.01 {
                        lastRepassPercent = coverage.percent
                        sequentialIndex = 0
                        coverageScanCursor = 0
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    }
                    coverageSettled = true   // ≥99.5% (or no longer improving) → stop re-scanning this crawl
                    return
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

    private func storeDecoded(_ image: DecodedThumbnail, for uid: PhotoUID) {
        decoded.setObject(DecodedThumbnailBox(image), forKey: Self.key(uid), cost: image.decodedCostBytes)
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
        return coverageScanCursor == 0 ? uids.count : coverageScanCursor
    }
}
#endif

private final class DecodedThumbnailBox: @unchecked Sendable {
    let value: DecodedThumbnail

    init(_ value: DecodedThumbnail) {
        self.value = value
    }
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

private final class DiskPresenceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]
    private var trackedKeys: Set<String> = []
    private var trackedTotal = 0
    private var trackedPresent = 0

    func beginTracking(_ uids: [PhotoUID]) {
        let keys = uids.map(Self.key)
        lock.withLock {
            trackedKeys = Set(keys)
            trackedTotal = uids.count
            trackedPresent = keys.reduce(0) { count, key in
                count + (values[key] == true ? 1 : 0)
            }
        }
    }

    func set(_ uid: PhotoUID, present: Bool) {
        let key = Self.key(uid)
        lock.withLock {
            let old = values[key]
            values[key] = present
            guard trackedKeys.contains(key), old != present else { return }
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

    private static func key(_ uid: PhotoUID) -> String {
        "\(uid.volumeID)~\(uid.nodeID)"
    }
}
