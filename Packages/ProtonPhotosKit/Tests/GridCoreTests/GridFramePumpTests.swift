import XCTest
@testable import GridCore

/// Locks the coalesced render-loop semantics: one render per tick, retry on a failed present, keep
/// ticking while streaming work is pending, stop when idle.
final class GridFramePumpTests: XCTestCase {

    func testFreshPumpWantsAFirstFrame() {
        XCTAssertTrue(GridFramePump().shouldTick)
    }

    func testSuccessfulIdleFrameStopsTheLoop() {
        var pump = GridFramePump()
        XCTAssertFalse(pump.completeTick(presented: true, hasPendingWork: false))
        XCTAssertFalse(pump.shouldTick)
    }

    func testFailedPresentRetriesUntilAFrameLands() {
        // The initial-black-grid failure mode: a transiently missing drawable must keep the loop
        // ticking so content is drawn without waiting for a user scroll.
        var pump = GridFramePump()
        XCTAssertTrue(pump.completeTick(presented: false, hasPendingWork: false))
        XCTAssertTrue(pump.shouldTick)
        XCTAssertFalse(pump.completeTick(presented: true, hasPendingWork: false))
    }

    func testPendingStreamWorkKeepsTicking() {
        var pump = GridFramePump()
        XCTAssertTrue(pump.completeTick(presented: true, hasPendingWork: true))
        XCTAssertTrue(pump.shouldTick)
        XCTAssertFalse(pump.completeTick(presented: true, hasPendingWork: false))
    }

    func testInvalidationReawakensAnIdlePump() {
        var pump = GridFramePump()
        pump.completeTick(presented: true, hasPendingWork: false)
        XCTAssertFalse(pump.shouldTick)
        pump.invalidate()
        XCTAssertTrue(pump.shouldTick)
    }

    // MARK: - Active gating (host lifecycle: hidden/inactive surface must not keep the loop alive)

    func testFreshPumpIsActive() {
        XCTAssertTrue(GridFramePump().isActive)
    }

    func testDeactivatingGatesTicksOffEvenWithPendingWork() {
        var pump = GridFramePump()
        pump.invalidate()
        XCTAssertTrue(pump.shouldTick)
        XCTAssertTrue(pump.setActive(false))            // real transition
        XCTAssertFalse(pump.isActive)
        XCTAssertFalse(pump.shouldTick)                 // gated off despite being dirty
    }

    func testInactivePumpNeverKeepsTickingEvenWithPendingStreamWork() {
        var pump = GridFramePump()
        pump.setActive(false)
        // Even "pending work" / a failed present cannot keep an inactive loop running.
        XCTAssertFalse(pump.completeTick(presented: false, hasPendingWork: true))
        XCTAssertFalse(pump.shouldTick)
    }

    func testReactivatingRearmsExactlyOneFrame() {
        var pump = GridFramePump()
        pump.completeTick(presented: true, hasPendingWork: false)   // idle
        pump.setActive(false)
        XCTAssertFalse(pump.shouldTick)
        XCTAssertTrue(pump.setActive(true))             // real transition → re-arm
        XCTAssertTrue(pump.shouldTick)                  // one frame on return, no external nudge
        XCTAssertFalse(pump.completeTick(presented: true, hasPendingWork: false))   // then settles
    }

    func testRedundantSetActiveIsANoOpTransition() {
        var pump = GridFramePump()
        XCTAssertFalse(pump.setActive(true))            // already active
        pump.completeTick(presented: true, hasPendingWork: false)   // idle
        XCTAssertFalse(pump.setActive(true))            // still active → no re-arm
        XCTAssertFalse(pump.shouldTick)
    }
}
