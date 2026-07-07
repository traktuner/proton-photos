import Foundation
import SQLite3
import XCTest
@testable import UploadCore

/// Durable backup execution ownership: acquire/heartbeat/release, live-lock exclusion, lease-based
/// stale recovery, and the "crash never permanently blocks backup" guarantee. Clock is injected, so
/// every timing assertion is deterministic - no sleeps, no flakes.
final class BackupExecutionLockStoreTests: XCTestCase {

    private var tempDir: URL!
    private var clock: ClockBox!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-lock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        clock = ClockBox(start: Date(timeIntervalSince1970: 1_000_000))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore(lease: TimeInterval = 120) throws -> BackupExecutionLockManifestStore {
        let url = tempDir.appendingPathComponent(BackupExecutionLockManifestStore.databaseFileName)
        return try XCTUnwrap(BackupExecutionLockManifestStore(
            url: url, lockName: "photoBackup", leaseInterval: lease, now: { [clock] in clock!.now }
        ))
    }

    func testAcquireAndRelease() throws {
        let store = try makeStore()
        XCTAssertNil(store.currentLock())

        let outcome = store.acquire(owner: .foreground, runID: "run-1")
        guard case let .acquired(lock) = outcome else { return XCTFail("expected acquire on a free lock") }
        XCTAssertEqual(lock.owner, .foreground)
        XCTAssertEqual(lock.runID, "run-1")
        XCTAssertEqual(store.currentLock()?.runID, "run-1")

        XCTAssertTrue(store.release(runID: "run-1"))
        XCTAssertNil(store.currentLock())
        XCTAssertFalse(store.release(runID: "run-1"), "releasing an already-free lock reports no change")
    }

    func testReleaseRequiresOwnership() throws {
        let store = try makeStore()
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "run-1").didAcquire)
        XCTAssertFalse(store.release(runID: "someone-else"), "a non-owner must not release the lock")
        XCTAssertEqual(store.currentLock()?.runID, "run-1")
    }

    func testSecondOwnerCannotAcquireLiveLock() throws {
        let store = try makeStore()
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "fg").didAcquire)

        // A background window firing while the foreground pass is live must stand down.
        let outcome = store.acquire(owner: .iOSBackgroundTask, runID: "bg")
        guard case let .busy(current) = outcome else { return XCTFail("a live lock must report busy") }
        XCTAssertEqual(current.owner, .foreground)
        XCTAssertEqual(current.runID, "fg")
    }

    func testSameRunReacquiresAndRefreshes() throws {
        let store = try makeStore()
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "fg").didAcquire)
        clock.advance(by: 10)
        let outcome = store.acquire(owner: .foreground, runID: "fg")
        XCTAssertTrue(outcome.didAcquire, "the same run may re-acquire its own lock")
        XCTAssertEqual(store.currentLock()?.heartbeatAt, Date(timeIntervalSince1970: 1_000_010))
    }

    func testHeartbeatExtendsLockAgainstRecovery() throws {
        let store = try makeStore(lease: 120)
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "fg").didAcquire)   // heartbeat @ t0

        clock.advance(by: 90)
        XCTAssertTrue(store.heartbeat(runID: "fg", phase: "uploading"))            // heartbeat @ t0+90
        XCTAssertEqual(store.currentLock()?.phase, "uploading")

        // A cutoff 60s in the past would have reaped the ORIGINAL heartbeat, but the refresh saved it.
        let reaped = store.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(-60))
        XCTAssertTrue(reaped.isEmpty, "a freshly heartbeated lock must survive stale recovery")
        XCTAssertEqual(store.currentLock()?.runID, "fg")

        XCTAssertFalse(store.heartbeat(runID: "other", phase: nil), "only the owner may heartbeat")
    }

    func testStaleLockCanBeRecoveredAndReacquired() throws {
        let store = try makeStore(lease: 120)
        XCTAssertTrue(store.acquire(owner: .iOSBackgroundTask, runID: "bg").didAcquire)

        // The background run "crashes": no release. A different run cannot take a still-live lock.
        clock.advance(by: 60)
        XCTAssertFalse(store.acquire(owner: .foreground, runID: "fg").didAcquire)

        // Past the lease, an explicit recovery reaps it and the next start acquires cleanly.
        clock.advance(by: 100)   // now t0 + 160 > lease
        let reaped = store.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(-120))
        XCTAssertEqual(reaped.map(\.runID), ["bg"])
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "fg").didAcquire,
                      "a stale background lock recovers on the next foreground start")
    }

    func testAbandonedProcessLockCanBeRecoveredBeforeLeaseExpires() throws {
        let store = try makeStore(lease: 120)
        XCTAssertTrue(store.acquire(
            owner: .foreground,
            runID: "old",
            phase: "uploading",
            processContext: "ios/pid-123"
        ).didAcquire)

        let recovered = store.recoverAbandonedProcessLocks(
            currentProcessContext: "ios/pid-456",
            isProcessAlive: { pid in pid != 123 }
        )

        XCTAssertEqual(recovered.map(\.runID), ["old"])
        XCTAssertNil(store.currentLock())
        XCTAssertTrue(store.acquire(
            owner: .foreground,
            runID: "new",
            phase: "scanning",
            processContext: "ios/pid-456"
        ).didAcquire)
    }

    func testAbandonedProcessRecoveryDoesNotStealLiveOrUnrelatedLocks() throws {
        let store = try makeStore(lease: 120)
        XCTAssertTrue(store.acquire(
            owner: .foreground,
            runID: "live",
            phase: "uploading",
            processContext: "ios/pid-123"
        ).didAcquire)

        XCTAssertTrue(store.recoverAbandonedProcessLocks(
            currentProcessContext: "ios/pid-456",
            isProcessAlive: { _ in true }
        ).isEmpty)
        XCTAssertEqual(store.currentLock()?.runID, "live")

        XCTAssertTrue(store.recoverAbandonedProcessLocks(
            currentProcessContext: "macos/pid-456",
            isProcessAlive: { _ in false }
        ).isEmpty)
        XCTAssertEqual(store.currentLock()?.runID, "live")
    }

    func testAcquireAutoRecoversStaleWithoutExplicitCall() throws {
        let store = try makeStore(lease: 30)
        XCTAssertTrue(store.acquire(owner: .background, runID: "dead").didAcquire)
        clock.advance(by: 45)   // past the 30s lease with no heartbeat
        let outcome = store.acquire(owner: .foreground, runID: "fresh")
        XCTAssertTrue(outcome.didAcquire, "a lock never permanently blocks backup after a crash")
        XCTAssertEqual(store.currentLock()?.runID, "fresh")
    }

    func testRecoveryIsNoOpWhileLockIsLive() throws {
        let store = try makeStore(lease: 120)
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "fg").didAcquire)
        clock.advance(by: 30)
        let reaped = store.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(-120))
        XCTAssertTrue(reaped.isEmpty)
        XCTAssertEqual(store.currentLock()?.runID, "fg")
    }

    /// End-to-end ownership guarantee that models the controller path plus proof that a crashed
    /// owner never strands the queue: after recovery the queue's own rows are runnable again.
    func testCrashRecoveryLeavesLockFreeAndQueueRunnable() throws {
        let store = try makeStore(lease: 120)
        let queueURL = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))

        // A run acquires the lock and leaves a row mid-upload, then the process dies.
        XCTAssertTrue(store.acquire(owner: .iOSBackgroundTask, runID: "bg").didAcquire)
        queue.upsert(UploadBackupSyncQueueEntry(
            source: .file(URL(fileURLWithPath: "/p/a.jpg")),
            revision: UploadBackupRevision(date: Date(timeIntervalSince1970: 10)),
            originalFilename: "a.jpg",
            state: .uploading,
            updatedAt: clock.now
        ))

        // Next start: recover the stale lock, then the queue's stale-active recovery makes the row
        // runnable again. Neither the lock nor the row is permanently stuck.
        clock.advance(by: 200)
        _ = store.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(-120))
        XCTAssertTrue(store.acquire(owner: .foreground, runID: "fg").didAcquire)
        XCTAssertEqual(queue.requeueStaleActive(before: clock.now, updatedAt: clock.now), 1)
        XCTAssertEqual(queue.nextRunnable(limit: 10).map(\.source.identifier), ["/p/a.jpg"])
        queue.close()
    }

    func testFutureSchemaResetsToEmpty() throws {
        let url = tempDir.appendingPathComponent(BackupExecutionLockManifestStore.databaseFileName)
        do {
            let store = try XCTUnwrap(BackupExecutionLockManifestStore(url: url, now: { [clock] in clock!.now }))
            _ = store.acquire(owner: .foreground, runID: "fg")
            store.close()
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE backup_execution_lock_info SET value=99 WHERE key='schema';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let reopened = try XCTUnwrap(BackupExecutionLockManifestStore(url: url, now: { [clock] in clock!.now }))
        XCTAssertNil(reopened.currentLock(), "a future schema resets the lock table to empty")
    }

    private final class ClockBox: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(start: Date) { current = start }
        var now: Date { lock.withLock { current } }
        func advance(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
    }
}
