import XCTest
import PhotosCore
@testable import UploadCore

private func isOrderedSubsequence(_ sub: [UploadItemState], of seq: [UploadItemState]) -> Bool {
    var i = 0
    for s in seq where i < sub.count && s == sub[i] { i += 1 }
    return i == sub.count
}

final class UploadManagerTests: XCTestCase {

    private func jpegs(_ names: [String]) throws -> (URL, [URL]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let urls = try makeTempFiles(names.map { "\($0).jpg" }, in: dir)
        return (dir, urls)
    }

    // 2. UploadQueueOrderingTest
    func testQueuePreservesEnqueueOrder() async throws {
        let (_, urls) = try jpegs(["a", "b", "c", "d"])
        let uploader = MockUploader(workDuration: .milliseconds(5), deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)
        XCTAssertEqual(uploader.startedOrder, ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        // Snapshot order also stable by ordinal.
        let snap = await manager.snapshot()
        XCTAssertEqual(snap.map(\.displayName), ["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
    }

    // 3. UploadQueueConcurrencyTest
    func testRespectsMaxConcurrency() async throws {
        let (_, urls) = try jpegs((0..<6).map { "f\($0)" })
        let uploader = MockUploader(workDuration: .milliseconds(40), deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 2)
        await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)
        XCTAssertLessThanOrEqual(uploader.peakConcurrent, 2, "must never exceed configured concurrency")
        XCTAssertEqual(uploader.peakConcurrent, 2, "should actually run two in parallel")
    }

    // 4a. UploadStateMachineTest - happy path
    func testStateMachineHappyPath() async throws {
        let (_, urls) = try jpegs(["one"])
        let uploader = MockUploader()
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let recorder = StateRecorder()
        await manager.setOnChange { items, _ in recorder.record(items) }
        let ids = await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)
        let seq = recorder.sequence(ids[0])
        XCTAssertEqual(seq.last, .completed)
        XCTAssertTrue(
            isOrderedSubsequence([.queued, .preparing, .uploading(progress: 0.5), .completed], of: seq),
            "unexpected sequence: \(seq)"
        )
    }

    // 4b. UploadStateMachineTest - failed → retry → completed
    func testStateMachineRetryToCompleted() async throws {
        let (_, urls) = try jpegs(["x"])
        let uploader = MockUploader(deliverProgress: false, transientFailures: ["x.jpg": 1])
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let recorder = StateRecorder()
        await manager.setOnChange { items, _ in recorder.record(items) }
        let ids = await manager.enqueueFiles(urls, destination: .library)
        _ = await waitUntil(manager) { items in
            if case .failed = items.first?.state { return true }; return false
        }
        await manager.retry(ids[0])
        _ = await waitUntil(manager) { $0.first?.state == .completed }
        let seq = recorder.sequence(ids[0])
        // failed must appear, and completed must come after it.
        let failedIdx = seq.firstIndex { if case .failed = $0 { return true }; return false }
        XCTAssertNotNil(failedIdx, "sequence: \(seq)")
        XCTAssertEqual(seq.last, .completed)
    }

    // 4c. UploadStateMachineTest - cancel while in-flight
    func testCancelInFlight() async throws {
        let (_, urls) = try jpegs(["slow"])
        let uploader = MockUploader(workDuration: .seconds(5), deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(urls, destination: .library)
        _ = await waitUntil(manager) { $0.first?.state.isActive == true }
        await manager.cancel(ids[0])
        let snap = await waitUntil(manager) { $0.first?.state == .cancelled }
        XCTAssertEqual(snap.first?.state, .cancelled)
        XCTAssertFalse(uploader.cancelledTokens.isEmpty, "backend cancel should be invoked for in-flight item")
    }

    // 5. UploadUnsupportedFileTest
    func testUnsupportedFileIsSkippedNotCrashed() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let urls = try makeTempFiles(["note.txt", "good.jpg"], in: dir)
        let uploader = MockUploader(deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: .library)
        let snap = await waitForAllTerminal(manager)
        let txt = snap.first { $0.displayName == "note.txt" }
        let jpg = snap.first { $0.displayName == "good.jpg" }
        if case .failed = txt?.state {} else { XCTFail("txt should be failed/unsupported: \(String(describing: txt?.state))") }
        XCTAssertEqual(jpg?.state, .completed)
        XCTAssertEqual(uploader.startedOrder, ["good.jpg"], "unsupported file must never reach the backend")
    }

    // 7a. AlbumDestinationTest - existing album maps to add-to-album
    func testExistingAlbumAddsUploadedPhotos() async throws {
        let (_, urls) = try jpegs(["p1", "p2"])
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching()
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: UploadDestination(target: .existingAlbum(id: "alb", title: "Trip")))
        _ = await waitForAllTerminal(manager)
        let added = albums.addedSnapshot
        XCTAssertEqual(added.count, 2)
        XCTAssertTrue(added.allSatisfy { $0.1 == "alb" })
    }

    // 7b. AlbumDestinationTest - new album is created before add
    func testNewAlbumCreatedBeforeAdd() async throws {
        let (_, urls) = try jpegs(["n1"])
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching()
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: UploadDestination(target: .newAlbum(name: "Holiday")))
        _ = await waitForAllTerminal(manager)
        XCTAssertEqual(albums.createdNames, ["Holiday"])
        XCTAssertEqual(albums.addedSnapshot.first?.1, "new-album-1")
    }

    // 7c. AlbumDestinationTest - unsupported create fails fast, nothing uploads
    func testUnsupportedNewAlbumFailsFastWithoutUploading() async throws {
        let (_, urls) = try jpegs(["z"])
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching(canCreate: false)
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        await manager.enqueueFiles(urls, destination: UploadDestination(target: .newAlbum(name: "Nope")))
        let snap = await waitForAllTerminal(manager)
        if case .failed = snap.first?.state {} else { XCTFail("should fail fast") }
        XCTAssertTrue(uploader.startedOrder.isEmpty, "must not upload to library when album destination can't be honoured")
    }

    // 8. AlbumCoverSelectionTest - first uploaded photo becomes the cover
    func testFirstUploadedPhotoBecomesCover() async throws {
        let (_, urls) = try jpegs(["a", "b"])
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching()
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        let dest = UploadDestination(target: .existingAlbum(id: "alb", title: "T"), cover: .firstUploaded)
        await manager.enqueueFiles(urls, destination: dest)
        _ = await waitForAllTerminal(manager)
        XCTAssertEqual(albums.coversSnapshot.count, 1)
        XCTAssertEqual(albums.coversSnapshot.first?.1, testUID("a.jpg"))
    }

    func testSpecificCoverPhoto() async throws {
        let (_, urls) = try jpegs(["a", "b"])
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching()
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        let dest = UploadDestination(target: .existingAlbum(id: "alb", title: "T"),
                                     cover: .specific(testUID("b.jpg")))
        await manager.enqueueFiles(urls, destination: dest)
        _ = await waitForAllTerminal(manager)
        XCTAssertEqual(albums.coversSnapshot.first?.1, testUID("b.jpg"))
    }

    // 9. PartialFailureTest - upload ok but album add fails → partial success
    func testPartialSuccessWhenAlbumAddFails() async throws {
        let (_, urls) = try jpegs(["pf"])
        let uploader = MockUploader(deliverProgress: false)
        let albums = MockAlbumAttaching(failAdd: true)
        let manager = UploadManager(uploader: uploader, albums: albums, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(urls, destination: UploadDestination(target: .existingAlbum(id: "alb", title: "T")))
        let snap = await waitForAllTerminal(manager)
        let item = snap.first { $0.id == ids[0] }
        XCTAssertTrue(item?.partialSuccess ?? false, "should be a partial success")
        XCTAssertEqual(item?.uploadedUID, testUID("pf.jpg"), "uploaded photo must be preserved")
        if case .failed = item?.state {} else { XCTFail("state should be failed-with-partial") }
    }

    // 10. ResumeSupportTest - capability honesty + queue-level pause/resume
    func testResumeCapabilityIsHonest() async {
        let uploader = MockUploader()
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        XCTAssertFalse(manager.capabilities.supportsResumeAcrossRelaunch,
                       "in-memory operations cannot resume across relaunch")
    }

    func testPauseAndResumeQueuedItem() async throws {
        let (_, urls) = try jpegs(["a", "b", "c"])
        let uploader = MockUploader(workDuration: .milliseconds(30), deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let ids = await manager.enqueueFiles(urls, destination: .library)
        await manager.pause(ids[1])   // pause b while it's still queued (a is running)
        // a and c complete; b stays paused.
        _ = await waitUntil(manager) { items in
            items[0].state == .completed && items[2].state == .completed
        }
        let mid = await manager.snapshot()
        XCTAssertEqual(mid[1].state, .paused)
        await manager.resume(ids[1])
        let done = await waitUntil(manager) { $0[1].state == .completed }
        XCTAssertEqual(done[1].state, .completed)
    }

    func testCompletedUploadEmitsRefreshEvent() async throws {
        let (_, urls) = try jpegs(["refresh"])
        let uploader = MockUploader(deliverProgress: false)
        let manager = UploadManager(uploader: uploader, maxConcurrent: 1)
        let recorder = UploadCompletionRecorder()
        await manager.setOnCompleted { event in recorder.record(event) }

        await manager.enqueueFiles(urls, destination: .library)
        _ = await waitForAllTerminal(manager)

        let events = recorder.events
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.uploadedUID, testUID("refresh.jpg"))
        XCTAssertEqual(events.first?.displayName, "refresh.jpg")
    }

    func testUploadQueueNativeStateActions() throws {
        let (_, urls) = try jpegs(["active"])
        let active = UploadItem(id: UUID(), ordinal: 0, fileURL: urls[0], displayName: "active.jpg",
                                mediaType: "image/jpeg", byteCount: 1, state: .uploading(progress: 0.5))
        let failed = UploadItem(id: UUID(), ordinal: 1, fileURL: urls[0], displayName: "failed.jpg",
                                mediaType: "image/jpeg", byteCount: 1, state: .failed(message: "boom"))
        let caps = UploadBackendCapabilities(canUpload: true, supportsCancel: true,
                                             supportsPauseResume: false, supportsResumeAcrossRelaunch: false)

        XCTAssertEqual(UploadQueuePresentation.rowActions(for: active, capabilities: caps), [.cancel])
        XCTAssertEqual(UploadQueuePresentation.rowActions(for: failed, capabilities: caps), [.retry])

        var stats = UploadQueueStats()
        XCTAssertFalse(UploadQueuePresentation.canClearFinished(stats))
        stats.completed = 1
        XCTAssertTrue(UploadQueuePresentation.canClearFinished(stats))
        // summaryText is localized via the package catalog (compiled by Xcode; under plain SwiftPM the
        // raw key + interpolated counts is returned). Either way the three counts - completed=1,
        // active=0, failed=0 - must appear in that order. Asserting their order keeps the test
        // independent of language and of whether the catalog is compiled.
        let s = stats.summaryText
        var cursor = s.startIndex
        for expected in ["1", "0", "0"] {
            guard let r = s.range(of: expected, range: cursor..<s.endIndex) else {
                return XCTFail("summaryText missing count \(expected) in order: \(s)")
            }
            cursor = r.upperBound
        }
    }

    func testUploadPreparationStatusCountsPreUploadCheck() throws {
        let (_, urls) = try jpegs(["one"])
        let url = urls[0]
        let items = [
            UploadItem(id: UUID(), ordinal: 0, fileURL: url, displayName: "queued.jpg",
                       mediaType: "image/jpeg", byteCount: 1, state: .queued),
            UploadItem(id: UUID(), ordinal: 1, fileURL: url, displayName: "checking.jpg",
                       mediaType: "image/jpeg", byteCount: 1, state: .hashing),
            UploadItem(id: UUID(), ordinal: 2, fileURL: url, displayName: "uploading.jpg",
                       mediaType: "image/jpeg", byteCount: 1, state: .uploading(progress: 0.2)),
            UploadItem(id: UUID(), ordinal: 3, fileURL: url, displayName: "duplicate.jpg",
                       mediaType: "image/jpeg", byteCount: 1, state: .skipped(.activeDuplicate)),
            UploadItem(id: UUID(), ordinal: 4, fileURL: url, displayName: "failed.jpg",
                       mediaType: "image/jpeg", byteCount: 1, state: .failed(message: "boom")),
        ]

        let status = UploadPreparationStatus(items: items)

        XCTAssertEqual(status.total, 5)
        XCTAssertEqual(status.waiting, 1)
        XCTAssertEqual(status.checking, 1)
        XCTAssertEqual(status.checked, 2)
        XCTAssertEqual(status.skippedDuplicates, 1)
        XCTAssertEqual(status.failed, 1)
        XCTAssertEqual(status.resolved, 3)
        XCTAssertEqual(status.progressFraction, 0.6, accuracy: 0.0001)
        XCTAssertTrue(status.isRunning)
    }
}
