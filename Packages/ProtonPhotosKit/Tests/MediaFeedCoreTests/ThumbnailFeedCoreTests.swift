import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import Testing
import PhotosCore
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

        // Same crawl: the refused uid is quarantined — a new priority request must not re-download.
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

private func makePNGData(width: Int, height: Int) -> Data {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    for offset in stride(from: 0, to: pixels.count, by: 4) {
        pixels[offset] = 160
        pixels[offset + 1] = 90
        pixels[offset + 2] = 50
        pixels[offset + 3] = 255
    }
    let provider = CGDataProvider(data: Data(pixels) as CFData)!
    let image = CGImage(
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
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    precondition(CGImageDestinationFinalize(destination))
    return data as Data
}
