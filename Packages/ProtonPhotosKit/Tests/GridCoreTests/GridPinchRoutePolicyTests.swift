import XCTest
@testable import GridCore

/// Locks the shared pinch routing both platform hosts consume: in-band adjacent steps scrub the lattice,
/// overview-boundary steps dissolve, everything else (including ladder edges) reflows.
final class GridPinchRoutePolicyTests: XCTestCase {

    /// Production-shaped ladder: 0-3 are focus-row photo levels, 3→4 the overview warp, 4→5 the dense
    /// overview zoom.
    private let engine = SquareTileGridEngine(
        sectionCounts: [500],
        profile: GridLevelProfile(
            id: "route-test",
            levels: [
                GridLevelMetrics(levelID: 0, nominalColumns: 3, gap: 16, monthLabels: false, transitionKindToNext: .focusRowRelayout),
                GridLevelMetrics(levelID: 1, nominalColumns: 5, gap: 12, monthLabels: false, transitionKindToNext: .focusRowRelayout),
                GridLevelMetrics(levelID: 2, nominalColumns: 7, gap: 8, monthLabels: false, transitionKindToNext: .focusRowRelayout),
                GridLevelMetrics(levelID: 3, nominalColumns: 9, gap: 6, monthLabels: false, transitionKindToNext: .overviewWarp),
                GridLevelMetrics(levelID: 4, nominalColumns: 14, gap: 2, monthLabels: true, transitionKindToNext: .denseOverviewZoom),
                GridLevelMetrics(levelID: 5, nominalColumns: 20, gap: 2, monthLabels: true, transitionKindToNext: nil),
            ],
            defaultLevel: 2
        )
    )

    func testChainBandSpansTheFocusRowLevels() {
        for level in 0 ... 3 {
            let band = GridPinchRoutePolicy.chainBand(around: level, engine: engine)
            XCTAssertEqual(band.lo, 0, "level \(level)")
            XCTAssertEqual(band.hi, 3, "level \(level)")
        }
    }

    func testOverviewStartYieldsDegenerateBand() {
        let band4 = GridPinchRoutePolicy.chainBand(around: 4, engine: engine)
        XCTAssertEqual(band4.lo, 4)
        XCTAssertEqual(band4.hi, 4)
        let band5 = GridPinchRoutePolicy.chainBand(around: 5, engine: engine)
        XCTAssertEqual(band5.lo, 5)
        XCTAssertEqual(band5.hi, 5)
    }

    func testInBandStepRoutesToLattice() {
        let band = GridPinchRoutePolicy.chainBand(around: 2, engine: engine)
        XCTAssertEqual(GridPinchRoutePolicy.candidate(startLevel: 2, direction: -1, chainBand: band, engine: engine),
                       .lattice(target: 1))
        XCTAssertEqual(GridPinchRoutePolicy.candidate(startLevel: 2, direction: 1, chainBand: band, engine: engine),
                       .lattice(target: 3))
    }

    func testOverviewBoundaryStepRoutesToDissolve() {
        let band = GridPinchRoutePolicy.chainBand(around: 3, engine: engine)
        XCTAssertEqual(GridPinchRoutePolicy.candidate(startLevel: 3, direction: 1, chainBand: band, engine: engine),
                       .overviewDissolve(target: 4))
        let overviewBand = GridPinchRoutePolicy.chainBand(around: 4, engine: engine)
        XCTAssertEqual(GridPinchRoutePolicy.candidate(startLevel: 4, direction: 1, chainBand: overviewBand, engine: engine),
                       .overviewDissolve(target: 5))
        XCTAssertEqual(GridPinchRoutePolicy.candidate(startLevel: 4, direction: -1, chainBand: overviewBand, engine: engine),
                       .overviewDissolve(target: 3))
    }

    func testLadderEdgesRouteToReflow() {
        let band = GridPinchRoutePolicy.chainBand(around: 0, engine: engine)
        XCTAssertEqual(GridPinchRoutePolicy.candidate(startLevel: 0, direction: -1, chainBand: band, engine: engine),
                       .reflow)
        let topBand = GridPinchRoutePolicy.chainBand(around: 5, engine: engine)
        XCTAssertEqual(GridPinchRoutePolicy.candidate(startLevel: 5, direction: 1, chainBand: topBand, engine: engine),
                       .reflow)
    }

    func testOutOfBandNonBoundaryStepRoutesToReflow() {
        // A caller-narrowed band (captured at gesture start) can exclude an in-bounds focus-row step;
        // that step is neither lattice-eligible nor an overview boundary, so it must reflow.
        XCTAssertEqual(GridPinchRoutePolicy.candidate(startLevel: 2, direction: -1, chainBand: (lo: 2, hi: 3), engine: engine),
                       .reflow)
    }
}
