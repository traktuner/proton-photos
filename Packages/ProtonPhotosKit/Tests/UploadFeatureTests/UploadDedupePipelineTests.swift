import Foundation
import XCTest
import PhotosCore
@testable import UploadCore

// MARK: - Fakes

/// In-memory `UploadIdentityStore`.
final class FakeIdentityStore: UploadIdentityStore, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [UploadSourceIdentity: UploadIdentityRecord] = [:]

    func record(for source: UploadSourceIdentity) -> UploadIdentityRecord? {
        lock.withLock { rows[source] }
    }

    func upsert(_ record: UploadIdentityRecord) {
        lock.withLock { rows[record.source] = record }
    }
}

/// Deterministic hasher: digest derived from the file path; counts invocations to prove cache
/// hits never rehash.
final class FakeHasher: UploadHashing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var hashCount = 0
    var delay: Duration?

    func sha1(of descriptor: UploadResourceDescriptor) async throws -> Data {
        lock.withLock { hashCount += 1 }
        if let delay {
            try await Task.sleep(for: delay)
        }
        try Task.checkCancellation()
        var digest = Data(repeating: 0, count: 20)
        for (i, byte) in descriptor.fileURL.path.utf8.enumerated() {
            digest[i % 20] ^= byte
        }
        return digest
    }
}

/// Scripted duplicate checker: nameHash = "nh(<name>)", contentHash = "ch(<sha1>)"; canned remote
/// items keyed by name hash; records every findDuplicates batch.
final class FakeChecker: UploadDuplicateChecking, @unchecked Sendable {
    private let lock = NSLock()
    var epoch = "epoch-1"
    var remoteItemsByNameHash: [String: [RemotePhotoDuplicate]] = [:]
    var findError: Error?
    private(set) var findBatches: [[String]] = []
    private(set) var nameHashCalls = 0

    func nameHash(forCorrectedName name: String) async throws -> String {
        lock.withLock { nameHashCalls += 1 }
        return "nh(\(name))"
    }

    func contentHash(forSHA1Hex sha1Hex: String) async throws -> String {
        "ch(\(sha1Hex))"
    }

    func findDuplicates(nameHashes: [String]) async throws -> [RemotePhotoDuplicate] {
        if let findError { throw findError }
        return lock.withLock {
            findBatches.append(nameHashes)
            return nameHashes.flatMap { hash in remoteItemsByNameHash[hash] ?? [] }
        }
    }

    func hashKeyEpoch() async throws -> String { epoch }

    var findCallCount: Int { lock.withLock { findBatches.count } }
}

// MARK: - Tests

final class UploadDedupePipelineTests: XCTestCase {

    private var store: FakeIdentityStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var pipeline: UploadDedupePipeline!

    override func setUp() {
        super.setUp()
        store = FakeIdentityStore()
        hasher = FakeHasher()
        checker = FakeChecker()
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
    }

    private func descriptor(
        path: String = "/photos/IMG_1.HEIC",
        filename: String? = nil,
        size: Int64 = 1000,
        mtime: TimeInterval = 1_700_000_000
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: .file(URL(fileURLWithPath: path)),
            fileURL: URL(fileURLWithPath: path),
            filename: filename ?? (path as NSString).lastPathComponent,
            fileSize: size,
            modificationDate: Date(timeIntervalSince1970: mtime)
        )
    }

    func testFreshFileWithNoRemoteMatchUploads() async throws {
        let result = try await pipeline.resolve(descriptor())

        XCTAssertEqual(result.decision, .upload)
        XCTAssertEqual(result.identity.correctedName, "IMG_1.HEIC")
        XCTAssertEqual(result.identity.nameHash, "nh(IMG_1.HEIC)")
        XCTAssertEqual(result.identity.contentHash, "ch(\(result.identity.sha1Hex))")
        XCTAssertEqual(result.identity.sha1Digest.count, 20)
        XCTAssertEqual(hasher.hashCount, 1)
        // Identity persisted (crash-safe) without an outcome.
        let row = store.record(for: .file(URL(fileURLWithPath: "/photos/IMG_1.HEIC")))
        XCTAssertEqual(row?.sha1Hex, result.identity.sha1Hex)
        XCTAssertNil(row?.outcome)
    }

    func testSecondResolveReusesCachedHashes() async throws {
        _ = try await pipeline.resolve(descriptor())
        let nameHashCallsAfterFirst = checker.nameHashCalls
        _ = try await pipeline.resolve(descriptor())

        XCTAssertEqual(hasher.hashCount, 1, "unchanged file must not rehash")
        XCTAssertEqual(checker.nameHashCalls, nameHashCallsAfterFirst, "valid manifest row must reuse HMACs")
    }

    func testChangedSizeInvalidatesCachedHashes() async throws {
        _ = try await pipeline.resolve(descriptor(size: 1000))
        _ = try await pipeline.resolve(descriptor(size: 1001))
        XCTAssertEqual(hasher.hashCount, 2)
    }

    func testChangedModificationDateInvalidatesCachedHashes() async throws {
        _ = try await pipeline.resolve(descriptor(mtime: 1_700_000_000))
        _ = try await pipeline.resolve(descriptor(mtime: 1_700_000_001))
        XCTAssertEqual(hasher.hashCount, 2)
    }

    func testHashKeyEpochChangeRecomputesHMACsButNotSHA1() async throws {
        _ = try await pipeline.resolve(descriptor())
        let callsAfterFirst = checker.nameHashCalls
        checker.epoch = "epoch-2"
        _ = try await pipeline.resolve(descriptor())

        XCTAssertEqual(hasher.hashCount, 1, "SHA-1 does not depend on the hash key")
        XCTAssertGreaterThan(checker.nameHashCalls, callsAfterFirst, "HMACs must be recomputed for a new key epoch")
    }

    func testActiveDuplicateSkipsAndPersistsOutcome() async throws {
        let d = descriptor()
        // Resolve once to learn the content hash the fake produces, then plant the remote twin.
        let probe = try await pipeline.resolve(d)
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(nameHash: "nh(IMG_1.HEIC)", contentHash: probe.identity.contentHash, linkState: .active, linkID: "link-9")
        ]
        // New pipeline so the (empty) per-run duplicate cache from the probe doesn't linger.
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)

        let result = try await pipeline.resolve(d)
        XCTAssertEqual(result.decision, .skip(.activeDuplicate, remoteLinkID: "link-9"))

        let row = store.record(for: d.source)
        XCTAssertEqual(row?.outcome, UploadIdentityManifestStore.Outcome.duplicateActive.rawValue)
        XCTAssertEqual(row?.remoteLinkID, "link-9")
    }

    func testManifestKnownDuplicateSkipsWithoutAnyRemoteCall() async throws {
        let d = descriptor()
        let probe = try await pipeline.resolve(d)
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(nameHash: "nh(IMG_1.HEIC)", contentHash: probe.identity.contentHash, linkState: .active, linkID: "link-9")
        ]
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        _ = try await pipeline.resolve(d)   // records duplicateActive
        let callsAfterConfirmation = checker.findCallCount
        let hashesAfterConfirmation = hasher.hashCount

        // Third resolve, fresh pipeline (fresh run): manifest fast path, no query, no hashing.
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let result = try await pipeline.resolve(d)

        XCTAssertEqual(result.decision, .skip(.knownFromManifest, remoteLinkID: "link-9"))
        XCTAssertEqual(checker.findCallCount, callsAfterConfirmation, "manifest hit must not re-query")
        XCTAssertEqual(hasher.hashCount, hashesAfterConfirmation, "manifest hit must not rehash")
    }

    func testRecordUploadedEnablesManifestFastPathNextRun() async throws {
        let d = descriptor()
        let result = try await pipeline.resolve(d)
        XCTAssertEqual(result.decision, .upload)
        await pipeline.recordUploaded(d, identity: result.identity, remoteVolumeID: "vol", remoteLinkID: "new-link")

        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let second = try await pipeline.resolve(d)
        XCTAssertEqual(second.decision, .skip(.knownFromManifest, remoteLinkID: "new-link"))
    }

    func testTrashedOutcomeIsRecordedButRecheckedEveryRun() async throws {
        let d = descriptor()
        let probe = try await pipeline.resolve(d)
        checker.remoteItemsByNameHash["nh(IMG_1.HEIC)"] = [
            RemotePhotoDuplicate(nameHash: "nh(IMG_1.HEIC)", contentHash: probe.identity.contentHash, linkState: .trashed, linkID: "link-t")
        ]
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let second = try await pipeline.resolve(d)
        XCTAssertEqual(second.decision, .skip(.trashedDuplicate, remoteLinkID: "link-t"))
        XCTAssertEqual(store.record(for: d.source)?.outcome, UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue)

        // The user empties the trash → next run must re-check and upload, NOT trust the manifest.
        checker.remoteItemsByNameHash = [:]
        let queriesBefore = checker.findCallCount
        pipeline = UploadDedupePipeline(store: store, hasher: hasher, checker: checker)
        let third = try await pipeline.resolve(d)
        XCTAssertEqual(third.decision, .upload)
        XCTAssertGreaterThan(checker.findCallCount, queriesBefore)
    }

    func testConcurrentResolvesForSameNameHashQueryOnce() async throws {
        // Two distinct files with the same filename → same name hash → one remote query.
        let a = descriptor(path: "/a/IMG.jpg")
        let b = descriptor(path: "/b/IMG.jpg")
        let pipeline = self.pipeline!
        async let ra = pipeline.resolve(a)
        async let rb = pipeline.resolve(b)
        _ = try await (ra, rb)
        XCTAssertEqual(checker.findCallCount, 1, "same name hash within a run must be queried once")
    }

    func testPrimeBatchesAtProtonSize() async throws {
        let descriptors = (0 ..< 200).map { descriptor(path: "/photos/IMG_\($0).HEIC") }
        await pipeline.prime(descriptors)

        XCTAssertEqual(checker.findBatches.map(\.count), [150, 50], "prime must chunk at Proton's 150-hash batch size")
        XCTAssertEqual(hasher.hashCount, 0, "prime must never hash file contents")

        // Primed hashes are cache hits - resolving one must not add a query.
        let queriesAfterPrime = checker.findCallCount
        _ = try await pipeline.resolve(descriptors[0])
        XCTAssertEqual(checker.findCallCount, queriesAfterPrime)
    }

    func testDuplicateCheckFailureSurfacesAsError() async {
        checker.findError = UploadError.backend("duplicates endpoint down")
        do {
            _ = try await pipeline.resolve(descriptor())
            XCTFail("expected error")
        } catch {
            // resolve must throw - the manager surfaces this as a failed item, never a blind upload
        }
    }

    func testResolveCancellationDuringHashingPropagates() async throws {
        hasher.delay = .seconds(5)
        let d = descriptor()
        let pipeline = self.pipeline!
        let task = Task { _ = try await pipeline.resolve(d) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }
}
