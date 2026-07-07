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
        XCTAssertEqual(store.nextRunnable(limit: 2).map(\.source.identifier), ["old"])
        XCTAssertEqual(store.summary().total, 3)
        XCTAssertEqual(store.summary().waiting, 1)
        XCTAssertEqual(store.summary().active, 1)
        XCTAssertEqual(store.summary().uploaded, 1)
    }

    func testRunnableWorkDrainsNewestPhotoFirstRegardlessOfEnqueueTime() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        // A large old backlog enqueued long ago, then a brand-new photo enqueued just now: the new
        // photo has the LATEST asset date (revision) but the LATEST updated_at. It must still drain
        // first, so a freshly taken photo is protected ahead of the backlog.
        let oldBacklog = UploadBackupSyncQueueEntry(
            source: source("backlog"), revision: revision(100),
            originalFilename: "backlog.heic", byteCount: 1,
            state: .discovered, updatedAt: Date(timeIntervalSince1970: 1_000)
        )
        let justTaken = UploadBackupSyncQueueEntry(
            source: source("fresh"), revision: revision(9_999),
            originalFilename: "fresh.heic", byteCount: 1,
            state: .discovered, updatedAt: Date(timeIntervalSince1970: 9_000_000)
        )
        store.upsert(oldBacklog)
        store.upsert(justTaken)

        XCTAssertEqual(store.nextRunnable(limit: 2).map(\.source.identifier), ["fresh", "backlog"],
                       "newest photo (highest revision) drains first, even though it was enqueued last")
        let claimed = store.claimRunnable(limit: 1, claimedAt: Date(timeIntervalSince1970: 9_000_001))
        XCTAssertEqual(claimed.map(\.source.identifier), ["fresh"], "claim also prioritizes the newest photo")
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

    func testSQLiteQueueListsEntriesInOneStateOldestFirst() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        for (id, state, at) in [
            ("blocked-new", UploadBackupSyncQueueState.blockedByDraft, 30.0),
            ("blocked-old", .blockedByDraft, 10.0),
            ("waiting", .discovered, 5.0),
            ("blocked-future", .blockedByDraft, 100.0),
        ] {
            store.upsert(UploadBackupSyncQueueEntry(
                source: source(id),
                revision: revision(1),
                originalFilename: "\(id).heic",
                state: state,
                updatedAt: Date(timeIntervalSince1970: at)
            ))
        }

        let due = store.entries(in: .blockedByDraft, updatedBefore: Date(timeIntervalSince1970: 50), limit: 10)
        XCTAssertEqual(due.map(\.source.identifier), ["blocked-old", "blocked-new"],
                       "state filter + oldest-first ordering + strict updatedBefore cutoff")
        XCTAssertEqual(store.entries(in: .blockedByDraft, updatedBefore: Date(timeIntervalSince1970: 50), limit: 1).count, 1)
        XCTAssertTrue(store.entries(in: .sourceMissing, updatedBefore: .distantFuture, limit: 10).isEmpty)
    }

    func testSQLiteQueueAtomicallyClaimsRunnableRowsAndSkipsFutureBackoff() throws {
        let url = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: url))
        let now = Date(timeIntervalSince1970: 100)
        let old = UploadBackupSyncQueueEntry(
            source: source("old"),
            revision: revision(10),
            originalFilename: "old.heic",
            state: .discovered,
            updatedAt: Date(timeIntervalSince1970: 10)
        )
        let ready = UploadBackupSyncQueueEntry(
            source: source("ready"),
            revision: revision(20),
            originalFilename: "ready.heic",
            state: .queuedForUpload,
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let future = UploadBackupSyncQueueEntry(
            source: source("future"),
            revision: revision(30),
            originalFilename: "future.heic",
            state: .discovered,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
        [future, ready, old].forEach(store.upsert)

        let firstClaim = store.claimRunnable(limit: 2, claimedAt: now)

        // Newest photo first among the eligible (future-backoff row excluded until its updated_at):
        // ready (revision 20) before old (revision 10).
        XCTAssertEqual(firstClaim.map(\.source.identifier), ["ready", "old"])
        XCTAssertEqual(store.entry(for: old.source, revision: old.revision)?.state, .checking)
        XCTAssertEqual(store.entry(for: ready.source, revision: ready.revision)?.state, .checking)
        XCTAssertEqual(store.entry(for: future.source, revision: future.revision)?.state, .discovered)
        XCTAssertTrue(store.claimRunnable(limit: 10, claimedAt: now).isEmpty,
                      "claimed rows are active and future-backoff rows are not claimable yet")

        let secondClaim = store.claimRunnable(limit: 10, claimedAt: Date(timeIntervalSince1970: 250))
        XCTAssertEqual(secondClaim.map(\.source.identifier), ["future"])
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
            ("hashing", .hashing, .discovered),
            ("duplicate", .duplicateChecking, .discovered),
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
