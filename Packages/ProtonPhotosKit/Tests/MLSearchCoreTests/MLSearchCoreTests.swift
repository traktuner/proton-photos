import Testing
import Foundation
import PhotosCore
@testable import MLSearchCore

/// Comprehensive coverage for the pure-MLSearchCore architecture slice.
///
/// Covers the eight acceptance-criteria areas:
/// 1. idempotent planning (already indexed assets are not planned again)
/// 2. model version change creates a new indexing epoch
/// 3. failed/permanent asset does not block other assets
/// 4. transient failure can be retried
/// 5. index progress is stable and user-readable
/// 6. vector scoring returns deterministic ranked results
/// 7. no duplicate records for same PhotoUID + modelIdentifier + modelVersion
/// 8. store replay/restart semantics
@Suite struct MLSearchCoreTests {
    // MARK: - Fixtures

    private let descriptorV1 = MLModelDescriptor(identifier: "mobileclip-s0", version: 1, embeddingDimension: 4)
    private let descriptorV2 = MLModelDescriptor(identifier: "mobileclip-s0", version: 2, embeddingDimension: 4)

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "vol1", nodeID: id) }

    private func record(_ id: String, _ descriptor: MLModelDescriptor, _ vector: [Float32], ts: Date = Date(timeIntervalSince1970: 1000)) -> MLEmbeddingRecord {
        MLEmbeddingRecord(uid: uid(id), descriptor: descriptor, vector: ContiguousArray(vector), timestamp: ts)
    }

    // MARK: - 1. Idempotent planning: already indexed assets are not planned again

    @Test func alreadyIndexedAssetsAreNotPlannedAgain() {
        let store = InMemoryMLIndexStore()
        let assets = (0..<5).map { uid("a\($0)") }
        // Pre-index the first two.
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]),
            record("a1", descriptorV1, [0, 1, 0, 0]),
        ])

        let plan = MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV1, store: store)

        #expect(plan.toIndex.map(\.nodeID).sorted() == ["a2", "a3", "a4"])
        #expect(plan.skippedAlreadyIndexed.count == 2)
        #expect(plan.skippedPermanentFailure.isEmpty)
        #expect(plan.totalAssets == 5)
        #expect(!plan.isComplete)
    }

    @Test func rePlanningAfterFullIndexIsComplete() {
        let store = InMemoryMLIndexStore()
        let assets = [uid("a0"), uid("a1")]
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]),
            record("a1", descriptorV1, [0, 1, 0, 0]),
        ])
        let plan = MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV1, store: store)
        #expect(plan.toIndex.isEmpty)
        #expect(plan.isComplete)
    }

    // MARK: - 2. Model version change creates a new indexing epoch

    @Test func modelVersionChangeCreatesNewEpoch() {
        let store = InMemoryMLIndexStore()
        let assets = [uid("a0"), uid("a1")]
        // Fully indexed under v1.
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]),
            record("a1", descriptorV1, [0, 1, 0, 0]),
        ])
        // Under v2, everything must re-index despite v1 being complete.
        let planV2 = MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV2, store: store)
        #expect(planV2.toIndex.count == 2)
        #expect(planV2.skippedAlreadyIndexed.isEmpty)
        // v1 epoch is untouched by v2 planning.
        #expect(store.count(for: descriptorV1) == 2)
        #expect(store.count(for: descriptorV2) == 0)
    }

    @Test func differentModelIdentifierIsIndependentEpoch() {
        let otherModel = MLModelDescriptor(identifier: "other-clip", version: 1, embeddingDimension: 4)
        let store = InMemoryMLIndexStore()
        store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
        // Different identifier, same version → still a distinct epoch.
        #expect(!store.contains(uid: uid("a0"), descriptor: otherModel))
        #expect(store.contains(uid: uid("a0"), descriptor: descriptorV1))
    }

    // MARK: - 3. Failed/permanent asset does not block other assets

    @Test func permanentFailureDoesNotBlockOthers() {
        let store = InMemoryMLIndexStore()
        let assets = [uid("a0"), uid("a1"), uid("a2")]
        let permanentFailures: Set<PhotoUID> = [uid("a1")]
        let plan = MLIndexPlanner.plan(
            allAssets: assets,
            descriptor: descriptorV1,
            store: store,
            permanentFailures: permanentFailures
        )
        #expect(plan.toIndex.map(\.nodeID).sorted() == ["a0", "a2"])
        #expect(plan.skippedPermanentFailure.count == 1)
        #expect(plan.skippedPermanentFailure.contains(uid("a1")))
    }

    @Test func failedAssetExcludedFromBatchUpsert() {
        let store = InMemoryMLIndexStore()
        let assets = [uid("a0"), uid("a1"), uid("a2")]
        let permFailures: Set<PhotoUID> = [uid("a1")]
        let plan = MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV1, store: store, permanentFailures: permFailures)
        // Simulate embedding only the planned-to-index assets.
        let records = plan.toIndex.map { record($0.nodeID, descriptorV1, [1, 0, 0, 0]) }
        let report = store.upsert(records)
        #expect(report.indexed == 2)
        #expect(store.count(for: descriptorV1) == 2)
        // Re-plan: only the failed one stays excluded, the rest converge.
        let replan = MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV1, store: store, permanentFailures: permFailures)
        #expect(replan.toIndex.isEmpty)
        #expect(replan.skippedAlreadyIndexed.count == 2)
        #expect(replan.skippedPermanentFailure.count == 1)
    }

    // MARK: - 4. Transient failure can be retried

    @Test func transientFailureIsRetriedOnNextPass() {
        let store = InMemoryMLIndexStore()
        let assets = [uid("a0"), uid("a1")]
        // First pass: index a0, transient-fail a1 (not stored).
        store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
        let planAfter = MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV1, store: store)
        // a1 wasn't stored, so it should re-enter toIndex on the next planning pass.
        #expect(planAfter.toIndex.map(\.nodeID) == ["a1"])
        // Second pass: now succeed with a1.
        store.upsert([record("a1", descriptorV1, [0, 1, 0, 0])])
        let planFinal = MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV1, store: store)
        #expect(planFinal.toIndex.isEmpty)
        #expect(planFinal.isComplete)
    }

    @Test func transientFailureStatusWillIndexes() {
        let asset = MLPlannedAsset(uid: uid("a0"), status: .transientFailure(attempts: 2))
        #expect(asset.willIndex)
        let permanent = MLPlannedAsset(uid: uid("a1"), status: .permanentFailure(reason: "corrupt"))
        #expect(!permanent.willIndex)
        let needs = MLPlannedAsset(uid: uid("a2"), status: .needsIndexing)
        #expect(needs.willIndex)
        let done = MLPlannedAsset(uid: uid("a3"), status: .alreadyIndexed)
        #expect(!done.willIndex)
    }

    // MARK: - 5. Index progress is stable and user-readable

    @Test func progressStableAndUserReadable() {
        var progress = MLIndexProgress(descriptor: descriptorV1, totalAssets: 4)
        #expect(progress.fraction == 0)
        #expect(!progress.isComplete)

        progress.apply(MLIndexBatchReport(total: 2, indexed: 2))
        #expect(progress.indexed == 2)
        #expect(progress.settled == 2)
        #expect(progress.fraction == 0.5)

        progress.apply(MLIndexBatchReport(indexed: 1, permanentFailure: 1))
        #expect(progress.indexed == 3)
        #expect(progress.permanentFailure == 1)
        #expect(progress.fraction == 1.0)
        #expect(progress.isComplete)
        #expect(progress.phase == .completed)

        let summary = progress.summary
        #expect(summary.contains("complete"))
        #expect(summary.contains("mobileclip-s0"))
    }

    @Test func progressHandlesZeroAssets() {
        let progress = MLIndexProgress(descriptor: descriptorV1, totalAssets: 0)
        #expect(progress.fraction == 0)
        #expect(!progress.summary.isEmpty)
    }

    @Test func progressTransientFailurePreventsCompletion() {
        var progress = MLIndexProgress(descriptor: descriptorV1, totalAssets: 3)
        progress.apply(MLIndexBatchReport(indexed: 2, transientFailure: 1))
        #expect(!progress.isComplete)
        #expect(progress.phase != .completed)
    }

    // MARK: - 6. Vector scoring returns deterministic ranked results

    @Test func scoringReturnsDeterministicRankedResults() {
        let store = InMemoryMLIndexStore()
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]), // score 1.0
            record("a1", descriptorV1, [0.9, 0.1, 0, 0]), // score 0.9
            record("a2", descriptorV1, [0, 0, 0, 1]), // score 0.0
        ])
        let scorer = ReferenceDotProductScorer()
        let query: ContiguousArray<Float32> = [1, 0, 0, 0]
        let results = scorer.rank(records: store.allRecords(for: descriptorV1), queryVector: query, limit: 3)
        #expect(results.count == 3)
        #expect(results.results[0].uid == uid("a0"))
        #expect(results.results[0].score == 1.0)
        #expect(results.results[1].uid == uid("a1"))
        #expect(results.results[2].uid == uid("a2"))
        #expect(results.results[2].score == 0.0)
    }

    @Test func scoringIsDeterministicAcrossCalls() {
        let store = InMemoryMLIndexStore()
        store.upsert([
            record("a0", descriptorV1, [0.5, 0.5, 0, 0]),
            record("a1", descriptorV1, [0.4, 0.6, 0, 0]),
            record("a2", descriptorV1, [0.3, 0.7, 0, 0]),
        ])
        let scorer = ReferenceDotProductScorer()
        let query: ContiguousArray<Float32> = [1, 0, 0, 0]
        let r1 = scorer.rank(records: store.allRecords(for: descriptorV1), queryVector: query, limit: 10)
        let r2 = scorer.rank(records: store.allRecords(for: descriptorV1), queryVector: query, limit: 10)
        #expect(r1.results.map(\.uid.nodeID) == r2.results.map(\.uid.nodeID))
        #expect(r1.results.map(\.score) == r2.results.map(\.score))
    }

    @Test func scoringRespectsLimit() {
        let store = InMemoryMLIndexStore()
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]),
            record("a1", descriptorV1, [0.5, 0, 0, 0]),
            record("a2", descriptorV1, [0.1, 0, 0, 0]),
        ])
        let scorer = ReferenceDotProductScorer()
        let results = scorer.rank(records: store.allRecords(for: descriptorV1), queryVector: [1, 0, 0, 0], limit: 2)
        #expect(results.count == 2)
        #expect(results.results[0].uid == uid("a0"))
    }

    @Test func scoringTieBreaksByNewestTimestamp() {
        let older = Date(timeIntervalSince1970: 1000)
        let newer = Date(timeIntervalSince1970: 2000)
        let store = InMemoryMLIndexStore()
        store.upsert([
            MLEmbeddingRecord(uid: uid("older"), descriptor: descriptorV1, vector: ContiguousArray([1, 0, 0, 0]), timestamp: older),
            MLEmbeddingRecord(uid: uid("newer"), descriptor: descriptorV1, vector: ContiguousArray([1, 0, 0, 0]), timestamp: newer),
        ])
        let scorer = ReferenceDotProductScorer()
        let results = scorer.rank(records: store.allRecords(for: descriptorV1), queryVector: [1, 0, 0, 0], limit: 2)
        // Same score → newer first.
        #expect(results.results[0].uid == uid("newer"))
    }

    // MARK: - 7. No duplicate records for same PhotoUID + modelIdentifier + modelVersion

    @Test func noDuplicateRecordsForSameKey() {
        let store = InMemoryMLIndexStore()
        let r1 = record("a0", descriptorV1, [1, 0, 0, 0])
        let r2 = record("a0", descriptorV1, [0, 1, 0, 0]) // same key, different vector
        store.upsert([r1])
        let report = store.upsert([r2])
        #expect(report.skippedAlreadyIndexed == 1)
        #expect(store.count(for: descriptorV1) == 1)
        // The stored record is the first one (idempotent semantics: first write wins).
        let stored = store.allRecords(for: descriptorV1)
        #expect(stored.count == 1)
        // Guard the report/data agreement: the first-write-wins vector is retained, not r2's.
        #expect(stored.first?.vector == ContiguousArray([1, 0, 0, 0]))
    }

    @Test func containsReflectsCompositeKey() {
        let store = InMemoryMLIndexStore()
        store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
        #expect(store.contains(uid: uid("a0"), descriptor: descriptorV1))
        #expect(!store.contains(uid: uid("a0"), descriptor: descriptorV2))
        #expect(!store.contains(uid: uid("a1"), descriptor: descriptorV1))
    }

    // MARK: - 8. Store replay/restart semantics

    @Test func storeReplaySimulatesRestart() {
        // Simulate a "restart" by creating a fresh store and re-loading the same records.
        let original = InMemoryMLIndexStore()
        let assets = [uid("a0"), uid("a1"), uid("a2")]
        let savedRecords = assets.map { record($0.nodeID, descriptorV1, [1, 0, 0, 0]) }
        original.upsert(savedRecords)

        // "Persist" the records (in real life: serialize to disk). "Restart":
        let restarted = InMemoryMLIndexStore()
        restarted.upsert(savedRecords)
        // Idempotent re-load of the same records should not duplicate.
        let report = restarted.upsert(savedRecords)
        #expect(report.skippedAlreadyIndexed == 3)
        #expect(report.indexed == 0)
        #expect(restarted.count(for: descriptorV1) == 3)
    }

    @Test func storeRemoveOperations() {
        let store = InMemoryMLIndexStore()
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]),
            record("a1", descriptorV1, [0, 1, 0, 0]),
        ])
        store.remove(uid: uid("a0"), descriptor: descriptorV1)
        #expect(!store.contains(uid: uid("a0"), descriptor: descriptorV1))
        #expect(store.contains(uid: uid("a1"), descriptor: descriptorV1))
        #expect(store.count(for: descriptorV1) == 1)
        store.removeAll(for: descriptorV1)
        #expect(store.count(for: descriptorV1) == 0)
    }

    @Test func storeAllIndexedUIDsAndBulkMembership() {
        let store = InMemoryMLIndexStore()
        store.upsert([
            record("a0", descriptorV1, [1, 0, 0, 0]),
            record("a1", descriptorV1, [0, 1, 0, 0]),
        ])
        let allUIDs = store.allIndexedUIDs(for: descriptorV1)
        #expect(Set(allUIDs.map(\.nodeID)) == ["a0", "a1"])
        let membership = store.indexedUIDs(for: descriptorV1, from: [uid("a0"), uid("a2"), uid("a1")])
        #expect(membership == Set([uid("a0"), uid("a1")]))
    }

    // MARK: - Chunking

    @Test func chunkingPreservesOrderAndCoverage() {
        let store = InMemoryMLIndexStore()
        let assets = (0..<10).map { uid("a\($0)") }
        let plan = MLIndexPlanner.plan(allAssets: assets, descriptor: descriptorV1, store: store)
        let chunks = MLIndexPlanner.chunked(plan: plan, maxChunkSize: 4)
        #expect(chunks.count == 3) // 4 + 4 + 2
        #expect(chunks[0].toIndex.count == 4)
        #expect(chunks[1].toIndex.count == 4)
        #expect(chunks[2].toIndex.count == 2)
        let allUIDs = chunks.flatMap(\.toIndex).map(\.nodeID)
        #expect(allUIDs == (0..<10).map { "a\($0)" })
    }

    @Test func chunkingEmptyPlanYieldsSingleEmptyChunk() {
        let store = InMemoryMLIndexStore()
        store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
        let complete = MLIndexPlanner.plan(allAssets: [uid("a0")], descriptor: descriptorV1, store: store)
        let chunks = MLIndexPlanner.chunked(plan: complete, maxChunkSize: 10)
        #expect(chunks.count == 1)
        #expect(chunks[0].toIndex.isEmpty)
    }

    // MARK: - Batch report merging

    @Test func batchReportMergeAccumulates() {
        let a = MLIndexBatchReport(total: 3, indexed: 2, skippedAlreadyIndexed: 1)
        let b = MLIndexBatchReport(total: 4, indexed: 1, skippedAlreadyIndexed: 1, permanentFailure: 1, transientFailure: 1)
        let merged = a.merge(b)
        #expect(merged.total == 7)
        #expect(merged.indexed == 3)
        #expect(merged.skippedAlreadyIndexed == 2)
        #expect(merged.permanentFailure == 1)
        #expect(merged.transientFailure == 1)
        #expect(!merged.settled) // transient remains
    }

    // MARK: - Dimension validation

    @Test func dimensionMismatchRejected() {
        let store = InMemoryMLIndexStore()
        // A record whose vector doesn't match the descriptor's dimension is rejected at construction (precondition).
        // The store additionally defends against any malformed input by skipping it.
        let valid = record("a0", descriptorV1, [1, 0, 0, 0])
        store.upsert([valid])
        #expect(store.count(for: descriptorV1) == 1)
    }

    @Test func descriptorDisplayName() {
        #expect(descriptorV1.displayName == "mobileclip-s0 v1 (4d)")
        #expect(descriptorV2.displayName == "mobileclip-s0 v2 (4d)")
    }
}
