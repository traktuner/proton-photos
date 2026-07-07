import CoreGraphics
import XCTest
import PhotoViewerCore

/// Locks the shared bounded viewer-loading policy: the display decode size is screen-bounded (never the full
/// original just because a page appeared), and the load window is the current page only.
final class ViewerImageLoadPolicyTests: XCTestCase {

    func testDisplayMaxPixelSizeIsScreenBoundedWithHeadroomAndClamped() {
        // Screen-fit × headroom for a normal phone viewport at 3×: 900pt × 3 × 2 = 5400, clamped to the ceiling.
        let phone = ViewerImageLoadPolicy.displayMaxPixelSize(
            viewportPoints: CGSize(width: 400, height: 900), scale: 3)
        XCTAssertEqual(phone, ViewerImageLoadPolicy.maxDisplayPixelSize)

        // A small viewport stays below the ceiling: 400pt × 2 × 2 = 1600.
        let small = ViewerImageLoadPolicy.displayMaxPixelSize(
            viewportPoints: CGSize(width: 300, height: 400), scale: 2)
        XCTAssertEqual(small, 1600)
        XCTAssertLessThan(small, ViewerImageLoadPolicy.maxDisplayPixelSize)

        // Never unbounded: it never exceeds the ceiling.
        XCTAssertLessThanOrEqual(
            ViewerImageLoadPolicy.displayMaxPixelSize(viewportPoints: CGSize(width: 5000, height: 5000), scale: 3),
            ViewerImageLoadPolicy.maxDisplayPixelSize)
    }

    func testDisplayMaxPixelSizeFallsBackToCeilingForUnknownViewport() {
        // Zero / degenerate viewport or scale must still yield a BOUNDED decode (the ceiling), never 0 or unbounded.
        XCTAssertEqual(
            ViewerImageLoadPolicy.displayMaxPixelSize(viewportPoints: .zero, scale: 3),
            ViewerImageLoadPolicy.maxDisplayPixelSize)
        XCTAssertEqual(
            ViewerImageLoadPolicy.displayMaxPixelSize(viewportPoints: CGSize(width: 400, height: 900), scale: 0),
            ViewerImageLoadPolicy.maxDisplayPixelSize)
    }

    func testLoadWindowIsCurrentPageOnly() {
        XCTAssertTrue(ViewerImageLoadPolicy.shouldLoadDisplay(distanceFromCurrent: 0))
        // Neighbours (swipe-preview pages) do NOT load their display image - no fetch/decode fan-out.
        XCTAssertFalse(ViewerImageLoadPolicy.shouldLoadDisplay(distanceFromCurrent: 1))
        XCTAssertFalse(ViewerImageLoadPolicy.shouldLoadDisplay(distanceFromCurrent: 3))
        XCTAssertEqual(ViewerImageLoadPolicy.loadNeighborRadius, 0)
    }
}
