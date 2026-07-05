import Foundation
import XCTest
import PhotosCore
@testable import UploadCore

/// End-to-end folder sync over the REAL pieces (real temp files, SQLite queue, dedupe pipeline
/// with real streaming hashing, file resolver) - only the network seams (checker/uploader) are
/// fakes. This is the Stage-1 behavior contract: scan → check → upload → repeat without
/// re-uploading → sourceMissing when a file vanishes mid-way.
final class FolderBackupIntegrationTests: XCTestCase {

    private final class MemoryBackupStateStore: UploadBackupStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [UploadSourceIdentity: [UploadBackupRevision: UploadBackupAssetRecord]] = [:]

        func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
            lock.withLock { rows[source]?[revision] }
        }

        func hasAnyRecord(for source: UploadSourceIdentity) -> Bool {
            lock.withLock { !(rows[source]?.isEmpty ?? true) }
        }

        func upsert(_ record: UploadBackupAssetRecord) {
            lock.withLock { rows[record.source, default: [:]][record.revision] = record }
        }

        func count() -> Int {
            lock.withLock { rows.values.reduce(0) { $0 + $1.count } }
        }
    }

    private var tempDir: URL!
    private var folder: URL!
    private var queueStore: UploadBackupSyncQueueManifestStore!
    private var preflight: UploadBackupPreflightIndex!
    private var engine: UploadBackupSyncEngine!
    private var checker: FakeChecker!
    private var pipeline: UploadDedupePipeline!
    private var uploader: MockUploader!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-backup-integration-\(UUID().uuidString)", isDirectory: true)
        folder = tempDir.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        queueStore = try XCTUnwrap(UploadBackupSyncQueueManifestStore(
            url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        ))
        preflight = UploadBackupPreflightIndex(store: MemoryBackupStateStore())
        engine = UploadBackupSyncEngine(preflight: preflight, queue: queueStore)
        checker = FakeChecker()
        pipeline = UploadDedupePipeline(store: FakeIdentityStore(), checker: checker)
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
    }

    override func tearDownWithError() throws {
        queueStore.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeRunner() -> BackupSyncRunner {
        BackupSyncRunner(
            queue: queueStore,
            preflight: preflight,
            resolver: FileBackupResourceResolver(),
            identityResolver: pipeline,
            uploader: uploader
        )
    }

    func testScanRunRescanBacksUpOnceAndOnlyOnce() async throws {
        for name in ["IMG_0001.jpg", "IMG_0002.heic", "clip.mov"] {
            try Data(name.utf8).write(to: folder.appendingPathComponent(name))
        }

        // First pass: everything is new, everything uploads exactly once.
        let firstScan = try await engine.scan(FolderBackupCatalog(folder: folder))
        XCTAssertEqual(firstScan.scanned, 3)
        XCTAssertEqual(firstScan.queuedForWork, 3)

        let firstRun = await makeRunner().runUntilDrained()
        XCTAssertEqual(firstRun.uploaded, 3)
        XCTAssertEqual(firstRun.backedUp, 3)
        XCTAssertEqual(firstRun.fraction, 1.0)
        XCTAssertEqual(Set(uploader.requests.map(\.name)), ["IMG_0001.jpg", "IMG_0002.heic", "clip.mov"])
        XCTAssertTrue(uploader.requests.allSatisfy { $0.expectedSHA1 != nil },
                      "backup uploads must carry the integrity digest from the shared pipeline")

        // Second pass: the preflight index proves everything backed up WITHOUT touching bytes.
        let secondScan = try await engine.scan(FolderBackupCatalog(folder: folder))
        XCTAssertEqual(secondScan.alreadyBackedUp, 3)
        XCTAssertEqual(secondScan.queuedForWork, 0)

        let secondRun = await makeRunner().runUntilDrained()
        XCTAssertEqual(uploader.requests.count, 3, "a repeat sync must never re-upload")
        XCTAssertEqual(secondRun.backedUp, 3)
        XCTAssertEqual(secondRun.hasOutstandingWork, false)
    }

    func testFileDeletedBetweenScanAndRunBecomesSourceMissing() async throws {
        let doomed = folder.appendingPathComponent("gone.jpg")
        try Data("bytes".utf8).write(to: doomed)

        _ = try await engine.scan(FolderBackupCatalog(folder: folder))
        try FileManager.default.removeItem(at: doomed)

        let progress = await makeRunner().runUntilDrained()

        XCTAssertEqual(progress.sourceMissing, 1)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertTrue(uploader.requests.isEmpty)
        let entry = queueStore.entry(
            for: .file(doomed),
            revision: queueStore.entries(in: .sourceMissing, updatedBefore: .distantFuture, limit: 1).first?.revision
                ?? UploadBackupRevision(rawValue: 0)
        )
        XCTAssertEqual(entry?.state, .sourceMissing)
    }
}
