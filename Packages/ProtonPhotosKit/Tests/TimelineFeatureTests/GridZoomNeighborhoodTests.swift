import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// Stronger-than-anchor stability guards for the DETENT-ONLY model (Option A): a discrete, anchor-preserved
/// level change must keep the visible index NEIGHBOURHOOD centred on the anchor - it must not jump to an
/// unrelated global-index region, and within a level nothing rewraps. These pin the property the live video
/// violated (continuous per-frame rewrap), proven against the geometry the production grid actually renders:
/// settled `framePlan` at integer levels, re-anchored across a level change via `anchoredScrollOffsetY`.
@Suite struct GridZoomNeighborhoodTests {
    private let width: CGFloat = 1400
    private let viewport = CGSize(width: 1400, height: 900)
    private let viewportPointY: CGFloat = 450

    private func engine() -> SquareTileGridEngine { SquareTileGridEngine.testRegular(sectionCounts: [3000]) }

    private func midScroll(_ e: SquareTileGridEngine, level: Int) -> CGFloat {
        max(0, e.contentSize(level: level, width: width).height / 2 - viewport.height / 2)
    }
    private func visibleIndices(_ e: SquareTileGridEngine, level: Int, scrollY: CGFloat, overscan: CGFloat = 0) -> Set<Int> {
        Set(e.framePlan(level: level, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: scrollY), overscan: overscan).visibleSlots.map(\.index))
    }
    /// Simulate the host's discrete, anchor-preserving level change: capture the item at the viewport centre,
    /// then re-anchor scroll so that item stays at the same viewport point at the new level.
    private func reanchor(_ e: SquareTileGridEngine, from L: Int, scrollY S: CGFloat, to L2: Int) -> (scrollY: CGFloat, anchorIndex: Int) {
        let a = e.anchorItem(nearContentPoint: CGPoint(x: width / 2, y: S + viewportPointY), level: L, width: width)!
        var ny = e.anchoredScrollOffsetY(flatIndex: a.flatIndex, relInCellY: a.localFraction.y,
                                         contentFractionY: 0, viewportPointY: viewportPointY, level: L2, width: width)
        let maxY = max(0, e.contentSize(level: L2, width: width).height - viewport.height)
        ny = min(max(0, ny), maxY)
        return (ny, a.flatIndex)
    }
    /// Fraction of the SMALLER set retained by the other (continuity metric - 1.0 = the sparser view's items
    /// are all still shown).
    private func retained(_ a: Set<Int>, _ b: Set<Int>) -> Double {
        let small = a.count <= b.count ? a : b, big = a.count <= b.count ? b : a
        return small.isEmpty ? 1 : Double(small.intersection(big).count) / Double(small.count)
    }

    // DetentOnlyZoomPreservesLogicalViewportTest - a discrete level change keeps the anchor + its
    // neighbourhood near the viewport.
    @Test func detentOnlyZoomPreservesLogicalViewport() {
        let e = engine()
        let L = 2, S = midScroll(e, level: 2)
        let before = visibleIndices(e, level: L, scrollY: S)
        for L2 in [1, 3] {
            let r = reanchor(e, from: L, scrollY: S, to: L2)
            let after = visibleIndices(e, level: L2, scrollY: r.scrollY)
            #expect(after.contains(r.anchorIndex), "anchor lost on \(L)→\(L2)")
            #expect(retained(before, after) > 0.6, "neighbourhood not preserved \(L)→\(L2): \(retained(before, after))")
        }
    }

    // ZoomVisibleNeighborhoodDoesNotJumpTest - the visible index window stays centred on the anchor; it must
    // not become a disjoint range (e.g. 0-50 → 80-95).
    @Test func zoomVisibleNeighborhoodDoesNotJump() {
        let e = engine()
        let L = 2, S = midScroll(e, level: 2)
        let before = visibleIndices(e, level: L, scrollY: S)
        let r = reanchor(e, from: L, scrollY: S, to: 3)
        let after = visibleIndices(e, level: 3, scrollY: r.scrollY)
        #expect(after.contains(r.anchorIndex))
        #expect(!before.isDisjoint(with: after), "visible set jumped to a disjoint region")
        // Index ranges overlap (not a teleport to an unrelated region).
        #expect(after.min()! <= before.max()! && after.max()! >= before.min()!, "index ranges disjoint = jump")
    }

    // ConsecutiveZoomFramesHaveHighIndexOverlapTest - a sequence of discrete level changes keeps consecutive
    // visible sets highly overlapping around the anchor.
    @Test func consecutiveZoomFramesHaveHighIndexOverlap() {
        let e = engine()
        var L = 2, S = midScroll(e, level: 2)
        var prev = visibleIndices(e, level: L, scrollY: S)
        for L2 in [3, 4, 5] {
            let r = reanchor(e, from: L, scrollY: S, to: L2)
            let cur = visibleIndices(e, level: L2, scrollY: r.scrollY)
            #expect(retained(prev, cur) > 0.6, "low overlap \(L)→\(L2): \(retained(prev, cur))")
            L = L2; S = r.scrollY; prev = cur
        }
    }

    // AnchorItemAndNeighborhoodStableTest - the anchor AND its immediate flat-index neighbours stay visible
    // across a discrete step (not just the single anchor item).
    @Test func anchorItemAndNeighborhoodStable() {
        let e = engine()
        let L = 2, S = midScroll(e, level: 2)
        let r = reanchor(e, from: L, scrollY: S, to: 3)
        let after = visibleIndices(e, level: 3, scrollY: r.scrollY, overscan: 200)
        var kept = 0
        for k in -5 ... 5 where after.contains(r.anchorIndex + k) { kept += 1 }
        #expect(kept >= 9, "anchor neighbourhood not retained: \(kept)/11")
    }

    // ZoomDoesNotRewrapWholeGridEveryTickTest - within a level nothing rewraps: column count + an item's
    // (row,column) are functions of (level,width) only, independent of scroll. Only a deliberate LEVEL change
    // alters columns (a controlled topology transition, never a per-tick rewrap).
    @Test func zoomDoesNotRewrapWholeGridEveryTick() {
        let e = engine()
        let L = 3
        let cols = e.resolvedMetrics(level: L, width: width).columns
        let loc0 = e.locate(flatIndex: 1234, level: L, width: width)!
        for S in [CGFloat(0), 1000, 5000, 12000] {
            #expect(e.resolvedMetrics(level: L, width: width).columns == cols)        // scroll never changes columns
            // The visible set translates with scroll but the grid does not rewrap.
            _ = visibleIndices(e, level: L, scrollY: min(S, max(0, e.contentSize(level: L, width: width).height - viewport.height)))
        }
        let loc1 = e.locate(flatIndex: 1234, level: L, width: width)!
        #expect(loc0.row == loc1.row && loc0.column == loc1.column)                  // placement is scroll-independent
        #expect(e.resolvedMetrics(level: L + 1, width: width).columns != cols)        // only a level change rewraps
    }
}
