import Foundation
import XCTest
@testable import UploadCore

/// The row's calm behaviour: the active phase headline dwells (switches at most about once per
/// second) while structural/terminal changes and same-phase number updates apply immediately. Clock
/// is injected, so every assertion is deterministic - no sleeps.
final class BackupStatusStabilizerTests: XCTestCase {

    private func t(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func checking(value: Int = 0, total: Int = 100, fraction: Double = 0) -> BackupStatusPresentation {
        BackupStatusPresentation(
            headlineKey: "backup.phase_checking", isActive: true, accessory: .activity,
            progressFraction: fraction, backedUp: value, total: total)
    }

    private func uploading(value: Int = 0, total: Int = 100, fraction: Double = 0) -> BackupStatusPresentation {
        BackupStatusPresentation(
            headlineKey: "backup.phase_uploading", isActive: true, accessory: .activity,
            progressFraction: fraction, backedUp: value, total: total)
    }

    private func completed() -> BackupStatusPresentation {
        BackupStatusPresentation(
            headlineKey: "backup.phase_completed", isActive: false, accessory: .success,
            progressFraction: nil)
    }

    func testFirstIngestDisplaysImmediately() {
        var s = BackupStatusStabilizer(dwell: 1.0)
        let d = s.ingest(checking(), now: t(0))
        XCTAssertEqual(d.display.headlineKey, "backup.phase_checking")
        XCTAssertNil(d.wakeAt)
    }

    func testActivePhaseDoesNotFlapWithinTheDwell() {
        var s = BackupStatusStabilizer(dwell: 1.0)
        XCTAssertEqual(s.ingest(checking(), now: t(0)).display.headlineKey, "backup.phase_checking")

        // A flurry of checking↔uploading toggles inside the dwell window keeps the checking headline.
        XCTAssertEqual(s.ingest(uploading(), now: t(0.1)).display.headlineKey, "backup.phase_checking")
        XCTAssertEqual(s.ingest(checking(), now: t(0.2)).display.headlineKey, "backup.phase_checking")
        let held = s.ingest(uploading(), now: t(0.3))
        XCTAssertEqual(held.display.headlineKey, "backup.phase_checking", "the phase must not flap")
        XCTAssertEqual(held.wakeAt, t(1.0), "a single deferred wake is scheduled at the dwell boundary")
    }

    func testPhaseSwitchesOnceAfterTheDwellElapses() {
        var s = BackupStatusStabilizer(dwell: 1.0)
        _ = s.ingest(checking(), now: t(0))
        _ = s.ingest(uploading(), now: t(0.3))          // held
        let woken = s.wake(now: t(1.0))                   // dwell elapsed → apply the latest
        XCTAssertEqual(woken.display.headlineKey, "backup.phase_uploading")
        XCTAssertNil(woken.wakeAt)

        // And it now dwells again before switching back.
        let backToChecking = s.ingest(checking(), now: t(1.2))
        XCTAssertEqual(backToChecking.display.headlineKey, "backup.phase_uploading",
                       "switching is rate-limited to about once per dwell")
        XCTAssertEqual(backToChecking.wakeAt, t(2.0))
    }

    func testSamePhaseLetsOverallProgressThroughImmediately() {
        var s = BackupStatusStabilizer(dwell: 1.0)
        _ = s.ingest(uploading(value: 5, fraction: 0.05), now: t(0))
        let updated = s.ingest(uploading(value: 6, fraction: 0.06), now: t(0.1))
        XCTAssertEqual(updated.display.headlineKey, "backup.phase_uploading")
        XCTAssertEqual(updated.display.backedUp, 6, "counts advance without waiting for the dwell")
        XCTAssertEqual(updated.display.progressFraction, 0.06)
        XCTAssertNil(updated.wakeAt)
    }

    func testStructuralChangeAppliesImmediatelyEvenWithinDwell() {
        var s = BackupStatusStabilizer(dwell: 5.0)
        _ = s.ingest(checking(), now: t(0))
        // Finishing (active → completed) must never be delayed by the phase dwell.
        let done = s.ingest(completed(), now: t(0.2))
        XCTAssertEqual(done.display.headlineKey, "backup.phase_completed")
        XCTAssertFalse(done.display.isActive)
        XCTAssertNil(done.wakeAt)
    }

    func testLeavingAndReenteringActiveResetsTheDwell() {
        var s = BackupStatusStabilizer(dwell: 1.0)
        _ = s.ingest(checking(), now: t(0))
        _ = s.ingest(completed(), now: t(0.5))            // structural, immediate
        // Re-entering active starts a fresh dwell anchored now; a same-instant differing phase holds.
        _ = s.ingest(checking(), now: t(2.0))
        let held = s.ingest(uploading(), now: t(2.1))
        XCTAssertEqual(held.display.headlineKey, "backup.phase_checking")
        XCTAssertEqual(held.wakeAt, t(3.0))
    }
}
