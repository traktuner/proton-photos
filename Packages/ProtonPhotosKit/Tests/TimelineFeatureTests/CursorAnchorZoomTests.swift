import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// Pins the Apple anchor rule for detent zoom: a discrete level change is directed toward the item UNDER THE
/// CURSOR (the cursor item stays under the cursor), NOT the top-visible item. The engine owns the capture +
/// rebase; gap cursors resolve the nearest item in the focus row. (Focus-row neighbourhood STABILITY during a
/// live drag is the separate GridZoomTransaction step - see docs/grid-zoom-transaction.md - not tested here.)
@Suite struct CursorAnchorZoomTests {
    private let width: CGFloat = 1400
    private let eps: CGFloat = 1.0
    private func engine() -> SquareTileGridEngine { SquareTileGridEngine.testRegular(sectionCounts: [3000]) }

    // .../Tests/TimelineFeatureTests/<this>.swift → up 3 → ProtonPhotosKit
    private func source(_ name: String) -> String {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent(); url.deleteLastPathComponent(); url.deleteLastPathComponent()
        return (try? String(contentsOf: url.appendingPathComponent("Sources/TimelineFeature/\(name)"), encoding: .utf8)) ?? ""
    }

    /// Viewport-Y of the cursor item after a cursor-anchored change to `toLevel`.
    private func cursorItemViewportY(_ e: SquareTileGridEngine, fromLevel: Int, scrollY: CGFloat,
                                     cursorViewportY: CGFloat, toLevel: Int) -> CGFloat? {
        let cursorContent = CGPoint(x: width / 2, y: scrollY + cursorViewportY)
        guard let a = e.anchorItem(nearContentPoint: cursorContent, level: fromLevel, width: width),
              let ny = e.cursorAnchoredScrollOffsetY(levelChangeFrom: fromLevel, to: toLevel, width: width,
                                                     cursorContentPoint: cursorContent, sourceScrollOriginY: scrollY),
              let frame = e.slotRect(flatIndex: a.flatIndex, level: toLevel, width: width) else { return nil }
        return frame.minY + a.localFraction.y * frame.height - ny
    }

    // CursorAnchorItemRemainsUnderCursorAfterDiscreteZoomTest - the cursor item stays at the cursor's viewport
    // Y after a discrete zoom (in and out).
    @Test func cursorAnchorItemRemainsUnderCursorAfterDiscreteZoom() {
        let e = engine()
        let scrollY: CGFloat = 6000, cursorY: CGFloat = 600   // NOT the top of the viewport
        for toLevel in [0, 1, 3, 4, 5] {
            guard let y = cursorItemViewportY(e, fromLevel: 2, scrollY: scrollY, cursorViewportY: cursorY, toLevel: toLevel) else {
                Issue.record("no anchor for level \(toLevel)"); continue
            }
            #expect(abs(y - cursorY) < eps, "cursor item drifted on 2→\(toLevel): \(y) vs \(cursorY)")
        }
    }

    // PinchZoomUsesCursorAnchorNotViewportTopTest - the cursor item (mid-viewport) is held; the top item is
    // NOT held (its viewport position changes), proving the anchor is the cursor, not the top.
    @Test func pinchZoomUsesCursorAnchorNotViewportTop() {
        let e = engine()
        let scrollY: CGFloat = 6000, cursorY: CGFloat = 600
        // The cursor item stays at 600…
        let cursorY2 = cursorItemViewportY(e, fromLevel: 2, scrollY: scrollY, cursorViewportY: cursorY, toLevel: 4)!
        #expect(abs(cursorY2 - cursorY) < eps)
        // …while the TOP item (originally at viewport Y≈0) does NOT stay at the top under the cursor anchor.
        let topContent = CGPoint(x: width / 2, y: scrollY + 2)
        let topA = e.anchorItem(nearContentPoint: topContent, level: 2, width: width)!
        let ny = e.cursorAnchoredScrollOffsetY(levelChangeFrom: 2, to: 4, width: width,
                                               cursorContentPoint: CGPoint(x: width / 2, y: scrollY + cursorY), sourceScrollOriginY: scrollY)!
        let topFrame4 = e.slotRect(flatIndex: topA.flatIndex, level: 4, width: width)!
        let topY4 = topFrame4.minY + topA.localFraction.y * topFrame4.height - ny
        #expect(abs(topY4 - 2) > 30, "top item was held at the top - must not be (cursor anchor expected)")
    }

    // TopViewportAnchorIsNotUsedForTrackpadPinchTest - anchoring at the cursor produces a DIFFERENT scroll
    // offset than anchoring at the top would, and the host's pinch path passes the cursor (not top).
    @Test func topViewportAnchorIsNotUsedForTrackpadPinch() {
        let e = engine()
        let scrollY: CGFloat = 6000
        let cursorOffset = e.cursorAnchoredScrollOffsetY(levelChangeFrom: 2, to: 4, width: width,
                                                         cursorContentPoint: CGPoint(x: width / 2, y: scrollY + 600), sourceScrollOriginY: scrollY)!
        let topOffset = e.cursorAnchoredScrollOffsetY(levelChangeFrom: 2, to: 4, width: width,
                                                      cursorContentPoint: CGPoint(x: width / 2, y: scrollY + 2), sourceScrollOriginY: scrollY)!
        #expect(abs(cursorOffset - topOffset) > 30, "cursor anchor must differ from a top anchor")
        // The host's pinch passes the cursor point, setLevel rebases via the engine (not the top item).
        let host = source("MetalGridScrollHost.swift")
        #expect(host.contains("cursorContentPoint(for: event)"), "pinch must anchor on the cursor")
        #expect(host.contains("settleScrollOffsetY"), "setLevel must rebase on the explicit anchor")
        #expect(!host.contains("anchorAtViewportTop"), "live zoom / +- must not use the top-viewport anchor")
    }

    // SetLevelCanAnchorToExplicitItemTest - the engine can put an arbitrary explicit item under an arbitrary
    // viewport point (the capability setLevel relies on).
    @Test func setLevelCanAnchorToExplicitItem() {
        let e = engine()
        for flat in [120, 777, 1500] {
            let vp = CGPoint(x: 0, y: 500)
            let off = e.anchoredScrollOffset(flatIndex: flat, localFraction: CGPoint(x: 0.5, y: 0.5), viewportPoint: vp, level: 3, width: width)
            let frame = e.slotRect(flatIndex: flat, level: 3, width: width)!
            let landedY = frame.midY - off.y
            #expect(abs(landedY - vp.y) < eps, "explicit item not placed under the viewport point")
        }
    }

    // GapCursorResolvesNearestFocusRowItemTest - a cursor over an inter-cell gap resolves to an adjacent item
    // in the SAME row (the focus band), not nil.
    @Test func gapCursorResolvesNearestFocusRowItem() {
        let e = engine()
        let level = 2
        let plan = e.framePlan(level: level, viewportSize: CGSize(width: width, height: 900),
                               scrollOffset: CGPoint(x: 0, y: 3000), overscan: 0)
        // Two horizontally-adjacent slots in one full row.
        let row = Dictionary(grouping: plan.visibleSlots, by: { $0.row }).first { $0.value.count >= 2 }!.value
            .sorted { $0.column < $1.column }
        let a = row[0], b = row[1]
        let gapPoint = CGPoint(x: (a.slotRect.maxX + b.slotRect.minX) / 2, y: a.slotRect.midY)
        #expect(e.hitTest(contentPoint: gapPoint, level: level, width: width) == nil)   // truly a gap
        guard let resolved = e.anchorItem(nearContentPoint: gapPoint, level: level, width: width) else {
            Issue.record("gap did not resolve to an item"); return
        }
        #expect(resolved.flatIndex == a.index || resolved.flatIndex == b.index, "must resolve to an adjacent cell")
        #expect(abs(resolved.slotRect.midY - gapPoint.y) < e.resolvedMetrics(level: level, width: width).pitch, "resolved item must be in the focus row")
    }
}
