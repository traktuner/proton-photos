import CoreGraphics
import Testing
@testable import GridCore

/// Locks the drag-select edge auto-scroll ramp: a middle dead zone, linear ramp inside each edge band, and a
/// clamp to ±maxSpeed at/over the edges — the behavior that lets a drag-selection run past the visible rows
/// without gaps.
@Suite struct GridEdgeAutoScrollPolicyTests {
    private let height: CGFloat = 800
    private let inset: CGFloat = 100
    private let maxSpeed: CGFloat = 1200

    private func v(_ touchY: CGFloat) -> CGFloat {
        GridEdgeAutoScrollPolicy.velocity(touchY: touchY, viewportHeight: height, edgeInset: inset, maxSpeed: maxSpeed)
    }

    @Test func middleIsDeadZone() {
        #expect(v(400) == 0)
        #expect(v(inset) == 0)               // inner edge of the top band is exactly zero
        #expect(v(height - inset) == 0)      // inner edge of the bottom band is exactly zero
    }

    @Test func topBandScrollsUpAndRamps() {
        #expect(v(50) < 0)                   // upper half of the band → negative (toward top)
        #expect(v(0) == -maxSpeed)           // the very top → full negative speed
        #expect(v(-40) == -maxSpeed)         // dragged above the viewport → clamped, not overshooting
        // Monotonic: closer to the edge is faster (more negative).
        #expect(v(20) < v(80))
    }

    @Test func bottomBandScrollsDownAndRamps() {
        #expect(v(height - 50) > 0)          // lower half of the band → positive (toward bottom)
        #expect(v(height) == maxSpeed)       // the very bottom → full positive speed
        #expect(v(height + 40) == maxSpeed)  // dragged below the viewport → clamped
        #expect(v(height - 20) > v(height - 80))
    }

    @Test func degenerateInputsYieldZero() {
        #expect(GridEdgeAutoScrollPolicy.velocity(touchY: 10, viewportHeight: 0, edgeInset: inset, maxSpeed: maxSpeed) == 0)
        #expect(GridEdgeAutoScrollPolicy.velocity(touchY: 10, viewportHeight: height, edgeInset: 0, maxSpeed: maxSpeed) == 0)
        #expect(GridEdgeAutoScrollPolicy.velocity(touchY: 10, viewportHeight: height, edgeInset: inset, maxSpeed: 0) == 0)
    }

    /// On a short viewport the band is capped at half-height so a dead zone always remains at the center.
    @Test func shortViewportKeepsDeadZone() {
        let short: CGFloat = 120
        let bigInset: CGFloat = 400          // larger than the viewport
        let center = GridEdgeAutoScrollPolicy.velocity(
            touchY: short / 2, viewportHeight: short, edgeInset: bigInset, maxSpeed: maxSpeed
        )
        #expect(center == 0)
        #expect(GridEdgeAutoScrollPolicy.isInEdgeBand(touchY: short / 2, viewportHeight: short, edgeInset: bigInset) == false)
    }

    @Test func edgeBandDetection() {
        #expect(GridEdgeAutoScrollPolicy.isInEdgeBand(touchY: 10, viewportHeight: height, edgeInset: inset))
        #expect(GridEdgeAutoScrollPolicy.isInEdgeBand(touchY: height - 10, viewportHeight: height, edgeInset: inset))
        #expect(GridEdgeAutoScrollPolicy.isInEdgeBand(touchY: 400, viewportHeight: height, edgeInset: inset) == false)
    }
}
