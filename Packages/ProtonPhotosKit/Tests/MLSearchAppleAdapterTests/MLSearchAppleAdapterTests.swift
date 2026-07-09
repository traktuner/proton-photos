import Testing
import Foundation
import CoreML
import PhotosCore
import MLSearchCore
@testable import MLSearchAppleAdapter

/// Architecture/compute-policy tests for `MLSearchAppleAdapter`.
///
/// Real model files aren't committed yet (license spike pending), so these tests exercise the
/// compute-policy surface, the model locator, and the Accelerate-backed scoring kernel
/// (which is independent of any model artifact). They do NOT instantiate a real CoreML model.
@Suite struct MLSearchAppleAdapterTests {
    private let descriptor = MLModelDescriptor(identifier: "mobileclip-s0", version: 1, embeddingDimension: 4)
    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "vol1", nodeID: id) }

    private func block(_ vectors: [(String, [Float32])]) -> MLVectorBlock {
        var block = MLVectorBlock(descriptor: descriptor)
        for (id, vector) in vectors {
            block.append(uid: uid(id), vector: ContiguousArray(vector))
        }
        return block
    }

    // MARK: - Compute policy

    @Test func defaultPolicyIsCpuAndNeuralEngine() {
        let policy = CoreMLComputePolicy.default
        #expect(policy.computeUnits == .cpuAndNeuralEngine)
    }

    @Test func policyProducesCorrectConfiguration() {
        let policy = CoreMLComputePolicy.default
        let config = policy.modelConfiguration
        #expect(config.computeUnits == .cpuAndNeuralEngine)
    }

    @Test func defaultInitAlsoMapsToCpuAndNeuralEngine() {
        let policy = CoreMLComputePolicy()
        #expect(policy.computeUnits == .cpuAndNeuralEngine)
        #expect(policy == .default)
    }

    @Test func policyEquality() {
        #expect(CoreMLComputePolicy.default == CoreMLComputePolicy())
    }

    @Test func noPublicProductionAPIExposesAllUnits() {
        // .all (GPU) must not be reachable as a production policy.
        let policy = CoreMLComputePolicy.default
        #expect(policy.computeUnits != .all)
    }

    @Test func noPublicProductionAPIExposesCpuOnly() {
        // .cpuOnly must not be reachable as a production policy.
        let policy = CoreMLComputePolicy.default
        #expect(policy.computeUnits != .cpuOnly)
    }

    // MARK: - Model locator

    @Test func locatorReportsMissingWhenBundleHasNoArtifact() throws {
        // A bundle without any `.mlmodelc` must report missing rather than crash or
        // fabricate a URL.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-locator-empty-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let bundle = try #require(Bundle(url: root))
        let locator = BundleMLModelLocator(bundle: bundle)
        let status = locator.availability(for: descriptor)
        #expect(status == .missing(descriptor: descriptor))
        #expect(!status.isAvailable)
    }

    @Test func locatorFindsArtifactInInjectedBundle() throws {
        // The bundle is injected, so availability is positively testable: a directory
        // containing `<identifier>.mlmodelc` acts as the host bundle.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-locator-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let artifact = root.appendingPathComponent("\(descriptor.identifier).mlmodelc", isDirectory: true)
        try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: true)

        let bundle = try #require(Bundle(url: root))
        let locator = BundleMLModelLocator(bundle: bundle)
        let status = locator.availability(for: descriptor)
        guard case .available(let url) = status else {
            Issue.record("Expected .available, got \(status)")
            return
        }
        #expect(url.lastPathComponent == "\(descriptor.identifier).mlmodelc")
        #expect(status.isAvailable)
    }

    // MARK: - Accelerate scoring kernel

    @Test func accelerateScorerRanksCorrectly() {
        let block = block([
            ("a0", [1, 0, 0, 0]),
            ("a1", [0.5, 0.5, 0, 0]),
            ("a2", [0, 0, 0, 1]),
        ])
        let results = AccelerateVectorScorer().rank(block: block, query: ContiguousArray([1, 0, 0, 0]), limit: 3)
        #expect(results.descriptor == descriptor)
        #expect(results.count == 3)
        #expect(results.results[0].uid == uid("a0"))
        #expect(results.results[0].score == 1.0)
        #expect(results.results[1].uid == uid("a1"))
        #expect(results.results[2].uid == uid("a2"))
        #expect(results.results[2].score == 0.0)
    }

    @Test func accelerateScorerMatchesReferenceImplementation() {
        // The Accelerate kernel MUST agree with the pure-Swift reference oracle on the same
        // inputs (within Float epsilon) — including result order, since ranking is shared.
        let block = block([
            ("a0", [0.9, 0.1, 0.2, 0.3]),
            ("a1", [0.1, 0.8, 0.4, 0.2]),
            ("a2", [0.2, 0.3, 0.5, 0.7]),
        ])
        let query = ContiguousArray<Float32>([0.5, 0.4, 0.3, 0.2])
        let accelResults = AccelerateVectorScorer().rank(block: block, query: query, limit: 3)
        let refResults = ReferenceDotProductScorer().rank(block: block, query: query, limit: 3)

        #expect(accelResults.results.map(\.uid.nodeID) == refResults.results.map(\.uid.nodeID))
        for (a, r) in zip(accelResults.results, refResults.results) {
            #expect(abs(a.score - r.score) < 1e-5)
        }
    }

    @Test func accelerateScorerDeterministicAcrossCalls() {
        let block = block([
            ("a0", [1, 0, 0, 0]),
            ("a1", [0.5, 0.5, 0, 0]),
        ])
        let q = ContiguousArray<Float32>([1, 0, 0, 0])
        let scorer = AccelerateVectorScorer()
        let r1 = scorer.rank(block: block, query: q, limit: 10)
        let r2 = scorer.rank(block: block, query: q, limit: 10)
        #expect(r1.results.map(\.uid.nodeID) == r2.results.map(\.uid.nodeID))
        #expect(r1.results.map(\.score) == r2.results.map(\.score))
    }

    @Test func accelerateScorerRespectsLimit() {
        let block = block((0..<5).map { ("a\($0)", [Float32($0), 0, 0, 0]) })
        let results = AccelerateVectorScorer().rank(block: block, query: ContiguousArray([1, 0, 0, 0]), limit: 2)
        #expect(results.count == 2)
        #expect(results.results[0].uid == uid("a4"))
    }

    @Test func accelerateScorerQueryDimensionMismatchIsEmpty() {
        let block = block([("a0", [1, 0, 0, 0])])
        // Query of different dimension must not crash and must return no results.
        let results = AccelerateVectorScorer().rank(block: block, query: ContiguousArray([1, 0, 0, 0, 0]), limit: 5)
        #expect(results.isEmpty)
    }

    @Test func accelerateScorerTieBreaksByRowOrderLikeReference() {
        let block = block([
            ("b-later", [1, 0, 0, 0]),
            ("a-earlier", [1, 0, 0, 0]),
        ])
        let results = AccelerateVectorScorer().rank(block: block, query: ContiguousArray([1, 0, 0, 0]), limit: 2)
        // Shared ranking: equal scores break by row order (insertion order of the block).
        #expect(results.results.map(\.uid.nodeID) == ["b-later", "a-earlier"])
    }
}
