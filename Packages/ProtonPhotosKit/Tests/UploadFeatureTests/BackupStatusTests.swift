import Foundation
import XCTest
@testable import UploadCore

/// The shared user-facing backup status surface: phase derivation honesty (checking is never
/// worded as uploading, no fake progress), count aggregation, and stability.
final class BackupStatusTests: XCTestCase {

    private func progress(
        total: Int = 0, waiting: Int = 0, uploadQueued: Int = 0, checking: Int = 0,
        uploading: Int = 0, uploaded: Int = 0, alreadyBackedUp: Int = 0,
        skippedRemoteDeletions: Int = 0, sourceMissing: Int = 0, blocked: Int = 0,
        failed: Int = 0, currentItemName: String? = nil,
        isRunning: Bool = false, isPausedByPolicy: Bool = false
    ) -> BackupSyncProgress {
        var p = BackupSyncProgress()
        p.total = total
        p.waiting = waiting
        p.uploadQueued = uploadQueued
        p.checking = checking
        p.uploading = uploading
        p.uploaded = uploaded
        p.alreadyBackedUp = alreadyBackedUp
        p.skippedRemoteDeletions = skippedRemoteDeletions
        p.sourceMissing = sourceMissing
        p.blocked = blocked
        p.failed = failed
        p.currentItemName = currentItemName
        p.isRunning = isRunning
        p.isPausedByPolicy = isPausedByPolicy
        return p
    }

    // MARK: Phase honesty

    func testScanningIsIndeterminate() {
        let status = BackupStatus(progress: progress(total: 40, waiting: 40), isScanning: true)
        XCTAssertEqual(status.phase, .scanning)
        XCTAssertNil(status.totalConsidered, "totals are still growing - claiming one would lie")
        XCTAssertNil(status.fractionCompleted)
        XCTAssertEqual(status.titleKey, "backup.phase_scanning")
    }

    func testCheckingIsNeverLabeledUploading() {
        let status = BackupStatus(
            progress: progress(total: 10, waiting: 7, checking: 2, alreadyBackedUp: 1,
                               currentItemName: "IMG_0042.HEIC", isRunning: true),
            isScanning: false
        )
        XCTAssertEqual(status.phase, .checking)
        XCTAssertEqual(status.titleKey, "backup.phase_checking")
        XCTAssertNotEqual(status.titleKey, "backup.phase_uploading",
                          "hash/duplicate checking must never present as uploading")
        XCTAssertEqual(status.currentItemName, "IMG_0042.HEIC")
    }

    func testUploadingOnlyWhenUploadsDominateNotAStrayByteMovement() {
        let checkingOnly = BackupStatus(
            progress: progress(total: 5, waiting: 4, checking: 1, isRunning: true), isScanning: false
        )
        XCTAssertEqual(checkingOnly.phase, .checking)

        // A stray upload while most of the library is still UNEXAMINED must stay "checking" — this is
        // the first-reconcile case where ~everything turns out already backed up, and presenting it as
        // "Sichert neue Objekte" (uploading new objects) is the misleading status the user reported.
        let strayUploadDuringCheck = BackupStatus(
            progress: progress(total: 100, waiting: 90, uploading: 1, uploaded: 1, isRunning: true),
            isScanning: false
        )
        XCTAssertEqual(strayUploadDuringCheck.phase, .checking,
                       "one upload among a large unexamined backlog is still 'checking', not 'uploading'")

        // Once nothing is left to examine and bytes are moving, it is genuinely uploading.
        let uploadingNow = BackupStatus(
            progress: progress(total: 5, waiting: 0, uploading: 1, uploaded: 4, isRunning: true),
            isScanning: false
        )
        XCTAssertEqual(uploadingNow.phase, .uploading)
        XCTAssertEqual(uploadingNow.titleKey, "backup.phase_uploading")
    }

    func testPolicyPauseWinsWhileRunning() {
        let status = BackupStatus(
            progress: progress(total: 5, waiting: 4, uploading: 1, isRunning: true, isPausedByPolicy: true),
            isScanning: false
        )
        XCTAssertEqual(status.phase, .paused)
    }

    func testInterruptedRunIsWaitingNotCompleted() {
        let status = BackupStatus(
            progress: progress(total: 10, waiting: 4, uploadQueued: 2, uploaded: 6), isScanning: false
        )
        XCTAssertEqual(status.phase, .waiting)
        XCTAssertLessThan(status.fractionCompleted ?? 1, 1.0)
    }

    func testBlockedOnlyRemainsWaitingWithHonestFraction() {
        let status = BackupStatus(
            progress: progress(total: 3, alreadyBackedUp: 2, blocked: 1), isScanning: false
        )
        XCTAssertEqual(status.phase, .waiting)
        XCTAssertEqual(status.fractionCompleted, 2.0 / 3.0)
    }

    func testFailureSummaryIsStableAndRecoverableLooking() {
        let p = progress(total: 4, uploaded: 2, sourceMissing: 1, failed: 1)
        let first = BackupStatus(progress: p, isScanning: false)
        let second = BackupStatus(progress: p, isScanning: false)
        XCTAssertEqual(first, second, "same durable input must derive the identical summary")
        XCTAssertEqual(first.phase, .needsAttention)
        XCTAssertEqual(first.needsAttentionCount, 2)
        XCTAssertEqual(first.backedUp, 2)
    }

    func testCompletedAndIdle() {
        let done = BackupStatus(
            progress: progress(total: 3, uploaded: 1, alreadyBackedUp: 2), isScanning: false
        )
        XCTAssertEqual(done.phase, .completed)
        XCTAssertEqual(done.fractionCompleted, 1.0)

        let idle = BackupStatus(progress: progress(), isScanning: false)
        XCTAssertEqual(idle.phase, .idle)
        XCTAssertEqual(idle.totalConsidered, 0)
        XCTAssertNil(idle.fractionCompleted, "an empty queue has no honest fraction")
    }

    // MARK: Counts

    func testCountsAggregateFromQueueSummaryIncludingUploadQueueSplit() {
        var summary = UploadBackupSyncQueueSummary()
        summary.include(.discovered, count: 3)
        summary.include(.queuedForUpload, count: 2)
        summary.include(.checking)
        summary.include(.uploading)
        summary.include(.completed, count: 4)
        summary.include(.alreadyBackedUp, count: 5)
        summary.include(.skippedRemoteDeletion)
        summary.include(.sourceMissing)
        summary.include(.blockedByDraft)
        summary.include(.failed)

        XCTAssertEqual(summary.waiting, 5, "queued-for-upload rows still count as waiting overall")
        XCTAssertEqual(summary.queuedForUpload, 2)

        let status = BackupStatus(
            progress: BackupSyncProgress(summary: summary, isRunning: true), isScanning: false
        )
        XCTAssertEqual(status.totalConsidered, 20)
        XCTAssertEqual(status.uploadQueued, 2)
        XCTAssertEqual(status.backedUp, 9)
        XCTAssertEqual(status.alreadyBackedUp, 5)
        XCTAssertEqual(status.uploaded, 4)
        XCTAssertEqual(status.skippedRemoteDeletions, 1)
        XCTAssertEqual(status.sourceMissing, 1)
        XCTAssertEqual(status.waitingRetry, 1)
        XCTAssertEqual(status.failed, 1)
        // checked = everything past its backup-status check (incl. upload-queued and blocked).
        XCTAssertEqual(status.checked, 4 + 5 + 1 + 1 + 1 + 1 + 2)
    }

    // MARK: Manual upload-check mapping

    func testManualCheckMapsToSharedPhasesWithoutClaimingUpload() {
        var running = UploadPreparationStatus()
        running.total = 10
        running.waiting = 4
        running.checking = 2
        running.checked = 3
        running.skippedDuplicates = 1
        let checking = BackupStatus(manualUploadCheck: running)
        XCTAssertEqual(checking.phase, .checking,
                       "the preparation aggregate cannot see bytes - it must never claim uploading")
        XCTAssertEqual(checking.alreadyBackedUp, 1)
        XCTAssertEqual(checking.totalConsidered, 10)

        let idle = BackupStatus(manualUploadCheck: UploadPreparationStatus())
        XCTAssertEqual(idle.phase, .idle)
        XCTAssertNil(idle.fractionCompleted)

        var failed = UploadPreparationStatus()
        failed.total = 2
        failed.checked = 1
        failed.failed = 1
        XCTAssertEqual(BackupStatus(manualUploadCheck: failed).phase, .needsAttention)

        var done = UploadPreparationStatus()
        done.total = 2
        done.checked = 1
        done.skippedDuplicates = 1
        XCTAssertEqual(BackupStatus(manualUploadCheck: done).phase, .completed)
    }
}
