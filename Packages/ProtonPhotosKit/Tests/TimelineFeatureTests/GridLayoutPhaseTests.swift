import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// Engine-owned COLUMN PHASE: the settled grid after a zoom keeps the anchor item in the CURSOR's column, so
/// the photo under the cursor does NOT fly across the grid on release. The phase is `column(g)=(phase+g)%cols`,
/// chosen so `column(anchor)==cursorColumn`. These tests pin the phase math, the small commit delta, and that
/// the phase persists + scrolls coherently. (Trade-off: a cursor-aligned phase splits the partial row between
/// the oldest top-left and newest bottom-right ends - see the report; the bottom pin resets to canonical.)
@Suite struct GridLayoutPhaseTests {
    private let viewport = CGSize(width: 1400, height: 900)
    private let width: CGFloat = 1400
    private let count = 5000
    private let anchor = 2137
    private let cursor = CGPoint(x: 690, y: 430)   // mid-viewport (so the cursor column is NOT the far edge)
    private let sourceLevel = 3

    private func setup(target: Int) -> (e: SquareTileGridEngine, tx: GridZoomTransaction, desiredCol: Int, phase: Int, scrollY: CGFloat) {
        let e = SquareTileGridEngine.testRegular(sectionCounts: [count])
        let src = e.slotRect(flatIndex: anchor, level: sourceLevel, width: width)!
        let tx = e.beginZoomTransaction(cursorContentPoint: CGPoint(x: src.midX, y: src.midY),
                                        viewportPoint: cursor, level: sourceLevel, width: width)!
        let desiredCol = e.cursorColumn(viewportX: tx.anchorViewportPoint.x, level: target, width: width)
        let phase = e.columnPhase(forItem: anchor, targetColumn: desiredCol, level: target, width: width)
        let scrollY = e.anchoredScrollOffset(flatIndex: anchor, localFraction: tx.anchorLocalFraction,
                                             viewportPoint: tx.anchorViewportPoint, level: target, width: width, columnPhase: phase).y
        return (e, tx, desiredCol, phase, scrollY)
    }

    private func phasedPlan(_ s: (e: SquareTileGridEngine, tx: GridZoomTransaction, desiredCol: Int, phase: Int, scrollY: CGFloat), target: Int) -> GridFramePlan {
        s.e.framePlan(level: target, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: s.scrollY), overscan: 0, columnPhase: s.phase)
    }

    // MARK: 1 - SettledTargetPreservesCursorAnchorColumnTest
    @Test func settledTargetPreservesCursorAnchorColumn() {
        for target in 0 ..< SquareTileGridEngine.testRegularLevels.count {
            let s = setup(target: target)
            let anchorSlot = phasedPlan(s, target: target).visibleSlots.first { $0.index == anchor }
            #expect(anchorSlot?.column == s.desiredCol,
                    "settled anchor column \(anchorSlot?.column as Any) != cursor column \(s.desiredCol) at target \(target)")
        }
    }

    // MARK: 2 - CommitAnchorHorizontalDeltaIsSmallTest
    @Test func commitAnchorHorizontalDeltaIsSmall() {
        // Targets 0,2,3,5,6 have a large canonical phase shift (≥1 column) per the seam measurement.
        for target in [0, 2, 3, 5, 6] {
            let s = setup(target: target)
            let pitch = s.e.resolvedMetrics(level: target, width: width).pitch
            let phased = s.e.commitDelta(transaction: s.tx, targetLevel: target, viewportSize: viewport, columnPhase: s.phase)
            let canonical = s.e.commitDelta(transaction: s.tx, targetLevel: target, viewportSize: viewport)
            #expect(abs(phased.anchorDelta.width) < pitch,
                    "phased horizontal delta not sub-cell at target \(target): \(phased.anchorDelta.width) (pitch \(pitch))")
            #expect(abs(phased.anchorDelta.height) < 1.0, "vertical must still be rebased to ~0")
            // The phase shrinks the fly from hundreds of px to sub-cell.
            #expect(abs(phased.anchorDelta.width) < abs(canonical.anchorDelta.width),
                    "phase must shrink the horizontal delta at target \(target): phased \(phased.anchorDelta.width) vs canonical \(canonical.anchorDelta.width)")
        }
    }

    // MARK: 3 - SelectedPhotoDoesNotMoveToFarRightOnReleaseTest
    @Test func selectedPhotoDoesNotMoveToFarRightOnRelease() {
        let target = 5   // a big zoom-out (densest) - the original far-right fly
        let s = setup(target: target)
        let cols = s.e.resolvedMetrics(level: target, width: width).columns
        #expect(s.desiredCol < cols - 1, "the mid-viewport cursor must not BE the far-right column")
        let anchorSlot = phasedPlan(s, target: target).visibleSlots.first { $0.index == anchor }!
        #expect(anchorSlot.column == s.desiredCol, "selected photo must settle in the cursor column")
        #expect(anchorSlot.column != cols - 1, "selected photo must NOT settle to the far-right column")
        // Without the phase (canonical bottom-right) it lands elsewhere - that is the bug being fixed.
        let canonicalCol = s.e.framePlan(level: target, viewportSize: viewport,
                                         scrollOffset: CGPoint(x: 0, y: s.scrollY), overscan: 0)
            .visibleSlots.first { $0.index == anchor }?.column
        #expect(canonicalCol != s.desiredCol, "canonical phase would move the anchor to a different column (the bug)")
    }

    // MARK: 4 - NoLargeRectLerpForMatchedGlobalIndexTest
    @Test func noLargeRectLerpForMatchedGlobalIndex() {
        for target in [0, 3, 5, 6] {
            let s = setup(target: target)
            let pitch = s.e.resolvedMetrics(level: target, width: width).pitch
            let at0 = GridZoomCommitBridge.frame(transaction: s.tx, engine: s.e, targetLevel: target,
                                                 viewportSize: viewport, scrollY: s.scrollY, overscan: 0, progress: 0, columnPhase: s.phase)
            let at1 = GridZoomCommitBridge.frame(transaction: s.tx, engine: s.e, targetLevel: target,
                                                 viewportSize: viewport, scrollY: s.scrollY, overscan: 0, progress: 1, columnPhase: s.phase)
            let a0 = at0.first { $0.index == anchor }!.rect
            let a1 = at1.first { $0.index == anchor }!.rect
            #expect(abs(a1.minX - a0.minX) < pitch,
                    "bridge moves the anchor \(abs(a1.minX - a0.minX))px (≥1 cell) across the commit at target \(target)")
        }
    }

    // MARK: 5 - FocusRowPhasePreservedAfterCommitTest
    @Test func focusRowPhasePreservedAfterCommit() {
        for target in [1, 2, 3, 4, 5] {
            let s = setup(target: target)
            let txFocus = s.tx.frame(continuousLevel: CGFloat(target), viewportSize: viewport, overscan: 0).focusRow
            let plan = phasedPlan(s, target: target)
            let anchorRow = plan.visibleSlots.first { $0.index == anchor }!.row
            let settledFocus = plan.visibleSlots.filter { $0.row == anchorRow }.map(\.index).sorted()
            #expect(Set(settledFocus) == Set(txFocus),
                    "settled focus row differs from transaction focus row at target \(target): \(settledFocus) vs \(txFocus)")
        }
    }

    // MARK: 6 - PhaseComputedFromAnchorGlobalIndexAndDesiredColumnTest
    @Test func phaseComputedFromAnchorGlobalIndexAndDesiredColumn() {
        let target = 3
        let e = SquareTileGridEngine.testRegular(sectionCounts: [count])
        let cols = e.resolvedMetrics(level: target, width: width).columns
        for desired in [0, 1, cols / 2, cols - 1] {
            let phase = e.columnPhase(forItem: anchor, targetColumn: desired, level: target, width: width)
            let scrollY = e.anchoredScrollOffset(flatIndex: anchor, localFraction: CGPoint(x: 0.5, y: 0.5),
                                                 viewportPoint: cursor, level: target, width: width, columnPhase: phase).y
            let col = e.framePlan(level: target, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: scrollY), overscan: 0, columnPhase: phase)
                .visibleSlots.first { $0.index == anchor }?.column
            #expect(col == desired, "columnPhase did not map anchor to desired column \(desired): got \(col as Any)")
        }
    }

    // MARK: 7 - GridPhasePersistsAfterZoomTest
    // The column is a pure function of (phase + globalIndex), independent of scroll - so the phase persists and
    // the next frame never snaps back to the canonical phase.
    @Test func gridPhasePersistsAfterZoom() {
        let target = 4
        let s = setup(target: target)
        let cols = s.e.resolvedMetrics(level: target, width: width).columns
        for scrollY in [CGFloat(800), 3000, 7000] {
            let plan = s.e.framePlan(level: target, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: scrollY), overscan: 0, columnPhase: s.phase)
            for slot in plan.visibleSlots {
                #expect(slot.column == ((s.phase + slot.index) % cols + cols) % cols,
                        "phase not persisted: item \(slot.index) column \(slot.column) ≠ (phase+index)%cols at scroll \(scrollY)")
            }
        }
    }

    // MARK: 8 - ScrollingAfterPhasedZoomRemainsCoherentTest
    // Scrolling one row keeps every item in the SAME column and shifts its row by exactly one pitch.
    @Test func scrollingAfterPhasedZoomRemainsCoherent() {
        let target = 3
        let s = setup(target: target)
        let pitch = s.e.resolvedMetrics(level: target, width: width).pitch
        let planA = s.e.framePlan(level: target, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 2000), overscan: pitch * 2, columnPhase: s.phase)
        let planB = s.e.framePlan(level: target, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 2000 + pitch), overscan: pitch * 2, columnPhase: s.phase)
        let bByIndex = Dictionary(uniqueKeysWithValues: planB.visibleSlots.map { ($0.index, $0) })
        var checked = 0
        for sa in planA.visibleSlots {
            guard let sb = bByIndex[sa.index] else { continue }
            #expect(sa.column == sb.column, "item \(sa.index) changed column on scroll (incoherent phase)")
            #expect(abs((sa.viewportRect.minY - sb.viewportRect.minY) - pitch) < 0.5, "row not coherent on scroll for \(sa.index)")
            checked += 1
        }
        #expect(checked > 10, "expected many items visible in both scroll offsets")
    }
}
