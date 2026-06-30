import CryptoKit
import Foundation
import Testing
import PhotosCore
@testable import MediaByteCache

/// Deterministic key-store double: no Keychain dependency in unit tests.
private final class MemoryCacheKeyStore: CacheKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: SymmetricKey] = [:]
    private let available: Bool

    init(available: Bool = true) {
        self.available = available
    }

    func loadOrCreateKey(account: String) -> SymmetricKey? {
        guard available else { return nil }
        return lock.withLock {
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

@Suite("MediaByteCache")
struct MediaByteCacheTests {
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])

    private func png() -> Data {
        var data = Self.pngSignature
        data.append(Data([0x0D, 0x0A, 0x1A, 0x0A]))
        data.append(Data((0 ..< 512).map { UInt8($0 % 251) }))
        return data
    }

    private func uniqueNamespace() -> String {
        "byte-cache-\(UUID().uuidString)"
    }

    private func uid(_ id: String = "node-1") -> PhotoUID {
        PhotoUID(volumeID: "vol-1", nodeID: id)
    }

    @Test func encryptedBlobHasNoPlaintextAndRoundTrips() throws {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), keyStore: MemoryCacheKeyStore())
        cache.configure(accountUID: "acct-A")

        let plaintext = png()
        cache.storeToDisk(plaintext, for: uid())

        let blob = try Data(contentsOf: cache.diskURL(for: uid()))
        #expect(!blob.isEmpty)
        #expect(blob != plaintext)
        #expect(blob.range(of: plaintext) == nil)
        #expect(blob.range(of: Self.pngSignature) == nil)
        #expect(cache.diskData(for: uid()) == plaintext)
    }

    @Test func configuredCacheSurvivesAcrossInstances() {
        let store = MemoryCacheKeyStore()
        let namespace = uniqueNamespace()
        let first = ThumbnailCache(namespace: namespace, keyStore: store)
        first.configure(accountUID: "acct-A")
        first.storeToDisk(png(), for: uid())

        let relaunched = ThumbnailCache(namespace: namespace, keyStore: store)
        relaunched.configure(accountUID: "acct-A")

        #expect(relaunched.has(uid()) == true)
        #expect(relaunched.diskData(for: uid()) == png())
    }

    @Test func missingKeyIsCacheMissNotCrash() {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), keyStore: MemoryCacheKeyStore(available: false))
        cache.configure(accountUID: "acct-A")
        cache.storeToDisk(png(), for: uid())

        #expect(cache.has(uid()) == false)
        #expect(cache.diskData(for: uid()) == nil)
    }

    @Test func corruptBlobIsMissAndDeleted() throws {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), keyStore: MemoryCacheKeyStore())
        cache.configure(accountUID: "acct-A")
        cache.storeToDisk(png(), for: uid())

        let url = cache.diskURL(for: uid())
        try Data([1, 2, 3, 4, 5, 6, 7, 8]).write(to: url)

        #expect(cache.diskData(for: uid()) == nil)
        #expect(FileManager.default.fileExists(atPath: url.path) == false)
    }

    @Test func configurationSanitizesMemoryBudget() {
        #expect(ThumbnailCacheConfiguration(dataMemoryBudgetBytes: 0).dataMemoryBudgetBytes == 1)
        #expect(ThumbnailCacheConfiguration(dataMemoryBudgetBytes: 42).dataMemoryBudgetBytes == 42)
    }
}

@Suite("MediaByteCache platform purity")
struct MediaByteCachePlatformPurityTests {
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 3 { url.deleteLastPathComponent() }
        return url
    }

    private var mediaByteCacheSources: URL {
        packageRoot.appendingPathComponent("Sources/MediaByteCache")
    }

    private static let forbiddenFrameworkImports: [String] = [
        "AppKit",
        "UIKit",
        "SwiftUI",
        "AVKit",
        "MetalKit",
        "ImageIO",
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
        "CGImage",
        "ProcessInfo.processInfo.physicalMemory",
        "ProcessInfo.processInfo.activeProcessorCount",
    ]

    private static let allowedFrameworkImports: Set<String> = [
        "CryptoKit",
        "Foundation",
        "PhotosCore",
        "Security",
    ]

    @Test func hasNoPlatformOrDecoderFrameworkImports() throws {
        let files = try swiftFiles(in: mediaByteCacheSources)
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

        #expect(violations.isEmpty, "MediaByteCache must not import UI or decoder frameworks:\n\(violations.joined(separator: "\n"))")
        #expect(seen.subtracting(Self.allowedFrameworkImports).isEmpty, "Unexpected MediaByteCache imports: \(seen.subtracting(Self.allowedFrameworkImports).sorted())")
    }

    @Test func hasNoPlatformOrDecodedImageTokens() throws {
        let files = try swiftFiles(in: mediaByteCacheSources)
        #expect(!files.isEmpty)

        var violations: [String] = []
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for token in Self.forbiddenTokens where source.range(of: "\\b\(token)\\b", options: .regularExpression) != nil {
                violations.append("\(file.lastPathComponent): \(token)")
            }
        }

        #expect(violations.isEmpty, "MediaByteCache must not reference platform UI or decoded-image types:\n\(violations.joined(separator: "\n"))")
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
