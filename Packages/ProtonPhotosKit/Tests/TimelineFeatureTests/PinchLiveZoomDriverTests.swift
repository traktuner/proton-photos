// PinchLiveZoomDriverTests.swift
//
// V3.9: the CONTINUOUS MULTI-LEVEL live-pinch driver (pure; no engine / GPU / clock). The grid is one
// scrub surface across detents: segmentQ follows the finger 1:1 within the active adjacent interval, and
// crossing a detent swaps the interval seam-continuously. No mid-gesture latch; release settles the active
// segment to its nearest detent. Convention: band L0…L3 (chainLo 0, chainHi 3). Lower index = larger tiles.
//   • a segment is [source = floor(x)+1 (denser), target = floor(x) (larger)], segmentQ = (floor(x)+1) − x.

import Testing
import Foundation
import GridCore
@testable import TimelineFeature

@Suite struct PinchLiveZoomDriverTests {

    private func started(start: Int = 3, lo: Int = 0, hi: Int = 3) -> PinchLiveZoomDriver {
        var d = PinchLiveZoomDriver()
        d.begin(startLevel: start, chainLo: lo, chainHi: hi)
        return d
    }

    @discardableResult
    private func settle(_ d: inout PinchLiveZoomDriver, maxTicks: Int = 600) -> Int {
        var ticks = 0
        while !d.isCommitted && ticks < maxTicks { d.advance(dt: 1.0 / 60.0); ticks += 1 }
        return ticks
    }

    // ── 1. One gesture chains L3→L2→L1→L0 without a reset/lift ──
    @Test func chainsDownThroughAllLevelsWithoutReset() {
        var d = started(start: 3)
        var seen: [String] = []
        var x = 2.95
        while x >= 0 {
            let out = d.update(continuousLevel: x, dt: 1.0 / 60.0)
            let tag = "\(out.segmentSource)->\(out.segmentTarget)"
            if seen.last != tag { seen.append(tag) }
            #expect(d.phase == .scrub)               // never settles/commits while fingers are down
            x -= 0.05
        }
        #expect(seen == ["3->2", "2->1", "1->0"])    // passed continuously through every adjacent pair
        #expect(d.segmentTarget == 0)                // landed on the largest level
        #expect(abs(d.segmentQ - 1) < 1e-9)          // fully into L0
        #expect(!d.isCommitted)                      // still live - no forced settle between levels
    }

    // ── 2. Reverse chains L0→L1→L2→L3 without a reset ──
    @Test func chainsUpThroughAllLevelsWithoutReset() {
        var d = started(start: 0)
        var seen: [String] = []
        var x = 0.05
        while x <= 3 {
            let out = d.update(continuousLevel: x, dt: 1.0 / 60.0)
            let tag = "\(out.segmentSource)->\(out.segmentTarget)"
            if seen.last != tag { seen.append(tag) }
            #expect(d.phase == .scrub)
            x += 0.05
        }
        #expect(seen == ["1->0", "2->1", "3->2"])    // zoom-out chain through every pair
        #expect(d.segmentSource == 3)
        #expect(abs(d.segmentQ) < 1e-9)              // fully into L3 (q=0 = the denser/source end)
    }

    // ── 3. Slow scrub tracks the finger 1:1 within a segment ──
    @Test func slowScrubTracksRawOneToOne() {
        var d = started(start: 3)
        for (x, q) in [(2.9, 0.1), (2.8, 0.2), (2.7, 0.3), (2.55, 0.45)] {
            let out = d.update(continuousLevel: x, dt: 0.1)
            #expect(out.segmentSource == 3 && out.segmentTarget == 2)
            #expect(abs(out.segmentQ - q) < 1e-9)    // segmentQ == (seg+1) − x exactly (lowpass 1.0)
        }
    }

    // ── 4. Holding the finger still keeps the grid still (update AND tick are no-ops) ──
    @Test func stillFingerHoldsGrid() {
        var d = started(start: 3)
        _ = d.update(continuousLevel: 2.5, dt: 0.1)
        #expect(abs(d.segmentQ - 0.5) < 1e-9)
        for _ in 0 ..< 10 { _ = d.update(continuousLevel: 2.5, dt: 1.0 / 60.0) }
        #expect(abs(d.segmentQ - 0.5) < 1e-9)
        for _ in 0 ..< 10 { d.advance(dt: 1.0 / 60.0) }   // advance is a scrub no-op
        #expect(abs(d.segmentQ - 0.5) < 1e-9 && d.phase == .scrub)
    }

    // ── 5. segmentQ resets cleanly when crossing a detent ──
    @Test func segmentQResetsAtDetentCrossing() {
        var d = started(start: 3)
        let before = d.update(continuousLevel: 2.05, dt: 0.05)   // interval [3→2], near the L2 detent
        #expect(before.segmentSource == 3 && before.segmentTarget == 2)
        #expect(before.segmentQ > 0.9)
        let after = d.update(continuousLevel: 1.80, dt: 0.05)    // crossed below L2 (past hysteresis)
        #expect(after.segmentSource == 2 && after.segmentTarget == 1)   // interval swapped
        #expect(after.segmentQ < 0.3)                            // q reset toward the new source
    }

    // ── 6. Seam: the previous segment's q=1 detent IS the next segment's q=0 detent ──
    @Test func seamSharesTheCrossedDetent() {
        var d = started(start: 3)
        let before = d.update(continuousLevel: 2.01, dt: 0.05)   // [3→2], q≈1 ⇒ shows the L2 (target) detent
        #expect(before.segmentTarget == 2)
        let after = d.update(continuousLevel: 1.80, dt: 0.05)    // [2→1], q≈0 ⇒ shows the L2 (source) detent
        #expect(after.segmentSource == 2)                        // same detent (2) on both sides of the crossing
    }

    // ── 7. Reversing direction across a segment boundary stays stable ──
    @Test func reversalAcrossBoundaryIsStable() {
        var d = started(start: 3)
        _ = d.update(continuousLevel: 1.70, dt: 0.05)            // [2→1] q=0.30
        #expect(d.segmentSource == 2 && d.segmentTarget == 1)
        _ = d.update(continuousLevel: 1.95, dt: 0.05)            // reverse toward L2, still [2→1] q≈0.05
        #expect(d.segmentSource == 2 && d.segmentTarget == 1)
        let flipped = d.update(continuousLevel: 2.20, dt: 0.05)  // crossed back above L2 ⇒ flips to [3→2]
        #expect(flipped.segmentSource == 3 && flipped.segmentTarget == 2)
        #expect(flipped.segmentQ > 0.6 && flipped.segmentQ <= 1) // q bounded - no chaos at the flip
    }

    // ── 8. Fast multi-level flick jumps straight to the final segment in one update ──
    @Test func fastFlickJumpsToFinalSegment() {
        var d = started(start: 3)
        let out = d.update(continuousLevel: 0.5, dt: 1.0 / 120.0)  // L3 → ~L0.5 in one event
        #expect(out.segmentSource == 1 && out.segmentTarget == 0)
        #expect(abs(out.segmentQ - 0.5) < 1e-9)
        #expect(d.velocityQPerSecond > 5)                          // high recent velocity recorded
    }

    // ── 9. Release mid-segment settles the nearest detent (by global position) ──
    @Test func releaseMidSegmentSettlesNearestDetent() {
        var near0 = started(start: 3)
        _ = near0.update(continuousLevel: 1.7, dt: 0.05)         // [2→1] q=0.3 (closer to L2)
        #expect(near0.release() == 2)
        settle(&near0)
        #expect(near0.phase == .committed && near0.finalLevel == 2)
        #expect(abs(near0.segmentQ) < 1e-9)                      // returned to source (L2)

        var near1 = started(start: 3)
        _ = near1.update(continuousLevel: 1.3, dt: 0.05)         // [2→1] q=0.7 (closer to L1)
        #expect(near1.release() == 1)
        settle(&near1)
        #expect(near1.finalLevel == 1)
        #expect(abs(near1.segmentQ - 1) < 1e-9)                  // settled to target (L1)
    }

    // ── 10. Release settle is velocity-aware and never an instant snap ──
    @Test func releaseSettleIsNotInstant() {
        var d = started(start: 3)
        _ = d.update(continuousLevel: 1.4, dt: 0.1)              // [2→1] q=0.6, modest velocity
        _ = d.release()
        d.advance(dt: 1.0 / 60.0)                                 // ONE frame
        #expect(d.segmentQ < 1)                                   // did not jump straight to the detent
        #expect(d.segmentQ - 0.6 <= 8.0 / 60.0 + 1e-9)           // bounded by the speed cap (no snap)
    }

    // ── 11. A large advance force-finishes a settle in one step (the re-pinch interrupt primitive) ──
    @Test func largeAdvanceForceFinishesSettle() {
        var d = started(start: 3)
        _ = d.update(continuousLevel: 1.3, dt: 0.1)              // [2→1] q=0.7
        _ = d.release()
        d.advance(dt: 10)
        #expect(d.isCommitted && d.finalLevel == 1)
    }

    // ── 12. Band clamp: the chain can't run past the eligible band (holds at the boundary detent) ──
    @Test func bandClampHoldsAtEdges() {
        var top = started(start: 3)
        let o1 = top.update(continuousLevel: 4.5, dt: 0.05)      // beyond chainHi=3 (toward overview)
        #expect(o1.segmentSource == 3 && abs(o1.segmentQ) < 1e-9) // clamped: holds at L3 (no transition out)

        var bottom = started(start: 0)
        let o2 = bottom.update(continuousLevel: -2.0, dt: 0.05)  // below chainLo=0
        #expect(o2.segmentTarget == 0 && abs(o2.segmentQ - 1) < 1e-9) // clamped: holds at L0
    }

    // ── 13. Rest dead-band: a sub-threshold nudge engages no segment (grid holds the start detent) ──
    @Test func subDeadbandHoldsStart() {
        var d = started(start: 3)
        let out = d.update(continuousLevel: 2.995, dt: 0.1)      // |Δ| 0.005 < 0.02
        #expect(!out.hasSegment)
        #expect(abs(d.segmentQ) < 1e-9)                          // start L3 is the source end ⇒ q=0
    }

    // ── 14. Release before any move commits the start level (no change) ──
    @Test func releaseBeforeMoveCommitsStart() {
        var d = started(start: 3)
        #expect(d.release() == 3)
        settle(&d)
        #expect(d.finalLevel == 3 && d.phase == .committed)
    }

    // ── 14b. A short directional pinch below the scrub dead-band completes one adjacent step ──
    @Test func shortPinchInCompletesAdjacentStepAtClickSpeed() {
        var d = started(start: 3)
        let out = d.releaseTowardAdjacent(direction: -1)
        #expect(out.hasSegment)
        #expect(out.segmentSource == 3 && out.segmentTarget == 2)
        #expect(abs(out.segmentQ) < 1e-9)
        #expect(d.finalLevel == 2)
        let ticks = settle(&d)
        #expect(d.phase == .committed && d.finalLevel == 2)
        #expect(abs(d.segmentQ - 1) < 1e-9)
        #expect(ticks <= 26)       // ~420 ms at 60 Hz, matching the click transition duration
    }

    @Test func shortPinchOutCompletesAdjacentStepAtClickSpeed() {
        var d = started(start: 0)
        let out = d.releaseTowardAdjacent(direction: 1)
        #expect(out.hasSegment)
        #expect(out.segmentSource == 1 && out.segmentTarget == 0)
        #expect(abs(out.segmentQ - 1) < 1e-9)
        #expect(d.finalLevel == 1)
        let ticks = settle(&d)
        #expect(d.phase == .committed && d.finalLevel == 1)
        #expect(abs(d.segmentQ) < 1e-9)
        #expect(ticks <= 26)
    }

    // ── 15. Interior start chains both directions ──
    @Test func interiorStartChainsBothWays() {
        var down = started(start: 2)
        _ = down.update(continuousLevel: 1.5, dt: 0.05)
        #expect(down.segmentSource == 2 && down.segmentTarget == 1)
        var up = started(start: 2)
        _ = up.update(continuousLevel: 2.5, dt: 0.05)
        #expect(up.segmentSource == 3 && up.segmentTarget == 2)
    }

    // ── 15b. Release at exactly q=0.5 tie-breaks to the target detent (>=) ──
    @Test func releaseAtExactHalfTieBreaksToTarget() {
        var d = started(start: 3)
        _ = d.update(continuousLevel: 1.5, dt: 0.05)            // [2→1], q = 2 − 1.5 = 0.5 exactly
        #expect(abs(d.segmentQ - 0.5) < 1e-9)
        #expect(d.release() == 1)                                // tie ⇒ target
        settle(&d); #expect(d.finalLevel == 1)
    }

    // ── 15c. Release at a chain extreme settles the boundary detent ──
    @Test func releaseAtChainExtremeSettlesBoundary() {
        var d = started(start: 3)
        _ = d.update(continuousLevel: 0.1, dt: 0.05)            // chained down to [1→0], q=0.9 (near L0)
        #expect(d.segmentSource == 1 && d.segmentTarget == 0)
        #expect(d.release() == 0)                                // nearest = L0 (bottom boundary)
        settle(&d)
        #expect(d.finalLevel == 0 && abs(d.segmentQ - 1) < 1e-9)
    }

    // ── 15d. A degenerate band (overview start) is inert - the driver never chains ──
    @Test func degenerateBandIsInert() {
        var d = PinchLiveZoomDriver()
        d.begin(startLevel: 4, chainLo: 4, chainHi: 4)
        #expect(!d.chainable)
        let out = d.update(continuousLevel: 3.0, dt: 0.05)      // attempt to chain - must stay inert
        #expect(!out.hasSegment)
        #expect(d.release() == 4)                                // commits the start level, no chaining
    }

    // ── 15e. Low-pass (<1) does NOT smear across a detent crossing (seam-safe) ──
    @Test func lowPassResetsAtCrossing() {
        var t = PinchLiveZoomDriver.Tunables(); t.displayQLowPassAlpha = 0.25
        var d = PinchLiveZoomDriver(tuning: t)
        d.begin(startLevel: 3, chainLo: 0, chainHi: 3)
        _ = d.update(continuousLevel: 2.05, dt: 0.05)           // [3→2] near the L2 detent
        let after = d.update(continuousLevel: 1.80, dt: 0.05)   // crossed below L2
        #expect(after.segmentSource == 2 && after.segmentTarget == 1)
        // seam-correct value for the NEW segment is 2 − 1.80 = 0.20; the filter must NOT carry the old ~1.0.
        #expect(abs(after.segmentQ - 0.20) < 1e-9)
    }

    // ── 16. Reset returns to idle (re-usable across gestures) ──
    @Test func resetReturnsToIdle() {
        var d = started(start: 3)
        _ = d.update(continuousLevel: 1.4, dt: 0.1)
        _ = d.release(); settle(&d)
        d.reset()
        #expect(d.phase == .idle && !d.isActive && !d.isSelfAdvancing && !d.isCommitted)
        #expect(abs(d.segmentQ) < 1e-9)
    }
}
