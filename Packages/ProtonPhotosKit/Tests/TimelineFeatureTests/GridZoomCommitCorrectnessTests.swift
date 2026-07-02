import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// Commit CORRECTNESS: a thumbnail identity must never visibly fly from one slot to another on release. With the
/// engine-owned cursor-aligned phase the anchor stays in its column (sub-cell residual only); the bridge has a
/// HARD guarantee that it can never animate a matched globalIndex across a column; and the settled frame after
/// commit uses the committed phase immediately. These tests fail on the old "fly to the far right" behavior.
@Suite struct GridZoomCommitCorrectnessTests {
    private let viewport = CGSize(width: 1400, height: 900)
    private let width: CGFloat = 1400
    private let count = 5000
    private let anchor = 2137
    private let cursor = CGPoint(x: 690, y: 430)
    private let sourceLevel = 3

    private func setup(target: Int) -> (e: SquareTileGridEngine, tx: GridZoomTransaction, desiredCol: Int, phase: Int, scrollY: CGFloat, pitch: CGFloat) {
        let e = SquareTileGridEngine.testRegular(sectionCounts: [count])
        let src = e.slotRect(flatIndex: anchor, level: sourceLevel, width: width)!
        let tx = e.beginZoomTransaction(cursorContentPoint: CGPoint(x: src.midX, y: src.midY),
                                        viewportPoint: cursor, level: sourceLevel, width: width)!
        let desiredCol = e.cursorColumn(viewportX: tx.anchorViewportPoint.x, level: target, width: width)
        let phase = e.columnPhase(forItem: anchor, targetColumn: desiredCol, level: target, width: width)
        let scrollY = e.anchoredScrollOffset(flatIndex: anchor, localFraction: tx.anchorLocalFraction,
                                             viewportPoint: tx.anchorViewportPoint, level: target, width: width, columnPhase: phase).y
        return (e, tx, desiredCol, phase, scrollY, e.resolvedMetrics(level: target, width: width).pitch)
    }

    // MARK: 1 - CommitDoesNotMoveAnchorAcrossColumnsTest
    @Test func commitDoesNotMoveAnchorAcrossColumns() {
        for target in [0, 2, 3, 4, 5, 6] {           // dense + sparse targets (the original fly was at dense)
            let s = setup(target: target)
            let d = s.e.commitDelta(transaction: s.tx, targetLevel: target, viewportSize: viewport, columnPhase: s.phase)
            #expect(abs(d.anchorDelta.width) < s.pitch, "anchor moves ≥1 column at target \(target): \(d.anchorDelta.width)px (pitch \(s.pitch))")
            #expect(d.anchorColumnShift(pitch: s.pitch) == 0, "anchor changed column at target \(target)")
            #expect(abs(d.anchorDelta.height) < 1.0, "vertical must be rebased")
        }
    }

    // MARK: 2 - CommitBridgeRejectsLargeMatchedIndexMovementTest
    @Test func commitBridgeRejectsLargeMatchedIndexMovement() {
        let target = 5
        let s = setup(target: target)
        // WITHOUT the phase the canonical settled plan is a multi-column mismatch - the bridge must NOT lerp it.
        let canonicalMove = GridZoomCommitBridge.maxMatchedIndexMoveX(transaction: s.tx, engine: s.e, targetLevel: target,
                                                                      viewportSize: viewport, scrollY: s.scrollY, overscan: 0, columnPhase: nil)
        #expect(canonicalMove > s.pitch, "test scenario must actually have a >1-column mismatch without the phase")
        let settled = s.e.framePlan(level: target, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: s.scrollY), overscan: 0)
        let settledAnchor = settled.visibleSlots.first { $0.index == anchor }!.viewportRect
        // At a mid progress, the bridge must have SNAPPED to settled (no intermediate flying rect).
        let mid = GridZoomCommitBridge.frame(transaction: s.tx, engine: s.e, targetLevel: target, viewportSize: viewport,
                                             scrollY: s.scrollY, overscan: 0, progress: 0.5, columnPhase: nil)
        let midAnchor = mid.first { $0.index == anchor }!.rect
        #expect(abs(midAnchor.minX - settledAnchor.minX) < 0.5,
                "bridge displayed a matched index mid-flight across columns instead of snapping to settled")
    }

    // MARK: 3 - SelectedOrHoveredItemIsZoomAnchorTest
    @Test func selectedOrHoveredItemIsZoomAnchor() {
        let e = SquareTileGridEngine.testRegular(sectionCounts: [count])
        let hoveredItem = 2500
        let rect = e.slotRect(flatIndex: hoveredItem, level: sourceLevel, width: width)!
        let hover = CGPoint(x: rect.midX, y: rect.midY)
        // The engine anchor resolves to the item UNDER the cursor - not top, not centre, not a selected item.
        let a = e.anchorItem(nearContentPoint: hover, level: sourceLevel, width: width)
        #expect(a?.flatIndex == hoveredItem, "anchor must be the hovered item, got \(a?.flatIndex as Any)")
        let tx = e.beginZoomTransaction(cursorContentPoint: hover, viewportPoint: CGPoint(x: 200, y: 300), level: sourceLevel, width: width)!
        #expect(tx.anchorGlobalIndex == hoveredItem, "transaction must anchor the hovered item")
        // A different hover point resolves to a different anchor (so it tracks the cursor, not a fixed item).
        let other = e.slotRect(flatIndex: 80, level: sourceLevel, width: width)!
        let a2 = e.anchorItem(nearContentPoint: CGPoint(x: other.midX, y: other.midY), level: sourceLevel, width: width)
        #expect(a2?.flatIndex == 80)
    }

    // MARK: 4 - FocusRowCommitPhasePreservedTest
    @Test func focusRowCommitPhasePreserved() {
        for target in [1, 2, 3, 4, 5] {
            let s = setup(target: target)
            let txFocus = Set(s.tx.frame(continuousLevel: CGFloat(target), viewportSize: viewport, overscan: 0).focusRow)
            let plan = s.e.framePlan(level: target, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: s.scrollY), overscan: 0, columnPhase: s.phase)
            let anchorRow = plan.visibleSlots.first { $0.index == anchor }!.row
            let settledFocus = Set(plan.visibleSlots.filter { $0.row == anchorRow }.map(\.index))
            #expect(settledFocus == txFocus, "focus row neighborhood changed at commit, target \(target)")
        }
    }

    // MARK: 5 - SettledFrameUsesCommittedPhaseImmediatelyTest
    @Test func settledFrameUsesCommittedPhaseImmediately() {
        let target = 5
        let s = setup(target: target)
        // The phased settled frame (what the coordinator renders post-commit) places the anchor in the cursor
        // column; the canonical (snap-back) frame would NOT - proving the committed phase is used immediately.
        let phased = s.e.framePlan(level: target, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: s.scrollY), overscan: 0, columnPhase: s.phase)
        #expect(phased.visibleSlots.first { $0.index == anchor }?.column == s.desiredCol)
        let canonical = s.e.framePlan(level: target, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: s.scrollY), overscan: 0, columnPhase: nil)
        #expect(canonical.visibleSlots.first { $0.index == anchor }?.column != s.desiredCol,
                "if the settled frame snapped back to canonical phase, the anchor would move - it must not")
    }

    // MARK: 6 - NoMultiColumnMovementInCommitBridgeTest
    @Test func noMultiColumnMovementInCommitBridge() {
        for target in [0, 2, 3, 5, 6] {
            let s = setup(target: target)
            let move = GridZoomCommitBridge.maxMatchedIndexMoveX(transaction: s.tx, engine: s.e, targetLevel: target,
                                                                 viewportSize: viewport, scrollY: s.scrollY, overscan: s.pitch * 2, columnPhase: s.phase)
            #expect(move < s.pitch, "a matched index would move ≥1 column in the bridge at target \(target): \(move)px (pitch \(s.pitch))")
            // And every matched index in the actual bridge frame moves the SAME sub-cell amount (uniform shift).
            let at0 = GridZoomCommitBridge.frame(transaction: s.tx, engine: s.e, targetLevel: target, viewportSize: viewport, scrollY: s.scrollY, overscan: 0, progress: 0, columnPhase: s.phase)
            let at1 = GridZoomCommitBridge.frame(transaction: s.tx, engine: s.e, targetLevel: target, viewportSize: viewport, scrollY: s.scrollY, overscan: 0, progress: 1, columnPhase: s.phase)
            let m1 = Dictionary(uniqueKeysWithValues: at1.map { ($0.index, $0.rect.minX) })
            for slot in at0 where m1[slot.index] != nil {
                #expect(abs(m1[slot.index]! - slot.rect.minX) < s.pitch, "matched index \(slot.index) moved ≥1 column at target \(target)")
            }
        }
    }

    // MARK: 7 - BridgeOnlyHandlesResidualSubCellDeltaTest
    @Test func bridgeOnlyHandlesResidualSubCellDelta() {
        for target in [0, 2, 3, 5, 6] {
            let s = setup(target: target)
            // The bridge tolerance is strictly sub-cell.
            #expect(GridZoomCommitBridge.tolerance(targetPitch: s.pitch) < s.pitch,
                    "bridge tolerance must be sub-cell at target \(target)")
            // The actual residual the bridge would smooth is sub-cell (never a phase-sized move).
            let residual = GridZoomCommitBridge.maxMatchedIndexMoveX(transaction: s.tx, engine: s.e, targetLevel: target,
                                                                     viewportSize: viewport, scrollY: s.scrollY, overscan: 0, columnPhase: s.phase)
            #expect(residual < s.pitch, "residual not sub-cell at target \(target): \(residual)px")
        }
    }
}
