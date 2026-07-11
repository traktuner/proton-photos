import CryptoKit
import Foundation
import PhotosCore
import Testing
@testable import MLSearchCore

/// Universal lifecycle state machine: enable/download/activate/index, transactional model
/// switching, epoch isolation, crash recovery, and complete purge. Everything runs on real
/// Core components (installer, runner, in-memory or SQLite stores) with scripted transports,
/// embedders and governors — no CoreML, no network.
@Suite struct MLSmartSearchLifecycleTests {
    // MARK: - Fakes

    private final class ScriptedTransport: MLModelArtifactTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var payloads: [URL: Data]
        private var failuresRemaining: [URL: Int]
        private(set) var downloads = 0

        init(payloads: [URL: Data], failFirst: [URL: Int] = [:]) {
            self.payloads = payloads
            self.failuresRemaining = failFirst
        }

        func download(
            from url: URL,
            to destination: URL,
            expectedByteCount: Int64,
            progress: @escaping @Sendable (Int64, Int64?) -> Void
        ) async throws {
            let payload: Data = try lock.withLock {
                downloads += 1
                if let remaining = failuresRemaining[url], remaining > 0 {
                    failuresRemaining[url] = remaining - 1
                    throw URLError(.networkConnectionLost)
                }
                guard let data = payloads[url] else { throw URLError(.fileDoesNotExist) }
                return data
            }
            let total = Int64(payload.count)
            for step in 1...4 {
                progress(total * Int64(step) / 4, total)
            }
            try payload.write(to: destination)
        }

        var downloadCount: Int { lock.withLock { downloads } }
    }

    /// Embeds deterministic unit vectors and counts calls per uid.
    private final class CountingEmbedder: MLAssetEmbedder, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var calls: [PhotoUID: Int] = [:]

        func embed(uid: PhotoUID, descriptor: MLModelDescriptor) async -> MLEmbeddingOutcome {
            lock.withLock { calls[uid, default: 0] += 1 }
            var vector = ContiguousArray<Float32>(repeating: 0, count: descriptor.embeddingDimension)
            let index = Int(UInt(bitPattern: uid.nodeID.hashValue) % UInt(descriptor.embeddingDimension))
            vector[index] = 1
            return .embedded(vector)
        }

        func callCount(_ uid: PhotoUID) -> Int { lock.withLock { calls[uid] ?? 0 } }
        var totalCalls: Int { lock.withLock { calls.values.reduce(0, +) } }
    }

    private struct FixedTextEncoder: MLTextQueryEncoder {
        func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32> {
            var vector = ContiguousArray<Float32>(repeating: 0, count: descriptor.embeddingDimension)
            vector[0] = 1
            return vector
        }
    }

    /// Builds real `MLSearchService` sessions over the shared store; scriptable failures.
    private final class ScriptedRuntimeProvider: MLSmartSearchRuntimeProvider, @unchecked Sendable {
        private let lock = NSLock()
        let embedder = CountingEmbedder()
        private var failNextMakeSession = false
        private(set) var sessionsBuilt = 0
        /// When set, `makeSession` returns this instead of a real service.
        var sessionOverride: (@Sendable (MLInstalledModel) -> any MLSmartSearchSession)?

        struct MakeSessionFailure: Error {}

        func failNext() { lock.withLock { failNextMakeSession = true } }
        var builtCount: Int { lock.withLock { sessionsBuilt } }

        func makeSession(
            model: MLInstalledModel,
            store: any MLIndexStore,
            shouldContinueIndexing: @escaping @Sendable () -> Bool,
            onIndexProgress: @escaping @Sendable (MLIndexProgress) -> Void
        ) async throws -> any MLSmartSearchSession {
            let shouldFail = lock.withLock {
                let fail = failNextMakeSession
                failNextMakeSession = false
                if !fail { sessionsBuilt += 1 }
                return fail
            }
            if shouldFail { throw MakeSessionFailure() }
            if let sessionOverride {
                return sessionOverride(model)
            }
            return MLSearchService(
                descriptor: model.entry.descriptor,
                store: store,
                assetEmbedder: embedder,
                textEncoder: FixedTextEncoder(),
                scorer: ReferenceDotProductScorer(),
                runnerConfiguration: .init(chunkSize: 8),
                shouldContinue: shouldContinueIndexing,
                onProgress: onIndexProgress
            )
        }
    }

    private final class InMemoryStoreProvider: MLIndexStoreProvider, @unchecked Sendable {
        let store = InMemoryMLIndexStore()
        private let lock = NSLock()
        private var closes = 0
        func openStore() -> (any MLIndexStore)? { store }
        func closeStore() { lock.withLock { closes += 1 } }
        var closeCount: Int { lock.withLock { closes } }
    }

    /// File-backed state store whose saves can be scripted to fail (journal-write faults).
    private final class FlakyStateStore: MLSmartSearchStateStore, @unchecked Sendable {
        struct WriteFailure: Error {}
        private let backing: FileMLSmartSearchStateStore
        private let lock = NSLock()
        private var failing = false
        private var failingActivationWrites = false

        init(layout: MLModelInstallLayout) {
            backing = FileMLSmartSearchStateStore(layout: layout)
        }

        func setFailing(_ value: Bool) { lock.withLock { failing = value } }
        func setFailingActivationWrites(_ value: Bool) {
            lock.withLock { failingActivationWrites = value }
        }
        func load() throws -> MLSmartSearchPersistentState? { try backing.load() }
        func save(_ state: MLSmartSearchPersistentState) throws {
            if lock.withLock({ failing || (failingActivationWrites && state.activatedRevision != nil) }) {
                throw WriteFailure()
            }
            try backing.save(state)
        }
        func clear() { backing.clear() }
    }

    private final class TrackingSession: MLSmartSearchSession, @unchecked Sendable {
        let descriptor: MLModelDescriptor
        private let lock = NSLock()
        private var indexes = 0
        private var shutdowns = 0

        init(descriptor: MLModelDescriptor) { self.descriptor = descriptor }

        func index(_ assets: [PhotoUID]) async -> MLIndexPassOutcome {
            lock.withLock { indexes += 1 }
            return MLIndexPassOutcome(
                report: MLIndexBatchReport(),
                ranToCompletion: false,
                newPermanentFailures: [],
                progress: MLIndexProgress(phase: .idle, descriptor: descriptor)
            )
        }

        func search(_ text: String, limit: Int) async throws -> MLSearchResults {
            MLSearchResults(descriptor: descriptor, queryText: text, results: [])
        }

        func releaseMemory() async {}
        func shutdown() async { lock.withLock { shutdowns += 1 } }

        var indexCount: Int { lock.withLock { indexes } }
        var shutdownCount: Int { lock.withLock { shutdowns } }
    }

    private final class SessionRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [TrackingSession] = []

        func make(_ model: MLInstalledModel) -> TrackingSession {
            let session = TrackingSession(descriptor: model.entry.descriptor)
            lock.withLock { storage.append(session) }
            return session
        }

        var sessions: [TrackingSession] { lock.withLock { storage } }
    }

    private final class MutableAssets: @unchecked Sendable {
        private let lock = NSLock()
        private var uids: [PhotoUID]
        init(_ uids: [PhotoUID]) { self.uids = uids }
        var current: [PhotoUID] { lock.withLock { uids } }
        func set(_ new: [PhotoUID]) { lock.withLock { uids = new } }
    }

    private final class ToggleGovernor: MLIndexingGovernor, @unchecked Sendable {
        private let lock = NSLock()
        private var permitted = true
        func permitsIndexing() -> Bool { lock.withLock { permitted } }
        func set(_ value: Bool) { lock.withLock { permitted = value } }
    }

    // MARK: - Harness

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "vol1", nodeID: id) }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
    }

    private func downloadableEntry(id: String, payload: Data, track: MLModelReleaseTrack = .production) -> (MLModelCatalogEntry, URL) {
        let url = URL(string: "https://example.test/\(id)/weights.bin")!
        let qualification = track == .production ? MLModelReleaseQualification(
            artifactRevision: "rev1",
            hardwareModel: "test-device",
            osVersion: "test",
            peakResidentBytes: 1,
            imageP95Milliseconds: 1,
            textP95Milliseconds: 1,
            reachedSeriousThermalState: false,
            neuralEngineExecutionVerified: true,
            passed: true
        ) : nil
        let entry = MLModelCatalogEntry(
            id: MLModelID(id),
            displayName: id,
            family: "Test",
            descriptor: MLModelDescriptor(identifier: id, version: 1, embeddingDimension: 4),
            tokenizerID: "test-tokenizer",
            preprocessingID: "test-preprocessing",
            license: .mit,
            releaseTrack: track,
            estimatedInstalledBytes: Int64(payload.count),
            downloadPlan: MLModelDownloadPlan(revision: "rev1", items: [
                .init(url: url, artifact: MLModelArtifactSpec(relativePath: "weights.bin", sha256: sha256(payload), byteCount: Int64(payload.count))),
            ]),
            releaseQualification: qualification
        )
        return (entry, url)
    }

    private struct Harness {
        let lifecycle: MLSmartSearchLifecycle
        let layout: MLModelInstallLayout
        let stateStore: any MLSmartSearchStateStore
        let transport: ScriptedTransport
        let provider: ScriptedRuntimeProvider
        let storeProvider: InMemoryStoreProvider
        let assets: MutableAssets
        let governor: ToggleGovernor
    }

    private func makeHarness(
        catalog: MLModelCatalog,
        payloads: [URL: Data],
        assets: [PhotoUID],
        failFirst: [URL: Int] = [:],
        allowsDeveloperModels: Bool = true,
        root: URL? = nil,
        retryDelay: Duration = .seconds(60),
        stateStoreOverride: (any MLSmartSearchStateStore)? = nil
    ) throws -> Harness {
        let rootDir = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-lifecycle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let layout = MLModelInstallLayout(rootDirectory: rootDir)
        let transport = ScriptedTransport(payloads: payloads, failFirst: failFirst)
        let provider = ScriptedRuntimeProvider()
        let storeProvider = InMemoryStoreProvider()
        let mutableAssets = MutableAssets(assets)
        let governor = ToggleGovernor()
        let stateStore = stateStoreOverride ?? FileMLSmartSearchStateStore(layout: layout)
        let lifecycle = MLSmartSearchLifecycle(
            dependencies: .init(
                catalog: catalog,
                layout: layout,
                stateStore: stateStore,
                installer: MLModelInstaller(layout: layout, transport: transport),
                storeProvider: storeProvider,
                runtimeProvider: provider,
                assetsProvider: { mutableAssets.current },
                governor: governor,
                allowsDeveloperModels: allowsDeveloperModels
            ),
            configuration: .init(indexRetryDelay: retryDelay)
        )
        return Harness(
            lifecycle: lifecycle,
            layout: layout,
            stateStore: stateStore,
            transport: transport,
            provider: provider,
            storeProvider: storeProvider,
            assets: mutableAssets,
            governor: governor
        )
    }

    @discardableResult
    private func waitUntil(
        timeout: Duration = .seconds(10),
        _ predicate: @Sendable () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await predicate()
    }

    private func waitForCompleteIndex(_ harness: Harness, total: Int) async -> Bool {
        await waitUntil {
            let snapshot = await harness.lifecycle.currentSnapshot()
            if case .ready(let coverage) = snapshot.phase {
                return coverage.isComplete && coverage.total == total
            }
            return false
        }
    }

    // MARK: - Enable / download / index

    @Test func enableDownloadsInstallsAndIndexesToCompletion() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<20).map { uid("asset-\($0)") }
        let harness = try makeHarness(catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: assets)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        #expect(await harness.lifecycle.currentSnapshot().phase == .disabled)

        await harness.lifecycle.setEnabled(true)
        #expect(await waitForCompleteIndex(harness, total: assets.count))

        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.isEnabled)
        #expect(snapshot.selectedModelID == entryA.id)
        #expect(snapshot.isSearchAvailable)
        #expect(snapshot.installedModelBytes == Int64(payload.count))
        #expect(harness.storeProvider.store.count(for: entryA.descriptor) == assets.count)
        // Every asset embedded exactly once.
        #expect(harness.provider.embedder.totalCalls == assets.count)

        // Search returns epoch-consistent results.
        let results = try await harness.lifecycle.search("anything", limit: 5)
        #expect(results.descriptor == entryA.descriptor)
        #expect(!results.isEmpty)
    }

    @Test func modelWithoutHostedArtifactReportsNotDownloadable() async throws {
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [.tinyCLIPVit40M]),
            payloads: [:],
            assets: [uid("a")]
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        #expect(await harness.lifecycle.currentSnapshot().phase == .notInstalled(downloadable: false))
        #expect(harness.transport.downloadCount == 0)
    }

    @Test func failedDownloadIsRetryable() async throws {
        let payload = Data("retry-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-retry", payload: payload)
        let assets = [uid("a"), uid("b")]
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: assets,
            failFirst: [urlA: 1]
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        let failed = await waitUntil {
            if case .failed(let failure) = await harness.lifecycle.currentSnapshot().phase {
                return failure.kind == .download && failure.isRetryable
            }
            return false
        }
        #expect(failed)

        await harness.lifecycle.retry()
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(harness.transport.downloadCount == 2)
    }

    @Test func checksumMismatchFailsVerificationAndNeverActivates() async throws {
        let payload = Data("good-bytes".utf8)
        let urlA = URL(string: "https://example.test/model-bad/weights.bin")!
        // Pin a different hash than what the transport serves.
        let wrongSpec = MLModelArtifactSpec(relativePath: "weights.bin", sha256: sha256(Data("other".utf8)), byteCount: Int64(payload.count))
        let entryA = MLModelCatalogEntry(
            id: MLModelID("model-bad"),
            displayName: "model-bad",
            family: "Test",
            descriptor: MLModelDescriptor(identifier: "model-bad", version: 1, embeddingDimension: 4),
            tokenizerID: "t",
            preprocessingID: "p",
            license: .mit,
            releaseTrack: .production,
            estimatedInstalledBytes: 1,
            downloadPlan: MLModelDownloadPlan(revision: "rev1", items: [.init(url: urlA, artifact: wrongSpec)])
        )
        let harness = try makeHarness(catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: [uid("a")])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        let failed = await waitUntil {
            if case .failed(let failure) = await harness.lifecycle.currentSnapshot().phase {
                return failure.kind == .verification
            }
            return false
        }
        #expect(failed)
        #expect(harness.provider.builtCount == 0)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.modelDirectory(for: entryA.id).path))
    }

    // MARK: - Selection / switching

    @Test func sameSelectionDoesNotReindex() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<5).map { uid("asset-\($0)") }
        let harness = try makeHarness(catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: assets)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        let sessionsBefore = harness.provider.builtCount
        let embedsBefore = harness.provider.embedder.totalCalls

        await harness.lifecycle.select(entryA.id)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(harness.provider.builtCount == sessionsBefore)
        #expect(harness.provider.embedder.totalCalls == embedsBefore)
    }

    @Test func modelSwitchRetiresOldEpochCompletely() async throws {
        let payloadA = Data("model-a-bytes".utf8)
        let payloadB = Data("model-b-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let assets = (0..<10).map { uid("asset-\($0)") }
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB]),
            payloads: [urlA: payloadA, urlB: payloadB],
            assets: assets
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(harness.storeProvider.store.count(for: entryA.descriptor) == assets.count)

        await harness.lifecycle.select(entryB.id)
        #expect(await waitForCompleteIndex(harness, total: assets.count))

        // One clean reset: old epoch rows gone, old artifacts gone, new epoch complete.
        #expect(harness.storeProvider.store.count(for: entryA.descriptor) == 0)
        #expect(harness.storeProvider.store.count(for: entryB.descriptor) == assets.count)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.modelDirectory(for: entryA.id).path))
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.selectedModelID == entryB.id)

        let results = try await harness.lifecycle.search("anything", limit: 5)
        #expect(results.descriptor == entryB.descriptor)
    }

    @Test func staleQueryFromPreviousEpochIsDiscarded() async throws {
        /// Session whose search blocks until released, standing in for a slow old-epoch query.
        final class BlockingSession: MLSmartSearchSession, @unchecked Sendable {
            let descriptor: MLModelDescriptor
            private let lock = NSLock()
            private var releaseSearch: CheckedContinuation<Void, Never>?
            private var released = false

            init(descriptor: MLModelDescriptor) { self.descriptor = descriptor }

            func index(_ assets: [PhotoUID]) async -> MLIndexPassOutcome {
                MLIndexPassOutcome(
                    report: MLIndexBatchReport(total: assets.count, skippedAlreadyIndexed: assets.count),
                    ranToCompletion: true,
                    newPermanentFailures: [],
                    progress: MLIndexProgress(
                        phase: .completed,
                        descriptor: descriptor,
                        totalAssets: assets.count,
                        alreadyIndexed: assets.count
                    )
                )
            }

            func search(_ text: String, limit: Int) async throws -> MLSearchResults {
                await withCheckedContinuation { continuation in
                    let alreadyReleased = lock.withLock {
                        if released { return true }
                        releaseSearch = continuation
                        return false
                    }
                    if alreadyReleased { continuation.resume() }
                }
                return MLSearchResults(descriptor: descriptor, queryText: text, results: [
                    MLSearchResult(uid: PhotoUID(volumeID: "vol1", nodeID: "old-epoch"), score: 1),
                ])
            }

            func release() {
                let continuation = lock.withLock {
                    released = true
                    let c = releaseSearch
                    releaseSearch = nil
                    return c
                }
                continuation?.resume()
            }

            func releaseMemory() async {}
            func shutdown() async {}
        }

        let payloadA = Data("model-a-bytes".utf8)
        let payloadB = Data("model-b-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let assets = [uid("asset-0")]
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB]),
            payloads: [urlA: payloadA, urlB: payloadB],
            assets: assets
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        let blockingSession = BlockingSession(descriptor: entryA.descriptor)
        harness.provider.sessionOverride = { model in
            model.entry.id == entryA.id
                ? blockingSession
                : BlockingSession(descriptor: model.entry.descriptor)
        }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        _ = await waitUntil {
            if case .ready = await harness.lifecycle.currentSnapshot().phase { return true }
            return false
        }

        // Old-epoch query in flight…
        let pending = Task { try await harness.lifecycle.search("old query", limit: 5) }
        try? await Task.sleep(for: .milliseconds(100))
        // …the model switches…
        await harness.lifecycle.select(entryB.id)
        // …then the old query completes and must be discarded.
        blockingSession.release()
        await #expect(throws: MLSmartSearchQueryError.staleEpoch) {
            _ = try await pending.value
        }
    }

    // MARK: - Library changes

    @Test func newAndDeletedAssetsReconcileDuringIndexing() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let initial = (0..<4).map { uid("asset-\($0)") }
        let harness = try makeHarness(catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: initial)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        #expect(await waitForCompleteIndex(harness, total: initial.count))

        // New asset arrives, one asset is deleted.
        let added = uid("asset-new")
        var next = initial
        next.removeFirst()
        next.append(added)
        harness.assets.set(next)
        await harness.lifecycle.noteLibraryChanged()

        #expect(await waitUntil {
            harness.storeProvider.store.contains(uid: added, descriptor: entryA.descriptor)
                && !harness.storeProvider.store.contains(uid: initial[0], descriptor: entryA.descriptor)
        })
        // No duplicate work: unchanged assets embedded exactly once.
        #expect(harness.provider.embedder.callCount(initial[1]) == 1)
    }

    @Test func closedGovernorParksIndexingUntilConditionsChange() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<6).map { uid("asset-\($0)") }
        let harness = try makeHarness(catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: assets)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        harness.governor.set(false)
        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        _ = await waitUntil {
            if case .waiting = await harness.lifecycle.currentSnapshot().phase { return true }
            return false
        }
        try? await Task.sleep(for: .milliseconds(150))
        #expect(harness.provider.embedder.totalCalls == 0)

        harness.governor.set(true)
        await harness.lifecycle.noteConditionsChanged()
        #expect(await waitForCompleteIndex(harness, total: assets.count))
    }

    // MARK: - Disable / purge

    @Test func disablePurgesEverythingAndIsIdempotent() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<6).map { uid("asset-\($0)") }
        let harness = try makeHarness(catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: assets)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        // Sibling file outside the Smart Search root must survive the purge.
        let sibling = harness.layout.rootDirectory.deletingLastPathComponent()
            .appendingPathComponent("unrelated-\(UUID().uuidString).txt")
        try Data("keep me".utf8).write(to: sibling)
        defer { try? FileManager.default.removeItem(at: sibling) }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(FileManager.default.fileExists(atPath: harness.layout.rootDirectory.path))

        await harness.lifecycle.disableAndPurge()
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.phase == .disabled)
        #expect(!snapshot.isEnabled)
        #expect(!snapshot.isSearchAvailable)
        // The entire Smart Search root is gone: index DB + WAL/SHM, models, tmp, state file.
        #expect(!FileManager.default.fileExists(atPath: harness.layout.rootDirectory.path))
        #expect(FileManager.default.fileExists(atPath: sibling.path))
        #expect(try harness.stateStore.load() == nil)

        // Second disable is harmless.
        await harness.lifecycle.disableAndPurge()
        #expect(await harness.lifecycle.currentSnapshot().phase == .disabled)
    }

    @Test func purgeInventoryRemovesRealDatabaseAndSidecars() async throws {
        struct IdentityCipher: MLVectorCipher {
            func seal(_ plaintext: Data, context: MLVectorCipherContext) throws -> Data { plaintext }
            func open(_ ciphertext: Data, context: MLVectorCipherContext) throws -> Data { ciphertext }
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-purge-inventory-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)

        // Create the full artifact inventory: SQLite DB (+WAL via a write), a model install,
        // a partial download, and the state file.
        let storeProvider = SQLiteMLIndexStoreProvider(url: layout.indexDatabaseURL, cipher: IdentityCipher())
        let store = try #require(storeProvider.openStore())
        let descriptor = MLModelDescriptor(identifier: "model-a", version: 1, embeddingDimension: 4)
        store.upsert([MLEmbeddingRecord(uid: uid("a"), descriptor: descriptor, vector: [1, 0, 0, 0])])

        try FileManager.default.createDirectory(at: layout.installDirectory(for: MLModelID("model-a"), revision: "rev1"), withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: layout.installDirectory(for: MLModelID("model-a"), revision: "rev1").appendingPathComponent("weights.bin"))
        try FileManager.default.createDirectory(at: layout.temporaryDirectory, withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: layout.downloadFileURL(sha256: "deadbeef"))
        let stateStore = FileMLSmartSearchStateStore(layout: layout)
        try stateStore.save(MLSmartSearchPersistentState(isEnabled: true, selectedModelID: MLModelID("model-a")))

        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: [uid("a")],
            root: root
        )

        // Use the SQLite-backed provider for this test so purge must close real handles.
        let lifecycle = MLSmartSearchLifecycle(
            dependencies: .init(
                catalog: MLModelCatalog(entries: [entryA]),
                layout: layout,
                stateStore: stateStore,
                installer: MLModelInstaller(layout: layout, transport: harness.transport),
                storeProvider: storeProvider,
                runtimeProvider: harness.provider,
                assetsProvider: { [PhotoUID(volumeID: "vol1", nodeID: "a")] },
                governor: MLAlwaysPermitsIndexing(),
                allowsDeveloperModels: true
            )
        )
        await lifecycle.start()
        await lifecycle.disableAndPurge()

        #expect(!FileManager.default.fileExists(atPath: root.path))
        for url in layout.indexDatabaseFileURLs {
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func crashDuringPurgeCompletesOnNextStart() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-crash-purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)

        // Simulate a crash mid-purge: journal written, files still present.
        let stateStore = FileMLSmartSearchStateStore(layout: layout)
        try stateStore.save(MLSmartSearchPersistentState(
            isEnabled: false,
            selectedModelID: entryA.id,
            pendingOperation: .purge
        ))
        try FileManager.default.createDirectory(at: layout.modelsDirectory, withIntermediateDirectories: true)
        try Data("leftover".utf8).write(to: layout.modelsDirectory.appendingPathComponent("leftover.bin"))

        let harness = try makeHarness(catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: [uid("a")], root: root)
        await harness.lifecycle.start()

        #expect(await harness.lifecycle.currentSnapshot().phase == .disabled)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func crashBetweenInstallAndActivationRecoversWithoutRedownload() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<3).map { uid("asset-\($0)") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-crash-activate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)

        // First session: install completes (transport used once), then "crash" before the
        // state store records the activation.
        let installTransport = ScriptedTransport(payloads: [urlA: payload])
        let installer = MLModelInstaller(layout: layout, transport: installTransport)
        _ = try await installer.install(entryA) { _ in }
        #expect(installTransport.downloadCount == 1)
        try FileMLSmartSearchStateStore(layout: layout).save(
            MLSmartSearchPersistentState(isEnabled: true, selectedModelID: entryA.id, activatedRevision: nil)
        )

        // Relaunch: activation resumes from the verified install with zero downloads.
        let harness = try makeHarness(catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: assets, root: root)
        await harness.lifecycle.start()
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(harness.transport.downloadCount == 0)
    }

    @Test func crashMidSwitchRetiresOldEpochOnNextStart() async throws {
        let payloadA = Data("model-a-bytes".utf8)
        let payloadB = Data("model-b-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let assets = (0..<3).map { uid("asset-\($0)") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-crash-switch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = MLModelInstallLayout(rootDirectory: root)

        // Both models installed; switch journaled but interrupted before cleanup.
        let transport = ScriptedTransport(payloads: [urlA: payloadA, urlB: payloadB])
        let installer = MLModelInstaller(layout: layout, transport: transport)
        _ = try await installer.install(entryA) { _ in }
        _ = try await installer.install(entryB) { _ in }
        try FileMLSmartSearchStateStore(layout: layout).save(MLSmartSearchPersistentState(
            isEnabled: true,
            selectedModelID: entryB.id,
            activatedRevision: nil,
            pendingOperation: .switchModel(from: entryA.id, to: entryB.id)
        ))

        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB]),
            payloads: [urlA: payloadA, urlB: payloadB],
            assets: assets,
            root: root
        )
        // Seed old-epoch rows that the recovery must remove.
        harness.storeProvider.store.upsert([
            MLEmbeddingRecord(uid: assets[0], descriptor: entryA.descriptor, vector: [1, 0, 0, 0]),
        ])

        await harness.lifecycle.start()
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(harness.storeProvider.store.count(for: entryA.descriptor) == 0)
        #expect(harness.storeProvider.store.count(for: entryB.descriptor) == assets.count)
        #expect(await waitUntil {
            !FileManager.default.fileExists(atPath: layout.modelDirectory(for: entryA.id).path)
        })
        #expect(harness.transport.downloadCount == 0)
    }

    // MARK: - Environment / policy

    @Test func developerModelsAreInvisibleAndUnselectableWithoutTheCapability() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let (entryDev, _) = downloadableEntry(id: "model-dev", payload: payload, track: .developerOnly)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA, entryDev]),
            payloads: [urlA: payload],
            assets: [uid("a")],
            allowsDeveloperModels: false
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        _ = await waitForCompleteIndex(harness, total: 1)

        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.availableModels.map(\.id) == [entryA.id])

        await harness.lifecycle.select(entryDev.id)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await harness.lifecycle.currentSnapshot().selectedModelID == entryA.id)
    }

    @Test func downloadProgressIsMonotonicAndCoalesced() async throws {
        let payload = Data(repeating: 0xAB, count: 1 << 16)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let harness = try makeHarness(catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: [uid("a")])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        let fractions = Fractions()
        let observation = Task {
            for await snapshot in await harness.lifecycle.snapshots() {
                if case .downloading(let progress) = snapshot.phase, let fraction = progress.fraction {
                    fractions.append(fraction)
                }
            }
        }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        #expect(await waitForCompleteIndex(harness, total: 1))
        observation.cancel()

        let seen = fractions.values
        #expect(seen == seen.sorted(), "download progress must be monotonic")
        #expect(seen.count <= 102, "download progress must be coalesced, saw \(seen.count) emissions")
    }

    private final class Fractions: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Double] = []
        func append(_ value: Double) { lock.withLock { storage.append(value) } }
        var values: [Double] { lock.withLock { storage } }
    }

    @Test func searchUnavailableWhileDisabledOrUncovered() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let harness = try makeHarness(catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: [uid("a")])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await #expect(throws: MLSmartSearchQueryError.unavailable) {
            _ = try await harness.lifecycle.search("query", limit: 5)
        }
    }

    // MARK: - Journal-write failures (state persistence is error-visible)

    private func makeFlakyHarness(
        catalog: MLModelCatalog,
        payloads: [URL: Data],
        assets: [PhotoUID]
    ) throws -> (Harness, FlakyStateStore) {
        let rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-lifecycle-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        let flaky = FlakyStateStore(layout: MLModelInstallLayout(rootDirectory: rootDir))
        let harness = try makeHarness(
            catalog: catalog,
            payloads: payloads,
            assets: assets,
            root: rootDir,
            stateStoreOverride: flaky
        )
        return (harness, flaky)
    }

    private func waitForStorageFailure(_ harness: Harness) async -> Bool {
        await waitUntil {
            if case .failed(let failure) = await harness.lifecycle.currentSnapshot().phase {
                return failure.kind == .storage && failure.isRetryable
            }
            return false
        }
    }

    @Test func failedEnableJournalWriteIsHonestAndRetryable() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<3).map { uid("asset-\($0)") }
        let (harness, flaky) = try makeFlakyHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: assets
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        flaky.setFailing(true)
        await harness.lifecycle.setEnabled(true)

        // The failed journal write is visible and retryable — and no download started on top
        // of an unpersisted enable.
        #expect(await waitForStorageFailure(harness))
        #expect(harness.transport.downloadCount == 0)
        #expect(try flaky.load() == nil)

        flaky.setFailing(false)
        await harness.lifecycle.retry()
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(try flaky.load()?.isEnabled == true)
    }

    @Test func failedActivationStateWriteClosesSessionAndNeverStartsIndexing() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let (harness, flaky) = try makeFlakyHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: [uid("asset-a")]
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }
        let recorder = SessionRecorder()
        harness.provider.sessionOverride = { recorder.make($0) }

        await harness.lifecycle.start()
        flaky.setFailingActivationWrites(true)
        await harness.lifecycle.setEnabled(true)

        #expect(await waitForStorageFailure(harness))
        #expect(harness.provider.builtCount == 1)
        #expect(recorder.sessions.count == 1)
        #expect(recorder.sessions[0].shutdownCount == 1)
        #expect(recorder.sessions[0].indexCount == 0)
        #expect(try flaky.load()?.activatedRevision == nil)
        await #expect(throws: MLSmartSearchQueryError.unavailable) {
            _ = try await harness.lifecycle.search("anything", limit: 3)
        }

        flaky.setFailingActivationWrites(false)
        await harness.lifecycle.retry()
        #expect(await waitUntil {
            recorder.sessions.count == 2 && recorder.sessions[1].indexCount > 0
        })
        #expect(harness.provider.builtCount == 2)
        #expect(recorder.sessions[0].shutdownCount == 1)
        await harness.lifecycle.shutdown()
    }

    @Test func corruptStateIsReportedAndCanBePurgedWithoutStartingWork() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: [uid("asset-a")]
        )
        try Data("not-json".utf8).write(to: harness.layout.stateFileURL)

        await harness.lifecycle.start()

        #expect(await waitForStorageFailure(harness))
        #expect(harness.provider.builtCount == 0)
        #expect(harness.transport.downloadCount == 0)

        await harness.lifecycle.disableAndPurge()
        #expect(await harness.lifecycle.currentSnapshot().phase == .disabled)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.rootDirectory.path))
    }

    @Test func failedSwitchJournalKeepsOldModelServing() async throws {
        let payloadA = Data("model-a-bytes".utf8)
        let payloadB = Data("model-b-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payloadA)
        let (entryB, urlB) = downloadableEntry(id: "model-b", payload: payloadB)
        let assets = (0..<4).map { uid("asset-\($0)") }
        let (harness, flaky) = try makeFlakyHarness(
            catalog: MLModelCatalog(entries: [entryA, entryB]),
            payloads: [urlA: payloadA, urlB: payloadB],
            assets: assets
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        #expect(await waitForCompleteIndex(harness, total: assets.count))

        // The switch journal cannot be written: the switch must never have happened.
        flaky.setFailing(true)
        await harness.lifecycle.select(entryB.id)

        #expect(await waitForStorageFailure(harness))
        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.selectedModelID == entryA.id)
        #expect(try flaky.load()?.selectedModelID == entryA.id)
        #expect(try flaky.load()?.pendingOperation == nil)
        // Old epoch still queryable — nothing was retired on an unjournaled switch.
        let results = try await harness.lifecycle.search("anything", limit: 3)
        #expect(results.descriptor == entryA.descriptor)
        #expect(harness.storeProvider.store.count(for: entryA.descriptor) == assets.count)

        flaky.setFailing(false)
        await harness.lifecycle.retry()
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        #expect(await harness.lifecycle.currentSnapshot().selectedModelID == entryA.id)
    }

    @Test func failedPurgeJournalDeletesNothingAndRetryCompletesThePurge() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<3).map { uid("asset-\($0)") }
        let (harness, flaky) = try makeFlakyHarness(
            catalog: MLModelCatalog(entries: [entryA]),
            payloads: [urlA: payload],
            assets: assets
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        #expect(await waitForCompleteIndex(harness, total: assets.count))

        flaky.setFailing(true)
        await harness.lifecycle.disableAndPurge()

        // Unjournaled purge must not delete a single file — a crash here would otherwise
        // leave an untracked half-purge.
        #expect(await waitForStorageFailure(harness))
        #expect(FileManager.default.fileExists(atPath: harness.layout.rootDirectory.path))
        #expect(FileManager.default.fileExists(atPath: harness.layout.modelDirectory(for: entryA.id).path))
        #expect(try flaky.load()?.isEnabled == true)

        flaky.setFailing(false)
        await harness.lifecycle.retry()
        #expect(await harness.lifecycle.currentSnapshot().phase == .disabled)
        #expect(!FileManager.default.fileExists(atPath: harness.layout.rootDirectory.path))
    }

    // MARK: - Ordered shutdown

    @Test func shutdownClosesStoreStopsIndexingAndRefusesNewWork() async throws {
        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let assets = (0..<6).map { uid("asset-\($0)") }
        let harness = try makeHarness(catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: assets)
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        #expect(await waitForCompleteIndex(harness, total: assets.count))
        let sessionsBefore = harness.provider.builtCount

        await harness.lifecycle.shutdown()

        // Store handle closed (SQLite/WAL in production), and every subsequent intent is a
        // no-op: no new sessions, no downloads, queries honestly unavailable.
        #expect(harness.storeProvider.closeCount == 1)
        await harness.lifecycle.setEnabled(true)
        await harness.lifecycle.select(entryA.id)
        await harness.lifecycle.retry()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(harness.provider.builtCount == sessionsBefore)
        await #expect(throws: MLSmartSearchQueryError.unavailable) {
            _ = try await harness.lifecycle.search("query", limit: 3)
        }
        // Idempotent.
        await harness.lifecycle.shutdown()
        #expect(harness.storeProvider.closeCount == 1)
    }

    @Test func shutdownAwaitsTheRunningIndexPassBeforeReturning() async throws {
        /// Session whose index pass blocks until released — stands in for CoreML mid-inference.
        final class BlockingIndexSession: MLSmartSearchSession, @unchecked Sendable {
            let descriptor: MLModelDescriptor
            private let lock = NSLock()
            private var releaseIndex: CheckedContinuation<Void, Never>?
            private var released = false
            private(set) var indexStarted = false

            init(descriptor: MLModelDescriptor) { self.descriptor = descriptor }

            func index(_ assets: [PhotoUID]) async -> MLIndexPassOutcome {
                lock.withLock { indexStarted = true }
                await withCheckedContinuation { continuation in
                    let alreadyReleased = lock.withLock {
                        if released { return true }
                        releaseIndex = continuation
                        return false
                    }
                    if alreadyReleased { continuation.resume() }
                }
                return MLIndexPassOutcome(
                    report: MLIndexBatchReport(),
                    ranToCompletion: false,
                    newPermanentFailures: [],
                    progress: MLIndexProgress(phase: .idle, descriptor: descriptor)
                )
            }

            func release() {
                let continuation = lock.withLock {
                    released = true
                    let c = releaseIndex
                    releaseIndex = nil
                    return c
                }
                continuation?.resume()
            }

            var started: Bool { lock.withLock { indexStarted } }

            func search(_ text: String, limit: Int) async throws -> MLSearchResults {
                MLSearchResults(descriptor: descriptor, queryText: text, results: [])
            }
            func releaseMemory() async {}
            func shutdown() async {}
        }

        let payload = Data("model-a-bytes".utf8)
        let (entryA, urlA) = downloadableEntry(id: "model-a", payload: payload)
        let harness = try makeHarness(catalog: MLModelCatalog(entries: [entryA]), payloads: [urlA: payload], assets: [uid("a")])
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        let blocking = BlockingIndexSession(descriptor: entryA.descriptor)
        harness.provider.sessionOverride = { _ in blocking }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        #expect(await waitUntil { blocking.started })

        let done = Completion()
        let shutdownTask = Task { [lifecycle = harness.lifecycle] in
            await lifecycle.shutdown()
            done.mark()
        }
        // The index pass is still blocked: shutdown MUST NOT complete yet (this is exactly
        // the sign-out/purge race — deleting files under a running pass).
        try? await Task.sleep(for: .milliseconds(150))
        #expect(!done.isDone)

        blocking.release()
        await shutdownTask.value
        #expect(done.isDone)
        #expect(harness.storeProvider.closeCount == 1)
    }

    private final class Completion: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func mark() { lock.withLock { done = true } }
        var isDone: Bool { lock.withLock { done } }
    }

    // MARK: - License gates

    @Test func researchOnlyLicenseIsUnselectableAndNeverDownloadsInRelease() async throws {
        let payload = Data("research-bytes".utf8)
        let url = URL(string: "https://example.test/research/weights.bin")!
        // Mislabeled entry: production track, research-only license, hosted plan. The license
        // must win everywhere: not listed, not auto-selected, never downloaded.
        let entry = MLModelCatalogEntry(
            id: MLModelID("model-research"),
            displayName: "model-research",
            family: "Test",
            descriptor: MLModelDescriptor(identifier: "model-research", version: 1, embeddingDimension: 4),
            tokenizerID: "t",
            preprocessingID: "p",
            license: .appleAMLR,
            releaseTrack: .production,
            estimatedInstalledBytes: 1,
            downloadPlan: MLModelDownloadPlan(revision: "rev1", items: [
                .init(url: url, artifact: MLModelArtifactSpec(relativePath: "weights.bin", sha256: sha256(payload), byteCount: Int64(payload.count))),
            ])
        )
        #expect(!entry.isDownloadable)
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [entry]),
            payloads: [url: payload],
            assets: [uid("a")],
            allowsDeveloperModels: false
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)
        try? await Task.sleep(for: .milliseconds(100))

        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(snapshot.availableModels.isEmpty)
        #expect(snapshot.selectedModelID == nil)
        #expect(harness.transport.downloadCount == 0)

        await harness.lifecycle.select(entry.id)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await harness.lifecycle.currentSnapshot().selectedModelID == nil)
        #expect(harness.transport.downloadCount == 0)
    }

    @Test func unhostedProductionModelCannotEnableInRelease() async throws {
        let harness = try makeHarness(
            catalog: MLModelCatalog(entries: [.tinyCLIPVit40M]),
            payloads: [:],
            assets: [uid("a")],
            allowsDeveloperModels: false
        )
        defer { try? FileManager.default.removeItem(at: harness.layout.rootDirectory) }

        await harness.lifecycle.start()
        await harness.lifecycle.setEnabled(true)

        let snapshot = await harness.lifecycle.currentSnapshot()
        #expect(!snapshot.isEnabled)
        #expect(snapshot.availableModels.isEmpty)
        #expect(snapshot.selectedModelID == nil)
        #expect(snapshot.phase == .notInstalled(downloadable: false))
        #expect(harness.transport.downloadCount == 0)
    }
}
