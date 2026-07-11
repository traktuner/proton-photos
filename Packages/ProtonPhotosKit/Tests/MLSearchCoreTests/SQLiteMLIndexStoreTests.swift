import Testing
import Foundation
import PhotosCore
@testable import MLSearchCore

struct TestMLVectorCipher: MLVectorCipher {
    private let mask: UInt8 = 0xA5

    func seal(_ plaintext: Data, context: MLVectorCipherContext) throws -> Data {
        Data(plaintext.map { $0 ^ mask })
    }

    func open(_ ciphertext: Data, context: MLVectorCipherContext) throws -> Data {
        Data(ciphertext.map { $0 ^ mask })
    }

    /// Length-preserving scheme → sealed size == plaintext size (enables the store's
    /// pre-decryption byte-count validation in tests).
    func sealedByteCount(forPlaintextByteCount plaintextByteCount: Int) -> Int? {
        plaintextByteCount
    }
}

/// Persistent-store coverage for `SQLiteMLIndexStore`.
///
/// Every test runs against a throwaway on-disk database (real SQLite, real reopen semantics).
/// The in-memory store shares the protocol-level tests in `MLSearchCoreTests`; this suite covers
/// what only a persistent implementation can get wrong: durability across reopen, first-write-wins
/// under a UNIQUE index, chunked membership, blob round-trips, and epoch isolation on disk.
@Suite struct SQLiteMLIndexStoreTests {
    private let descriptorV1 = MLModelDescriptor(identifier: "mobileclip-s0", version: 1, embeddingDimension: 4)
    private let descriptorV2 = MLModelDescriptor(identifier: "mobileclip-s0", version: 2, embeddingDimension: 4)

    private func uid(_ id: String) -> PhotoUID { PhotoUID(volumeID: "vol1", nodeID: id) }

    private func record(_ id: String, _ descriptor: MLModelDescriptor, _ vector: [Float32], captureTime: Date? = nil) -> MLEmbeddingRecord {
        MLEmbeddingRecord(
            uid: uid(id),
            descriptor: descriptor,
            vector: ContiguousArray(vector),
            timestamp: Date(timeIntervalSince1970: 1_000),
            captureTime: captureTime
        )
    }

    private func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ml-index-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent(SQLiteMLIndexStore.databaseFileName)
    }

    private func withStore(_ body: (SQLiteMLIndexStore, URL) throws -> Void) throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        try body(store, url)
        store.close()
    }

    // MARK: - 1. Round-trip

    @Test func roundTripsOneEmbedding() throws {
        try withStore { store, _ in
            let capture = Date(timeIntervalSince1970: 555)
            store.upsert([record("a0", descriptorV1, [0.1, 0.2, 0.3, 0.4], captureTime: capture)])

            let loaded = try #require(store.allRecords(for: descriptorV1).first)
            #expect(loaded.uid == uid("a0"))
            #expect(loaded.descriptor == descriptorV1)
            // Rows persist as binary16: the round trip returns the fp16-quantized values.
            let expected = ContiguousArray<Float32>([0.1, 0.2, 0.3, 0.4].map(MLFloat16Codec.quantized))
            #expect(loaded.vector == expected)
            for (stored, original) in zip(loaded.vector, [0.1, 0.2, 0.3, 0.4] as [Float32]) {
                #expect(abs(stored - original) <= abs(original) * 0.001)
            }
            #expect(loaded.timestamp == Date(timeIntervalSince1970: 1_000))
            #expect(loaded.captureTime == capture)
            #expect(store.contains(uid: uid("a0"), descriptor: descriptorV1))
        }
    }

    // MARK: - 2. Batch upsert

    @Test func batchUpsertStoresManyInOneTransaction() throws {
        try withStore { store, _ in
            let records = (0..<500).map { record("a\($0)", descriptorV1, [Float32($0), 0, 0, 0]) }
            let report = store.upsert(records)
            #expect(report.indexed == 500)
            #expect(report.skippedAlreadyIndexed == 0)
            #expect(store.count(for: descriptorV1) == 500)
        }
    }

    // MARK: - 3. Duplicate key is first-write-wins

    @Test func duplicateKeyIsFirstWriteWinsAndReported() throws {
        try withStore { store, _ in
            store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
            let report = store.upsert([record("a0", descriptorV1, [0, 9, 9, 9])])
            #expect(report.indexed == 0)
            #expect(report.skippedAlreadyIndexed == 1)
            #expect(store.count(for: descriptorV1) == 1)
            // The stored vector is the FIRST write — the report and the data agree.
            #expect(store.allRecords(for: descriptorV1).first?.vector == ContiguousArray<Float32>([1, 0, 0, 0]))
        }
    }

    // MARK: - 4. Dimension mismatch rejected

    @Test func dimensionMismatchRejectedAndCounted() throws {
        try withStore { store, _ in
            let report = store.upsert([
                record("a0", descriptorV1, [1, 0, 0, 0]),
                record("a1", descriptorV1, [1, 0]),
            ])
            #expect(report.indexed == 1)
            #expect(report.permanentFailure == 1)
            #expect(report.total == report.indexed + report.skippedAlreadyIndexed + report.permanentFailure + report.transientFailure)
            #expect(!store.contains(uid: uid("a1"), descriptor: descriptorV1))
        }
    }

    // MARK: - 5. Membership is epoch-scoped and chunked

    @Test func indexedUIDsIsEpochScopedAndHandlesLargeInputs() throws {
        try withStore { store, _ in
            store.upsert((0..<450).map { record("a\($0)", descriptorV1, [Float32($0), 0, 0, 0]) })
            store.upsert([record("v2only", descriptorV2, [1, 0, 0, 0])])

            // 901 probe uids exercise multiple 200-pair chunks; v2-only and unknown uids must not match.
            var probes = (0..<450).map { uid("a\($0)") }
            probes.append(contentsOf: (0..<450).map { uid("missing\($0)") })
            probes.append(uid("v2only"))
            let members = store.indexedUIDs(for: descriptorV1, from: probes)
            #expect(members.count == 450)
            #expect(!members.contains(uid("v2only")))
            #expect(!members.contains(uid("missing0")))
        }
    }

    // MARK: - 6. Model version change creates a separate epoch

    @Test func modelVersionChangeCreatesSeparateEpoch() throws {
        try withStore { store, _ in
            store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
            #expect(store.count(for: descriptorV2) == 0)
            #expect(!store.contains(uid: uid("a0"), descriptor: descriptorV2))

            store.upsert([record("a0", descriptorV2, [2, 0, 0, 0])])
            #expect(store.count(for: descriptorV1) == 1)
            #expect(store.count(for: descriptorV2) == 1)
            #expect(store.allRecords(for: descriptorV1).first?.vector.first == 1)
            #expect(store.allRecords(for: descriptorV2).first?.vector.first == 2)
        }
    }

    // MARK: - 7./8. Removal

    @Test func removeOneUID() throws {
        try withStore { store, _ in
            store.upsert([
                record("a0", descriptorV1, [1, 0, 0, 0]),
                record("a1", descriptorV1, [0, 1, 0, 0]),
            ])
            store.remove(uid: uid("a0"), descriptor: descriptorV1)
            #expect(!store.contains(uid: uid("a0"), descriptor: descriptorV1))
            #expect(store.contains(uid: uid("a1"), descriptor: descriptorV1))
            #expect(store.count(for: descriptorV1) == 1)
        }
    }

    @Test func batchRemovalUsesOneGenerationAndClearsFailureState() throws {
        try withStore { store, _ in
            store.upsert([
                record("a0", descriptorV1, [1, 0, 0, 0]),
                record("a1", descriptorV1, [0, 1, 0, 0]),
                record("keep", descriptorV1, [0, 0, 1, 0]),
            ])
            let failed = uid("failed")
            #expect(store.recordFailures([
                MLIndexFailureRecord(
                    uid: failed,
                    descriptor: descriptorV1,
                    kind: .permanent,
                    reason: "unsupported",
                    attempts: 1
                ),
            ]))
            #expect(Set(store.allTrackedUIDs(for: descriptorV1)) == [uid("a0"), uid("a1"), uid("keep"), failed])
            let generation = store.generation(for: descriptorV1)

            store.remove(uids: [uid("a0"), uid("a1"), failed], descriptor: descriptorV1)

            #expect(store.generation(for: descriptorV1) == generation + 1)
            #expect(store.allIndexedUIDs(for: descriptorV1) == [uid("keep")])
            #expect(store.failureRecords(for: descriptorV1, from: [failed]).isEmpty)
        }
    }

    @Test func removeAllForDescriptorLeavesOtherEpochsIntact() throws {
        try withStore { store, _ in
            store.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
            store.upsert([record("a0", descriptorV2, [1, 0, 0, 0])])
            store.removeAll(for: descriptorV1)
            #expect(store.count(for: descriptorV1) == 0)
            #expect(store.count(for: descriptorV2) == 1)
        }
    }

    // MARK: - 9. Reopen from disk

    @Test func reopenedStoreSeesPersistedRecords() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let first = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        first.upsert([
            record("a0", descriptorV1, [1, 2, 3, 4]),
            record("a1", descriptorV1, [5, 6, 7, 8]),
        ])
        first.close()

        let reopened = try #require(SQLiteMLIndexStore(url: url, cipher: TestMLVectorCipher()))
        defer { reopened.close() }
        #expect(reopened.count(for: descriptorV1) == 2)
        #expect(reopened.contains(uid: uid("a0"), descriptor: descriptorV1))
        #expect(reopened.allRecords(for: descriptorV1).map(\.uid.nodeID) == ["a0", "a1"])
        // Idempotent replay after restart: no duplicates.
        let replay = reopened.upsert([record("a0", descriptorV1, [1, 2, 3, 4])])
        #expect(replay.skippedAlreadyIndexed == 1)
        #expect(reopened.count(for: descriptorV1) == 2)
    }

    // MARK: - Vector block (query-path load)

    @Test func vectorBlockStreamsAllRowsInKeyOrder() throws {
        try withStore { store, _ in
            store.upsert([
                record("b1", descriptorV1, [0, 1, 0, 0]),
                record("a0", descriptorV1, [1, 0, 0, 0]),
            ])
            let block = store.vectorBlock(for: descriptorV1)
            #expect(block.count == 2)
            #expect(block.dimension == 4)
            #expect(block.uids.map(\.nodeID) == ["a0", "b1"])

            // The packed block must rank identically to the record path.
            let results = ReferenceDotProductScorer().rank(block: block, query: [1, 0, 0, 0], limit: 2)
            #expect(results.results.first?.uid == uid("a0"))
            #expect(results.results.first?.score == 1.0)
        }
    }

    @Test func generationChangesOnlyWhenVectorStateChangesAndSurvivesReopen() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cipher = TestMLVectorCipher()
        let first = try #require(SQLiteMLIndexStore(url: url, cipher: cipher))
        #expect(first.generation(for: descriptorV1) == 0)
        first.upsert([record("a0", descriptorV1, [1, 0, 0, 0])])
        let insertedGeneration = first.generation(for: descriptorV1)
        #expect(insertedGeneration > 0)
        first.upsert([record("a0", descriptorV1, [9, 9, 9, 9])])
        #expect(first.generation(for: descriptorV1) == insertedGeneration)
        first.close()

        let reopened = try #require(SQLiteMLIndexStore(url: url, cipher: cipher))
        defer { reopened.close() }
        #expect(reopened.generation(for: descriptorV1) == insertedGeneration)
        reopened.remove(uid: uid("a0"), descriptor: descriptorV1)
        #expect(reopened.generation(for: descriptorV1) > insertedGeneration)
    }

    @Test func failureStateIsDurableAndSuccessfulEmbeddingClearsIt() throws {
        let url = makeTempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let cipher = TestMLVectorCipher()
        let failedUID = uid("failed")
        let first = try #require(SQLiteMLIndexStore(url: url, cipher: cipher))
        #expect(first.recordFailures([
            MLIndexFailureRecord(
                uid: failedUID,
                descriptor: descriptorV1,
                kind: .transient,
                attempts: 2,
                updatedAt: Date(timeIntervalSince1970: 10)
            ),
        ]))
        first.close()

        let reopened = try #require(SQLiteMLIndexStore(url: url, cipher: cipher))
        defer { reopened.close() }
        #expect(reopened.failureRecords(for: descriptorV1, from: [failedUID])[failedUID]?.attempts == 2)
        reopened.upsert([record("failed", descriptorV1, [1, 0, 0, 0])])
        #expect(reopened.failureRecords(for: descriptorV1, from: [failedUID]).isEmpty)
    }

    // MARK: - 10. 20k structural smoke (guarded, not a benchmark)

    @Test(.timeLimit(.minutes(1))) func smokeTwentyThousandUpsertAndLoad() throws {
        try withStore { store, _ in
            let dimension = 64
            let descriptor = MLModelDescriptor(identifier: "smoke", version: 1, embeddingDimension: dimension)
            let batchSize = 2_000
            for batch in 0..<10 {
                let records = (0..<batchSize).map { i -> MLEmbeddingRecord in
                    let n = batch * batchSize + i
                    var vector = ContiguousArray<Float32>(repeating: 0, count: dimension)
                    vector[n % dimension] = Float32(n)
                    return MLEmbeddingRecord(
                        uid: PhotoUID(volumeID: "vol1", nodeID: String(format: "n%06d", n)),
                        descriptor: descriptor,
                        vector: vector,
                        timestamp: Date(timeIntervalSince1970: 1_000)
                    )
                }
                let report = store.upsert(records)
                #expect(report.indexed == batchSize)
            }
            #expect(store.count(for: descriptor) == 20_000)

            let block = store.vectorBlock(for: descriptor)
            #expect(block.count == 20_000)

            var query = ContiguousArray<Float32>(repeating: 0, count: dimension)
            query[0] = 1
            let results = ReferenceDotProductScorer().rank(block: block, query: query, limit: 5)
            #expect(results.count == 5)
            // Highest score: the largest n hitting slot 0 (n % 64 == 0) → n = 19_968.
            #expect(results.results.first?.uid.nodeID == "n019968")

            // Membership over the whole set stays chunked and index-only.
            let probes = (0..<20_000).map { PhotoUID(volumeID: "vol1", nodeID: String(format: "n%06d", $0)) }
            #expect(store.indexedUIDs(for: descriptor, from: probes).count == 20_000)
        }
    }
}
