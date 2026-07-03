import XCTest
import PhotoViewerCore

/// Locks the shared pinch-to-close semantics for the viewer.
final class ViewerPinchDismissPolicyTests: XCTestCase {

    func testEngagesOnlyOnPinchInWhileUnzoomed() {
        XCTAssertTrue(ViewerPinchDismissPolicy.engages(gestureScale: 0.9, isZoomedIn: false))
        // Zoomed/panned media belongs to the zoom gesture, never to dismiss.
        XCTAssertFalse(ViewerPinchDismissPolicy.engages(gestureScale: 0.9, isZoomedIn: true))
        // Zoom intent or noise around rest scale never grabs the media.
        XCTAssertFalse(ViewerPinchDismissPolicy.engages(gestureScale: 1.0, isZoomedIn: false))
        XCTAssertFalse(ViewerPinchDismissPolicy.engages(gestureScale: 1.4, isZoomedIn: false))
        XCTAssertFalse(ViewerPinchDismissPolicy.engages(gestureScale: .nan, isZoomedIn: false))
    }

    func testDisplayScaleFollowsFingersWithinBounds() {
        XCTAssertEqual(ViewerPinchDismissPolicy.displayScale(gestureScale: 0.8), 0.8)
        // Floored so the media never collapses mid-gesture…
        XCTAssertEqual(
            ViewerPinchDismissPolicy.displayScale(gestureScale: 0.05),
            ViewerPinchDismissPolicy.minimumDisplayScale
        )
        // …and capped at rest size (pinching back out returns to rest, never zooms).
        XCTAssertEqual(ViewerPinchDismissPolicy.displayScale(gestureScale: 1.6), 1)
        XCTAssertEqual(ViewerPinchDismissPolicy.displayScale(gestureScale: .infinity), 1)
    }

    func testReleaseDecisionSplitsAtDismissThreshold() {
        XCTAssertTrue(ViewerPinchDismissPolicy.shouldDismiss(releaseScale: 0.5))
        XCTAssertFalse(ViewerPinchDismissPolicy.shouldDismiss(releaseScale: 0.9))
        XCTAssertFalse(ViewerPinchDismissPolicy.shouldDismiss(releaseScale: ViewerPinchDismissPolicy.dismissScale))
        // A degenerate reading must never spuriously close the viewer.
        XCTAssertFalse(ViewerPinchDismissPolicy.shouldDismiss(releaseScale: .nan))
    }

    func testThresholdOrderingIsCoherent() {
        XCTAssertLessThan(ViewerPinchDismissPolicy.dismissScale, ViewerPinchDismissPolicy.engagementScale)
        XCTAssertLessThan(ViewerPinchDismissPolicy.minimumDisplayScale, ViewerPinchDismissPolicy.dismissScale)
    }
}
