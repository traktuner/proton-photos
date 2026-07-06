import Foundation
import XCTest
@testable import UploadCore

/// The row's calm behaviour: the active subtitle dwells (switches at most about once per second)
/// while structural/terminal changes and same-subtitle number updates apply immediately. Clock is
/// injected, so every assertion is deterministic - no sleeps.
final class BackupStatusStabilizerTests: XCTestCase {

    private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func checking(value: Int = 0, total: Int = 100, fraction: Double = 0) -> BackupStatusPresentation {
        BackupStatusPresentation(
            headlineKey: "backup.status_active", detailKey: "backup.status_checking_detail",
            count: .init(key: "backup.detail_checked", value: value, total: total),
            progressFraction: fraction, isActive: true, accessory: .activity)
    }

    private func uploading(value: Int = 0, total: Int = 100, fraction: Double = 0) -> BackupStatusPresentation {
        BackupStatusPresentation(
            headlineKey: "backup.status_active", detailKey: "backup.status_uploading_detail",
            count: .init(key: "backup.detail_backed_up", value: value, total: total),
            progressFraction: fraction, isActive: true, accessory: .activity)
    }

    private func completed() -> BackupStatusPresentation {
        BackupStatusPresentation(
            headlineKey: "backup.phase_completed", detailKey: nil, count: nil,
            progressFraction: nil, isActive: false, accessory: .success)
    }

    func testFirstIngestDisplaysImmediately() {
        var s = BackupStatusStabilizer(dwell: 1.0)
        let d = s.ingest(checking(), now: t(0))
        XCTAssertEqual(d.display.detailKey, "backup.status_checking_detail")
        XCTAssertNil(d.wakeAt)
    }

    func testActiveSubtitleDoesNotFlapWithinTheDwell() {
        var s = BackupStatusStabilizer(dwell: 1.0)
        XCTAssertEqual(s.ingest(checking(), now: t(0)).display.detailKey, "backup.status_checking_detail")

        // A flurry of checking↔uploading toggles inside the dwell window keeps the checking subtitle.
        XCTAssertEqual(s.ingest(uploading(), now: t(0.1)).display.detailKey, "backup.status_checking_detail")
        XCTAssertEqual(s.ingest(checking(), now: t(0.2)).display.detailKey, "backup.status_checking_detail")
        let held = s.ingest(uploading(), now: t(0.3))
        XCTAssertEqual(held.display.detailKey, "backup.status_checking_detail", "the subtitle must not flap")
        XCTAssertEqual(held.wakeAt, t(1.0), "a single deferred wake is scheduled at the dwell boundary")
    }

    func testSubtitleSwitchesOnceAfterTheDwellElapses() {
        var s = BackupStatusStabilizer(dwell: 1.0)
        _ = s.ingest(checking(), now: t(0))
        _ = s.ingest(uploading(), now: t(0.3))          // held
        let woken = s.wake(now: t(1.0))                   // dwell elapsed → apply the latest
        XCTAssertEqual(woken.display.detailKey, "backup.status_uploading_detail")
        XCTAssertNil(woken.wakeAt)

        // And it now dwells again before switching back.
        let backToChecking = s.ingest(checking(), now: t(1.2))
        XCTAssertEqual(backToChecking.display.detailKey, "backup.status_uploading_detail",
                       "switching is rate-limited to about once per dwell")
        XCTAssertEqual(backToChecking.wakeAt, t(2.0))
    }

    func testSameSubtitleLetsNumbersThroughImmediately() {
        var s = BackupStatusStabilizer(dwell: 1.0)
        _ = s.ingest(checking(value: 5, fraction: 0.05), now: t(0))
        let updated = s.ingest(checking(value: 6, fraction: 0.06), now: t(0.1))
        XCTAssertEqual(updated.display.detailKey, "backup.status_checking_detail")
        XCTAssertEqual(updated.display.count?.value, 6, "counts advance without waiting for the dwell")
        XCTAssertEqual(updated.display.progressFraction, 0.06)
        XCTAssertNil(updated.wakeAt)
    }

    func testStructuralChangeAppliesImmediatelyEvenWithinDwell() {
        var s = BackupStatusStabilizer(dwell: 5.0)
        _ = s.ingest(checking(), now: t(0))
        // Finishing (active → completed) must never be delayed by the subtitle dwell.
        let done = s.ingest(completed(), now: t(0.2))
        XCTAssertEqual(done.display.headlineKey, "backup.phase_completed")
        XCTAssertFalse(done.display.isActive)
        XCTAssertNil(done.wakeAt)
    }

    func testLeavingAndReenteringActiveResetsTheDwell() {
        var s = BackupStatusStabilizer(dwell: 1.0)
        _ = s.ingest(checking(), now: t(0))
        _ = s.ingest(completed(), now: t(0.5))            // structural, immediate
        // Re-entering active starts a fresh dwell anchored now; a same-instant differing subtitle holds.
        _ = s.ingest(checking(), now: t(2.0))
        let held = s.ingest(uploading(), now: t(2.1))
        XCTAssertEqual(held.display.detailKey, "backup.status_checking_detail")
        XCTAssertEqual(held.wakeAt, t(3.0))
    }
}
