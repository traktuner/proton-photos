import Testing
import Foundation
import CoreGraphics
@testable import TimelineFeature

// Viewport-resize CAMERA rebase. RESIZE IS NOT ZOOM. Vertical resize preserves the content at a NORMALIZED
// viewport anchor (anchorFractionY = 0.5 = centre) — a continuous camera rebase, NOT a rigid one-edge pin.
// Width keys nominalColumns (resolution-independent). Frames are y-UP screen space (maxY=top, minY=bottom).
@Suite struct GridViewportResizeTests {
    private let eps: CGFloat = 0.5
    private let f: CGFloat = 0.5
    private func engine(_ count: Int = 6000) -> SquareTileGridEngine { SquareTileGridEngine(sectionCounts: [count]) }

    private func rebase(_ e: SquareTileGridEngine, oldFrame: CGRect, newFrame: CGRect, scrollY: CGFloat,
                        level: Int, phase: Int?, bottomPinned: Bool = false, anchorFractionY: CGFloat = 0.5) -> GridViewportResizeResult {
        e.rebasedScrollOffsetForViewportChange(GridViewportResizeInput(
            oldViewportFrame: oldFrame, newViewportFrame: newFrame, oldScrollY: scrollY, level: level,
            committedPhase: phase, itemCount: 6000, wasBottomPinned: bottomPinned,
            anchorFractionY: anchorFractionY))
    }
    /// The item at a normalized viewport fraction (default centre).
    private func anchorAt(_ e: SquareTileGridEngine, width: CGFloat, scrollY: CGFloat, vh: CGFloat, fraction: CGFloat = 0.5, level: Int, phase: Int?) -> Int? {
        e.anchorItem(nearContentPoint: CGPoint(x: width / 2, y: scrollY + vh * fraction), level: level, width: width, columnPhase: phase)?.flatIndex
    }
    private func visibleSet(_ e: SquareTileGridEngine, width: CGFloat, vh: CGFloat, scrollY: CGFloat, level: Int, phase: Int?) -> Set<Int> {
        Set(e.framePlan(level: level, viewportSize: CGSize(width: width, height: vh),
                        scrollOffset: CGPoint(x: 0, y: scrollY), overscan: 0, columnPhase: phase).visibleSlots.map(\.index))
    }
    private func repoRoot() -> URL { var u = URL(fileURLWithPath: #filePath); for _ in 0 ..< 5 { u.deleteLastPathComponent() }; return u }
    private func src(_ name: String) -> String {
        (try? String(contentsOf: repoRoot().appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature/\(name)"), encoding: .utf8)) ?? ""
    }

    // 1 — vertical resize uses the NORMALIZED viewport anchor: rebased (not raw), and strictly between the
    // strict-top (f=0) and strict-bottom (f=1) results — i.e. neither edge is rigidly pinned.
    @Test func verticalResizeUsesNormalizedViewportAnchor() {
        let e = engine()
        let old = CGRect(x: 0, y: 0, width: 1000, height: 1000), new = CGRect(x: 0, y: 200, width: 1000, height: 800)
        for level in [0, 2, 3] {
            for scrollY in [CGFloat(3000), 6000] {
                let centerBefore = anchorAt(e, width: 1000, scrollY: scrollY, vh: 1000, level: level, phase: nil)!
                let r = rebase(e, oldFrame: old, newFrame: new, scrollY: scrollY, level: level, phase: nil)
                #expect(anchorAt(e, width: 1000, scrollY: r.newScrollY, vh: 800, level: level, phase: nil) == centerBefore,
                        "centre anchor not preserved (L\(level) y\(scrollY))")
                let strictTop = rebase(e, oldFrame: old, newFrame: new, scrollY: scrollY, level: level, phase: nil, anchorFractionY: 0).newScrollY
                let strictBottom = rebase(e, oldFrame: old, newFrame: new, scrollY: scrollY, level: level, phase: nil, anchorFractionY: 1).newScrollY
                #expect(abs(r.newScrollY - scrollY) > eps, "must rebase, not reuse raw scrollY")
                #expect(r.newScrollY > min(strictTop, strictBottom) + eps && r.newScrollY < max(strictTop, strictBottom) - eps,
                        "normalized anchor must lie BETWEEN strict-top and strict-bottom pins")
            }
        }
    }

    // 2 — bottom edge up: height shrinks, scrollY rebased per centre anchor, lower content clipped, no jump.
    @Test func bottomEdgeShrinkClipsAndRebasesContinuously() {
        let e = engine()
        let old = CGRect(x: 0, y: 0, width: 1000, height: 1000), new = CGRect(x: 0, y: 200, width: 1000, height: 800)
        let centerBefore = anchorAt(e, width: 1000, scrollY: 6000, vh: 1000, level: 2, phase: nil)!
        let r = rebase(e, oldFrame: old, newFrame: new, scrollY: 6000, level: 2, phase: nil)
        #expect(r.anchorGlobalIndex == centerBefore && r.newScrollY > 6000 + eps, "centre held, content shifts up")
        let before = visibleSet(e, width: 1000, vh: 1000, scrollY: 6000, level: 2, phase: nil)
        let after = visibleSet(e, width: 1000, vh: 800, scrollY: r.newScrollY, level: 2, phase: nil)
        #expect(after.count < before.count, "shorter viewport shows fewer rows")
        #expect(after.intersection(before).count >= after.count / 2, "no jump to unrelated indices")
    }

    // 3 — bottom edge down (expand): more content revealed, smooth, no jump.
    @Test func bottomEdgeExpandRevealsAndRebasesContinuously() {
        let e = engine()
        let old = CGRect(x: 0, y: 200, width: 1000, height: 800), new = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let centerBefore = anchorAt(e, width: 1000, scrollY: 6000, vh: 800, level: 2, phase: nil)!
        let r = rebase(e, oldFrame: old, newFrame: new, scrollY: 6000, level: 2, phase: nil)
        #expect(r.anchorGlobalIndex == centerBefore)
        #expect(visibleSet(e, width: 1000, vh: 1000, scrollY: r.newScrollY, level: 2, phase: nil).count
                > visibleSet(e, width: 1000, vh: 800, scrollY: 6000, level: 2, phase: nil).count, "expand reveals more")
    }

    // 4 — top edge down (shrink): centre held, content rebased; upper rows clipped (host moves the frame).
    @Test func topEdgeShrinkClipsAndRebasesContinuously() {
        let e = engine()
        let old = CGRect(x: 0, y: 0, width: 1000, height: 1000), new = CGRect(x: 0, y: 0, width: 1000, height: 800) // maxY ↓
        let centerBefore = anchorAt(e, width: 1000, scrollY: 6000, vh: 1000, level: 2, phase: nil)!
        let r = rebase(e, oldFrame: old, newFrame: new, scrollY: 6000, level: 2, phase: nil)
        #expect(r.anchorGlobalIndex == centerBefore)
        #expect(anchorAt(e, width: 1000, scrollY: r.newScrollY, vh: 800, level: 2, phase: nil) == centerBefore, "centre jumped")
    }

    // 5 — top edge up (expand): centre held, more content revealed at the top.
    @Test func topEdgeExpandRevealsAndRebasesContinuously() {
        let e = engine()
        let old = CGRect(x: 0, y: 0, width: 1000, height: 800), new = CGRect(x: 0, y: 0, width: 1000, height: 1000) // maxY ↑
        let centerBefore = anchorAt(e, width: 1000, scrollY: 6000, vh: 800, level: 2, phase: nil)!
        let r = rebase(e, oldFrame: old, newFrame: new, scrollY: 6000, level: 2, phase: nil)
        #expect(r.anchorGlobalIndex == centerBefore)
        #expect(visibleSet(e, width: 1000, vh: 1000, scrollY: r.newScrollY, level: 2, phase: nil).count
                > visibleSet(e, width: 1000, vh: 800, scrollY: 6000, level: 2, phase: nil).count)
    }

    // 6 — width unchanged → no width-derived metric change at all (pure height clips/reveals only).
    @Test func pureHeightResizeDoesNotChangeGridMetrics() {
        let e = engine()
        // Pure height rebase reports identical width-derived metrics + unchanged content height.
        let before = e.resolvedMetrics(level: 2, width: 1000)
        let r = rebase(e, oldFrame: CGRect(x: 0, y: 0, width: 1000, height: 1000), newFrame: CGRect(x: 0, y: 200, width: 1000, height: 800), scrollY: 6000, level: 2, phase: nil)
        #expect(r.newContentSize.height == e.contentSize(level: 2, width: 1000).height)
        let after = e.resolvedMetrics(level: 2, width: 1000)
        #expect(before.columns == after.columns && abs(before.slotSide - after.slotSide) < eps, "pure height must not change width-derived metrics")
    }

    // 7 — FIXED-COLUMNS, WIDTH-FILLING width change: the grid FILLS the width (no gutter), the column count is
    // CONSTANT (never reflows), the tile SCALES with width, the gap is unchanged, and because the columns don't
    // change the centre anchor item is preserved EXACTLY (no row shift).
    @Test func pureWidthResizeFillsWidthScalesTileNoReflow() {
        let e = engine()
        let old = CGRect(x: 0, y: 0, width: 1000, height: 800), new = CGRect(x: 0, y: 0, width: 1400, height: 800)
        for level in 0 ..< e.levelCount {
            let narrow = e.resolvedMetrics(level: level, width: 1000)
            let wide = e.resolvedMetrics(level: level, width: 1400)
            for (m, w) in [(narrow, CGFloat(1000)), (wide, CGFloat(1400))] {
                #expect(abs((CGFloat(m.columns) * m.pitch - m.gap) - w) < 2.0, "L\(level): grid must fill width \(w)")
            }
            #expect(wide.columns == narrow.columns, "L\(level): a width change must NOT reflow (column count constant)")
            #expect(wide.slotSide > narrow.slotSide, "L\(level): the tile must scale up with width")
            #expect(abs(narrow.gap - wide.gap) < eps)
        }
        let centerBefore = anchorAt(e, width: 1000, scrollY: 6000, vh: 800, level: 2, phase: nil)!
        let r = rebase(e, oldFrame: old, newFrame: new, scrollY: 6000, level: 2, phase: nil)
        #expect(r.anchorGlobalIndex == centerBefore)
        // Fixed-columns ⇒ no reflow ⇒ the centre item is preserved EXACTLY (no horizontal neighbour drift).
        let after = anchorAt(e, width: 1400, scrollY: r.newScrollY, vh: 800, level: 2, phase: nil)!
        #expect(after == centerBefore, "centre item must be preserved exactly on a fixed-columns resize (\(after) vs \(centerBefore))")
    }

    // 8 — combined width + height: metrics from new width, anchor preserved, no jump.
    @Test func combinedResizeRebasesFromLogicalAnchor() {
        let e = engine()
        let old = CGRect(x: 0, y: 0, width: 1000, height: 800), new = CGRect(x: 0, y: 0, width: 1300, height: 1000)
        let centerBefore = anchorAt(e, width: 1000, scrollY: 6000, vh: 800, level: 2, phase: nil)!
        let r = rebase(e, oldFrame: old, newFrame: new, scrollY: 6000, level: 2, phase: nil)
        #expect(r.anchorGlobalIndex == centerBefore)
        #expect(r.newContentSize.height == e.contentSize(level: 2, width: 1300, columnPhase: nil).height)
        // The anchor item is preserved vertically (r.anchorGlobalIndex above). Fixed-columns keeps the column
        // count unchanged, but the slot SCALES with width so the rows visible at the exact viewport CENTRE shift
        // slightly; the centre item may differ by up to one row. Tolerate that; a real vertical jump is ≫ a row.
        let after = anchorAt(e, width: 1300, scrollY: r.newScrollY, vh: 1000, level: 2, phase: nil)!
        let newCols = e.resolvedMetrics(level: 2, width: 1300).columns
        #expect(abs(after - centerBefore) <= newCols, "centre item must stay within one row of the preserved anchor (got \(after) vs \(centerBefore))")
    }

    // 9 — sidebar toggle = width change → same helper/path.
    @Test func sidebarToggleUsesWidthResizeRebasePath() {
        let e = engine()
        let wide = CGRect(x: 0, y: 0, width: 1280, height: 860), narrow = CGRect(x: 300, y: 0, width: 980, height: 860)
        let centerBefore = anchorAt(e, width: 1280, scrollY: 6000, vh: 860, level: 2, phase: nil)!
        let r = rebase(e, oldFrame: wide, newFrame: narrow, scrollY: 6000, level: 2, phase: nil)
        // The vertical anchor is preserved; fixed-columns keeps the column count unchanged, but the slot scales
        // with the narrower width so the centre item may differ by up to one row. Tolerate it.
        let after = anchorAt(e, width: 980, scrollY: r.newScrollY, vh: 860, level: 2, phase: nil)!
        let newCols = e.resolvedMetrics(level: 2, width: 980).columns
        #expect(abs(after - centerBefore) <= newCols, "centre item must stay within one row after the sidebar width change (\(after) vs \(centerBefore))")
        let host = src("MetalGridScrollHost.swift")
        #expect(host.contains("coordinator.rebaseForViewportChange") && host.contains("rebaseForResize"))
        #expect(!host.contains("restoreScroll") && !host.contains("oldScrollOrigin"))
    }

    // 9b — sidebar animation changes the LAYOUT viewport width, even though the MTKView keeps rendering
    // full-width under the translucent sidebar. The resize camera must therefore measure and rebase in
    // layout-space (`full.width - leadingObstructionInset`) and must react to safe-area inset changes directly
    // instead of waiting for a later AppKit layout/scroll tick.
    @Test func hostUsesLayoutSpaceFrameForSidebarResize() {
        let host = src("MetalGridScrollHost.swift")
        #expect(host.contains("let inset = coordinator.leadingObstructionInset"))
        #expect(host.contains("full.width - inset"))
        #expect(host.contains("private func applyLeadingInsetChange(from oldValue: CGFloat)"))
        #expect(host.contains("coordinator.sidebarObstructionInset = eventLeadingInset"))
        #expect(host.contains("rebaseForResize(oldFrame: oldFrame, newFrame: newFrame)"))
        #expect(host.contains("lastViewportScreenFrame = newFrame"))
    }

    // 9c — runtime host policy holds the stationary vertical edge: bottom-edge drags preserve the top,
    // top-edge drags preserve the bottom, and width-only/sidebar changes preserve the top. The engine stays
    // generic; this guard only constrains the production coordinator policy.
    @Test func coordinatorUsesStationaryEdgeResizeAnchors() {
        let coord = src("MetalGridCoordinator.swift")
        guard let range = coord.range(of: "private func resizeAnchorFraction") else {
            Issue.record("resizeAnchorFraction missing"); return
        }
        let body = String(coord[range.lowerBound ..< (coord.index(range.lowerBound, offsetBy: 700, limitedBy: coord.endIndex) ?? coord.endIndex)])
        #expect(body.contains("delta.movedBottomEdge && !delta.movedTopEdge { return 0 }"))
        #expect(body.contains("delta.movedTopEdge && !delta.movedBottomEdge { return 1 }"))
        #expect(body.contains("return 0.5"))
        #expect(body.contains("return 0"))
        guard let rebase = coord.range(of: "func rebaseForViewportChange") else {
            Issue.record("rebaseForViewportChange missing"); return
        }
        let rebaseBody = String(coord[rebase.lowerBound ..< (coord.index(rebase.lowerBound, offsetBy: 900, limitedBy: coord.endIndex) ?? coord.endIndex)])
        #expect(rebaseBody.contains("let anchorFractionY = resizeAnchorFraction(for: delta)"))
        #expect(!rebaseBody.contains("anchorFractionY: 0.5)   // normalized viewport-centre camera anchor"))
    }

    // 10
    @Test func bottomPinnedResizeStaysBottomPinned() {
        let e = engine()
        let new = CGRect(x: 0, y: 0, width: 1400, height: 800)
        let r = rebase(e, oldFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), newFrame: new, scrollY: 12345, level: 2, phase: nil, bottomPinned: true)
        #expect(r.bottomPinned)
        #expect(abs(r.newScrollY - max(0, r.newContentSize.height - new.height)) < eps)
    }

    // 11
    @Test func nonBottomResizeDoesNotBecomeBottomPinned() {
        let e = engine()
        let old = CGRect(x: 0, y: 0, width: 1000, height: 800), new = CGRect(x: 0, y: 0, width: 1200, height: 800)
        let r = rebase(e, oldFrame: old, newFrame: new, scrollY: 6000, level: 2, phase: nil, bottomPinned: false)
        #expect(!r.bottomPinned)
        #expect(abs(r.newScrollY - max(0, r.newContentSize.height - new.height)) > e.resolvedMetrics(level: 2, width: 1200).pitch)
    }

    // 12
    @Test func resizeDoesNotStartZoomTransaction() {
        let resizeSrc = src("GridViewportResizeRebase.swift")
        #expect(!resizeSrc.contains("beginZoomTransaction") && !resizeSrc.contains("GridZoomCommitBridge.") && !resizeSrc.contains("GridZoomTransaction("))
        let host = src("MetalGridScrollHost.swift")
        if let range = host.range(of: "private func rebaseForResize") {
            let body = String(host[range.lowerBound ..< (host.index(range.lowerBound, offsetBy: 1100, limitedBy: host.endIndex) ?? host.endIndex)])
            #expect(!body.contains("beginZoomTransaction") && !body.contains("beginCommitBridge"))
        }
    }

    // 13
    @Test func firstFrameAfterResizeUsesRebasedScrollY() {
        let host = src("MetalGridScrollHost.swift")
        #expect(host.contains("let y = min(max(0, r.newScrollY), maxY)"))
        guard let scrollIdx = host.range(of: "scroll(to: CGPoint(x: 0, y: y))"),
              let applyIdx = host.range(of: "applyContentSize(coordinator.contentSize())            // new content height") else {
            Issue.record("resize apply/scroll missing"); return
        }
        #expect(applyIdx.lowerBound < scrollIdx.lowerBound)
    }

    // 14
    @Test func resizeVisibleNeighborhoodOverlap() {
        let e = engine()
        let old = CGRect(x: 0, y: 0, width: 1000, height: 800), new = CGRect(x: 0, y: 0, width: 1400, height: 800)
        let r = rebase(e, oldFrame: old, newFrame: new, scrollY: 6000, level: 2, phase: nil)
        let before = visibleSet(e, width: 1000, vh: 800, scrollY: 6000, level: 2, phase: nil)
        let after = visibleSet(e, width: 1400, vh: 800, scrollY: r.newScrollY, level: 2, phase: nil)
        #expect(before.contains(r.anchorGlobalIndex!) && after.contains(r.anchorGlobalIndex!))
        #expect(before.intersection(after).count >= min(before.count, after.count) / 2)
    }

    // 15
    @Test func resizeGapConsistency() {
        let e = engine()
        let new = CGRect(x: 0, y: 0, width: 1400, height: 800)
        let r = rebase(e, oldFrame: CGRect(x: 0, y: 0, width: 1000, height: 800), newFrame: new, scrollY: 6000, level: 2, phase: nil)
        let m = e.resolvedMetrics(level: 2, width: new.width)
        let plan = e.framePlan(level: 2, viewportSize: CGSize(width: new.width, height: new.height), scrollOffset: CGPoint(x: 0, y: r.newScrollY), overscan: 0, columnPhase: nil)
        let row = Dictionary(grouping: plan.visibleSlots, by: { $0.row }).values.first { $0.count == m.columns }!.sorted { $0.column < $1.column }
        for i in 1 ..< row.count {
            #expect(abs((row[i].viewportRect.minX - row[i - 1].viewportRect.minX) - m.pitch) < eps)
            #expect(abs((row[i].viewportRect.minX - row[i - 1].viewportRect.maxX) - m.gap) < eps)
        }
    }

    // 15b — fresh-open fix: a manual window resize must detach the bottom-pin (like a scroll) so the rebase
    // runs even on a freshly-opened (bottom-pinned) grid. Guard the host wiring + the rebase-bypass condition.
    @Test func liveWindowResizeDetachesBottomPinSoRebaseRuns() {
        let host = src("MetalGridScrollHost.swift")
        #expect(host.contains("NSWindow.willStartLiveResizeNotification") && host.contains("windowWillLiveResize"),
                "host must observe window live-resize to detach the bottom-pin")
        // windowWillLiveResize still clears stickToBottom (now also arms the live-resize presentation).
        if let r = host.range(of: "func windowWillLiveResizeImpl()") {
            let body = String(host[r.lowerBound ..< (host.index(r.lowerBound, offsetBy: 220, limitedBy: host.endIndex) ?? host.endIndex)])
            #expect(body.contains("stickToBottom = false"), "a live window resize must clear stickToBottom (like a scroll)")
        } else { Issue.record("windowWillLiveResize missing") }
        // And the rebase IS bypassed while stuck to bottom (so detaching is what makes it run) — documents the cause.
        #expect(host.contains("guard !stickToBottom, let r = result else { return }"))
    }

    // 16 — Apple-like regression: a continuous sequence of height steps each rebases smoothly (centre held),
    // scrollY moves monotonically (NOT a strict-edge pin where it would be constant), and no late jump.
    @Test func appleResizeReferenceRegression() {
        let e = engine()
        var scrollY: CGFloat = 6000
        var vh: CGFloat = 1100
        let centerStart = anchorAt(e, width: 1000, scrollY: scrollY, vh: vh, level: 2, phase: nil)!
        var lastScrollY = scrollY
        var moved = false
        for newVH in stride(from: CGFloat(1000), through: 600, by: -100) {   // bottom edge rising in steps
            let old = CGRect(x: 0, y: 1100 - vh, width: 1000, height: vh)
            let new = CGRect(x: 0, y: 1100 - newVH, width: 1000, height: newVH)
            let r = rebase(e, oldFrame: old, newFrame: new, scrollY: scrollY, level: 2, phase: nil)
            #expect(anchorAt(e, width: 1000, scrollY: r.newScrollY, vh: newVH, level: 2, phase: nil) == centerStart, "centre drifted at vh \(newVH)")
            #expect(r.newScrollY >= lastScrollY - eps, "scrollY must move continuously, no backward jump")
            if abs(r.newScrollY - lastScrollY) > eps { moved = true }
            lastScrollY = r.newScrollY; scrollY = r.newScrollY; vh = newVH
        }
        #expect(moved, "a strict-edge pin would never move scrollY — the camera must rebase")
    }
}
