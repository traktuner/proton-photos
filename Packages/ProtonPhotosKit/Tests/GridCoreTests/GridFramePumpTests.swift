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
}
