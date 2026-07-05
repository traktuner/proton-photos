import Foundation
import XCTest
import PhotosCore
@testable import UploadCore

/// Scripted `UploadIdentityResolving`: decisions per filename, recorded calls, optional delay so
/// cancellation can land mid-"hashing".
final class FakeIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
    private let lock = NSLock()
    var decisionsByFilename: [String: UploadDuplicateDecision] = [:]
    var errorsByFilename: [String: Error] = [:]
    var resolveDelay: Duration?
    private var _resolved: [String] = []
    private var _primedFilenames: [[String]] = []
    private var _recordedUploads: [(filename: String, remoteLinkID: String)] = []

    var resolved: [String] { lock.withLock { _resolved } }
    var primedFilenames: [[String]] { lock.withLock { _primedFilenames } }
    var recordedUploads: [(filename: String, remoteLinkID: String)] { lock.withLock { _recordedUploads } }

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        if let resolveDelay {
            try await Task.sleep(for: resolveDelay)
        }
        try Task.checkCancellation()
        lock.withLock { _resolved.append(descriptor.filename) }
        if let error = lock.withLock({ errorsByFilename[descriptor.filename] }) { throw error }
        let decision = lock.withLock { decisionsByFilename[descriptor.filename] } ?? .upload
        let identity = UploadIdentity(
            correctedName: "corrected-\(descriptor.filename)",
            nameHash: "nh",
            sha1Hex: String(repeating: "ab", count: 20),
            sha1Digest: Data(repeating: 0xAB, count: 20),
            contentHash: "ch"
        )
        return UploadPreflightResult(identity: identity, decision: decision)
    }

    func prime(_ descriptors: [UploadResourceDescriptor]) async {
        lock.withLock { _primedFilenames.append(descriptors.map(\.filename)) }
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async {
        lock.withLock { _recordedUploads.append((descriptor.filename, remoteLinkID)) }
    }
}

final class UploadManagerDedupeTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-manager-dedupe-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testDuplicateItemSkipsWithoutUploadingBytes() async throws {
        let urls = try makeTempFiles(["dup.jpg", "new.jpg"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        resolver.decisionsByFilename["dup.jpg"] = .skip(.activeDuplicate, remoteLinkID: "l1")
        let completions = UploadCompletionRecorder()
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)
        await manager.setOnCompleted { completions.record($0) }

        await manager.enqueueFiles(urls, destination: .library)
        let items = await waitForAllTerminal(manager)

        let dup = try XCTUnwrap(items.first { $0.displayName == "dup.jpg" })
        let fresh = try XCTUnwrap(items.first { $0.displayName == "new.jpg" })
        XCTAssertEqual(dup.state, .skipped(.activeDuplicate))
        XCTAssertEqual(fresh.state, .completed)
        XCTAssertEqual(uploader.startedOrder, ["corrected-new.jpg"], "duplicate bytes must never upload")
        XCTAssertEqual(completions.events.map(\.displayName), ["new.jpg"],
                       "skipped duplicates must not emit a completion event (no new node exists)")

        let stats = { () -> UploadQueueStats in
            var s = UploadQueueStats()
            for item in items {
                switch item.state {
                case .completed: s.completed += 1
                case let .skipped(reason) where reason.countsAsBackedUp: s.skippedDuplicates += 1
                default: break
                }
            }
            return s
        }()
        XCTAssertEqual(stats.skippedDuplicates, 1)
    }

    func testNonDuplicateUploadsOnceWithIdentityApplied() async throws {
        let urls = try makeTempFiles(["photo one.jpg"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)

        await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)

        XCTAssertEqual(uploader.requests.count, 1)
        let request = try XCTUnwrap(uploader.requests.first)
        XCTAssertEqual(request.name, "corrected-photo one.jpg", "the Proton-corrected name must be uploaded")
        XCTAssertEqual(request.expectedSHA1, Data(repeating: 0xAB, count: 20), "the hashed digest must reach the backend")
        XCTAssertEqual(resolver.recordedUploads.map(\.filename), ["photo one.jpg"],
                       "successful uploads must be recorded in the manifest")
    }

    func testResolveFailureFailsTheItemWithoutBlindUpload() async throws {
        let urls = try makeTempFiles(["broken.jpg"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        resolver.errorsByFilename["broken.jpg"] = UploadError.backend("duplicate check unavailable")
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)

        await manager.enqueueFiles(urls, destination: .library)
        let items = await waitForAllTerminal(manager)

        guard case .failed = items[0].state else {
            return XCTFail("expected failed, got \(items[0].state)")
        }
        XCTAssertTrue(uploader.startedOrder.isEmpty, "a failed duplicate check must not upload blindly")
    }

    func testDraftDuplicateFailsRetryablyInsteadOfClaimingBackedUp() async throws {
        let urls = try makeTempFiles(["draft.jpg"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        resolver.decisionsByFilename["draft.jpg"] = .skip(.draftExists, remoteLinkID: "draft-link")
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)

        await manager.enqueueFiles(urls, destination: .library)
        let items = await waitForAllTerminal(manager)

        guard case let .failed(message) = items[0].state else {
            return XCTFail("expected failed draft state, got \(items[0].state)")
        }
        XCTAssertFalse(message.isEmpty)
        XCTAssertTrue(uploader.startedOrder.isEmpty, "a draft blocker must never upload blindly")
        XCTAssertEqual(UploadQueuePresentation.rowActions(for: items[0], capabilities: .unavailable), [.retry])
    }

    func testRemoteDeletionSkipDoesNotCountAsBackedUpDuplicate() async throws {
        let urls = try makeTempFiles(["deleted.jpg"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        resolver.decisionsByFilename["deleted.jpg"] = .skip(.deletedRemotely, remoteLinkID: "old-link")
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)

        await manager.enqueueFiles(urls, destination: .library)
        let items = await waitForAllTerminal(manager)

        XCTAssertEqual(items[0].state, .skipped(.deletedRemotely))
        XCTAssertTrue(uploader.startedOrder.isEmpty, "remote deletion policy must not restore bytes")
        var stats = UploadQueueStats()
        if case let .skipped(reason) = items[0].state {
            if reason.countsAsBackedUp {
                stats.skippedDuplicates += 1
            } else {
                stats.skippedRemoteDeletions += 1
            }
        }
        XCTAssertEqual(stats.skippedDuplicates, 0)
        XCTAssertEqual(stats.skippedRemoteDeletions, 1)
    }

    func testCancelDuringHashingCancelsWithoutUpload() async throws {
        let urls = try makeTempFiles(["slow.jpg"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        resolver.resolveDelay = .seconds(5)
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)

        let ids = await manager.enqueueFiles(urls, destination: .library)
        _ = await waitUntil(manager) { $0.first?.state == .hashing }
        await manager.cancel(ids[0])
        let items = await waitForAllTerminal(manager, timeout: .seconds(2))

        XCTAssertEqual(items[0].state, .cancelled)
        XCTAssertTrue(uploader.startedOrder.isEmpty, "cancel during hashing must abort before any upload")
    }

    func testStateSequenceIncludesHashingBeforeUploading() async throws {
        let urls = try makeTempFiles(["seq.jpg"], in: tempDir)
        let uploader = MockUploader(deliverProgress: false)
        let resolver = FakeIdentityResolver()
        let recorder = StateRecorder()
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)
        await manager.setOnChange { items, _ in recorder.record(items) }

        let ids = await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)

        let sequence = recorder.sequence(ids[0])
        let hashingIndex = try XCTUnwrap(sequence.firstIndex(of: .hashing), "items must pass through .hashing")
        let completedIndex = try XCTUnwrap(sequence.firstIndex(of: .completed))
        XCTAssertLessThan(hashingIndex, completedIndex)
    }

    func testEnqueuePrimesTheBatch() async throws {
        let urls = try makeTempFiles(["a.jpg", "b.jpg", "c.jpg"], in: tempDir)
        let resolver = FakeIdentityResolver()
        let manager = UploadManager(uploader: MockUploader(), identityResolver: resolver)

        await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)
        // prime is fire-and-forget - give it a beat.
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(resolver.primedFilenames.count, 1)
        XCTAssertEqual(Set(resolver.primedFilenames[0]), ["a.jpg", "b.jpg", "c.jpg"])
    }

    func testWithoutResolverBehaviourIsUnchanged() async throws {
        let urls = try makeTempFiles(["plain.jpg"], in: tempDir)
        let uploader = MockUploader()
        let manager = UploadManager(uploader: uploader)

        await manager.enqueueFiles(urls, destination: .library)
        let items = await waitForAllTerminal(manager)

        XCTAssertEqual(items[0].state, .completed)
        XCTAssertEqual(uploader.startedOrder, ["plain.jpg"], "no resolver → original name, no dedupe")
        XCTAssertNil(uploader.requests.first?.expectedSHA1)
    }

    func testMissingSecondariesDecisionSkipsPrimaryForManualUploads() async throws {
        // Manual uploads are single-resource compounds; if the policy ever reports missing
        // secondaries the primary itself IS on the server, so nothing may upload.
        let urls = try makeTempFiles(["live.heic"], in: tempDir)
        let uploader = MockUploader()
        let resolver = FakeIdentityResolver()
        resolver.decisionsByFilename["live.heic"] = .uploadMissingSecondaries(
            primaryLinkID: "l1",
            missing: [UploadSourceIdentity(kind: .fileURL, identifier: "/x.mov", resource: .livePairedVideo)]
        )
        let manager = UploadManager(uploader: uploader, identityResolver: resolver)

        await manager.enqueueFiles(urls, destination: .library)
        let items = await waitForAllTerminal(manager)

        XCTAssertEqual(items[0].state, .skipped(.primaryAlreadyPresent))
        XCTAssertTrue(uploader.startedOrder.isEmpty)
    }
}
