import Foundation
import Testing
import PhotosCore
@testable import MediaByteCache

/// A `FullMediaProvider` spy that counts `originalData` calls and emits deterministic byte progress,
/// so tests can assert the cache-first helper never hits the network on a warm cache.
private actor SpyMediaProvider: FullMediaProvider {
    let bytes: Data
    private(set) var originalCallCount = 0

    init(bytes: Data) { self.bytes = bytes }

    func preview(for uid: PhotoUID) async throws -> Data { bytes }

    func originalData(
        for uid: PhotoUID,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> Data {
        originalCallCount += 1
        onProgress(0.5)
        onProgress(1.0)
        return bytes
    }
}

/// Thread-safe holder for the last progress value the closure observed (the closure is `@Sendable`
/// and synchronous, so it can't await an actor).
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _last: Double = -1
    var last: Double { lock.lock(); defer { lock.unlock() }; return _last }
    func set(_ v: Double) { lock.lock(); _last = v; lock.unlock() }
}

@Suite struct EncryptedOriginalProviderTests {

    private func uniqueRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("eop-\(UUID().uuidString)", isDirectory: true)
    }

    private func makeCache() -> ThumbnailCache {
        // Default init uses a process-ephemeral key, so store→read round-trips within one instance work.
        ThumbnailCache(namespace: "originals-\(UUID().uuidString.prefix(8))", rootDirectory: uniqueRoot())
    }

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "vol-1", nodeID: id) }

    /// Cache hit returns cached bytes, reports completion, and NEVER calls `FullMediaProvider.originalData`.
    @Test func cacheHitAvoidsOriginalData() async throws {
        let cache = makeCache()
        let u = uid("hit")
        let cached = Data("cached-original-bytes".utf8)
        cache.storeToDisk(cached, for: u)           // prime the encrypted cache

        let spy = SpyMediaProvider(bytes: Data("network".utf8))
        let box = ProgressBox()
        let helper = EncryptedOriginalProvider(media: spy, cache: cache, policy: .readOnly)

        let out = try await helper.originalData(for: u, onProgress: { box.set($0) })

        #expect(out == cached)
        #expect(await spy.originalCallCount == 0)    // the key guarantee
        #expect(box.last == 1.0)                     // a warm hit "completes" for progress UIs
        #expect(cache.diskData(for: u) == cached)    // LRU touch didn't corrupt the blob
    }

    /// Cache miss downloads via the provider, then seals the bytes into the encrypted cache when persisting.
    @Test func cacheMissDownloadsThenStoresWhenEnabled() async throws {
        let cache = makeCache()
        let u = uid("miss")
        let net = Data("network-original-bytes".utf8)
        let spy = SpyMediaProvider(bytes: net)
        let helper = EncryptedOriginalProvider(media: spy, cache: cache, policy: .persisting(capBytes: nil))

        let out = try await helper.originalData(for: u)

        #expect(out == net)
        #expect(await spy.originalCallCount == 1)
        #expect(cache.diskData(for: u) == net)       // stored for later viewer/export reuse
    }

    /// No cache configured → always downloads, nothing stored.
    @Test func cacheDisabledDownloadsAndDoesNotStore() async throws {
        let u = uid("nocache")
        let net = Data("net".utf8)
        let spy = SpyMediaProvider(bytes: net)
        let helper = EncryptedOriginalProvider(media: spy, cache: nil, policy: .readOnly)

        let out = try await helper.originalData(for: u)

        #expect(out == net)
        #expect(await spy.originalCallCount == 1)
    }

    /// Read-only policy reuses a warm cache but must NOT grow it on a miss (the export/share contract).
    @Test func readOnlyPolicyDoesNotStoreOnMiss() async throws {
        let cache = makeCache()
        let u = uid("readonly")
        let net = Data("net-bytes".utf8)
        let spy = SpyMediaProvider(bytes: net)
        let helper = EncryptedOriginalProvider(media: spy, cache: cache, policy: .readOnly)

        let out = try await helper.originalData(for: u)

        #expect(out == net)
        #expect(await spy.originalCallCount == 1)
        #expect(cache.diskData(for: u) == nil)       // export read must not seed the cache
    }
}
