import Testing
import Foundation
import PhotosCore
@testable import MLSearchCore

/// End-to-end runner coverage with a scripted embedder: full pass, chunk-durable interruption
/// and resume, failure classification, cancellation, and honest progress states — all without
/// any model or platform code.
@Suite struct MLIndexRunnerTests {
    private let descriptor = MLModelDescriptor(identifier: "mobileclip-s0", version: 1, embeddingDimension: 4)

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "vol1", nodeID: id) }

    /// Deterministic embedder: vector derives from the uid; failures are scripted per uid.
    /// Counts embed calls so tests can prove what was (not) re-computed.
    private final class ScriptedEmbedder: MLAssetEmbedder, @unchecked Sendable {
        enum Script { case permanent, transientOnce }
        private let lock = NSLock()
        private var scripts: [PhotoUID: Script]
        private(set) var embedCalls: [PhotoUID] = []

        init(scripts: [PhotoUID: Script] = [:]) {
            self.scripts = scripts
        }

        func callCount(for uid: PhotoUID) -> Int {
            lock.withLock { embedCalls.filter { $0 == uid }.count }
        }

        var totalCalls: Int { lock.withLock { embedCalls.count } }

        func embed(uid: PhotoUID, descriptor: MLModelDescriptor) async -> MLEmbeddingOutcome {
            lock.withLock {
                embedCalls.append(uid)
                switch scripts[uid] {
                case .permanent:
                    return .permanentFailure(reason: "scripted")
                case .transientOnce:
                    scripts[uid] = nil // succeed on the next attempt
                    return .transientFailure
                case nil:
                    var vector = ContiguousArray<Float32>(repeating: 0, count: descriptor.embeddingDimension)
                    vector[0] = Float32(uid.nodeID.count)
                    return .embedded(vector)
                }
            }
        }
    }

    @Test func fullPassIndexesEverythingOnce() async {
        let store = InMemoryMLIndexStore()
        let embedder = ScriptedEmbedder()
        let runner = MLIndexRunner(store: store, embedder: embedder, configuration: .init(chunkSize: 3))
        let assets = (0..<10).map { uid("a\($0)") }

        let outcome = await runner.runPass(allAssets: assets, descriptor: descriptor)

        #expect(outcome.ranToCompletion)
        #expect(outcome.report.indexed == 10)
        #expect(store.count(for: descriptor) == 10)
        #expect(outcome.progress.phase == .completed)
        #expect(outcome.progress.isComplete)
        #expect(embedder.totalCalls == 10)

        // Second pass: nothing to do, nothing re-embedded.
        let second = await runner.runPass(allAssets: assets, descriptor: descriptor)
        #expect(second.ranToCompletion)
        #expect(second.report.indexed == 0)
        #expect(second.progress.phase == .completed)
        #expect(embedder.totalCalls == 10)
    }

    @Test func gateStopPersistsPartialChunkAndResumes() async {
        let store = InMemoryMLIndexStore()
        let gate = LockedGate(remainingAssets: 4)
        let embedder = ScriptedEmbedder()
        let runner = MLIndexRunner(
            store: store,
            embedder: embedder,
            configuration: .init(chunkSize: 10),
            shouldContinue: { gate.consumePermission() }
        )
        let assets = (0..<10).map { uid("a\($0)") }

        let first = await runner.runPass(allAssets: assets, descriptor: descriptor)
        #expect(!first.ranToCompletion)
        #expect(first.report.indexed == 4)
        #expect(store.count(for: descriptor) == 4) // partial chunk persisted before the stop
        #expect(first.progress.phase == .idle)      // never a false "completed"
        #expect(!first.progress.isComplete)

        // Fresh runner with an open gate: resumes from store state, re-embeds nothing.
        let resumed = MLIndexRunner(store: store, embedder: embedder, configuration: .init(chunkSize: 4))
        let second = await resumed.runPass(allAssets: assets, descriptor: descriptor)
        #expect(second.ranToCompletion)
        #expect(second.report.indexed == 6)
        #expect(store.count(for: descriptor) == 10)
        #expect(embedder.totalCalls == 10) // 4 + 6, no duplicates, no recompute
        #expect(second.progress.phase == .completed)
    }

    @Test func failureClassificationDrivesSchedulingAcrossPasses() async {
        let store = InMemoryMLIndexStore()
        let bad = uid("corrupt")
        let flaky = uid("flaky")
        let good = uid("good")
        let embedder = ScriptedEmbedder(scripts: [bad: .permanent, flaky: .transientOnce])
        let runner = MLIndexRunner(store: store, embedder: embedder)
        let assets = [bad, flaky, good]

        let first = await runner.runPass(allAssets: assets, descriptor: descriptor)
        #expect(first.ranToCompletion)
        #expect(first.report.indexed == 1)
        #expect(first.report.permanentFailure == 1)
        #expect(first.report.transientFailure == 1)
        #expect(first.newPermanentFailures == [bad])
        #expect(first.progress.phase == .idle) // transient pending → not complete
        #expect(!first.progress.isComplete)

        // Permanent failures are durable. Transient misses require no stored side channel:
        // absence from the index naturally schedules them on the next pass.
        #expect(store.failureRecords(for: descriptor, from: [flaky]).isEmpty)
        let second = await runner.runPass(allAssets: assets, descriptor: descriptor)
        #expect(second.ranToCompletion)
        #expect(second.report.indexed == 1)
        #expect(second.newPermanentFailures.isEmpty)
        #expect(store.count(for: descriptor) == 2)
        #expect(store.contains(uid: flaky, descriptor: descriptor))
        #expect(!store.contains(uid: bad, descriptor: descriptor))
        #expect(embedder.callCount(for: bad) == 1)   // permanent: never retried
        #expect(embedder.callCount(for: flaky) == 2) // transient: retried once, then stored
        #expect(second.progress.phase == .completed)
    }

    @Test func cancellationStopsBeforeStartingAnotherAsset() async {
        let store = InMemoryMLIndexStore()
        let embedder = CancellationBarrierEmbedder(stopAtCall: 3)
        let runner = MLIndexRunner(store: store, embedder: embedder, configuration: .init(chunkSize: 32))
        let assets = (0..<50).map { uid("a\($0)") }

        let pass = Task { await runner.runPass(allAssets: assets, descriptor: descriptor) }
        await embedder.waitUntilBlocked()
        pass.cancel()
        await embedder.resume()
        let outcome = await pass.value

        #expect(!outcome.ranToCompletion)
        #expect(outcome.report.indexed == 3)
        #expect(store.count(for: descriptor) == 3)
        #expect(await embedder.totalCalls == 3)
        #expect(outcome.progress.phase == .idle)
        #expect(!outcome.progress.isComplete)
    }

    @Test func progressCallbackIsMonotonicAndHonest() async {
        let store = InMemoryMLIndexStore()
        let embedder = ScriptedEmbedder()
        let snapshots = ProgressCollector()
        let runner = MLIndexRunner(
            store: store,
            embedder: embedder,
            configuration: .init(chunkSize: 2),
            onProgress: { snapshots.append($0) }
        )
        _ = await runner.runPass(allAssets: (0..<6).map { uid("a\($0)") }, descriptor: descriptor)

        let settledSeries = snapshots.value.map(\.settled)
        #expect(settledSeries == settledSeries.sorted()) // never goes backwards
        #expect(snapshots.value.last?.phase == .completed)
        #expect(snapshots.value.allSatisfy { $0.totalAssets == 6 })
    }
}

private actor CancellationBarrierEmbedder: MLAssetEmbedder {
    private let stopAtCall: Int
    private var calls = 0
    private var blocked = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    init(stopAtCall: Int) {
        self.stopAtCall = stopAtCall
    }

    var totalCalls: Int { calls }

    func embed(uid: PhotoUID, descriptor: MLModelDescriptor) async -> MLEmbeddingOutcome {
        calls += 1
        if calls == stopAtCall {
            blocked = true
            blockedWaiters.forEach { $0.resume() }
            blockedWaiters.removeAll()
            await withCheckedContinuation { resumeContinuation = $0 }
        }
        var vector = ContiguousArray<Float32>(repeating: 0, count: descriptor.embeddingDimension)
        vector[0] = 1
        return .embedded(vector)
    }

    func waitUntilBlocked() async {
        if blocked { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func resume() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

/// Minimal thread-safe helpers for scripting gates and capturing callbacks in tests.
private final class LockedGate: @unchecked Sendable {
    private let lock = NSLock()
    private var remainingAssets: Int

    init(remainingAssets: Int) {
        self.remainingAssets = remainingAssets
    }

    func consumePermission() -> Bool {
        lock.withLock {
            guard remainingAssets > 0 else { return false }
            remainingAssets -= 1
            return true
        }
    }
}

private final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MLIndexProgress] = []
    var value: [MLIndexProgress] { lock.withLock { stored } }
    func append(_ progress: MLIndexProgress) {
        lock.withLock { stored.append(progress) }
    }
}
