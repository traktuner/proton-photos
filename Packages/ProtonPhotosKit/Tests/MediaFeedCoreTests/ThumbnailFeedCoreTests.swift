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
    private let payloads: [PhotoUID: Data]
    private let failAll: Bool

    init(payloads: [PhotoUID: Data] = [:], failAll: Bool = false) {
        self.payloads = payloads
        self.failAll = failAll
    }

    func loadThumbnails(for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void) async {
        order.append(contentsOf: uids)
        guard !failAll else { return }
        for uid in uids {
            if let data = payloads[uid] { onLoaded(uid, data) }
        }
    }

    func fetched(_ uid: PhotoUID) -> Bool { order.contains(uid) }
    func requestCount() -> Int { order.count }
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

    private static func configuration(
        downloadConcurrencyLimit: Int = 2,
        batchSize: Int = 2,
        maxConcurrentDecodes: Int = 1
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
            visibleQuietWindow: 0.25,
            crawlBackoffSeconds: 0.25,
            downloadTimeoutSeconds: 1
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
