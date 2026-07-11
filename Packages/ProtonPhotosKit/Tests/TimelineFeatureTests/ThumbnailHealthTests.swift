import AppKit
import Testing
import PhotosCore
import MediaCache
@testable import TimelineFeature

/// `.serialized`: these tests share the `PhotoDiagnostics.shared` global (each calls `resetForTests()`
/// then asserts exact counter values), so they must not run in parallel with one another.
@Suite("Thumbnail cache health", .serialized)
struct ThumbnailHealthTests {
    @Test func diskButNotRAMWarmupTest() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "disk-only")
        let cache = ThumbnailCache(namespace: Self.uniqueNamespace("disk"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        cache.storeToDisk(Self.pngData(), for: uid)
        let loader = FakeThumbnailLoader()
        let feed = await Self.makeFeed(cache: cache, loader: loader)

        let before = await feed.cacheState(for: ThumbnailRequest(uid: uid))
        #expect(before.diskThumbnail)
        #expect(!before.ramDecoded)

        let result = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 10)
        #expect(result.decodedFromDisk == 1)
        #expect(result.queuedNetwork == 0)
        #expect(result.mainThreadDecodeCount == 0)
        #expect(await loader.requestCount() == 0)

        let after = await feed.cacheState(for: ThumbnailRequest(uid: uid))
        #expect(after.diskThumbnail)
        #expect(after.ramDecoded)
    }

    @Test @MainActor func realDataSourceWarmDrainsMoreThanOneBatch() async throws {
        let count = 130
        let uids = (0 ..< count).map { PhotoUID(volumeID: "vol", nodeID: "warm-batch-\($0)") }
        let cache = ThumbnailCache(namespace: Self.uniqueNamespace("warm-batch"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        let png = Self.pngData()
        for uid in uids {
            cache.storeToDisk(png, for: uid)
        }
        let feed = await Self.makeFeed(cache: cache, loader: FakeThumbnailLoader())
        let items = uids.map { PhotoItem(uid: $0, captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/jpeg") }
        let dataSource = RealMetalGridDataSource(sections: [
            TimelineSection(id: "warm-batch", date: Date(timeIntervalSince1970: 0), title: "Warm Batch", items: items)
        ], feed: feed)

        var availabilityCallbacks = 0
        dataSource.onImagesAvailable = { availabilityCallbacks += 1 }
        dataSource.warm(uids)

        try await Self.waitUntil {
            uids.allSatisfy { dataSource.hasImage(for: $0) }
        }
        #expect(availabilityCallbacks >= 2, "warming \(count) items must drain across more than one \(96)-item batch")
    }

    @Test @MainActor func repeatedWarmDemandDoesNotRestartLargeViewportAtFirstBatch() async throws {
        let count = 220
        let uids = (0 ..< count).map { PhotoUID(volumeID: "vol", nodeID: "repeat-warm-\($0)-\(UUID().uuidString)") }
        let cache = ThumbnailCache(namespace: Self.uniqueNamespace("repeat-warm"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        let loader = FakeThumbnailLoader()
        let feed = await Self.makeFeed(cache: cache, loader: loader, concurrency: 2, batch: 32)
        let items = uids.map { PhotoItem(uid: $0, captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/jpeg") }
        let dataSource = RealMetalGridDataSource(sections: [
            TimelineSection(id: "repeat-warm", date: Date(timeIntervalSince1970: 0), title: "Repeat Warm", items: items)
        ], feed: feed)

        var availabilityCallbacks = 0
        dataSource.onImagesAvailable = {
            availabilityCallbacks += 1
            if availabilityCallbacks < 12 {
                dataSource.warm(uids)
            }
        }

        dataSource.warm(uids)
        for _ in 0 ..< 100 {
            if availabilityCallbacks >= 5 { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(availabilityCallbacks >= 5)
        for _ in 0 ..< 100 {
            if await loader.fetched(uids[180]) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(
            await loader.fetched(uids[180]),
            "Repeated L5-sized warm calls must progress beyond the first 96 visible items while callbacks continue"
        )
        await feed.stopPrefetch()
    }

    @Test @MainActor func firstWarmPassFetchesVisibleNetworkMissesButNotDiskHits() async throws {
        // The opening viewport (a fresh data source's first warm pass) must decode disk-present cells straight
        // from disk and fetch only the true disk-misses over the network - exercising the first-pass
        // `.visibleNow` warm path (map to ThumbnailRequest + priority) end to end.
        let misses = (0 ..< 3).map { PhotoUID(volumeID: "vol", nodeID: "fp-miss-\($0)-\(UUID().uuidString)") }
        let onDisk = PhotoUID(volumeID: "vol", nodeID: "fp-hit-\(UUID().uuidString)")
        let cache = ThumbnailCache(namespace: Self.uniqueNamespace("first-pass"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        cache.storeToDisk(Self.pngData(), for: onDisk)
        let loader = FakeThumbnailLoader(payloads: Dictionary(uniqueKeysWithValues: misses.map { ($0, Self.pngData()) }))
        let feed = await Self.makeFeed(cache: cache, loader: loader)
        let items = (misses + [onDisk]).map { PhotoItem(uid: $0, captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/jpeg") }
        let dataSource = RealMetalGridDataSource(sections: [
            TimelineSection(id: "first-pass", date: Date(timeIntervalSince1970: 0), title: "First Pass", items: items)
        ], feed: feed)

        dataSource.warm(misses + [onDisk])   // opening viewport → first warm pass

        for _ in 0 ..< 150 {
            let allMissesFetched = await withAllFetched(misses, loader)
            if dataSource.hasImage(for: onDisk) && allMissesFetched { break }
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(dataSource.hasImage(for: onDisk))          // disk hit decoded from disk in the first pass
        #expect(await withAllFetched(misses, loader))      // every true miss was fetched over the network
        #expect(await loader.fetched(onDisk) == false)     // the disk hit was never fetched
    }

    private func withAllFetched(_ uids: [PhotoUID], _ loader: FakeThumbnailLoader) async -> Bool {
        for uid in uids where await !loader.fetched(uid) { return false }
        return true
    }

    @Test @MainActor func realDataSourceMarksBackendRefusedThumbnailsNonRetryable() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "refused-\(UUID().uuidString)")
        let feed = await Self.makeFeed(
            cache: ThumbnailCache(namespace: Self.uniqueNamespace("refused"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health")),
            loader: FakeThumbnailLoader(itemErrors: [uid: "no thumbnail for node"])
        )
        let item = PhotoItem(uid: uid, captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/jpeg")
        let dataSource = RealMetalGridDataSource(sections: [
            TimelineSection(id: "refused", date: Date(timeIntervalSince1970: 0), title: "Refused", items: [item])
        ], feed: feed)

        #expect(dataSource.canRetryThumbnail(for: uid))
        #expect(await feed.image(for: uid) == nil)
        #expect(!dataSource.canRetryThumbnail(for: uid))
    }

    // (Placeholder-image + GridTransitionSpriteDescriptor "no drop / arrives during pinch" tests were
    // removed with the legacy GridThumbnailFallback / GridSpriteTransitionView. The Metal grid's
    // placeholder-until-resident behavior is covered by MetalGridPlaceholderTests.)

    @Test func noMainThreadDecodeTest() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "no-main")
        let cache = ThumbnailCache(namespace: Self.uniqueNamespace("main"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        cache.storeToDisk(Self.pngData(), for: uid)
        let feed = await Self.makeFeed(cache: cache, loader: FakeThumbnailLoader())

        let result = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(result.decodedFromDisk == 1)
        #expect(result.mainThreadDecodeCount == 0)
    }

    @Test func noNPlusOneDBDuringPinchTest() {
        PhotoDiagnostics.shared.resetForTests()
        PhotoDiagnostics.shared.setActivePinch(true)
        PhotoDiagnostics.shared.setActivePinch(false)
        #expect(PhotoDiagnostics.shared.dbQueryCountDuringActivePinch() == 0)
    }

    // (textureCacheHitTest covered the deleted GridSpriteRenderStats atlas-build accounting; the Metal
    // texture cache's upload dedup/budget is covered by MetalGridUploadDedupTests/UploadBudgetTests.)

    @Test func prefetchProgressTest() async throws {
        // Unique nodeID per run: the prefetch resume-checkpoint is persisted in UserDefaults keyed by
        // the uid list's (count-first-last) signature, so a fixed id would resume "at end" on reruns.
        let uid = PhotoUID(volumeID: "vol", nodeID: "prefetch-\(UUID().uuidString)")
        let loader = FakeThumbnailLoader(payloads: [uid: Self.pngData()])
        let cache = ThumbnailCache(namespace: Self.uniqueNamespace("prefetch"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        let feed = await Self.makeFeed(cache: cache, loader: loader, concurrency: 1, batch: 1)
        let prefetcher = ThumbnailPrefetcher(feed: feed)

        await prefetcher.start(uids: [uid])
        try await Task.sleep(for: .milliseconds(350))

        let status = await prefetcher.status()
        #expect(status.diskFileCount >= 1)
        #expect(status.diskThumbnailCoverageFraction >= 1)
    }

    @Test func priorityUpgradeTest() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "upgrade")
        let loader = FakeThumbnailLoader(payloads: [uid: Self.pngData()])
        let feed = await Self.makeFeed(cache: ThumbnailCache(namespace: Self.uniqueNamespace("upgrade"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health")), loader: loader, concurrency: 1, batch: 1)
        PhotoDiagnostics.shared.resetForTests()

        await feed.requestPriority(uid, priority: .idleLibraryCrawl)
        await feed.requestPriority(uid, priority: .visibleNow)

        #expect(PhotoDiagnostics.shared.counter("thumb.priorityUpgrade") == 1)
    }

    @Test func cacheStateSeparationTest() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "tier")
        let cache = ThumbnailCache(namespace: Self.uniqueNamespace("tier"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        cache.storeToDisk(Self.pngData(), for: uid)
        let feed = await Self.makeFeed(cache: cache, loader: FakeThumbnailLoader())

        let diskOnly = await feed.cacheState(for: ThumbnailRequest(uid: uid))
        #expect(diskOnly.knownInTimeline)
        #expect(diskOnly.diskThumbnail)
        #expect(!diskOnly.ramDecoded)
        #expect(!diskOnly.gpuTexture)

        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        let decoded = await feed.cacheState(for: ThumbnailRequest(uid: uid), gpuTextureResident: false)
        #expect(decoded.diskThumbnail)
        #expect(decoded.ramDecoded)
        #expect(!decoded.gpuTexture)
    }

    @Test func coldCacheClassifiesVisiblePlaceholderCause() {
        PhotoDiagnostics.shared.resetForTests()
        let uid = PhotoUID(volumeID: "vol", nodeID: "cold")
        PhotoDiagnostics.shared.classifyThumbnail(ThumbnailVisualClassification(
            uid: uid,
            rect: CGRect(x: 0, y: 0, width: 50, height: 50),
            state: .diskMissing,
            phase: "pinchChanged",
            context: "synthetic.coldCache"
        ))
        let counters = PhotoDiagnostics.shared.thumbHealthCounters()
        #expect(counters.visibleCount == 1)
        #expect(counters.diskMissing == 1)
        #expect(counters.geometryHole == 0)
        #expect(counters.unknownBug == 0)
    }

    @Test func ramHitGpuMissClassificationTest() {
        PhotoDiagnostics.shared.resetForTests()
        PhotoDiagnostics.shared.classifyThumbnail(ThumbnailVisualClassification(
            uid: PhotoUID(volumeID: "vol", nodeID: "gpu-miss"),
            rect: CGRect(x: 1, y: 2, width: 30, height: 30),
            state: .ramHitGpuMissing,
            phase: "pinchChanged",
            context: "synthetic.ramWithoutTexture"
        ))
        let counters = PhotoDiagnostics.shared.thumbHealthCounters()
        #expect(counters.visibleCount == 1)
        #expect(counters.ramHitGpuMissing == 1)
        #expect(counters.geometryHole == 0)
    }

    @Test func geometryHoleDetectionTest() {
        PhotoDiagnostics.shared.resetForTests()
        PhotoDiagnostics.shared.classifyThumbnail(ThumbnailVisualClassification(
            uid: nil,
            rect: CGRect(x: 10, y: 10, width: 100, height: 100),
            state: .geometryHole,
            phase: "pinchChanged",
            context: "synthetic.omittedSprite"
        ))
        let counters = PhotoDiagnostics.shared.thumbHealthCounters()
        #expect(counters.visibleCount == 1)
        #expect(counters.geometryHole == 1)
        #expect(counters.diskMissing == 0)
    }

    @Test func decodeWarmupStatsAreObservable() async throws {
        PhotoDiagnostics.shared.resetForTests()
        let uid = PhotoUID(volumeID: "vol", nodeID: "decode-stats")
        let cache = ThumbnailCache(namespace: Self.uniqueNamespace("decode-stats"), rootDirectory: timelineFeatureTestCacheRoot("thumb-health"))
        cache.storeToDisk(Self.pngData(), for: uid)
        let feed = await Self.makeFeed(cache: cache, loader: FakeThumbnailLoader())

        _ = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)

        let stats = PhotoDiagnostics.shared.decodeStats()
        #expect(stats.diskCacheHit >= 1)
        #expect(stats.ramDecodeStarted >= 1)
        #expect(stats.ramDecodeCompleted >= 1)
        #expect(stats.ramDecodeFailed == 0)
    }

    private static func makeFeed(
        cache: ThumbnailCache,
        loader: FakeThumbnailLoader,
        concurrency: Int = 2,
        batch: Int = 2
    ) async -> ThumbnailFeed {
        ThumbnailFeed(cache: cache, loader: loader, concurrency: concurrency, batch: batch)
    }

    private static func uniqueNamespace(_ prefix: String) -> String {
        "tests-\(prefix)-\(UUID().uuidString)"
    }

    private static func pngData() -> Data {
        let image = testCGImage()
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])!
    }

    private static func waitUntil(
        timeout: Duration = .seconds(2),
        interval: Duration = .milliseconds(20),
        _ condition: @MainActor @escaping () -> Bool
    ) async throws {
        let started = ContinuousClock.now
        while await !condition() {
            if started.duration(to: .now) >= timeout {
                Issue.record("condition did not become true within \(timeout)")
                return
            }
            try await Task.sleep(for: interval)
        }
    }

    private static func testCGImage() -> CGImage {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = 180
            pixels[offset + 1] = 80
            pixels[offset + 2] = 40
            pixels[offset + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }
}

private actor FakeThumbnailLoader: ThumbnailBatchLoader {
    private var requests: [PhotoUID] = []
    private let payloads: [PhotoUID: Data]
    private let itemErrors: [PhotoUID: String]

    init(payloads: [PhotoUID: Data] = [:], itemErrors: [PhotoUID: String] = [:]) {
        self.payloads = payloads
        self.itemErrors = itemErrors
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async -> ThumbnailBatchLoadResult {
        requests.append(contentsOf: uids)
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

    func requestCount() -> Int {
        requests.count
    }

    func fetched(_ uid: PhotoUID) -> Bool {
        requests.contains(uid)
    }
}
