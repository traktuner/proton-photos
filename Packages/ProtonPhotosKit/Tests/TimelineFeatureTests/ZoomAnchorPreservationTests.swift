import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// Pins the zoom anchor model the engine must honour: the anchor identity is the ITEM (section / global
/// index) + a local fraction within its slot, NOT a raw scroll offset. Across changing slotSide / gap /
/// column-count / row / section-offset, the engine rebases the scroll offset from the anchor item so the
/// same logical point stays under the same viewport point — the grid never jumps to a different timeline
/// position. These guard the live-pinch fix.
@Suite struct ZoomAnchorPreservationTests {
    private let width: CGFloat = 1400
    private let viewport = CGSize(width: 1400, height: 900)
    private let viewportPoint = CGPoint(x: 700, y: 450)   // where the finger holds the anchor

    private func singleSection() -> SquareTileGridEngine { SquareTileGridEngine(sectionCounts: [3000]) }
    private func manySections() -> SquareTileGridEngine {
        SquareTileGridEngine(sectionCounts: [37, 80, 12, 220, 95, 160, 44, 300, 9, 188])
    }

    /// Capture a logical anchor at `level`/`scrollY` from a viewport point, exactly like the coordinator.
    private func capture(_ e: SquareTileGridEngine, level: Int, scrollY: CGFloat)
        -> (anchor: GridZoomAnchor, flatIndex: Int, localFraction: CGPoint)? {
        let contentPoint = CGPoint(x: viewportPoint.x, y: scrollY + viewportPoint.y)
        guard let a = e.anchorItem(nearContentPoint: contentPoint, level: level, width: width) else { return nil }
        let frac = contentPoint.y / e.contentSize(level: level, width: width).height
        let anchor = GridZoomAnchor(flatIndex: a.flatIndex, viewportPoint: viewportPoint,
                                    contentFractionY: frac, relInCell: a.localFraction)
        return (anchor, a.flatIndex, a.localFraction)
    }

    // ZoomPreservesAnchorItemTest — the same anchor item stays under the same viewport point across apparent
    // metrics (source level → target/apparent levels).
    @Test func zoomPreservesAnchorItem() {
        let e = singleSection()
        guard let cap = capture(e, level: 2, scrollY: 9000) else { Issue.record("no anchor"); return }
        for x in [CGFloat(2.0), 2.4, 3.0, 3.6, 4.2, 5.0] {
            let plan = e.zoomFramePlan(continuousLevel: x, viewportSize: viewport, anchor: cap.anchor, overscan: 400)
            guard let slot = plan.visibleSlots.first(where: { $0.index == cap.flatIndex }) else {
                Issue.record("anchor item not visible at \(x)"); continue
            }
            let landedY = slot.viewportRect.minY + cap.localFraction.y * slot.viewportRect.height
            #expect(abs(landedY - viewportPoint.y) < 1.0, "anchor drifted at apparent level \(x): \(landedY)")
        }
    }

    // ZoomDoesNotJumpToDifferentTimelinePositionTest — changing slotSide/gap/columns must keep the anchor
    // item on-screen and the visible window centred on it (no jump to unrelated global indices).
    @Test func zoomDoesNotJumpToDifferentTimelinePosition() {
        let e = singleSection()
        guard let cap = capture(e, level: 2, scrollY: 9000) else { Issue.record("no anchor"); return }
        for x in [CGFloat(2.0), 2.5, 3.0, 4.0, 5.0] {
            let plan = e.zoomFramePlan(continuousLevel: x, viewportSize: viewport, anchor: cap.anchor, overscan: 0)
            guard let slot = plan.visibleSlots.first(where: { $0.index == cap.flatIndex }) else {
                Issue.record("anchor jumped off-screen at \(x)"); continue
            }
            // The anchor stays on-screen (its square is within the viewport), not jumped to an extreme.
            #expect(slot.viewportRect.midY > 0 && slot.viewportRect.midY < viewport.height)
            // The visible window is the anchor's timeline neighbourhood: plenty of items with nearby global
            // indices are present (a jump would surface a disjoint index range).
            let near = plan.visibleSlots.filter { abs($0.index - cap.flatIndex) <= 80 }.count
            #expect(near >= 10, "visible window is not centred on the anchor at \(x)")
        }
    }

    // SectionAwareAnchorPreservationTest — with multiple sections, the anchor item (in a LATER section,
    // whose top offset + row count both shift when columns change) stays under the viewport point.
    @Test func sectionAwareAnchorPreservation() {
        let e = manySections()
        // Anchor deep in the library so several sections (with changing heights) sit above it.
        let scrollY = e.contentSize(level: 2, width: width).height * 0.7
        guard let cap = capture(e, level: 2, scrollY: scrollY) else { Issue.record("no anchor"); return }
        let loc2 = e.locate(flatIndex: cap.flatIndex, level: 2, width: width)!
        #expect(loc2.section > 0, "anchor should be past the first section")
        // The section's top offset genuinely changes between metrics (proves section-awareness matters).
        let top2 = e.sectionTop(section: loc2.section, level: 2, width: width)!
        let top4 = e.sectionTop(section: loc2.section, level: 4, width: width)!
        #expect(abs(top2 - top4) > 1.0, "section top offset must change with metrics")
        for x in [CGFloat(2.0), 2.6, 3.3, 4.0, 4.8] {
            let plan = e.zoomFramePlan(continuousLevel: x, viewportSize: viewport, anchor: cap.anchor, overscan: 400)
            guard let slot = plan.visibleSlots.first(where: { $0.index == cap.flatIndex }) else {
                Issue.record("section anchor not visible at \(x)"); continue
            }
            let landedY = slot.viewportRect.minY + cap.localFraction.y * slot.viewportRect.height
            #expect(abs(landedY - viewportPoint.y) < 1.0, "section-aware anchor drifted at \(x): \(landedY)")
        }
    }

    // ScrollOffsetRebasedWhenMetricsChangeTest — the offset is RECOMPUTED from the anchor item + apparent
    // metrics; the raw start offset is not reused (and reusing it would put the anchor elsewhere).
    @Test func scrollOffsetRebasedWhenMetricsChange() {
        let e = singleSection()
        let startScrollY: CGFloat = 9000
        guard let cap = capture(e, level: 2, scrollY: startScrollY) else { Issue.record("no anchor"); return }
        let rebased = e.anchoredScrollOffset(flatIndex: cap.flatIndex, localFraction: cap.localFraction,
                                             viewportPoint: viewportPoint, level: 4, width: width)
        #expect(abs(rebased.y - startScrollY) > 1.0, "offset must be rebased, not the raw start scrollOffset")
        // With the rebased offset the anchor sits at the viewport point; with the raw offset it does not.
        let frame4 = e.slotRect(flatIndex: cap.flatIndex, level: 4, width: width)!
        let anchorContentY = frame4.minY + cap.localFraction.y * frame4.height
        #expect(abs((anchorContentY - rebased.y) - viewportPoint.y) < 1.0)        // rebased → correct
        #expect(abs((anchorContentY - startScrollY) - viewportPoint.y) > 50.0)    // raw reuse → wrong (jump)
    }

    // VisibleSlotsStableAroundAnchorDuringPinchTest — over a fine continuous sweep, the anchor stays visible
    // and the view stays in its timeline neighbourhood every frame (no mid-pinch jump).
    @Test func visibleSlotsStableAroundAnchorDuringPinch() {
        let e = singleSection()
        guard let cap = capture(e, level: 2, scrollY: 9000) else { Issue.record("no anchor"); return }
        var prevNear: Set<Int>? = nil
        for step in 0 ... 20 {
            let x = 2.0 + CGFloat(step) * 0.1   // 2.0 → 4.0 in fine steps
            let plan = e.zoomFramePlan(continuousLevel: x, viewportSize: viewport, anchor: cap.anchor, overscan: 100)
            let visible = Set(plan.visibleSlots.map(\.index))
            #expect(visible.contains(cap.flatIndex), "anchor lost at apparent level \(x)")
            // The anchor's index-neighbourhood remains present and overlaps the previous frame (local
            // coherence — the view doesn't teleport between frames).
            let near = visible.filter { abs($0 - cap.flatIndex) <= 60 }
            #expect(near.count >= 8, "anchor neighbourhood thinned out at \(x)")
            if let prevNear, !prevNear.isEmpty {
                let overlap = near.intersection(prevNear).count
                #expect(overlap >= 4, "visible neighbourhood jumped between frames at \(x)")
            }
            prevNear = near
        }
    }
}
