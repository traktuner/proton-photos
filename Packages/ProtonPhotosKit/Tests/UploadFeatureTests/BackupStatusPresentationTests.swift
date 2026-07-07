import Foundation
import XCTest
@testable import UploadCore

/// The shared display projection of `BackupStatus`: a stable umbrella headline while active, an
/// honest per-phase subtitle, and counts that never mislabel checking as uploading.
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

    // MARK: Active phases share ONE stable umbrella headline

    func testScanningIsUmbrellaHeadlineWithScanningSubtitleAndNoFakeProgress() {
        let s = status(progress(total: 40, waiting: 40), isScanning: true)
        XCTAssertEqual(s.phase, .scanning)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.status_active")
        XCTAssertEqual(p.detailKey, "backup.status_scanning_detail")
        XCTAssertNil(p.count, "scanning has no honest total, so no count")
        XCTAssertNil(p.progressFraction, "scanning must stay indeterminate")
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.accessory, .activity)
    }

    func testCheckingUsesCheckingSubtitleAndCheckedCountNeverUploadWording() {
        let s = status(progress(total: 100, uploadQueued: 5, checking: 1, alreadyBackedUp: 20, isRunning: true))
        XCTAssertEqual(s.phase, .checking)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.status_active", "the title is the stable umbrella, not the phase")
        XCTAssertEqual(p.detailKey, "backup.status_checking_detail")
        XCTAssertNotEqual(p.detailKey, "backup.status_uploading_detail",
                          "checking/hashing/dedupe must never be worded as uploading")
        XCTAssertEqual(p.count?.key, "backup.detail_checked")
        XCTAssertEqual(p.count?.value, s.checked)
        XCTAssertEqual(p.count?.total, s.totalConsidered)
        XCTAssertTrue(p.isActive)
        XCTAssertEqual(p.accessory, .activity)
    }

    func testUploadingUsesUploadingSubtitleAndBackedUpCountOnlyWhenBytesMove() {
        let s = status(progress(total: 100, uploading: 3, uploaded: 12, alreadyBackedUp: 20, isRunning: true))
        XCTAssertEqual(s.phase, .uploading)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.status_active")
        XCTAssertEqual(p.detailKey, "backup.status_uploading_detail")
        XCTAssertEqual(p.count?.key, "backup.detail_backed_up")
        XCTAssertEqual(p.count?.value, s.backedUp)
        XCTAssertEqual(p.count?.total, s.totalConsidered)
        XCTAssertTrue(p.isActive)
    }

    // MARK: Resting / terminal phases

    func testCompletedIsSuccessAndNeverUploading() {
        let s = status(progress(total: 10, uploaded: 4, alreadyBackedUp: 6))
        XCTAssertEqual(s.phase, .completed)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_completed")
        XCTAssertFalse(p.isActive)
        XCTAssertEqual(p.accessory, .success)
        XCTAssertNotEqual(p.detailKey, "backup.status_uploading_detail")
        XCTAssertEqual(p.count?.key, "backup.detail_already_backed_up")
        XCTAssertEqual(p.count?.value, 6)
    }

    func testNeedsAttentionExplainsInPlainLanguageWithCount() {
        let s = status(progress(total: 10, uploaded: 5, sourceMissing: 1, failed: 2))
        XCTAssertEqual(s.phase, .needsAttention)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_attention")
        XCTAssertEqual(p.detailKey, "backup.status_attention_detail", "a plain sentence, not just a number")
        XCTAssertEqual(p.count?.key, "backup.detail_attention")
        XCTAssertEqual(p.count?.value, s.needsAttentionCount)
        XCTAssertEqual(p.accessory, .attention)
        XCTAssertFalse(p.isActive)
    }

    func testPausedKeepsProgressButIsNotActive() {
        let s = status(progress(total: 10, checking: 1, uploaded: 3, isRunning: true, isPausedByPolicy: true))
        XCTAssertEqual(s.phase, .paused)
        let p = BackupStatusPresentation(s)
        XCTAssertEqual(p.headlineKey, "backup.phase_paused")
        XCTAssertEqual(p.accessory, .paused)
        XCTAssertFalse(p.isActive, "paused is not spinning-active")
    }

    func testWaitingAndIdleAreCalmAndCarryNoUploadWording() {
        let waiting = BackupStatusPresentation(status(progress(total: 10, waiting: 3, uploaded: 2)))
        XCTAssertEqual(waiting.headlineKey, "backup.phase_waiting")
        XCTAssertFalse(waiting.isActive)
        XCTAssertEqual(waiting.accessory, .idle)

        let idle = BackupStatusPresentation(status(progress()))
        XCTAssertEqual(idle.headlineKey, "backup.phase_idle")
        XCTAssertNil(idle.count)
        XCTAssertNil(idle.detailKey)
        XCTAssertEqual(idle.accessory, .idle)
    }

    // MARK: Determinism & count edge cases

    func testMappingIsDeterministic() {
        let s = status(progress(total: 100, checking: 1, alreadyBackedUp: 40, isRunning: true))
        XCTAssertEqual(BackupStatusPresentation(s), BackupStatusPresentation(s))
    }

    func testCountIsOmittedWhenThereIsNoHonestTotal() {
        // Running with an unknown total (0) must not fabricate an "X of 0" count.
        let s = status(progress(total: 0, checking: 1, isRunning: true))
        let p = BackupStatusPresentation(s)
        XCTAssertNil(p.count)
    }

    func testCountLocalizationKeysAreFinite() {
        // Every count the mapping can emit maps to a real catalog key via the localized switch (the
        // default "\(value)" branch is only a safety net and must not be reached for real counts).
        for s in [
            status(progress(total: 100, checking: 1, alreadyBackedUp: 20, isRunning: true)),
            status(progress(total: 100, uploading: 1, uploaded: 5, isRunning: true)),
            status(progress(total: 10, uploaded: 4, alreadyBackedUp: 6)),
            status(progress(total: 10, uploaded: 5, failed: 2)),
            status(progress(total: 10, waiting: 3, uploaded: 2)),
        ] {
            if let count = BackupStatusPresentation(s).count {
                XCTAssertTrue(
                    ["backup.detail_checked", "backup.detail_backed_up", "backup.detail_already_backed_up",
                     "backup.detail_attention", "backup.detail_waiting"].contains(count.key),
                    "unexpected count key \(count.key)"
                )
            }
        }
    }

    // MARK: Liveness line - the "still moving" signal when the settled count sits flat

    func testActivePhasesSurfaceCurrentItemAsLivenessName() {
        for (label, base) in [
            ("uploading", progress(total: 100, uploading: 3, uploaded: 12, alreadyBackedUp: 20, isRunning: true)),
            ("checking", progress(total: 100, uploadQueued: 5, checking: 1, alreadyBackedUp: 20, isRunning: true)),
        ] {
            var p = base
            p.currentItemName = "IMG_3917.heic"
            let pres = BackupStatusPresentation(status(p))
            XCTAssertEqual(pres.liveItemName, "IMG_3917.heic", "\(label): the in-flight name is the liveness signal")
            XCTAssertNotNil(pres.localizedLiveItem, "\(label): renders a localized 'working on' line")
        }
    }

    func testLivenessNameIsAbsentWhenIdleOrEmpty() {
        // Settled/terminal states are not "working on" anything.
        let completed = status(progress(total: 10, uploaded: 10, isRunning: false))
        XCTAssertNil(BackupStatusPresentation(completed).liveItemName)

        // An empty name never renders a bare "working on" line.
        var running = progress(total: 100, uploading: 1, isRunning: true)
        running.currentItemName = ""
        XCTAssertNil(BackupStatusPresentation(status(running)).localizedLiveItem)
    }
}
