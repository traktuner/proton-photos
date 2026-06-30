import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// The live→settled commit seam, MEASURED. The live pinch renders a `GridZoomTransaction` (anchor pinned at the
/// cursor column → focus-row stable); the settled grid is bottom-right anchored. They share metrics at the
/// committed integer level but differ in COLUMN PHASE. These tests quantify and bound that seam: the anchor's
/// vertical position must coincide (the scroll is rebased from the anchor), the anchor item must be preserved,
/// the focus band must stay in the same local neighborhood, and the residual horizontal phase shift must be
/// bounded — so a regression that jumps to an unrelated neighborhood fails here.
@Suite struct GridZoomCommitSeamTests {
    private let viewport = CGSize(width: 1400, height: 900)
    private let width: CGFloat = 1400
    private let count = 5000
    private let anchor = 2137
    private let cursor = CGPoint(x: 690, y: 430)   // mid-viewport cursor (NOT top, NOT centre exactly)

    private func engine() -> SquareTileGridEngine { SquareTileGridEngine(sectionCounts: [count]) }

    /// A transaction captured the way the coordinator does: the anchor is the item under the cursor's CONTENT
    /// point at the source level, pinned at the cursor's viewport point.
    private func transaction(sourceLevel: Int) -> (SquareTileGridEngine, GridZoomTransaction) {
        let e = engine()
        let src = e.slotRect(flatIndex: anchor, level: sourceLevel, width: width)!
        let cursorContent = CGPoint(x: src.midX, y: src.midY)
        let tx = e.beginZoomTransaction(cursorContentPoint: cursorContent, viewportPoint: cursor,
                                        level: sourceLevel, width: width)!
        return (e, tx)
    }

    // MARK: 1 — TransactionFinalAnchorMatchesSettledAnchorTest
    // The anchor's VERTICAL position coincides exactly at the committed level (the scroll is rebased from the
    // anchor); the horizontal difference is the bounded column-phase shift (≤ one row), never a wild jump.
    @Test func transactionFinalAnchorMatchesSettledAnchor() {
        let (e, tx) = transaction(sourceLevel: 3)
        for target in 0 ..< e.levelCount {
            let d = e.commitDelta(transaction: tx, targetLevel: target, viewportSize: viewport)
            #expect(abs(d.anchorDelta.height) < 1.0,
                    "anchor vertical not rebased at target \(target): Δy=\(d.anchorDelta.height)")
            let pitch = e.resolvedMetrics(level: target, width: width).pitch
            #expect(abs(d.anchorDelta.width) <= pitch * CGFloat(e.resolvedMetrics(level: target, width: width).columns) + 1,
                    "horizontal phase shift unbounded at target \(target): Δx=\(d.anchorDelta.width)")
            #expect(d.transactionAnchorRect != .zero && d.settledAnchorRect != .zero)
        }
    }

    // MARK: 2 — TransactionToSettledFocusRowOverlapTest
    // The final transaction focus row and the settled focus band overlap highly around the anchor (the anchor
    // itself is always in both); not required to be 100% when the phase differs, but clearly the same locality.
    @Test func transactionToSettledFocusRowOverlap() {
        let (e, tx) = transaction(sourceLevel: 3)
        for target in [1, 2, 3, 4, 5] {
            let d = e.commitDelta(transaction: tx, targetLevel: target, viewportSize: viewport)
            #expect(d.transactionFocusRow.contains(anchor), "anchor missing from transaction focus row")
            #expect(d.settledFocusRow.contains(anchor), "anchor missing from settled focus band")
            #expect(d.focusRowOverlap >= 0.4,
                    "focus row overlap too low at target \(target): \(d.focusRowOverlap) (tx=\(d.transactionFocusRow) settled=\(d.settledFocusRow))")
        }
    }

    // MARK: 3 — CommitScrollOffsetRebasedFromAnchorTest
    // The settled scroll offset is computed from the anchor item + local fraction + target metrics, so the
    // anchor's settled cell lands back under the cursor's viewport Y. It is NOT a reused/stale scroll offset.
    @Test func commitScrollOffsetRebasedFromAnchor() {
        let (e, tx) = transaction(sourceLevel: 3)
        for target in [0, 2, 4, 6] {
            let d = e.commitDelta(transaction: tx, targetLevel: target, viewportSize: viewport)
            // The rebase pins the anchor's vertical centre at the cursor's viewport Y.
            #expect(abs(d.settledAnchorRect.midY - cursor.y) < 1.0,
                    "anchor not rebased under the cursor Y at target \(target): \(d.settledAnchorRect.midY) vs \(cursor.y)")
            // Different anchors ⇒ different rebased scroll offsets (proves it depends on the anchor, not stale).
            let other = e.beginZoomTransaction(cursorContentPoint: CGPoint(x: e.slotRect(flatIndex: 40, level: 3, width: width)!.midX,
                                                                           y: e.slotRect(flatIndex: 40, level: 3, width: width)!.midY),
                                               viewportPoint: cursor, level: 3, width: width)!
            let d2 = e.commitDelta(transaction: other, targetLevel: target, viewportSize: viewport)
            #expect(abs(d.settledScrollOffsetY - d2.settledScrollOffsetY) > 1.0,
                    "scroll offset does not depend on the anchor item at target \(target)")
        }
    }

    // MARK: 4 — NoCommitJumpToUnrelatedNeighborhoodTest
    // The visible index sets of the transaction final frame and the settled plan overlap substantially: the
    // commit stays in the same local neighborhood (same photos ±), never a jump to unrelated indices.
    @Test func noCommitJumpToUnrelatedNeighborhood() {
        let (e, tx) = transaction(sourceLevel: 3)
        for target in [1, 2, 3, 4, 5] {
            let d = e.commitDelta(transaction: tx, targetLevel: target, viewportSize: viewport)
            #expect(d.neighborhoodOverlap >= 0.5,
                    "visible neighborhood overlap too low at target \(target): \(d.neighborhoodOverlap)")
        }
    }

    // MARK: 5 — ReleaseDoesNotDiscardCursorAnchorTest
    // The commit anchor is the item under the CURSOR (captured at gesture start), never a viewport-top / centre
    // fallback. The settled focus band is around the cursor's item, not row 0 of the viewport.
    @Test func releaseDoesNotDiscardCursorAnchor() {
        let (e, tx) = transaction(sourceLevel: 2)
        #expect(tx.anchorGlobalIndex == anchor, "transaction must anchor the cursor's item, got \(tx.anchorGlobalIndex)")
        let d = e.commitDelta(transaction: tx, targetLevel: 4, viewportSize: viewport)
        #expect(d.settledFocusRow.contains(anchor), "settled focus band must contain the cursor anchor")
        // The rebased scroll keeps the anchor on-screen near the cursor, not pinned to the library top.
        #expect(d.settledScrollOffsetY > 1.0, "a mid-library anchor must NOT rebase to the very top (top-anchor fallback)")
        #expect(d.settledAnchorRect.minY >= -1 && d.settledAnchorRect.maxY <= viewport.height + 1,
                "anchor not visible near the cursor after commit")
    }

    // MARK: 6 — CommitDeltaIsMeasuredTest
    // The measurement helper returns finite, sane values across the whole ladder and logs the seam so it is
    // never hidden. Also pins the transaction-lattice rect ↔ live-frame rect consistency (seamless bridge start).
    @Test func commitDeltaIsMeasured() {
        let (e, tx) = transaction(sourceLevel: 3)
        for target in 0 ..< e.levelCount {
            let d = e.commitDelta(transaction: tx, targetLevel: target, viewportSize: viewport)
            #expect(d.anchorDeltaDistance.isFinite)
            #expect(!d.transactionFocusRow.isEmpty && !d.settledFocusRow.isEmpty)
            #expect(d.focusRowOverlap >= 0 && d.focusRowOverlap <= 1)
            #expect(d.neighborhoodOverlap >= 0 && d.neighborhoodOverlap <= 1)
            let pitch = e.resolvedMetrics(level: target, width: width).pitch
            // Phased (cursor-aligned) delta — the post-fix value.
            let desiredCol = e.cursorColumn(viewportX: tx.anchorViewportPoint.x, level: target, width: width)
            let phase = e.columnPhase(forItem: anchor, targetColumn: desiredCol, level: target, width: width)
            let phased = e.commitDelta(transaction: tx, targetLevel: target, viewportSize: viewport, columnPhase: phase)
            print("[GridZoomCommitTest] target=\(target) CANONICALΔx=\(Int(d.anchorDelta.width)) (col \(d.anchorColumnShift(pitch: pitch))) "
                  + "PHASEDΔx=\(Int(phased.anchorDelta.width)) (col \(phased.anchorColumnShift(pitch: pitch))) "
                  + "phasedFocusOverlap=\(String(format: "%.2f", phased.focusRowOverlap))")
        }
        // The live frame's anchor rect must equal the lattice rect at the same level (so the bridge starts seamlessly).
        let frame = tx.frame(continuousLevel: 3, viewportSize: viewport, overscan: 0)
        let frameAnchor = frame.visibleSlots.first { $0.index == anchor }!.rect
        let latticeAnchor = tx.rect(forGlobalIndex: anchor, continuousLevel: 3, viewportSize: viewport)!
        #expect(abs(frameAnchor.minX - latticeAnchor.minX) < 0.01 && abs(frameAnchor.minY - latticeAnchor.minY) < 0.01)
    }
}
