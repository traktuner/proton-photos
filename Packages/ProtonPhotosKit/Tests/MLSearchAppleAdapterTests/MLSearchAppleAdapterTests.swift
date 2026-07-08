import Testing
import Foundation
import CoreML
import PhotosCore
import MLSearchCore
@testable import MLSearchAppleAdapter

/// Architecture/compute-policy tests for `MLSearchAppleAdapter`.
///
/// Real model files aren't committed yet (license spike pending), so these tests exercise the
/// compute-policy surface, the availability facade stubs, and the Accelerate-backed scorer
/// (which is independent of any model artifact). They do NOT instantiate a real CoreML model.
@Suite struct MLSearchAppleAdapterTests {
    private let descriptor = MLModelDescriptor(identifier: "mobileclip-s0", version: 1, embeddingDimension: 4)
    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "vol1", nodeID: id) }

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

    @Test func cpuOnlyPolicyRoundTrips() {
        let policy = CoreMLComputePolicy.cpuOnly
        #expect(policy.computeUnits == .cpuOnly)
        #expect(policy.modelConfiguration.computeUnits == .cpuOnly)
    }

    @Test func performanceOptimizedUsesAllUnits() {
        let policy = CoreMLComputePolicy.performanceOptimized
        #expect(policy.computeUnits == .all)
    }

    @Test func policyEquality() {
        #expect(CoreMLComputePolicy.default == CoreMLComputePolicy(computeUnits: .cpuAndNeuralEngine))
        #expect(CoreMLComputePolicy.default != CoreMLComputePolicy.cpuOnly)
    }

    // MARK: - Model availability (stubs: no model committed yet)

    @Test func availabilityFacadeReturnsMissingForUncommittedModel() {
        // No `.mlmodelc` for "mobileclip-s0" is bundled in the test bundle, so the facade must
        // report missing rather than crash or fabricate a URL.
        let status = MLModelAvailabilityFacade.availability(for: descriptor)
        if case .missing(let returnedDescriptor) = status {
            #expect(returnedDescriptor == descriptor)
        } else {
            Issue.record("Expected .missing for uncommitted model, got \(status)")
        }
    }

    @Test func availabilityBooleanMatchesFacade() {
        // No model committed → isModelAvailable must be false.
        #expect(!MLModelAvailabilityFacade.isModelAvailable(for: descriptor))
    }

    @Test func diagnosticsStructReflectsStatus() {
        let status = MLModelAvailabilityFacade.availability(for: descriptor)
        let diag = MLModelDiagnostics(descriptor: descriptor, status: status)
        #expect(diag.descriptor == descriptor)
        #expect(!diag.isAvailable)
    }

    // MARK: - Accelerate vector scorer

    @Test func accelerateScorerRanksCorrectly() {
        let records = [
            MLEmbeddingRecord(uid: uid("a0"), descriptor: descriptor, vector: ContiguousArray([1, 0, 0, 0])),
            MLEmbeddingRecord(uid: uid("a1"), descriptor: descriptor, vector: ContiguousArray([0.5, 0.5, 0, 0])),
            MLEmbeddingRecord(uid: uid("a2"), descriptor: descriptor, vector: ContiguousArray([0, 0, 0, 1])),
        ]
        let scorer = AccelerateVectorScorer()
        let results = scorer.rank(records: records, queryVector: ContiguousArray([1, 0, 0, 0]), limit: 3)
        #expect(results.count == 3)
        #expect(results.results[0].uid == uid("a0"))
        #expect(results.results[0].score == 1.0)
        #expect(results.results[1].uid == uid("a1"))
        #expect(results.results[2].uid == uid("a2"))
        #expect(results.results[2].score == 0.0)
    }

    @Test func accelerateScorerMatchesReferenceImplementation() {
        // The Accelerate-backed scorer MUST agree with the pure-Swift reference oracle on
        // the same inputs (within Float epsilon).
        let records = [
            MLEmbeddingRecord(uid: uid("a0"), descriptor: descriptor, vector: ContiguousArray([0.9, 0.1, 0.2, 0.3])),
            MLEmbeddingRecord(uid: uid("a1"), descriptor: descriptor, vector: ContiguousArray([0.1, 0.8, 0.4, 0.2])),
            MLEmbeddingRecord(uid: uid("a2"), descriptor: descriptor, vector: ContiguousArray([0.2, 0.3, 0.5, 0.7])),
        ]
        let query = ContiguousArray<Float32>([0.5, 0.4, 0.3, 0.2])
        let accel = AccelerateVectorScorer()
        let ref = ReferenceDotProductScorer()

        let accelResults = accel.rank(records: records, queryVector: query, limit: 3)
        let refResults = ref.rank(records: records, queryVector: query, limit: 3)

        #expect(accelResults.results.map(\.uid.nodeID) == refResults.results.map(\.uid.nodeID))
        for (a, r) in zip(accelResults.results, refResults.results) {
            #expect(abs(a.score - r.score) < 1e-5)
        }
    }

    @Test func accelerateScorerDeterministicAcrossCalls() {
        let records = [
            MLEmbeddingRecord(uid: uid("a0"), descriptor: descriptor, vector: ContiguousArray([1, 0, 0, 0])),
            MLEmbeddingRecord(uid: uid("a1"), descriptor: descriptor, vector: ContiguousArray([0.5, 0.5, 0, 0])),
        ]
        let scorer = AccelerateVectorScorer()
        let q = ContiguousArray<Float32>([1, 0, 0, 0])
        let r1 = scorer.rank(records: records, queryVector: q, limit: 10)
        let r2 = scorer.rank(records: records, queryVector: q, limit: 10)
        #expect(r1.results.map(\.uid.nodeID) == r2.results.map(\.uid.nodeID))
        #expect(r1.results.map(\.score) == r2.results.map(\.score))
    }

    @Test func accelerateScorerRespectsLimit() {
        let records = (0..<5).map {
            MLEmbeddingRecord(uid: uid("a\($0)"), descriptor: descriptor, vector: ContiguousArray([Float($0), 0, 0, 0]))
        }
        let scorer = AccelerateVectorScorer()
        let results = scorer.rank(records: records, queryVector: ContiguousArray([1, 0, 0, 0]), limit: 2)
        #expect(results.count == 2)
    }

    @Test func accelerateScorerSkipsDimensionMismatch() {
        let good = MLEmbeddingRecord(uid: uid("a0"), descriptor: descriptor, vector: ContiguousArray([1, 0, 0, 0]))
        let records = [good]
        let scorer = AccelerateVectorScorer()
        // Query of different dimension must not crash and must skip mismatched records.
        let results = scorer.rank(records: records, queryVector: ContiguousArray([1, 0, 0, 0, 0]), limit: 5)
        #expect(results.isEmpty)
    }
}
