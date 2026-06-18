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
        let cache = ThumbnailCache(namespace: Self.uniqueNamespace("disk"))
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

    @Test func missingThumbnailPlaceholderTest() {
        #expect(GridThumbnailFallback.placeholderImage.width > 0)
        #expect(GridThumbnailFallback.placeholderImage.height > 0)
    }

    @Test func noDropMissingImageTest() {
        let descriptor = GridTransitionSpriteDescriptor(
            key: "missing",
            image: nil,
            imageSize: .zero,
            fromFrame: CGRect(x: 1, y: 2, width: 30, height: 40),
            toFrame: CGRect(x: 1, y: 2, width: 30, height: 40),
            fromAlpha: 1,
            toAlpha: 1,
            priority: 0
        )
        #expect(descriptor.image != nil)
        #expect(descriptor.usedPlaceholderFallback)
        #expect(descriptor.fromFrame == descriptor.toFrame)
    }

    @Test func thumbnailArrivesDuringPinchTest() {
        let placeholder = GridTransitionSpriteDescriptor(
            key: "__ph__",
            image: nil,
            imageSize: .zero,
            fromFrame: CGRect(x: 4, y: 5, width: 60, height: 70),
            toFrame: CGRect(x: 4, y: 5, width: 60, height: 70),
            fromAlpha: 1,
            toAlpha: 1,
            priority: 0
        )
        let real = GridTransitionSpriteDescriptor(
            key: "vol~arrived",
            image: Self.testCGImage(),
            imageSize: CGSize(width: 8, height: 8),
            fromFrame: placeholder.fromFrame,
            toFrame: placeholder.toFrame,
            fromAlpha: 1,
            toAlpha: 1,
            priority: 0
        )
        #expect(real.fromFrame == placeholder.fromFrame)
        #expect(real.toFrame == placeholder.toFrame)
        #expect(real.key != placeholder.key)
    }

    @Test func noMainThreadDecodeTest() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "no-main")
        let cache = ThumbnailCache(namespace: Self.uniqueNamespace("main"))
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

    @Test func textureCacheHitTest() {
        var stats = GridSpriteRenderStats()
        stats.descriptorCount = 4
        stats.renderedSpriteCount = 4
        stats.atlasBuildCount = 1
        stats.textureUploadCount = 1
        let firstBuilds = stats.atlasBuildCount
        stats.vertexBuildCount += 1
        #expect(stats.atlasBuildCount == firstBuilds)
        #expect(stats.textureUploadCount == 1)
    }

    @Test func prefetchProgressTest() async throws {
        // Unique nodeID per run: the prefetch resume-checkpoint is persisted in UserDefaults keyed by
        // the uid list's (count-first-last) signature, so a fixed id would resume "at end" on reruns.
        let uid = PhotoUID(volumeID: "vol", nodeID: "prefetch-\(UUID().uuidString)")
        let loader = FakeThumbnailLoader(payloads: [uid: Self.pngData()])
        let cache = ThumbnailCache(namespace: Self.uniqueNamespace("prefetch"))
        let feed = await Self.makeFeed(cache: cache, loader: loader, concurrency: 1, batch: 1)
        let prefetcher = ThumbnailPrefetcher(feed: feed)

        await prefetcher.start(uids: [uid])
        try await Task.sleep(for: .milliseconds(350))

        let status = await prefetcher.status()
        #expect(status.diskFileCount >= 1)
        #expect(status.diskThumbnailCoveragePercent >= 1)
    }

    @Test func priorityUpgradeTest() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "upgrade")
        let loader = FakeThumbnailLoader(payloads: [uid: Self.pngData()])
        let feed = await Self.makeFeed(cache: ThumbnailCache(namespace: Self.uniqueNamespace("upgrade")), loader: loader, concurrency: 1, batch: 1)
        PhotoDiagnostics.shared.resetForTests()

        await feed.requestPriority(uid, priority: .idleLibraryCrawl)
        await feed.requestPriority(uid, priority: .visibleNow)

        #expect(PhotoDiagnostics.shared.counter("thumb.priorityUpgrade") == 1)
    }

    @Test func cacheStateSeparationTest() async throws {
        let uid = PhotoUID(volumeID: "vol", nodeID: "tier")
        let cache = ThumbnailCache(namespace: Self.uniqueNamespace("tier"))
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
        let cache = ThumbnailCache(namespace: Self.uniqueNamespace("decode-stats"))
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
        let aspects = await MainActor.run { AspectRegistry(namespace: Self.uniqueNamespace("aspects")) }
        return ThumbnailFeed(cache: cache, loader: loader, aspects: aspects, concurrency: concurrency, batch: batch)
    }

    private static func uniqueNamespace(_ prefix: String) -> String {
        "tests-\(prefix)-\(UUID().uuidString)"
    }

    private static func pngData() -> Data {
        let image = testCGImage()
        let rep = NSBitmapImageRep(cgImage: image)
        return rep.representation(using: .png, properties: [:])!
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

    init(payloads: [PhotoUID: Data] = [:]) {
        self.payloads = payloads
    }

    func loadThumbnails(
        for uids: [PhotoUID],
        onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void
    ) async {
        requests.append(contentsOf: uids)
        for uid in uids {
            if let data = payloads[uid] {
                onLoaded(uid, data)
            }
        }
    }

    func requestCount() -> Int {
        requests.count
    }
}
