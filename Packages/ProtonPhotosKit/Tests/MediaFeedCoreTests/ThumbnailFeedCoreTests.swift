import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import PhotosCore
import MediaDecodingCore
@testable import MediaByteCache
@testable import MediaFeedCore

private final class MemoryCacheKeyStore: CacheKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: SymmetricKey] = [:]

    func loadOrCreateKey(account: String) -> SymmetricKey? {
        lock.withLock {
            if let key = keys[account] { return key }
            let key = SymmetricKey(size: .bits256)
            keys[account] = key
            return key
        }
    }

    func existingKey(account: String) -> SymmetricKey? {
        lock.withLock { keys[account] }
    }

    func deleteKey(account: String) {
        lock.withLock { _ = keys.removeValue(forKey: account) }
    }
}

private actor RecordingLoader: ThumbnailBatchLoader {
    private var order: [PhotoUID] = []
    private var finishedBatchCount = 0
    private let payloads: [PhotoUID: Data]
    private let itemErrors: [PhotoUID: String]
    private let batchError: String?
    private let failAll: Bool
    private let delayMilliseconds: Int

    init(
        payloads: [PhotoUID: Data] = [:],
        itemErrors: [PhotoUID: String] = [:],
        batchError: String? = nil,
        failAll: Bool = false,
        delayMilliseconds: Int = 0
    ) {
        self.payloads = payloads
        self.itemErrors = itemErrors
        self.batchError = batchError
        self.failAll = failAll
        self.delayMilliseconds = delayMilliseconds
    }

    func loadThumbnails(for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void) async -> ThumbnailBatchLoadResult {
        order.append(contentsOf: uids)
        if delayMilliseconds > 0 {
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
        }
        defer { finishedBatchCount += 1 }
        if let batchError { return ThumbnailBatchLoadResult(batchError: batchError) }
        guard !failAll else { return .delivered }   // models a loader that delivers nothing and reports nothing
        var errors: [PhotoUID: String] = [:]
        for uid in uids {
            if let data = payloads[uid] {
                onLoaded(uid, data)
            } else if let reason = itemErrors[uid] {
                errors[uid] = reason
            }
        }
        return ThumbnailBatchLoadResult(itemErrors: errors)
    }

    func fetched(_ uid: PhotoUID) -> Bool { order.contains(uid) }
    func requestCount() -> Int { order.count }
    func finishedBatches() -> Int { finishedBatchCount }
}

/// Advanceable monotonic clock for deterministic demand-window tests (no real sleeps / wall-clock reliance).
private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    func read() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

/// Thread-safe fire counter for the `onImagesAvailable` arrival-wake tests (the callback is `@Sendable`).
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    func value() -> Int { lock.withLock { count } }
}

@Suite("MediaFeedCore")
struct ThumbnailFeedCoreTests {
    @Test func diskOnlyBytesWarmIntoDecodedRamWithoutNetwork() async throws {
        let uid = Self.uid("disk-only")
        let cache = Self.cache("disk")
        cache.storeToDisk(Self.pngData(width: 24, height: 12), for: uid)
        let loader = RecordingLoader()
        let aspects = LockedAspects()
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(maxConcurrentDecodes: 2),
            onDecoded: { uid, decoded in
                aspects.record(uid, aspect: decoded.aspectRatio)
            }
        )

        let before = await feed.cacheState(for: ThumbnailRequest(uid: uid))
        #expect(before.diskThumbnail)
        #expect(!before.ramDecoded)

        let result = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(result.decodedFromDisk == 1)
        #expect(result.queuedNetwork == 0)
        #expect(result.mainThreadDecodeCount == 0)
        #expect(await loader.requestCount() == 0)
        #expect(feed.memoryDecoded(for: uid) != nil)
        #expect(aspects.value(for: uid).map { abs($0 - 2.0) < 0.2 } == true)

        let after = await feed.cacheState(for: ThumbnailRequest(uid: uid))
        #expect(after.diskThumbnail)
        #expect(after.ramDecoded)
    }

    @Test func networkDeliveryWakesHostWhenViewportLive() async throws {
        // The crawl worker stores network arrivals to DISK ONLY. Without an arrival wake, a grid host whose
        // visible set is unchanged never re-warms those bytes into RAM → "black until the user scrolls a nudge
        // further". This proves the shared wake fires when a delivery lands while a viewport is live.
        let uid = Self.uid("wake-live")
        let cache = Self.cache("wake-live")   // empty disk → the item must be fetched over the (fake) network
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let wakes = Counter()
        await feed.setOnImagesAvailable { wakes.increment() }

        feed.noteVisibleDemand()                                   // a viewport is live → arrivals must wake it
        await feed.requestPriority(uid, priority: .visibleNow)     // enqueue the disk-miss for the crawl worker

        try await Self.waitUntil { wakes.value() > 0 }
        #expect(wakes.value() > 0)
        #expect(await loader.fetched(uid))
    }

    @Test func backgroundCrawlDeliveryDoesNotWakeHostWithoutDemand() async throws {
        // A purely background crawl (no live viewport) must NOT spin the host's display loop: the wake stays
        // silent when there has been no recent visible demand.
        let uid = Self.uid("wake-idle")
        let cache = Self.cache("wake-idle")
        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache, loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )
        let wakes = Counter()
        await feed.setOnImagesAvailable { wakes.increment() }

        await feed.startPrefetch([uid])                            // crawl only — never sets visible demand
        try await Self.waitUntil { await loader.fetched(uid) }
        try await Task.sleep(for: .milliseconds(120))              // give any (erroneous) wake time to fire
        #expect(wakes.value() == 0)
    }

    @Test func visiblePressureExcludesSequentialBacklogButTracksLiveDemand() async throws {
        // The Map's GPS crawl yields on `hasVisibleThumbnailPressure`. A pending whole-library sequential
        // fill must NOT count as pressure - keying the GPS crawl to `hasPendingThumbnailWork` parked it
        // until every one of 20k+ thumbnails was cached (the "map empty until the crawl finished" bug).
        let clock = MutableClock(Date(timeIntervalSince1970: 1_000))
        let uids = (0 ..< 8).map { Self.uid("pressure-\($0)") }
        let loader = RecordingLoader(delayMilliseconds: 250)
        let feed = ThumbnailFeedCore(
            cache: Self.cache("pressure"), loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1),
            clock: { clock.read() }
        )

        await feed.startPrefetch(uids)   // seeds the whole-library sequential backlog
        #expect(await feed.hasPendingThumbnailWork(), "sequential backlog must count as pending work")
        #expect(await feed.hasVisibleThumbnailPressure() == false,
                "a background fill alone must NOT register as visible pressure")

        feed.noteVisibleDemand()         // a live viewport appears
        #expect(await feed.hasVisibleThumbnailPressure(), "live demand must register as visible pressure")

        clock.advance(10)                // demand window (2 s) expires
        #expect(await feed.hasVisibleThumbnailPressure() == false,
                "expired demand must release the pressure so the GPS crawl resumes")
    }

    @Test func corruptDiskBlobDoesNotStarveVisibleFetch() async throws {
        let cache = Self.cache("corrupt")
        let uid = Self.uid("corrupt")
        try Data(repeating: 0x09, count: 64).write(to: cache.diskURL(for: uid))
        #expect(cache.has(uid))

        let loader = RecordingLoader(payloads: [uid: Self.pngData(width: 8, height: 8)])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.requestPriority(uid, priority: .visibleNow)
        try await Self.waitUntil { await loader.fetched(uid) }
        #expect(await loader.fetched(uid))
        #expect(cache.hasUsableDiskData(uid))
    }

    @Test func platformPolicyIsInjectedThroughSanitizedConfiguration() {
        let configuration = ThumbnailFeedCoreConfiguration(
            targetPixels: -10,
            downloadConcurrencyLimit: 0,
            initialDownloadConcurrency: 99,
            minimumDownloadConcurrency: 0,
            batchSize: 0,
            decodedMemoryBudgetBytes: 0,
            maxConcurrentDecodes: 0,
            priorityQueueLimit: 0,
            sequentialScanLimit: 0,
            visibleQuietWindow: -1,
            crawlBackoffSeconds: -1,
            downloadTimeoutSeconds: 0
        )

        #expect(configuration.targetPixels == 1)
        #expect(configuration.downloadConcurrencyLimit == 1)
        #expect(configuration.initialDownloadConcurrency == 1)
        #expect(configuration.minimumDownloadConcurrency == 1)
        #expect(configuration.batchSize == 1)
        #expect(configuration.decodedMemoryBudgetBytes == 1)
        #expect(configuration.maxConcurrentDecodes == 1)
        #expect(configuration.priorityQueueLimit == 1)
        #expect(configuration.sequentialScanLimit == 1)
        #expect(configuration.visibleQuietWindow == 0)
        #expect(configuration.crawlBackoffSeconds == 0)
        #expect(configuration.downloadTimeoutSeconds == 0.1)
    }

    // MARK: - Prefetch batch accounting (downloadStarted / downloadCompleted / failed classification)

    @Test func batchLoaderCompletesAllRequestedThumbnails() async throws {
        let uids = (0 ..< 3).map { Self.uid("full-\($0)") }
        let cache = Self.cache("full")
        let loader = RecordingLoader(payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.pngData(width: 8, height: 8)) }))
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration(batchSize: 4))

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().downloadCompleted == 3 }

        let status = await feed.prefetchStatus()
        #expect(status.downloadStarted == 3)
        #expect(status.downloadCompleted == 3)
        #expect(status.failed == 0)
        #expect(uids.allSatisfy { cache.has($0) })
    }

    @Test func partialBatchCountsCompletedVersusFailed() async throws {
        let served = (0 ..< 2).map { Self.uid("part-ok-\($0)") }
        let refused = (0 ..< 2).map { Self.uid("part-no-\($0)") }
        let cache = Self.cache("partial")
        let loader = RecordingLoader(
            payloads: Dictionary(uniqueKeysWithValues: served.map { ($0, Self.pngData(width: 8, height: 8)) }),
            itemErrors: Dictionary(uniqueKeysWithValues: refused.map { ($0, "no thumbnail for node") })
        )
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration(batchSize: 4))

        await feed.startPrefetch(served + refused)
        try await Self.waitUntil {
            let status = await feed.prefetchStatus()
            return status.downloadCompleted == 2 && status.failed == 2
        }

        let status = await feed.prefetchStatus()
        #expect(status.downloadStarted == 4)
        #expect(status.downloadCompleted == 2)
        #expect(status.failed == 2)
        #expect(status.failedItemError == 2)
        #expect(status.failedTimeout == 0)
        #expect(status.failedBatchError == 0)
        #expect(status.unfetchableCount == 2)
        #expect(status.lastErrors.joined().contains("no thumbnail for node"))
    }

    @Test func zeroResultBatchRecordsClassifiedFailureAndBacksOff() async throws {
        let uids = (0 ..< 2).map { Self.uid("zero-\($0)") }
        let frozen = Date(timeIntervalSince1970: 5000)
        let loader = RecordingLoader(batchError: "simulated 429")
        let feed = ThumbnailFeedCore(
            cache: Self.cache("zero"),
            loader: loader,
            configuration: Self.configuration(batchSize: 2),
            clock: { frozen }
        )

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().failedBatchError == 2 }

        // Frozen clock → the crawl backoff never expires; no further attempts may happen.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await loader.requestCount() == 2)

        let status = await feed.prefetchStatus()
        #expect(status.downloadStarted == 2)
        #expect(status.downloadCompleted == 0)
        #expect(status.failed == 2)
        #expect(status.failedBatchError == 2)
        #expect(status.lastErrors.joined().contains("simulated 429"))
        await feed.stopPrefetch()   // frozen clock never expires the backoff; don't leave the worker looping
    }

    @Test func endOfCrawlCoverageRescanIsBoundedNotFullLibraryScan() async throws {
        // Concurrency invariant: a single end-of-crawl coverage step stats only a BOUNDED chunk, never the
        // whole library, so no worker (and not the whole stampede of them) can hold the serial feed actor for
        // an O(library) scan that would starve a visible warm decode. Proven directly on the incremental scan.
        let feed = ThumbnailFeedCore(cache: Self.cache("coverage-bound"), loader: RecordingLoader(), configuration: Self.configuration())
        let library = (0 ..< 5000).map { Self.uid("cov-\($0)") }

        let statsInOneStep = await feed.coverageScanStepStatCountForTesting(seeding: library)

        #expect(statsInOneStep < library.count)   // one actor-held step never scans the whole 5000-item library
        #expect(statsInOneStep == 512)            // it advances exactly one bounded chunk
    }

    @Test func coverageScanAbortsImmediatelyWhenViewportIsLive() async throws {
        // A live viewport aborts the coverage re-scan BEFORE it stats a single item, so a visible warm decode is
        // never blocked behind coverage maintenance. Frozen clock → the demand stays "recent".
        let frozen = Date(timeIntervalSince1970: 5000)
        let feed = ThumbnailFeedCore(cache: Self.cache("coverage-abort"), loader: RecordingLoader(),
                                     configuration: Self.configuration(), clock: { frozen })
        feed.noteVisibleDemand()   // synchronous (nonisolated); frozen clock keeps it recent
        let library = (0 ..< 5000).map { Self.uid("abort-\($0)") }

        let scanned = await feed.coverageScanStepStatCountForTesting(seeding: library)

        #expect(scanned == 0)   // aborted before the first `cache.has` stat
    }

    @Test func endOfCrawlCoverageRefreshIsSingleFlightAndSkipsRedundantScan() async throws {
        // Many workers reach the drained end together, but the coverage refresh is SINGLE-FLIGHT: exactly one
        // runs, not one per worker (the previous end-of-crawl stampede). And because the crawl's per-item
        // `diskPresence` tracking already established full coverage during the drain, that one refresh settles
        // from the KNOWN state without a redundant full `cache.has` re-scan.
        let uids = (0 ..< 40).map { Self.uid("single-flight-\($0)") }
        let cache = Self.cache("single-flight")
        let png = Self.pngData(width: 8, height: 8)
        for uid in uids { cache.storeToDisk(png, for: uid) }   // all disk-present → the crawl drains straight to the end
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(),
                                     configuration: Self.configuration(downloadConcurrencyLimit: 8))

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.coverageRefreshStartCountForTesting() >= 1 }
        try await Task.sleep(for: .milliseconds(120))   // give any stampede a chance to (wrongly) start more

        #expect(await feed.coverageRefreshStartCountForTesting() == 1)              // one refresh, not one per worker
        #expect(await feed.coverageFullScanCountForTesting() == 0)                  // known state → no redundant full sweep
        #expect(await feed.prefetchStatus().diskThumbnailCoverageFraction >= 1.0)   // and coverage is correct
        await feed.stopPrefetch()
    }

    @Test func coverageRefreshResumesAfterVisibleDemandQuiets() async throws {
        let clock = MutableClock(Date(timeIntervalSince1970: 1000))
        let uids = (0 ..< 20).map { Self.uid("resume-\($0)") }
        let cache = Self.cache("coverage-resume")
        let png = Self.pngData(width: 8, height: 8)
        for uid in uids { cache.storeToDisk(png, for: uid) }
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(),
                                     configuration: Self.configuration(downloadConcurrencyLimit: 4),
                                     clock: { clock.read() })

        feed.noteVisibleDemand()   // viewport live at T=1000 → coverage refresh must stay gated
        await feed.startPrefetch(uids)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await feed.coverageRefreshStartCountForTesting() == 0)   // no refresh while demand is recent

        clock.advance(1.0)   // demand quiets
        try await Self.waitUntil { await feed.coverageRefreshStartCountForTesting() >= 1 }
        #expect(await feed.coverageRefreshStartCountForTesting() >= 1)   // coverage refresh resumes once idle
        await feed.stopPrefetch()
    }

    // MARK: - Decoded RAM tier: PhotoUID-keyed costed LRU cache (replaces NSCache<NSString>)

    @Test func decodedCacheHitAndMissKeyedByPhotoUID() {
        let cache = DecodedThumbnailCache(costLimit: 1_000_000)
        let a = Self.uid("dc-a"); let b = Self.uid("dc-b")
        cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 320)   // keyed directly by PhotoUID, no NSString built
        #expect(cache.image(for: a) != nil)
        #expect(cache.image(for: b) == nil)
        #expect(cache.contains(a))
        #expect(!cache.contains(b))
    }

    @Test func decodedCacheEvictsLruWhenOverBudgetAndKeepsRecentlyUsed() {
        // Budget holds exactly two 10×10×4=400-byte entries; the third eviction targets the LRU.
        let cache = DecodedThumbnailCache(costLimit: 800)
        let ids = (0 ..< 3).map { Self.uid("dc-lru-\($0)") }
        cache.set(Self.decodedThumb(10, 10), for: ids[0], decodePixelCap: 320)
        cache.set(Self.decodedThumb(10, 10), for: ids[1], decodePixelCap: 320)
        _ = cache.image(for: ids[0])                    // touch ids[0] → MRU, so ids[1] becomes the LRU
        cache.set(Self.decodedThumb(10, 10), for: ids[2], decodePixelCap: 320)   // over budget → evict LRU (ids[1])

        #expect(cache.image(for: ids[0]) != nil)        // recently used survives
        #expect(cache.image(for: ids[1]) == nil)        // least-recently used evicted
        #expect(cache.image(for: ids[2]) != nil)        // just-inserted survives
        #expect(cache.snapshotForTesting().count == 2)
    }

    @Test func decodedCacheReplaceUpdatesRunningCost() {
        let cache = DecodedThumbnailCache(costLimit: 10_000_000)
        let a = Self.uid("dc-rep")
        cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 320)    // 400
        #expect(cache.snapshotForTesting().cost == 400)
        cache.set(Self.decodedThumb(20, 20), for: a, decodePixelCap: 320)    // 1600, same UID → replace, not add
        #expect(cache.snapshotForTesting().count == 1)
        #expect(cache.snapshotForTesting().cost == 1600)
    }

    @Test func decodedCacheKeepsSingleOverBudgetItemThenReclaims() {
        // An item alone larger than the whole budget is kept (transiently over budget), then reclaimed
        // when a newer item arrives.
        let cache = DecodedThumbnailCache(costLimit: 100)
        let a = Self.uid("dc-big-a")
        cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 320)    // 400 > 100 → kept
        #expect(cache.image(for: a) != nil)
        #expect(cache.snapshotForTesting().count == 1)
        let b = Self.uid("dc-big-b")
        cache.set(Self.decodedThumb(10, 10), for: b, decodePixelCap: 320)    // keeping=b → evict LRU (a)
        #expect(cache.image(for: b) != nil)
        #expect(cache.image(for: a) == nil)
    }

    @Test func decodedCacheSetCostLimitEvictsDownToBudget() {
        let cache = DecodedThumbnailCache(costLimit: 10_000_000)
        let ids = (0 ..< 3).map { Self.uid("dc-shrink-\($0)") }
        for id in ids { cache.set(Self.decodedThumb(10, 10), for: id, decodePixelCap: 320) }   // 3×400 = 1200
        cache.setCostLimit(800)                          // shrink → evict oldest down to ≤800
        #expect(cache.snapshotForTesting().count == 2)
        #expect(cache.snapshotForTesting().cost <= 800)
        #expect(cache.image(for: ids[2]) != nil)         // newest survives
        #expect(cache.image(for: ids[0]) == nil)         // oldest evicted
    }

    @Test func decodedCacheRemoveAllClears() {
        let cache = DecodedThumbnailCache(costLimit: 10_000_000)
        cache.set(Self.decodedThumb(10, 10), for: Self.uid("dc-x"), decodePixelCap: 320)
        cache.removeAll()
        #expect(cache.snapshotForTesting().count == 0)
        #expect(cache.snapshotForTesting().cost == 0)
        #expect(cache.image(for: Self.uid("dc-x")) == nil)
    }

    // MARK: - Size-aware decoded tier (soft→sharp upgrades)

    @Test func warmReDecodesSharperWhenALargerPixelSizeIsRequested() async throws {
        // Decoded once small for a dense level, the same UID must re-decode sharper for a larger level —
        // "already decoded" is size-aware, keyed on the shared 1.25× upgrade hysteresis.
        let uid = Self.uid("upgrade")
        let cache = Self.cache("upgrade")
        cache.storeToDisk(Self.pngData(width: 64, height: 64), for: uid)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())

        let small = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(small.decodedFromDisk == 1)
        #expect(feed.memoryDecoded(for: uid)?.pixelWidth == 16)   // configuration targetPixels = 16

        let sharpened = await feed.warmDecoded([ThumbnailRequest(uid: uid, pixelSize: 64)], priority: .visibleNow, limit: 1)
        #expect(sharpened.alreadyDecoded == 0)
        #expect(sharpened.decodedFromDisk == 1)                   // re-decoded, not skipped
        #expect(feed.memoryDecoded(for: uid)?.pixelWidth == 64)   // cached image actually got sharper
    }

    @Test func warmSkipsSlightlyLargerAsksWithoutChurn() async throws {
        // An ask below the 1.25× hysteresis (18 vs cap 16) must not re-decode — repeated settled frames at
        // a marginally different effective size stay free.
        let uid = Self.uid("no-churn")
        let cache = Self.cache("no-churn")
        cache.storeToDisk(Self.pngData(width: 64, height: 64), for: uid)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())

        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        for _ in 0 ..< 3 {
            let again = await feed.warmDecoded([ThumbnailRequest(uid: uid, pixelSize: 18)], priority: .visibleNow, limit: 1)
            #expect(again.alreadyDecoded == 1)
            #expect(again.decodedFromDisk == 0)
        }
        #expect(feed.memoryDecoded(for: uid)?.pixelWidth == 16)
    }

    @Test func sourceLimitedImageNeverReDecodesInALoop() async throws {
        // The recorded decode CAP (not the achieved size) gates adequacy: a 64 px source asked for at 320
        // yields a 64 px image, and repeating the 320 ask must be a no-op, not a per-frame re-decode.
        let uid = Self.uid("src-limited")
        let cache = Self.cache("src-limited")
        cache.storeToDisk(Self.pngData(width: 64, height: 64), for: uid)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())

        let first = await feed.warmDecoded([ThumbnailRequest(uid: uid, pixelSize: 320)], priority: .visibleNow, limit: 1)
        #expect(first.decodedFromDisk == 1)
        #expect(feed.memoryDecoded(for: uid)?.pixelWidth == 64)   // source-limited below the 320 ask

        for _ in 0 ..< 3 {
            let again = await feed.warmDecoded([ThumbnailRequest(uid: uid, pixelSize: 320)], priority: .visibleNow, limit: 1)
            #expect(again.alreadyDecoded == 1)
            #expect(again.decodedFromDisk == 0)
        }
        // And the render loop's retry signal agrees: nothing sharper is available for this ask.
        #expect(!feed.decodedNeedsSharperSource(uid, forPixels: 320))
    }

    @Test func decodedNeedsSharperSourceReportsOnlyPresentUndersizedEntries() async throws {
        let uid = Self.uid("sharper-signal")
        let cache = Self.cache("sharper-signal")
        cache.storeToDisk(Self.pngData(width: 64, height: 64), for: uid)
        let feed = ThumbnailFeedCore(cache: cache, loader: RecordingLoader(), configuration: Self.configuration())

        #expect(!feed.decodedNeedsSharperSource(uid, forPixels: 64))   // absent → false (missing-tile path)
        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)   // cap 16
        #expect(feed.decodedNeedsSharperSource(uid, forPixels: 64))    // present but materially undersized
        #expect(!feed.decodedNeedsSharperSource(uid, forPixels: 18))   // within hysteresis → adequate
    }

    @Test func decodedCacheUpgradeReplacesCostAndKeepsLargerOnRace() {
        let cache = DecodedThumbnailCache(costLimit: 10_000_000)
        let a = Self.uid("dc-upgrade")
        cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 16)    // 400 bytes
        cache.set(Self.decodedThumb(20, 20), for: a, decodePixelCap: 320)   // upgrade replaces cost in place
        #expect(cache.snapshotForTesting().count == 1)
        #expect(cache.snapshotForTesting().cost == 1600)
        // A smaller concurrent decode landing last must not undo the sharp entry (cross-grid warm race).
        cache.set(Self.decodedThumb(10, 10), for: a, decodePixelCap: 16)
        #expect(cache.snapshotForTesting().cost == 1600)
        #expect(cache.image(for: a)?.pixelWidth == 20)
    }

    @Test func decodedRamTierRespondsToMemoryPressureThroughFeed() async throws {
        // End-to-end through the feed: warmDecoded stores into the decoded tier; a critical pressure purge
        // drops it; restoring the budget lets a fresh decode land again.
        let uid = Self.uid("dc-pressure")
        let diskCache = Self.cache("dc-pressure")
        diskCache.storeToDisk(Self.pngData(width: 12, height: 12), for: uid)
        let feed = ThumbnailFeedCore(cache: diskCache, loader: RecordingLoader(), configuration: Self.configuration())

        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(feed.memoryDecoded(for: uid) != nil)

        feed.applyDecodedMemoryPressure(scale: 0.0, purge: true)   // critical → shrink budget + purge
        #expect(feed.memoryDecoded(for: uid) == nil)

        feed.applyDecodedMemoryPressure(scale: 1.0, purge: false)  // back to full budget
        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(feed.memoryDecoded(for: uid) != nil)               // decodes land again
    }

    @Test func memoryOnlyRenderReadPathNeverFallsThroughToDiskOrDecode() async throws {
        // The per-frame render read (`memoryDecoded`) must be a pure RAM lookup: bytes sitting on DISK must
        // NOT be silently read/decrypted/decoded by it — that is warmDecoded's (off-render) job. A nil here
        // despite disk-present bytes is the proof; after an explicit warm the same read serves from RAM.
        let uid = Self.uid("render-pure")
        let diskCache = Self.cache("render-pure")
        diskCache.storeToDisk(Self.pngData(width: 12, height: 12), for: uid)
        let feed = ThumbnailFeedCore(cache: diskCache, loader: RecordingLoader(), configuration: Self.configuration())

        #expect(diskCache.hasUsableDiskData(uid))                  // bytes ARE on disk…
        #expect(feed.memoryDecoded(for: uid) == nil)               // …but the render read does no disk work
        #expect(feed.memoryDecoded(for: uid) == nil)               // stable: repeated reads stay memory-only

        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(feed.memoryDecoded(for: uid) != nil)               // the off-render warm fills the RAM tier
    }

    @Test func diskHitsDoNotBecomeDownloads() async throws {
        let uids = (0 ..< 3).map { Self.uid("disk-hit-\($0)") }
        let cache = Self.cache("diskhits")
        for uid in uids { cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid) }
        let loader = RecordingLoader()
        let feed = ThumbnailFeedCore(cache: cache, loader: loader, configuration: Self.configuration())

        await feed.startPrefetch(uids)
        try await Self.waitUntil { await feed.prefetchStatus().diskHit >= 3 }

        let status = await feed.prefetchStatus()
        #expect(status.downloadStarted == 0)
        #expect(status.failed == 0)
        #expect(await loader.requestCount() == 0)
    }

    @Test func prefetchStatusReportsIncrementalDiskCoverage() async throws {
        let cached = (0 ..< 2).map { Self.uid("coverage-cached-\($0)") }
        let missing = Self.uid("coverage-missing")
        let cache = Self.cache("coverage")
        for uid in cached { cache.storeToDisk(Self.pngData(width: 8, height: 8), for: uid) }
        let loader = RecordingLoader(itemErrors: [missing: "no thumbnail for node"])
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.startPrefetch(cached + [missing])
        try await Self.waitUntil {
            let status = await feed.prefetchStatus()
            return status.diskHit >= cached.count && status.failedItemError == 1
        }

        let status = await feed.prefetchStatus()
        #expect(status.diskThumbnailTotal == 3)
        #expect(status.diskFileCount == 2)
        #expect(status.diskThumbnailCoverageFraction == 2.0 / 3.0)
        #expect(await loader.requestCount() == 1)
    }

    @Test func timeoutDoesNotDoubleCountCompletionOrFailure() async throws {
        let uid = Self.uid("timeout")
        let cache = Self.cache("timeout")
        let loader = RecordingLoader(
            payloads: [uid: Self.pngData(width: 8, height: 8)],
            delayMilliseconds: 500
        )
        let feed = ThumbnailFeedCore(
            cache: cache,
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1, downloadTimeoutSeconds: 0.1)
        )

        await feed.startPrefetch([uid])
        try await Self.waitUntil { await feed.prefetchStatus().failedTimeout == 1 }

        let atTimeout = await feed.prefetchStatus()
        #expect(atTimeout.downloadStarted == 1)
        #expect(atTimeout.downloadCompleted == 0)
        #expect(atTimeout.failed == 1)

        // The uncancellable loader finishes late; its bytes land on disk, but the batch was
        // already accounted: failed stays 1, completed stays 0 (never both for one item).
        try await Self.waitUntil { await loader.finishedBatches() >= 1 }
        try await Self.waitUntil { cache.has(uid) }
        let afterLateDelivery = await feed.prefetchStatus()
        #expect(afterLateDelivery.downloadCompleted == 0)
        #expect(afterLateDelivery.failed == 1)
        #expect(afterLateDelivery.downloadStarted == 1)

        // The late-delivered blob is now a disk hit: a new visible request must NOT re-download.
        await feed.requestPriority(uid, priority: .visibleNow)
        try await Task.sleep(for: .milliseconds(200))
        #expect(await loader.requestCount() == 1)
    }

    @Test func prefetchStaysPausedDuringInteraction() async throws {
        let uids = (0 ..< 2).map { Self.uid("interact-\($0)") }
        let loader = RecordingLoader(payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.pngData(width: 8, height: 8)) }))
        let feed = ThumbnailFeedCore(cache: Self.cache("interact"), loader: loader, configuration: Self.configuration())

        await feed.setUserInteractionActive(true)
        await feed.startPrefetch(uids)
        try await Task.sleep(for: .milliseconds(300))
        #expect(await loader.requestCount() == 0)
        #expect(await feed.prefetchStatus().pausedReason == "interaction")

        await feed.setUserInteractionActive(false)
        try await Self.waitUntil { await feed.prefetchStatus().downloadCompleted == 2 }
        #expect(await loader.requestCount() == 2)
    }

    @Test func refusedItemsAreQuarantinedUntilNextCrawlStart() async throws {
        let uid = Self.uid("refused")
        let loader = RecordingLoader(itemErrors: [uid: "no thumbnail for node"])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("refused"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.startPrefetch([uid])
        try await Self.waitUntil { await feed.prefetchStatus().failedItemError == 1 }
        #expect(await loader.requestCount() == 1)

        // Same crawl: the refused uid is quarantined - a new priority request must not re-download.
        await feed.requestPriority(uid, priority: .visibleNow)
        try await Self.waitUntil { await feed.prefetchStatus().skippedUnfetchable >= 1 }
        #expect(await loader.requestCount() == 1)

        // A fresh crawl start clears the quarantine and retries exactly once.
        await feed.startPrefetch([uid])
        await feed.requestPriority(uid, priority: .visibleNow)
        try await Self.waitUntil { await loader.requestCount() == 2 }
        #expect(await loader.requestCount() == 2)
    }

    @Test func visiblePathDoesNotRefetchBackendRefusedItems() async throws {
        let uid = Self.uid("visible-refused")
        let loader = RecordingLoader(itemErrors: [uid: "Node has no thumbnails"])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("visible-refused"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        // First visible request hits the loader and learns the refusal…
        #expect(await feed.decoded(for: uid) == nil)
        #expect(await loader.requestCount() == 1)
        // …every further visibility is short-circuited for this crawl.
        #expect(await feed.decoded(for: uid) == nil)
        #expect(await feed.decoded(for: uid) == nil)
        #expect(await loader.requestCount() == 1)

        // A fresh crawl start retries once (the node may have gained a thumbnail since).
        await feed.startPrefetch([])
        #expect(await feed.decoded(for: uid) == nil)
        #expect(await loader.requestCount() == 2)
    }

    @Test func diagnosticsExplainEveryFailure() async throws {
        let refused = Self.uid("diag-refused")
        let loader = RecordingLoader(itemErrors: [refused: "decrypt failed"])
        let feed = ThumbnailFeedCore(
            cache: Self.cache("diag"),
            loader: loader,
            configuration: Self.configuration(downloadConcurrencyLimit: 1, batchSize: 1)
        )

        await feed.startPrefetch([refused])
        try await Self.waitUntil { await feed.prefetchStatus().failed == 1 }

        let status = await feed.prefetchStatus()
        // failed=N must decompose into the classified buckets…
        #expect(status.failed == status.failedTimeout + status.failedBatchError + status.failedItemError + status.failedUnreported)
        #expect(status.failedItemError == 1)
        // …and the human-readable reason must be surfaced.
        #expect(status.lastErrors.joined().contains("decrypt failed"))
    }

    private static func configuration(
        downloadConcurrencyLimit: Int = 2,
        batchSize: Int = 2,
        maxConcurrentDecodes: Int = 1,
        visibleQuietWindow: TimeInterval = 0.25,
        crawlBackoffSeconds: TimeInterval = 0.25,
        downloadTimeoutSeconds: Double = 1
    ) -> ThumbnailFeedCoreConfiguration {
        ThumbnailFeedCoreConfiguration(
            targetPixels: 16,
            downloadConcurrencyLimit: downloadConcurrencyLimit,
            initialDownloadConcurrency: 1,
            minimumDownloadConcurrency: 1,
            batchSize: batchSize,
            decodedMemoryBudgetBytes: 16 * 1024 * 1024,
            maxConcurrentDecodes: maxConcurrentDecodes,
            priorityQueueLimit: 16,
            sequentialScanLimit: 16,
            visibleQuietWindow: visibleQuietWindow,
            crawlBackoffSeconds: crawlBackoffSeconds,
            downloadTimeoutSeconds: downloadTimeoutSeconds
        )
    }

    private static func cache(_ prefix: String) -> ThumbnailCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProtonPhotosKit-feed-core-\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = ThumbnailCache(
            namespace: "feed-core-\(prefix)-\(UUID().uuidString)",
            keyStore: MemoryCacheKeyStore(),
            rootDirectory: root
        )
        cache.configure(accountUID: "acct-A")
        return cache
    }

    private static func uid(_ id: String) -> PhotoUID {
        PhotoUID(volumeID: "vol", nodeID: "\(id)-\(UUID().uuidString)")
    }

    private static func pngData(width: Int, height: Int) -> Data {
        makePNGData(width: width, height: height)
    }

    /// A decoded thumbnail of a known pixel size → deterministic `decodedCostBytes` (width*height*4) for
    /// cost/eviction assertions.
    private static func decodedThumb(_ width: Int, _ height: Int) -> DecodedThumbnail {
        DecodedThumbnail(image: makeCGImage(width: width, height: height))
    }

    private static func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0 ..< 60 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

@Suite("MediaFeedCore platform purity")
struct ThumbnailFeedCorePlatformPurityTests {
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 { url.deleteLastPathComponent() }
        return url
    }

    private var sources: URL {
        packageRoot.appendingPathComponent("Sources/MediaFeedCore")
    }

    private static let forbiddenFrameworkImports: [String] = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "AVKit",
        "MetalKit",
    ]

    private static let forbiddenTokens: [String] = [
        "NSImage",
        "UIImage",
        "NSView",
        "UIView",
        "NSWorkspace",
        "NSOpenPanel",
        "UIApplication",
        "NSApplication",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let allowedFrameworkImports: Set<String> = [
        "Foundation",
        "MediaByteCache",
        "MediaDecodingCore",
        "PhotosCore",
    ]

    @Test func hasNoPlatformFrameworkImports() throws {
        let files = try swiftFiles(in: sources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        var seen: Set<String> = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for line in source.split(whereSeparator: { $0.isNewline }) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("import ") else { continue }
                let remainder = trimmed.dropFirst("import ".count)
                let moduleName = remainder.split(separator: " ").first.map(String.init) ?? String(remainder)
                seen.insert(moduleName)
                if Self.forbiddenFrameworkImports.contains(moduleName) {
                    violations.append("\(file.lastPathComponent): \(trimmed)")
                }
            }
        }

        #expect(violations.isEmpty, "MediaFeedCore must not import platform UI frameworks:\n\(violations.joined(separator: "\n"))")
        #expect(seen.subtracting(Self.allowedFrameworkImports).isEmpty, "Unexpected MediaFeedCore imports: \(seen.subtracting(Self.allowedFrameworkImports).sorted())")
    }

    @Test func hasNoPlatformImageOrHardwarePolicyTokens() throws {
        let files = try swiftFiles(in: sources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in Self.forbiddenTokens where source.contains(token) {
                violations.append("\(file.lastPathComponent): \(token)")
            }
        }

        #expect(violations.isEmpty, "MediaFeedCore must not reference platform UI types or hardware policy:\n\(violations.joined(separator: "\n"))")
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var results: [URL] = []
        for case let url as URL in enumerator {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  url.pathExtension == "swift" else { continue }
            results.append(url)
        }
        return results.sorted { $0.path < $1.path }
    }
}

private final class LockedAspects: @unchecked Sendable {
    private let lock = NSLock()
    private var aspects: [PhotoUID: CGFloat] = [:]

    func record(_ uid: PhotoUID, aspect: CGFloat) {
        lock.withLock {
            aspects[uid] = aspect
        }
    }

    func value(for uid: PhotoUID) -> CGFloat? {
        lock.withLock { aspects[uid] }
    }
}

private func makeCGImage(width: Int, height: Int) -> CGImage {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        pixels[offset] = 160
        pixels[offset + 1] = 90
        pixels[offset + 2] = 50
        pixels[offset + 3] = 255
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

private func makePNGData(width: Int, height: Int) -> Data {
    let image = makeCGImage(width: width, height: height)
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}
