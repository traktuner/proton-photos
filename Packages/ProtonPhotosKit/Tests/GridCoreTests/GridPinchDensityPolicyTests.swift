import XCTest
@testable import GridCore

/// Locks the shared pinch→density-step tuning: a casual pinch must not run through the whole ladder.
final class GridPinchDensityPolicyTests: XCTestCase {

    func testSmallPinchProducesNoStep() {
        // Below the √2 commit point nothing happens - resting fingers and micro-motions are stable.
        for scale: CGFloat in [1.0, 1.1, 1.25, 1.35, 0.85, 0.75] {
            XCTAssertEqual(GridPinchDensityPolicy.levelSteps(pinchScale: scale), 0, "scale \(scale)")
        }
    }

    func testDeliberatePinchIsExactlyOneStep() {
        for scale: CGFloat in [1.5, 2.0, 2.7] {
            XCTAssertEqual(GridPinchDensityPolicy.levelSteps(pinchScale: scale), 1, "scale \(scale)")
        }
        for scale: CGFloat in [1 / 1.5, 1 / 2.0, 1 / 2.7] {
            XCTAssertEqual(GridPinchDensityPolicy.levelSteps(pinchScale: scale), -1, "scale \(scale)")
        }
    }

    func testStepsGrowLogarithmically() {
        XCTAssertEqual(GridPinchDensityPolicy.levelSteps(pinchScale: 3.0), 2)
        XCTAssertEqual(GridPinchDensityPolicy.levelSteps(pinchScale: 4.0), 2)
        XCTAssertEqual(GridPinchDensityPolicy.levelSteps(pinchScale: 6.0), 3)
        XCTAssertEqual(GridPinchDensityPolicy.levelSteps(pinchScale: 1.0 / 4.0), -2)
    }

    func testContinuousDeltaKeepsLivePinchSmoothBetweenSteps() {
        XCTAssertEqual(GridPinchDensityPolicy.continuousLevelDelta(pinchScale: 1.0), 0, accuracy: 0.0001)
        XCTAssertEqual(GridPinchDensityPolicy.continuousLevelDelta(pinchScale: 2.0), 1, accuracy: 0.0001)
        XCTAssertEqual(GridPinchDensityPolicy.continuousLevelDelta(pinchScale: 0.5), -1, accuracy: 0.0001)
        XCTAssertEqual(GridPinchDensityPolicy.continuousLevelDelta(pinchScale: sqrt(2)), 0.5, accuracy: 0.0001)
    }

    func testFullLadderNeedsAnExtremeGesture() {
        // Crossing 4 steps needs > 11× finger scale - a physical near-impossibility in one gesture,
        // so a single ordinary pinch can never fly through every grid level again.
        XCTAssertLessThan(GridPinchDensityPolicy.levelSteps(pinchScale: 8.0), 4)
    }

    func testMagnificationMappingMatchesTrackpadTuning() {
        // The macOS trackpad curve is linear in the ADDITIVE magnification sum: 0.42 per step, sign = direction.
        XCTAssertEqual(GridPinchDensityPolicy.magnificationPerLevel, 0.42)
        XCTAssertEqual(GridPinchDensityPolicy.continuousLevelDelta(magnification: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(GridPinchDensityPolicy.continuousLevelDelta(magnification: 0.42), 1, accuracy: 0.0001)
        XCTAssertEqual(GridPinchDensityPolicy.continuousLevelDelta(magnification: -0.84), -2, accuracy: 0.0001)
        XCTAssertEqual(GridPinchDensityPolicy.continuousLevelDelta(magnification: .nan), 0)
        XCTAssertEqual(GridPinchDensityPolicy.continuousLevelDelta(magnification: .infinity), 0)
    }

    func testDegenerateScalesAreSafe() {
        // Non-finite or non-positive recognizer readings are ignored outright (0 steps)…
        XCTAssertEqual(GridPinchDensityPolicy.levelSteps(pinchScale: 0), 0)
        XCTAssertEqual(GridPinchDensityPolicy.levelSteps(pinchScale: -3), 0)
        XCTAssertEqual(GridPinchDensityPolicy.levelSteps(pinchScale: .infinity), 0)
        XCTAssertEqual(GridPinchDensityPolicy.levelSteps(pinchScale: .nan), 0)
        // …and finite extremes clamp at ±4 steps (16×), beyond any production ladder.
        XCTAssertEqual(GridPinchDensityPolicy.levelSteps(pinchScale: 1_000), 4)
        XCTAssertEqual(GridPinchDensityPolicy.levelSteps(pinchScale: 0.0001), -4)
    }
}
