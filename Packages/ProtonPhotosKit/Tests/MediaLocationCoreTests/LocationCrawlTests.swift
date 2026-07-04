import Testing
import Foundation
import CryptoKit
import PhotosCore
@testable import MediaLocationCore

private func uid(_ n: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: n) }
private func tempDir() -> URL {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("crawltest-" + UUID().uuidString)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}
private func makeStore(_ dir: URL) -> PhotoLocationStore {
    let store = PhotoLocationStore(directory: dir)
    store.configure(accountUID: "acct", key: SymmetricKey(size: .bits256))
    return store
}

/// Thread-safe flag/counter boxes for the `@Sendable` probe closures.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set(_ v: Bool) { lock.withLock { value = v } }
    func get() -> Bool { lock.withLock { value } }
}
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() -> Int { lock.withLock { count += 1; return count } }
    func value() -> Int { lock.withLock { count } }
}

private func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met within \(timeout)")
}

@Suite struct LocationCrawlTests {
    @Test func crawlInsertsCoordinatesPersistsAndCompletes() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero, mergeEvery: 2, saveEvery: 2)

        let uids = [uid("a"), uid("b"), uid("c")]
        await crawl.start(
            uids: uids,
            captureDates: [uid("a"): Date(timeIntervalSince1970: 1)],
            location: { u in
                u == uid("b") ? .noLocation : .found(latitude: 47.8, longitude: 13.0)
            },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.phase == .completed }

        let progress = await index.scanProgress
        #expect(await index.coordinates.count == 2)
        #expect(progress.scanned == 3)
        #expect(progress.total == 3)
        #expect(progress.found == 2)
        #expect(progress.noLocation == 1)
        #expect(progress.failed == 0)
        // Persisted (encrypted) snapshot round-trips.
        let reopened = PhotoLocationStore(directory: dir)
        #expect(reopened.load().isEmpty)   // wrong key/unconfigured reads empty
        #expect(store.load().count == 2)
    }

    @Test func emptyAndFailedProbesDoNotCrashAndAreCounted() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero)

        await crawl.start(
            uids: [uid("x"), uid("y")],
            captureDates: [:],
            location: { u in u == uid("x") ? .noLocation : .failed(category: "http-429") },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.phase == .completed }

        let progress = await index.scanProgress
        #expect(await index.coordinates.isEmpty)
        #expect(progress.noLocation == 1)
        #expect(progress.failed == 1)
        #expect(progress.phase == .completed)   // mixed outcome is a completed scan, not a failure
    }

    @Test func allProbesFailingReportsFailurePhaseNotNoPlaces() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero)

        await crawl.start(
            uids: [uid("x"), uid("y")],
            captureDates: [:],
            location: { _ in .failed(category: "offline") },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.phase == .failed }
        #expect(await index.scanProgress.phase == .failed)
    }

    @Test func firstCoordinatesPublishBeforeAllCandidatesAreScanned() async throws {
        // The map must fill progressively - pins appear after the first merged batch, NOT once the whole
        // run (or the thumbnail crawl) finishes.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero, mergeEvery: 1)
        let gate = Flag()   // blocks probes after the first, keeping the run "still scanning"

        let uids = (0 ..< 5).map { uid("p\($0)") }
        await crawl.start(
            uids: uids,
            captureDates: [:],
            location: { u in
                if u != uids[0] {
                    while !gate.get() { try? await Task.sleep(for: .milliseconds(5)) }
                }
                return .found(latitude: 47.8, longitude: 13.0)
            },
            index: index,
            store: store
        )

        // First coordinate lands while the crawl is provably still running (scanning, 4 items left).
        try await waitUntil { await !index.coordinates.isEmpty }
        let midRun = await index.scanProgress
        #expect(midRun.phase == .scanning, "index must publish while the crawl is still scanning")
        #expect(midRun.scanned < uids.count)
        #expect(await index.revision > 0)

        gate.set(true)
        try await waitUntil { await index.scanProgress.phase == .completed }
        #expect(await index.coordinates.count == uids.count)
    }

    @Test func scanningStateIsVisibleWhileRunningWithZeroFound() async throws {
        // The "Noch keine Orte" regression: with zero finds so far the UI must be able to say
        // "scanning", and may say "no geotagged photos" only after the crawl completes.
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero)
        let gate = Flag()

        await crawl.start(
            uids: [uid("a"), uid("b")],
            captureDates: [:],
            location: { _ in
                while !gate.get() { try? await Task.sleep(for: .milliseconds(5)) }
                return .noLocation
            },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.phase == .scanning }
        #expect(await index.coordinates.isEmpty)
        #expect(await index.scanProgress.phase == .scanning)   // UI: "scanning", NOT "no places yet"

        gate.set(true)
        try await waitUntil { await index.scanProgress.phase == .completed }
        #expect(await index.scanProgress.found == 0)           // UI: now honestly "no geotagged photos"
    }

    @Test func visibleDemandPausesCrawlWithoutPermanentStarvation() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        let crawl = LocationCrawl(throttle: .zero, backoff: .milliseconds(10))
        let demand = Flag(); demand.set(true)   // visible thumbnail pressure active from the start
        let probes = Counter()

        await crawl.start(
            uids: [uid("a"), uid("b")],
            captureDates: [:],
            location: { _ in _ = probes.increment(); return .noLocation },
            index: index,
            store: store,
            shouldYield: { demand.get() }
        )
        try await waitUntil { await index.scanProgress.phase == .scanning }
        try await Task.sleep(for: .milliseconds(80))
        #expect(probes.value() == 0, "crawl must back off while visible demand is active")

        demand.set(false)   // demand subsides → crawl must resume on its own
        try await waitUntil { await index.scanProgress.phase == .completed }
        #expect(probes.value() == 2, "crawl must resume and finish once demand subsides")
    }

    @Test func crawlSkipsAlreadyIndexedUIDs() async throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = makeStore(dir)
        let index = await PhotoLocationIndex()
        await index.replaceAll([PhotoCoordinate(uid: uid("done"), latitude: 1, longitude: 2, date: .distantPast)])
        let crawl = LocationCrawl(throttle: .zero)
        let probes = Counter()

        await crawl.start(
            uids: [uid("done"), uid("new")],
            captureDates: [:],
            location: { _ in _ = probes.increment(); return .found(latitude: 3, longitude: 4) },
            index: index,
            store: store
        )
        try await waitUntil { await index.scanProgress.phase == .completed }
        #expect(probes.value() == 1, "already-indexed uids must not be re-probed (resumable crawl)")
        #expect(await index.coordinates.count == 2)
    }
}
