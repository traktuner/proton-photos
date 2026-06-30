import AppKit
import Foundation
import Testing
import PhotosCore
@testable import MediaCache

/// Records fetch order and optionally serves payloads (or fails all → models a rate-limit).
actor RecordingLoader: ThumbnailBatchLoader {
    private(set) var order: [PhotoUID] = []
    private let payloads: [PhotoUID: Data]
    private let failAll: Bool

    init(payloads: [PhotoUID: Data] = [:], failAll: Bool = false) {
        self.payloads = payloads
        self.failAll = failAll
    }

    func loadThumbnails(for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void) async {
        order.append(contentsOf: uids)
        guard !failAll else { return }
        for uid in uids { if let data = payloads[uid] { onLoaded(uid, data) } }
    }

    func fetchOrder() -> [PhotoUID] { order }
    func fetched(_ uid: PhotoUID) -> Bool { order.contains(uid) }
}

/// Controllable monotonic clock for the feed's crawl-yield logic.
final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date) { current = start }
    func now() -> Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

@Suite("Thumbnail crawl yield / offline decoupling", .serialized)
struct ThumbnailCrawlYieldTests {
    // MARK: - Offline decoupling

    @Test func offlineDisabledStillAllowsThumbnailCrawl() {
        // The split: thumbnails ALWAYS crawl; the toggle only governs (future) derivative offline caching.
        #expect(OfflineLibraryPolicy.shouldCrawlThumbnails(offlineEnabled: false) == true)
        #expect(OfflineLibraryPolicy.shouldCrawlThumbnails(offlineEnabled: true) == true)
        #expect(OfflineLibraryPolicy.shouldCacheOfflineDerivatives(offlineEnabled: false) == false)
        #expect(OfflineLibraryPolicy.shouldCacheOfflineDerivatives(offlineEnabled: true) == true)
    }

    @Test func crawlRunsIndependentlyOfAnyOfflineFlag() async throws {
        let uids = (0 ..< 4).map { PhotoUID(volumeID: "v", nodeID: "crawl-\(UUID())-\($0)") }
        let loader = RecordingLoader(payloads: Dictionary(uniqueKeysWithValues: uids.map { ($0, Self.bytes()) }))
        let clock = ClockBox(Date(timeIntervalSince1970: 1000))
        let feed = await Self.makeFeed(loader: loader, clock: clock, concurrency: 2, batch: 2)

        await feed.startPrefetch(uids)   // no offline flag anywhere in this path
        try await Self.waitUntil { await feed.prefetchStatus().diskThumbnailCoverageFraction >= 1.0 }

        #expect(await feed.prefetchStatus().diskThumbnailCoverageFraction >= 1.0)
    }

    // MARK: - Visible priority preempts crawl; crawl yields to recent demand

    @Test func visibleDemandPausesSequentialCrawl() async throws {
        let visible = PhotoUID(volumeID: "v", nodeID: "visible-\(UUID())")
        let seq = (0 ..< 3).map { PhotoUID(volumeID: "v", nodeID: "seq-\(UUID())-\($0)") }
        let payloads = Dictionary(uniqueKeysWithValues: (seq + [visible]).map { ($0, Self.bytes()) })
        let loader = RecordingLoader(payloads: payloads)
        let clock = ClockBox(Date(timeIntervalSince1970: 1000))
        let feed = await Self.makeFeed(loader: loader, clock: clock, concurrency: 1, batch: 1)

        // Live visible demand at T=1000 (clock stays put → demand is always "recent").
        await feed.requestPriority(visible, priority: .visibleNow)
        await feed.startPrefetch(seq)

        try await Self.waitUntil { await loader.fetched(visible) }   // visible is served…
        // …while the sequential crawl stays paused because demand is recent.
        let duringDemand = await loader.fetchOrder()
        #expect(duringDemand.contains(visible))
        #expect(duringDemand.allSatisfy { !seq.contains($0) })

        // Demand goes quiet (advance past the 0.25 s window) → the crawl resumes.
        clock.advance(1.0)
        await feed.resumePrefetch()
        try await Self.waitUntil { let o = await loader.fetchOrder(); return seq.allSatisfy { o.contains($0) } }
        let finalOrder = await loader.fetchOrder()
        #expect(seq.allSatisfy { finalOrder.contains($0) })   // crawl resumes once demand quiets
    }

    @Test func rateLimitedBatchBacksOffSequentialCrawl() async throws {
        // A loader that fails everything models a 429: the crawl should back off rather than hammer on.
        let seq = (0 ..< 3).map { PhotoUID(volumeID: "v", nodeID: "rl-\(UUID())-\($0)") }
        let loader = RecordingLoader(failAll: true)
        let clock = ClockBox(Date(timeIntervalSince1970: 1000))
        let feed = await Self.makeFeed(loader: loader, clock: clock, concurrency: 1, batch: 1)

        await feed.startPrefetch(seq)
        // First failing batch trips the backoff; with the clock frozen the crawl stays parked.
        try await Self.waitUntil { await loader.fetchOrder().count >= 1 }
        let firstCount = await loader.fetchOrder().count
        try await Task.sleep(for: .milliseconds(250))
        #expect(await loader.fetchOrder().count == firstCount)   // no further attempts during backoff
    }

    // MARK: - Disk hit warms RAM without network

    @Test func diskHitWarmsRamWithoutNetwork() async throws {
        let store = MemoryCacheKeyStore()
        let cache = ThumbnailCache(namespace: "diskhit-\(UUID())", keyStore: store)
        cache.configure(accountUID: "acct-A")
        let uid = PhotoUID(volumeID: "v", nodeID: "disk-only")
        cache.storeToDisk(Self.bytes(), for: uid)               // encrypted on disk, no RAM, no network

        let loader = RecordingLoader()                          // would record any network call
        let feed = await Self.makeFeed(cache: cache, loader: loader)

        let result = await feed.warmDecoded([ThumbnailRequest(uid: uid)], priority: .visibleNow, limit: 1)
        #expect(result.decodedFromDisk == 1)
        #expect(result.queuedNetwork == 0)
        #expect(await loader.fetchOrder().isEmpty)              // decrypted disk → RAM with zero network
    }

    // MARK: - Corrupt blob must not starve the network

    @Test func corruptDiskBlobDoesNotStarveVisibleFetch() async throws {
        let store = MemoryCacheKeyStore()
        let cache = ThumbnailCache(namespace: "corrupt-\(UUID())", keyStore: store)
        cache.configure(accountUID: "acct-A")
        let uid = PhotoUID(volumeID: "v", nodeID: "corrupt")
        // A blob that EXISTS on disk but can't decrypt (as if left by a prior launch / wrong key). Written
        // DIRECTLY to the on-disk path — not via storeToDisk — so it is NOT pre-marked decryptable.
        try Data(repeating: 0x09, count: 64).write(to: cache.diskURL(for: uid))
        #expect(cache.has(uid) == true)   // file exists → the old `has()` would have skipped the network

        let loader = RecordingLoader(payloads: [uid: Self.bytes()])
        let feed = await Self.makeFeed(cache: cache, loader: loader, concurrency: 1, batch: 1)

        await feed.requestPriority(uid, priority: .visibleNow)
        try await Self.waitUntil { await loader.fetched(uid) }
        #expect(await loader.fetched(uid))                 // fetched from the loader despite the corrupt blob
        #expect(cache.hasUsableDiskData(uid) == true)      // and replaced it with a decryptable blob
    }

    // MARK: - Helpers

    private static func makeFeed(
        cache: ThumbnailCache? = nil,
        loader: RecordingLoader,
        clock: ClockBox = ClockBox(Date(timeIntervalSince1970: 1000)),
        concurrency: Int = 1,
        batch: Int = 1
    ) async -> ThumbnailFeed {
        let aspects = await MainActor.run { AspectRegistry(namespace: "yield-\(UUID())") }
        let cache = cache ?? ThumbnailCache(namespace: "yield-\(UUID())", keyStore: MemoryCacheKeyStore())
        return ThumbnailFeed(cache: cache, loader: loader, aspects: aspects, concurrency: concurrency, batch: batch, clock: clock.now)
    }

    /// Polls a condition up to ~3 s so the async crawl has time to run without a brittle fixed sleep.
    private static func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
        for _ in 0 ..< 60 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// A real, decodable PNG so `warmDecoded` can downsample it.
    private static func bytes() -> Data {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = 160; pixels[offset + 1] = 90; pixels[offset + 2] = 50; pixels[offset + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])!
    }
}
