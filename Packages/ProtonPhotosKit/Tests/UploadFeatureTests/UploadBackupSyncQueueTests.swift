import Foundation
import SQLite3
import XCTest
@testable import UploadCore

final class UploadBackupSyncQueueTests: XCTestCase {
    private struct StaticCatalog: UploadBackupAssetCatalog {
        let items: [UploadBackupAssetCandidate]

        func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
            AsyncThrowingStream { continuation in
                for item in items { continuation.yield(item) }
                continuation.finish()
            }
        }
    }

    private final class MemoryBackupStore: UploadBackupStateStore, @unchecked Sendable {
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

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-backup-sync-queue-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func revision(_ seconds: TimeInterval) -> UploadBackupRevision {
        UploadBackupRevision(date: Date(timeIntervalSinceReferenceDate: seconds))
    }

    private func source(_ id: String, resource: UploadSourceIdentity.Resource = .primary) -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id, resource: resource)
    }

    private func candidate(
        id: String,
        revision seconds: TimeInterval,
        editRevision: UploadBackupEditRevision = .unavailable,
        resource: UploadSourceIdentity.Resource = .primary
    ) -> UploadBackupAssetCandidate {
        let snapshot = UploadBackupAssetSnapshot(
            source: source(id, resource: resource),
            revision: revision(seconds),
            editRevision: editRevision,
            resourceCount: 1
        )
        return UploadBackupAssetCandidate(
            snapshot: snapshot,
            originalFilename: "IMG_\(id).HEIC",
            byteCount: 1024
        )
    }

    func testSQLiteQueueRoundTripsAndOrdersRunnableWork() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let old = UploadBackupSyncQueueEntry(
            source: source("old"),
            revision: revision(10),
            originalFilename: "old.heic",
            byteCount: 10,
            state: .queuedForUpload,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let newer = UploadBackupSyncQueueEntry(
            source: source("new"),
            revision: revision(20),
            originalFilename: "new.heic",
            byteCount: nil,
            state: .checking,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let done = UploadBackupSyncQueueEntry(
            source: source("done"),
            revision: revision(30),
            originalFilename: "done.heic",
            state: .completed,
            updatedAt: Date(timeIntervalSince1970: 5)
        )

        store.upsert(newer)
        store.upsert(done)
        store.upsert(old)

        XCTAssertEqual(store.entry(for: old.source, revision: old.revision), old)
        XCTAssertEqual(store.nextRunnable(limit: 2).map(\.source.identifier), ["old", "new"])
        XCTAssertEqual(store.summary().total, 3)
        XCTAssertEqual(store.summary().waiting, 1)
        XCTAssertEqual(store.summary().active, 1)
        XCTAssertEqual(store.summary().uploaded, 1)
    }

    func testSQLiteQueueUpdatesStateWithoutRewritingDescriptor() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let entry = UploadBackupSyncQueueEntry(
            source: source("asset"),
            revision: revision(10),
            originalFilename: "asset.heic",
            byteCount: 99,
            state: .hashing,
            attempts: 1,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        store.upsert(entry)

        store.updateState(
            source: entry.source,
            revision: entry.revision,
            state: .failed,
            attempts: 2,
            lastError: "network",
            updatedAt: Date(timeIntervalSince1970: 20)
        )

        let updated = try XCTUnwrap(store.entry(for: entry.source, revision: entry.revision))
        XCTAssertEqual(updated.originalFilename, "asset.heic")
        XCTAssertEqual(updated.byteCount, 99)
        XCTAssertEqual(updated.state, .failed)
        XCTAssertEqual(updated.attempts, 2)
        XCTAssertEqual(updated.lastError, "network")
    }

    func testSQLiteQueueRequeuesStaleActiveStatesAfterCrash() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let old = Date(timeIntervalSince1970: 10)
        let fresh = Date(timeIntervalSince1970: 90)
        let recoveredAt = Date(timeIntervalSince1970: 100)
        let cutoff = Date(timeIntervalSince1970: 50)

        let staleStates: [(String, UploadBackupSyncQueueState, UploadBackupSyncQueueState)] = [
            ("checking", .checking, .discovered),
            ("hashing", .hashing, .checking),
            ("duplicate", .duplicateChecking, .hashing),
            ("uploading", .uploading, .queuedForUpload),
            ("finalizing", .finalizing, .queuedForUpload),
        ]
        for (id, state, _) in staleStates {
            store.upsert(UploadBackupSyncQueueEntry(
                source: source(id),
                revision: revision(10),
                originalFilename: "\(id).heic",
                state: state,
                updatedAt: old
            ))
        }
        store.upsert(UploadBackupSyncQueueEntry(
            source: source("fresh-uploading"),
            revision: revision(20),
            originalFilename: "fresh.heic",
            state: .uploading,
            updatedAt: fresh
        ))
        store.upsert(UploadBackupSyncQueueEntry(
            source: source("done"),
            revision: revision(30),
            originalFilename: "done.heic",
            state: .completed,
            updatedAt: old
        ))

        XCTAssertEqual(store.requeueStaleActive(before: cutoff, updatedAt: recoveredAt), staleStates.count)

        for (id, _, expected) in staleStates {
            let entry = try XCTUnwrap(store.entry(for: source(id), revision: revision(10)))
            XCTAssertEqual(entry.state, expected)
            XCTAssertEqual(entry.updatedAt, recoveredAt)
        }
        XCTAssertEqual(store.entry(for: source("fresh-uploading"), revision: revision(20))?.state, .uploading)
        XCTAssertEqual(store.entry(for: source("done"), revision: revision(30))?.state, .completed)
        XCTAssertEqual(
            Set(store.nextRunnable(limit: 10).map(\.source.identifier)),
            Set(staleStates.map { $0.0 }),
            "recovered rows must become runnable again; stale uploading/finalizing may not disappear"
        )
    }

    func testSQLiteQueueResetsFutureSchema() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        do {
            let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
            store.upsert(UploadBackupSyncQueueEntry(
                source: source("asset"),
                revision: revision(10),
                originalFilename: "asset.heic",
                updatedAt: Date()
            ))
            store.close()
        }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE backup_sync_queue_info SET value=99 WHERE key='schema';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let reopened = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        XCTAssertEqual(reopened.count(), 0)
    }

    func testSyncEngineScansIntoSharedQueueWithSafeDecisions() async throws {
        let backupStore = MemoryBackupStore()
        let queueURL = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        let now = Date(timeIntervalSince1970: 123)
        let index = UploadBackupPreflightIndex(store: backupStore, now: { now })
        let known = candidate(id: "known", revision: 10)
        await index.markBackedUp(known.snapshot)
        let trustedDrift = candidate(id: "known", revision: 20, editRevision: .trustedNoContentEdits)
        let newAsset = candidate(id: "new", revision: 30)
        let unknownEdit = candidate(id: "known", revision: 40, editRevision: .revision(revision(35)))
        let engine = UploadBackupSyncEngine(preflight: index, queue: queue, now: { now })

        let result = try await engine.scan(StaticCatalog(items: [trustedDrift, newAsset, unknownEdit]))

        XCTAssertEqual(result.scanned, 3)
        XCTAssertEqual(result.alreadyBackedUp, 1)
        XCTAssertEqual(result.queuedForWork, 2)
        XCTAssertEqual(result.backendChecksRequired, 1)
        XCTAssertEqual(queue.entry(for: trustedDrift.snapshot.source, revision: trustedDrift.snapshot.revision)?.state, .alreadyBackedUp)
        XCTAssertEqual(queue.entry(for: newAsset.snapshot.source, revision: newAsset.snapshot.revision)?.state, .discovered)
        XCTAssertEqual(queue.entry(for: unknownEdit.snapshot.source, revision: unknownEdit.snapshot.revision)?.state, .checking)
    }
}
