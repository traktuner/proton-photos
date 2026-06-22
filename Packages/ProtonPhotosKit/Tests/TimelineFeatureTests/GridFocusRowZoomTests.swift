import Testing
import Foundation
import CoreGraphics
@testable import TimelineFeature

/// Focus-row stability for the engine-owned `GridZoomTransaction`, using REAL global indices (the lab's
/// numeric labels wrap mod 96 — never assert on those). The row under the cursor must stay the same
/// contiguous neighbourhood as zoom metrics change: zoom-in drops edge neighbours, zoom-out adds them; the
/// row never re-wraps into unrelated indices. Plus the new largest level + monotonic ladder.
@Suite struct GridFocusRowZoomTests {
    private let viewport = CGSize(width: 1400, height: 900)
    private let cursor = CGPoint(x: 700, y: 450)   // mid-viewport cursor
    private let anchor = 1000                        // a real global index, mid-library

    private func tx(anchorGlobalIndex: Int = 1000, total: Int = 3000) -> GridZoomTransaction {
        GridZoomTransaction(totalItems: total, anchorGlobalIndex: anchorGlobalIndex,
                            anchorViewportPoint: cursor, anchorLocalFraction: CGPoint(x: 0.5, y: 0.5),
                            levels: SquareTileGridEngine.defaultLevels, sourceLevel: 3)
    }
    private func focusRow(_ t: GridZoomTransaction, _ level: CGFloat) -> [Int] {
        t.frame(continuousLevel: level, viewportSize: viewport, overscan: 0).focusRow
    }
    private func isContiguous(_ a: [Int]) -> Bool { !a.isEmpty && a.max()! - a.min()! == a.count - 1 }

    // FocusRowIdentitiesStableOnZoomInTest — zooming in keeps a contiguous subset of the SAME neighbourhood
    // around the anchor; it must not show unrelated indices.
    @Test func focusRowIdentitiesStableOnZoomIn() {
        let t = tx()
        let source = focusRow(t, 3)
        #expect(isContiguous(source) && source.contains(anchor))
        let maxDist = max(anchor - source.min()!, source.max()! - anchor)
        for zoomedIn in [CGFloat(2), 1, 0] {
            let fr = focusRow(t, zoomedIn)
            #expect(isContiguous(fr), "focus row split at level \(zoomedIn): \(fr)")
            #expect(fr.contains(anchor), "anchor left the focus row at \(zoomedIn)")
            #expect(fr.count <= source.count, "zoom-in should not widen the focus row")
            #expect(fr.allSatisfy { abs($0 - anchor) <= maxDist }, "zoom-in showed UNRELATED indices: \(fr)")
        }
    }

    // FocusRowExpandsOnZoomOutTest — zooming out keeps the source neighbourhood and ADDS neighbours left/right.
    @Test func focusRowExpandsOnZoomOut() {
        let t = tx()
        let source = Set(focusRow(t, 3))
        for zoomedOut in [CGFloat(4), 5, 6] {
            let fr = focusRow(t, zoomedOut)
            #expect(isContiguous(fr) && fr.contains(anchor))
            #expect(source.isSubset(of: Set(fr)), "zoom-out dropped source focus items at \(zoomedOut)")
            #expect(fr.count >= source.count, "zoom-out should widen the focus row")
        }
    }

    // FocusRowDoesNotSplitAcrossRowsTest — the focus row is one contiguous run; no focus-row item appears in
    // another y-band, and the row-0 slots equal the focus row exactly.
    @Test func focusRowDoesNotSplitAcrossRows() {
        let t = tx()
        for level in stride(from: CGFloat(0), through: 6, by: 0.5) {
            let frame = t.frame(continuousLevel: level, viewportSize: viewport, overscan: 0)
            #expect(isContiguous(frame.focusRow), "focus row not contiguous at \(level): \(frame.focusRow)")
            let row0 = frame.visibleSlots.filter { $0.row == 0 }.map(\.index).sorted()
            #expect(row0 == frame.focusRow, "row-0 slots disagree with focusRow at \(level)")
        }
    }

    // CursorAnchorItemRemainsInFocusRowTest — across the whole ladder the anchor stays in the focus row AND
    // its slot stays under the cursor.
    @Test func cursorAnchorItemRemainsInFocusRow() {
        let t = tx()
        for level in stride(from: CGFloat(0), through: 6, by: 0.25) {
            let frame = t.frame(continuousLevel: level, viewportSize: viewport, overscan: 0)
            #expect(frame.focusRow.contains(anchor), "anchor missing from focus row at \(level)")
            guard let slot = frame.visibleSlots.first(where: { $0.index == anchor }) else {
                Issue.record("anchor slot missing at \(level)"); continue
            }
            #expect(abs(slot.rect.midX - cursor.x) < 1 && abs(slot.rect.midY - cursor.y) < 1,
                    "anchor not under the cursor at \(level)")
        }
    }

    // ZoomDirectionUsesCursorItemTest — the transaction anchors on the item UNDER THE CURSOR (engine resolves
    // it), and the host captures it from the cursor (not viewport top).
    @Test func zoomDirectionUsesCursorItem() {
        let e = SquareTileGridEngine(sectionCounts: [3000])
        let width: CGFloat = 1400
        // A content point on a known item at level 3.
        let plan = e.framePlan(level: 3, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 6000), overscan: 0)
        let target = plan.visibleSlots[plan.visibleSlots.count / 2]
        let contentPoint = CGPoint(x: target.slotRect.midX, y: target.slotRect.midY)
        let t = e.beginZoomTransaction(cursorContentPoint: contentPoint, viewportPoint: cursor, level: 3, width: width)!
        #expect(t.anchorGlobalIndex == target.index, "transaction must anchor on the cursor item")
        // Host wiring: pinch passes the cursor item, not the top-visible item.
        let host = hostSource()
        #expect(host.contains("beginZoomTransaction") || host.contains("cursorContentPoint(for: event)"))
        #expect(!host.contains("anchorAtViewportTop()"), "live zoom must not use the top-viewport anchor")
    }

    // GapCursorResolvesNearestFocusRowItemTest — a cursor over a gap still yields a valid adjacent anchor.
    @Test func gapCursorResolvesNearestFocusRowItem() {
        let e = SquareTileGridEngine(sectionCounts: [3000])
        let width: CGFloat = 1400
        let plan = e.framePlan(level: 3, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 6000), overscan: 0)
        let row = Dictionary(grouping: plan.visibleSlots, by: { $0.row }).first { $0.value.count >= 2 }!.value
            .sorted { $0.column < $1.column }
        let gapPoint = CGPoint(x: (row[0].slotRect.maxX + row[1].slotRect.minX) / 2, y: row[0].slotRect.midY)
        let t = e.beginZoomTransaction(cursorContentPoint: gapPoint, viewportPoint: cursor, level: 3, width: width)
        #expect(t != nil)
        #expect(t!.anchorGlobalIndex == row[0].index || t!.anchorGlobalIndex == row[1].index)
    }

    // FocusRowNeighborhoodOverlapTest — over a fine continuous sweep, consecutive focus rows overlap highly
    // and always contain the anchor (no per-frame jump).
    @Test func focusRowNeighborhoodOverlap() {
        let t = tx()
        var prev: Set<Int>? = nil
        for step in 0 ... 24 {
            let level = CGFloat(step) * 0.25                  // 0 → 6
            let fr = Set(focusRow(t, level))
            #expect(fr.contains(anchor))
            if let prev, !prev.isEmpty {
                let small = min(fr.count, prev.count)
                let overlap = fr.intersection(prev).count
                #expect(Double(overlap) / Double(small) > 0.6, "focus row jumped at \(level)")
            }
            prev = fr
        }
    }

    // NoStatelessContinuousRewrapInProductionTest — production live zoom uses the transaction, not a
    // per-frame stateless `engine.zoomFramePlan(continuousLevel:)`.
    @Test func noStatelessContinuousRewrapInProduction() {
        let coord = coordinatorSource()
        #expect(coord.contains("GridZoomTransaction"), "live zoom must use the transaction")
        #expect(!coord.contains("engine.zoomFramePlan("), "production must not re-resolve a stateless plan per frame")
    }

    // LargerZoomLevelExistsTest — a new largest level was added at the front, bigger than the old largest.
    @Test func largerZoomLevelExists() {
        let levels = SquareTileGridEngine.defaultLevels
        #expect(levels.count == 7, "expected the added largest level (7 total)")
        #expect(levels[0].slotSide >= 360, "new largest level should be ≥360pt: \(levels[0].slotSide)")
        #expect(levels[0].slotSide > 260, "new largest must exceed the previous largest (260)")
    }

    // (The "seamless commit via column phase" test was removed: the engine has no column-phase concept —
    // the settled grid is always bottom-right anchored, and the release jump is handled by the host's scroll
    // lock, not a phase. See ZoomAnchorPreservationTests / CursorAnchorZoomTests for commit anchoring.)

    // LevelMetricsMonotonicTest — zooming out: slotSide strictly decreases, pitch strictly decreases, gap
    // does not increase.
    @Test func levelMetricsMonotonic() {
        let levels = SquareTileGridEngine.defaultLevels
        for i in 1 ..< levels.count {
            #expect(levels[i].slotSide < levels[i - 1].slotSide, "slotSide not decreasing at \(i)")
            #expect(levels[i].pitch < levels[i - 1].pitch, "pitch not decreasing at \(i)")
            #expect(levels[i].gap <= levels[i - 1].gap, "gap increased at \(i)")
        }
    }

    // TransactionIsSingleSectionOnlyTest — the live transaction's flat single-run model is valid only for one
    // section; `beginZoomTransaction` returns nil for a multi-section engine (production keeps live continuous
    // zoom OFF there and zooms via the section-aware +/- path), and nil for an empty library.
    @Test func transactionIsSingleSectionOnly() {
        let width: CGFloat = 1400
        let cursor = CGPoint(x: 700, y: 5000)
        let vp = CGPoint(x: 700, y: 450)
        let single = SquareTileGridEngine(sectionCounts: [3000])
        #expect(single.beginZoomTransaction(cursorContentPoint: cursor, viewportPoint: vp, level: 3, width: width) != nil,
                "single-section engine must capture a live transaction")
        let multi = SquareTileGridEngine(sectionCounts: [500, 700, 1800])
        #expect(multi.beginZoomTransaction(cursorContentPoint: cursor, viewportPoint: vp, level: 3, width: width) == nil,
                "multi-section engine must NOT capture a live transaction (live zoom off in production)")
        let empty = SquareTileGridEngine(sectionCounts: [])
        #expect(empty.beginZoomTransaction(cursorContentPoint: cursor, viewportPoint: vp, level: 3, width: width) == nil,
                "empty library must capture no transaction")
    }

    // MARK: source scan
    private func sourcesDir() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent(); url.deleteLastPathComponent(); url.deleteLastPathComponent()
        return url.appendingPathComponent("Sources/TimelineFeature")
    }
    private func hostSource() -> String { (try? String(contentsOf: sourcesDir().appendingPathComponent("MetalGridScrollHost.swift"), encoding: .utf8)) ?? "" }
    private func coordinatorSource() -> String { (try? String(contentsOf: sourcesDir().appendingPathComponent("MetalGridCoordinator.swift"), encoding: .utf8)) ?? "" }
}
