import Foundation
import PhotosCore
import Testing
@testable import MLSearchCore

@Suite struct MLSemanticSearchEngineTests {
    private let descriptor = MLModelDescriptor(identifier: "test-model", version: 1, embeddingDimension: 3)

    private func uid(_ value: String) -> PhotoUID {
        PhotoUID(volumeID: "v", nodeID: value)
    }

    private struct Encoder: MLTextQueryEncoder {
        let vector: ContiguousArray<Float32>
        func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32> {
            vector
        }
    }

    private struct DualEncoder: MLAssetEmbedder, MLTextQueryEncoder {
        func embed(uid: PhotoUID, descriptor: MLModelDescriptor) async -> MLEmbeddingOutcome {
            .embedded(uid.nodeID == "tree" ? [1, 0, 0] : [0, 1, 0])
        }

        func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32> {
            [1, 0, 0]
        }
    }

    @Test func normalizesQueryAndRanksSharedIndex() async throws {
        let store = InMemoryMLIndexStore()
        store.upsert([
            MLEmbeddingRecord(uid: uid("tree"), descriptor: descriptor, vector: [1, 0, 0]),
            MLEmbeddingRecord(uid: uid("water"), descriptor: descriptor, vector: [0, 1, 0]),
        ])
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [9, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )

        let result = try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "trees", limit: 2))
        #expect(result.results.map(\.uid.nodeID) == ["tree", "water"])
        #expect(abs((result.results.first?.score ?? 0) - 1) < 0.0001)
        #expect(result.durationMs != nil)
    }

    @Test func cachedBlockRefreshesAfterStoreGenerationChanges() async throws {
        let store = InMemoryMLIndexStore()
        store.upsert([MLEmbeddingRecord(uid: uid("first"), descriptor: descriptor, vector: [1, 0, 0])])
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )
        #expect(try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "x")).count == 1)

        store.upsert([MLEmbeddingRecord(uid: uid("second"), descriptor: descriptor, vector: [1, 0, 0])])
        #expect(try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "x")).count == 2)
    }

    @Test func switchingDescriptorDoesNotReusePreviousModelBlock() async throws {
        let other = MLModelDescriptor(identifier: "other-model", version: 1, embeddingDimension: 3)
        let store = InMemoryMLIndexStore()
        store.upsert([
            MLEmbeddingRecord(uid: uid("first"), descriptor: descriptor, vector: [1, 0, 0]),
            MLEmbeddingRecord(uid: uid("second"), descriptor: other, vector: [1, 0, 0]),
            MLEmbeddingRecord(uid: uid("third"), descriptor: other, vector: [1, 0, 0]),
        ])
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )

        #expect(try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "x")).count == 1)
        #expect(try await engine.search(MLSearchQuery(descriptor: other, queryText: "x")).count == 2)
        #expect(try await engine.search(MLSearchQuery(descriptor: descriptor, queryText: "x")).count == 1)
    }

    @Test func coverageDistinguishesSearchablePermanentAndPending() async {
        let store = InMemoryMLIndexStore()
        let indexed = uid("indexed")
        let permanent = uid("permanent")
        let pending = uid("pending")
        store.upsert([MLEmbeddingRecord(uid: indexed, descriptor: descriptor, vector: [1, 0, 0])])
        store.recordFailures([
            MLIndexFailureRecord(
                uid: permanent,
                descriptor: descriptor,
                kind: .permanent,
                reason: "unsupported",
                attempts: 1
            ),
        ])
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )

        let coverage = await engine.coverage(for: descriptor, allAssets: [indexed, permanent, pending])
        #expect(coverage.indexed == 1)
        #expect(coverage.permanentlyUnindexable == 1)
        #expect(coverage.pending == 1)
        #expect(!coverage.isComplete)
    }

    @Test func coverageCountsDuplicateHostUIDsOnce() async {
        let store = InMemoryMLIndexStore()
        let indexed = uid("indexed")
        store.upsert([MLEmbeddingRecord(uid: indexed, descriptor: descriptor, vector: [1, 0, 0])])
        let engine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )

        let coverage = await engine.coverage(
            for: descriptor,
            allAssets: [indexed, indexed, uid("pending"), uid("pending")]
        )

        #expect(coverage.total == 2)
        #expect(coverage.indexed == 1)
        #expect(coverage.pending == 1)
    }

    @Test func rejectsEmptyInvalidAndWrongDimensionQueries() async {
        let store = InMemoryMLIndexStore()
        let emptyEngine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )
        await #expect(throws: MLSemanticSearchError.emptyQuery) {
            try await emptyEngine.search(MLSearchQuery(descriptor: descriptor, queryText: "  "))
        }

        let zeroEngine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [0, 0, 0]),
            scorer: ReferenceDotProductScorer()
        )
        await #expect(throws: MLSemanticSearchError.invalidQueryEmbedding) {
            try await zeroEngine.search(MLSearchQuery(descriptor: descriptor, queryText: "x"))
        }

        let wrongEngine = MLSemanticSearchEngine(
            store: store,
            encoder: Encoder(vector: [1, 0]),
            scorer: ReferenceDotProductScorer()
        )
        await #expect(throws: MLSemanticSearchError.queryDimensionMismatch(expected: 3, actual: 2)) {
            try await wrongEngine.search(MLSearchQuery(descriptor: descriptor, queryText: "x"))
        }
    }

    @Test func serviceUsesOneDescriptorForIndexCoverageAndSearch() async throws {
        let assets = [uid("water"), uid("tree")]
        let encoder = DualEncoder()
        let releases = ReleaseCounter()
        let service = MLSearchService(
            descriptor: descriptor,
            store: InMemoryMLIndexStore(),
            assetEmbedder: encoder,
            textEncoder: encoder,
            scorer: ReferenceDotProductScorer(),
            releaseInferenceResources: { releases.increment() }
        )

        let indexed = await service.index(assets)
        #expect(indexed.report.indexed == 2)
        #expect(releases.value == 1)
        #expect(await service.coverage(for: assets).isComplete)
        let results = try await service.search("trees", limit: 1)
        #expect(results.descriptor == descriptor)
        #expect(results.results.map(\.uid.nodeID) == ["tree"])
        await service.releaseMemory()
        #expect(releases.value == 2)
    }
}

private final class ReleaseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}
