import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// The release commit bridge: GEOMETRY-ONLY morph from the `GridZoomTransaction` final frame → the settled
/// `GridFramePlan`. Matched strictly by GLOBAL INDEX (never screen position); each index's viewport rect eases
/// from its transaction-final position to its settled position; identities never change; it ENDS exactly on the
/// settled plan; bounded duration; no spring/bounce. (Not crossfade, not photo replacement, not a new live model.)
@Suite struct GridZoomCommitBridgeTests {
    private let viewport = CGSize(width: 1400, height: 900)
    private let width: CGFloat = 1400
    private let count = 5000
    private let anchor = 2137
    private let cursor = CGPoint(x: 690, y: 430)
    private let overscan: CGFloat = 0
    private let sourceLevel = 3
    private let targetLevel = 5    // a large phase shift (≈9 columns per the seam measurement)

    // The bridge is the cursor-aligned PHASED settle (sub-cell residual); compute that phase + its rebased scrollY.
    private func setup() -> (e: SquareTileGridEngine, tx: GridZoomTransaction, phase: Int, scrollY: CGFloat) {
        let e = SquareTileGridEngine(sectionCounts: [count])
        let src = e.slotRect(flatIndex: anchor, level: sourceLevel, width: width)!
        let tx = e.beginZoomTransaction(cursorContentPoint: CGPoint(x: src.midX, y: src.midY),
                                        viewportPoint: cursor, level: sourceLevel, width: width)!
        let desiredCol = e.cursorColumn(viewportX: tx.anchorViewportPoint.x, level: targetLevel, width: width)
        let phase = e.columnPhase(forItem: anchor, targetColumn: desiredCol, level: targetLevel, width: width)
        let scrollY = e.anchoredScrollOffset(flatIndex: tx.anchorGlobalIndex, localFraction: tx.anchorLocalFraction,
                                             viewportPoint: tx.anchorViewportPoint, level: targetLevel, width: width, columnPhase: phase).y
        return (e, tx, phase, scrollY)
    }

    private func bridge(_ e: SquareTileGridEngine, _ tx: GridZoomTransaction, _ scrollY: CGFloat, _ phase: Int, _ t: CGFloat) -> [GridRenderSlot] {
        GridZoomCommitBridge.frame(transaction: tx, engine: e, targetLevel: targetLevel,
                                   viewportSize: viewport, scrollY: scrollY, overscan: overscan, progress: t, columnPhase: phase)
    }

    // MARK: 1 — CommitBridgeMeasuresHorizontalPhaseShiftTest
    @Test func commitBridgeMeasuresHorizontalPhaseShift() {
        let (e, tx, _, _) = setup()
        let d = e.commitDelta(transaction: tx, targetLevel: targetLevel, viewportSize: viewport)   // canonical (no phase)
        #expect(abs(d.anchorDelta.height) < 1.0, "the seam is horizontal: vertical must be rebased to ~0")
        #expect(abs(d.anchorDelta.width) > 1.0, "a phase-shifting commit must measure a non-zero horizontal shift")
        let pitch = e.resolvedMetrics(level: targetLevel, width: width).pitch
        #expect(d.anchorColumnShift(pitch: pitch) != 0, "the horizontal shift is a whole-column phase shift")
    }

    // MARK: 2 — CommitBridgeInterpolatesMatchedGlobalIndexRectsTest
    @Test func commitBridgeInterpolatesMatchedGlobalIndexRects() {
        let (e, tx, phase, scrollY) = setup()
        // The anchor is matched (present in both the transaction-final frame AND the phased settled plan); with
        // the phase its move is sub-cell, so the bridge eases it (rather than snapping).
        let from = tx.rect(forGlobalIndex: anchor, continuousLevel: CGFloat(targetLevel), viewportSize: viewport)!
        let settled = e.framePlan(level: targetLevel, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: scrollY), overscan: overscan, columnPhase: phase)
        let to = settled.visibleSlots.first { $0.index == anchor }!.viewportRect
        for t in stride(from: CGFloat(0), through: 1, by: 0.2) {
            let p = GridZoomCommitBridge.easedProgress(t)
            let expectedX = from.minX + (to.minX - from.minX) * p
            let expectedY = from.minY + (to.minY - from.minY) * p
            let slot = bridge(e, tx, scrollY, phase, t).first { $0.index == anchor }   // keyed by globalIndex
            #expect(slot != nil, "anchor missing from bridge frame at t=\(t)")
            #expect(abs(slot!.rect.minX - expectedX) < 0.01 && abs(slot!.rect.minY - expectedY) < 0.01,
                    "matched-index rect not eased-lerped at t=\(t): \(slot!.rect.origin) vs (\(expectedX),\(expectedY))")
        }
    }

    // MARK: 3 — CommitBridgeKeepsAnchorDeltaMonotonicTest
    @Test func commitBridgeKeepsAnchorDeltaMonotonic() {
        let (e, tx, phase, scrollY) = setup()
        let settled = e.framePlan(level: targetLevel, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: scrollY), overscan: overscan, columnPhase: phase)
        let settledAnchorX = settled.visibleSlots.first { $0.index == anchor }!.viewportRect.minX
        var lastDistance = CGFloat.greatestFiniteMagnitude
        for t in stride(from: CGFloat(0), through: 1, by: 0.1) {
            let x = bridge(e, tx, scrollY, phase, t).first { $0.index == anchor }!.rect.minX
            let distance = abs(x - settledAnchorX)
            #expect(distance <= lastDistance + 0.01, "anchor distance to settled not monotonic at t=\(t): \(distance) > \(lastDistance)")
            lastDistance = distance
        }
        #expect(lastDistance < 0.01, "anchor must reach the settled position at t=1")
    }

    // MARK: 4 — CommitBridgeDoesNotChangeGlobalIdentityTest
    @Test func commitBridgeDoesNotChangeGlobalIdentity() {
        let (e, tx, phase, scrollY) = setup()
        let identitiesAt0 = bridge(e, tx, scrollY, phase, 0).map(\.index)
        for t in stride(from: CGFloat(0), through: 1, by: 0.25) {
            let slots = bridge(e, tx, scrollY, phase, t)
            let ids = slots.map(\.index)
            #expect(Set(ids).count == ids.count, "duplicate globalIndex in bridge frame at t=\(t) (would be duplicate chaos)")
            #expect(ids.sorted() == identitiesAt0.sorted(), "the set of visible global identities changed across t=\(t)")
        }
    }

    // MARK: 5 — CommitBridgeCompletesAtSettledGridFrameTest
    @Test func commitBridgeCompletesAtSettledGridFrame() {
        let (e, tx, phase, scrollY) = setup()
        let settled = e.framePlan(level: targetLevel, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: scrollY), overscan: overscan, columnPhase: phase)
        let finalByIndex = Dictionary(uniqueKeysWithValues: bridge(e, tx, scrollY, phase, 1).map { ($0.index, $0.rect) })
        // Every settled-visible item's bridged rect at t=1 EXACTLY equals the settled GridFramePlan rect.
        for s in settled.visibleSlots {
            let r = finalByIndex[s.index]
            #expect(r != nil, "settled item \(s.index) missing from bridge final frame")
            #expect(abs(r!.minX - s.viewportRect.minX) < 0.01 && abs(r!.minY - s.viewportRect.minY) < 0.01
                    && abs(r!.width - s.viewportRect.width) < 0.01 && abs(r!.height - s.viewportRect.height) < 0.01,
                    "bridge final rect for \(s.index) != settled plan rect")
        }
    }

    // MARK: 6 — CommitBridgeDurationIsBoundedTest
    @Test func commitBridgeDurationIsBounded() {
        #expect(GridZoomCommitBridge.duration >= 0.12 && GridZoomCommitBridge.duration <= 0.18,
                "bridge duration must be 120–180 ms, got \(GridZoomCommitBridge.duration)")
    }

    // MARK: 7 — CommitBridgeNoSpringNoBounceTest
    @Test func commitBridgeNoSpringNoBounce() {
        #expect(GridZoomCommitBridge.easedProgress(0) == 0)
        #expect(abs(GridZoomCommitBridge.easedProgress(1) - 1) < 1e-9)
        var last = CGFloat(-1)
        for t in stride(from: CGFloat(0), through: 1, by: 0.02) {
            let p = GridZoomCommitBridge.easedProgress(t)
            #expect(p >= -1e-9 && p <= 1 + 1e-9, "easing overshot [0,1] at t=\(t): \(p) (spring/bounce)")
            #expect(p >= last - 1e-9, "easing not monotonic non-decreasing at t=\(t): \(p) < \(last)")
            last = p
        }
    }
}
