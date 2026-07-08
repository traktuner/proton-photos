import Foundation
import XCTest
@testable import UploadCore

/// The shared display projection of `BackupStatus`: a compact, honest row - an icon, a phase
/// headline (checking vs backing up, driven by real byte movement), one subtitle line
/// ("<n> of <m>" + a live upload %), and an optional attention line. Same model on every platform.
final class BackupStatusPresentationTests: XCTestCase {

    private func progress(
        total: Int = 0, waiting: Int = 0, uploadQueued: Int = 0, checking: Int = 0,
        uploading: Int = 0, uploaded: Int = 0, alreadyBackedUp: Int = 0,
        skippedRemoteDeletions: Int = 0, sourceMissing: Int = 0, blocked: Int = 0,
        failed: Int = 0, isRunning: Bool = false, isPausedByPolicy: Bool = false
    ) -> BackupSyncProgress {
        var p = BackupSyncProgress()
        p.total = total; p.waiting = waiting; p.uploadQueued = uploadQueued
        p.checking = checking; p.uploading = uploading; p.uploaded = uploaded
        p.alreadyBackedUp = alreadyBackedUp; p.skippedRemoteDeletions = skippedRemoteDeletions
        p.sourceMissing = sourceMissing; p.blocked = blocked; p.failed = failed
        p.isRunning = isRunning; p.isPausedByPolicy = isPausedByPolicy
        return p
    }

    private func status(_ p: BackupSyncProgress, isScanning: Bool = false) -> BackupStatus {
        BackupStatus(progress: p, isScanning: isScanning)
    }

    // MARK: The one distinction that must always be right: checking vs backing up

    func testCheckingHeadlineWhenNoBytesAreMoving() {
        // A running pass with no in-flight upload is CHECKING - never "backing up".
        let s = status(progress(total: 100, uploadQueued: 5, checking: 1, alreadyBackedUp: 20, isRunning: true))
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_checking")
        XCTAssertNotEqual(p.headlineKey, "backup.phase_uploading",
                          "checking/hashing must never be worded as uploading")
        XCTAssertNil(p.uploadPercent, "no byte transfer => no percentage")
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.accessory, .activity)
    }

    func testBackingUpHeadlineOnlyWhenBytesAreActuallyMoving() {
        // Same big backlog, but one file is genuinely uploading: headline flips to backing up and a
        // live percentage appears - proving the upload even while the overall pass is mostly checking.
        var raw = progress(total: 100, uploadQueued: 5, checking: 1, uploading: 1, alreadyBackedUp: 20, isRunning: true)
        raw.currentUploadingName = "IMG_5560.MOV"
        raw.currentUploadingFraction = 0.43
        let p = BackupStatusPresentation(status(raw))
        XCTAssertEqual(p.headlineKey, "backup.phase_uploading")
        XCTAssertEqual(p.uploadPercent, 43)
        let subtitle = try? XCTUnwrap(p.localizedSubtitle)
        // The per-file percent must appear in the subtitle. (In the SPM test bundle the string catalog
        // is copied uncompiled, so L10n resolves the key form "...backup.file_upload_percent 43";
        // in the app build the resolved localized value "...file 43 %" appears. Both contain "43".)
        XCTAssertEqual(subtitle?.contains("43"), true, "the live percentage proves the upload is moving")
        XCTAssertFalse(subtitle?.contains("IMG_5560.MOV") ?? true, "no filename in the subtitle")
        XCTAssertFalse(subtitle?.contains("IMG_5560.MOV") ?? true, "no filename in the subtitle")
    }

    func testSubtitleIsCountOfBackedUpOverTotalWithNoPercentWhenNotUploading() {
        let s = status(progress(total: 100, checking: 1, uploaded: 10, alreadyBackedUp: 20, isRunning: true))
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.backedUp, 30)
        XCTAssertEqual(p.total, 100)
        XCTAssertNil(p.uploadPercent)
        let subtitle = try? XCTUnwrap(p.localizedSubtitle)
        XCTAssertEqual(subtitle?.contains("30"), true)
        XCTAssertEqual(subtitle?.contains("100"), true)
        XCTAssertEqual(subtitle?.contains("%"), false)
    }

    func testScanningHasNoFakeProgressAndNoSubtitle() {
        let s = status(progress(total: 40, waiting: 40), isScanning: true)
        XCTAssertEqual(s.phase, .scanning)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_scanning")
        XCTAssertNil(p.progressFraction, "scanning must stay indeterminate")
        XCTAssertNil(p.localizedSubtitle, "no honest total mid-scan => no subtitle")
        XCTAssertTrue(p.isActive)
    }

    // MARK: Resting / terminal phases

    func testCompletedIsSuccessAndNotActive() {
        let s = status(progress(total: 10, uploaded: 4, alreadyBackedUp: 6))
        XCTAssertEqual(s.phase, .completed)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_completed")
        XCTAssertFalse(p.isActive)
        XCTAssertEqual(p.accessory, .success)
    }

    func testAttentionLineAppearsOnlyWhenSomethingNeedsTheUser() {
        let clean = BackupStatusPresentation(status(progress(total: 10, checking: 1, alreadyBackedUp: 5, isRunning: true)))
        XCTAssertNil(clean.localizedAttention, "nothing failed => no attention line")

        let s = status(progress(total: 10, uploaded: 5, sourceMissing: 1, failed: 2))
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_attention")
        XCTAssertEqual(p.attentionCount, s.needsAttentionCount)
        XCTAssertNotNil(p.localizedAttention)
        XCTAssertEqual(p.accessory, .attention)
    }

    func testPausedKeepsProgressButIsNotActive() {
        let s = status(progress(total: 10, checking: 1, uploaded: 3, isRunning: true, isPausedByPolicy: true))
        XCTAssertEqual(s.phase, .paused)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_paused")
        XCTAssertEqual(p.accessory, .paused)
        XCTAssertFalse(p.isActive)
    }

    func testIdleIsCalmWithNoSubtitle() {
        let idle = BackupStatusPresentation(status(progress()))
        XCTAssertEqual(idle.headlineKey, "backup.phase_idle")
        XCTAssertNil(idle.localizedSubtitle)
        XCTAssertEqual(idle.accessory, .idle)
    }

    func testMappingIsDeterministic() {
        let s = status(progress(total: 100, checking: 1, alreadyBackedUp: 40, isRunning: true))
        XCTAssertEqual(BackupStatusPresentation(s), BackupStatusPresentation(s))
    }
}
