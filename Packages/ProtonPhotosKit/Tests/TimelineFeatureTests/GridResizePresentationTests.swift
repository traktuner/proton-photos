import Testing
import Foundation
import CoreGraphics
@testable import TimelineFeature

// PHASE 1 — live window-resize PRESENTATION LAYER. During a live window edge drag the grid is presented as a
// STABLE rendered surface: the settled slots are snapshotted ONCE on begin, then each frame presented UNIFORMLY
// SCALED to the new width (square tiles preserved) about the stationary LEFT edge + viewport CENTRE — ONE coherent
// surface, NO per-tick engine resolve (re-resolving recomputes every tile position → a reflow, which is exactly
// what Apple does not do). The clip is frozen and re-centred ONCE on release (the centre anchor), so nothing
// drifts or snaps. These are the deterministic guards; the smoothness / no-blank / no-reflow acceptance is visual QA.
@Suite struct GridResizePresentationTests {
    private let eps: CGFloat = 0.001
    private func repoRoot() -> URL { var u = URL(fileURLWithPath: #filePath); for _ in 0 ..< 5 { u.deleteLastPathComponent() }; return u }
    private func src(_ name: String) -> String {
        (try? String(contentsOf: repoRoot().appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature/\(name)"), encoding: .utf8)) ?? ""
    }

    // MARK: - Pure transform math (presentationScaledRect)

    // 1 — a square tile stays SQUARE at any scale and its size is exactly the width ratio (× k) — never squashed.
    @Test func scalePreservesSquareTilesAtWidthRatio() {
        for k in [CGFloat(0.4), 0.75, 1.0, 1.6] {
            let out = MetalGridCoordinator.presentationScaledRect(CGRect(x: 137, y: 421, width: 200, height: 200), scale: k, insetX: 0, anchorY: 400)
            #expect(abs(out.width - out.height) < eps, "tile must stay square at scale \(k)")
            #expect(abs(out.width - 200 * k) < eps, "tile size must scale by the width ratio")
        }
    }

    // 2 — k = 1 is the identity (the gesture-start frame == the settled grid → no pop on begin).
    @Test func unitScaleIsIdentity() {
        let r = CGRect(x: 312, y: 47, width: 180, height: 180)
        let out = MetalGridCoordinator.presentationScaledRect(r, scale: 1, insetX: 24, anchorY: 450)
        #expect(abs(out.minX - r.minX) < eps && abs(out.minY - r.minY) < eps && abs(out.width - r.width) < eps && abs(out.height - r.height) < eps)
    }

    // 3 — the content LEFT edge is held at the inset anchor (the stationary X edge in viewport space).
    @Test func leftEdgeHeldAtInset() {
        let inset: CGFloat = 50
        let out = MetalGridCoordinator.presentationScaledRect(CGRect(x: inset, y: 400, width: 200, height: 200), scale: 0.6, insetX: inset, anchorY: 400)
        #expect(abs(out.minX - inset) < eps, "the content origin edge must stay pinned at the inset")
    }

    // 4 — CENTRE-anchored: the row at the viewport centre HOLDS at the centre under any scale (the item you are
    // looking at stays put — no vertical drift while dragging the side edge); rows above/below scale out symmetrically.
    @Test func centreAnchoredHoldsCentreRow() {
        let H: CGFloat = 800
        // A 100-tall cell centred on the viewport centre line (its midY = H/2) stays centred under any scale.
        let centreCell = CGRect(x: 0, y: H / 2 - 50, width: 100, height: 100)
        for k in [CGFloat(0.5), 1.0, 1.6] {
            let out = MetalGridCoordinator.presentationScaledRect(centreCell, scale: k, insetX: 0, anchorY: H / 2)
            #expect(abs(out.midY - H / 2) < eps, "the centre row must stay at the viewport centre at scale \(k)")
        }
        // A row ABOVE the centre moves further up on a scale-up and toward the centre on a scale-down (symmetric).
        let above = CGRect(x: 0, y: 100, width: 100, height: 100)
        let up = MetalGridCoordinator.presentationScaledRect(above, scale: 1.5, insetX: 0, anchorY: H / 2)
        let down = MetalGridCoordinator.presentationScaledRect(above, scale: 0.5, insetX: 0, anchorY: H / 2)
        #expect(up.minY < above.minY, "a scale-up pushes an above-centre row further up")
        #expect(down.minY > above.minY, "a scale-down pulls an above-centre row toward the centre")
    }

    // 5 — the scaled content FILLS the current content width: a cell whose right edge was at the start content-right
    // maps to the current content-right (the inset-anchored scale by the width ratio gives no gutter / no overflow).
    @Test func scaledContentFillsCurrentWidth() {
        // start layout width 1280 (no inset); narrow to 960 ⇒ k = 0.75. A cell at the right edge (maxX = 1280).
        let k: CGFloat = 960.0 / 1280.0
        let rightCell = MetalGridCoordinator.presentationScaledRect(CGRect(x: 1080, y: 0, width: 200, height: 200), scale: k, insetX: 0, anchorY: 400)
        #expect(abs(rightCell.maxX - 960) < eps, "the content right edge must map to the new content width (fills, no gutter)")
    }

    // MARK: - Lifecycle / bypass guards (structural)

    // 6 — the presentation SCALES the gesture-start SNAPSHOT each tick; it does NOT re-resolve the engine per frame
    // (that would reflow). drawPresentationResize maps the snapshot slots through presentationScaledRect and rebuilds
    // groups from THOSE — never `engine.framePlan` for the render.
    @Test func presentationScalesSnapshotNotPerFrameResolve() {
        let coord = src("MetalGridCoordinator.swift")
        guard let range = coord.range(of: "func drawPresentationResize") else { Issue.record("drawPresentationResize missing"); return }
        let body = String(coord[range.lowerBound ..< (coord.index(range.lowerBound, offsetBy: 1600, limitedBy: coord.endIndex) ?? coord.endIndex)])
        #expect(body.contains("presentationSnapshotSlots") && body.contains("presentationScaledRect"),
                "the render must SCALE the captured snapshot (one coherent surface), not re-resolve per tick")
        #expect(!body.contains("engine.framePlan"), "drawPresentationResize must NOT re-resolve the layout per tick (that reflows)")
        #expect(body.contains("buildRealGroups"), "groups are rebuilt from the SCALED snapshot slots")
        #expect(coord.contains("if presentationResizeActive {") && coord.contains("drawPresentationResize(in: view"))
    }

    // 7 — the SHARED snapshot capture builds the settled slots ONCE with generous overscan ABOVE (so a scale-out
    // reveals real rows) + records the start box; begin captures the CENTRE anchor + uses it; never in a zoom.
    @Test func beginSnapshotsWithOverscanAndCenterAnchor() {
        let coord = src("MetalGridCoordinator.swift")
        guard let cap = coord.range(of: "func captureSnapshot()") else { Issue.record("captureSnapshot missing"); return }
        let capBody = String(coord[cap.lowerBound ..< (coord.index(cap.lowerBound, offsetBy: 1600, limitedBy: coord.endIndex) ?? coord.endIndex)])
        #expect(capBody.contains("max(budget.overscanFraction, 1.5)"), "the snapshot must carry generous overscan rows above")
        #expect(capBody.contains("engine.framePlan") && capBody.contains("presentationSnapshotSlots ="), "captureSnapshot builds the slots once")
        #expect(capBody.contains("presentationStartLayoutWidth"), "captureSnapshot records the start layout width (the scale denominator)")
        #expect(coord.contains("func captureCenterAnchor()") && coord.contains("anchorItem(nearContentPoint:"), "the centre anchor is captured at the viewport centre")
        guard let range = coord.range(of: "func beginPresentationResize()") else { Issue.record("beginPresentationResize missing"); return }
        let body = String(coord[range.lowerBound ..< (coord.index(range.lowerBound, offsetBy: 1500, limitedBy: coord.endIndex) ?? coord.endIndex)])
        #expect(body.contains("captureCenterAnchor()") && body.contains("captureSnapshot()"), "begin captures the centre anchor + the snapshot")
        #expect(coord.contains("var canPresentResize") && coord.contains("zoomTransaction == nil") && coord.contains("!gridTransition.isActive"))
    }

    // 8 — layout() presents SYNCHRONOUSLY per tick (draw(), not async needsDisplay which the live-resize runloop
    // coalesces) and early-returns BEFORE the normal per-tick reflow path.
    @Test func layoutPresentsSynchronouslyAndBypassesReflow() {
        let host = src("MetalGridScrollHost.swift")
        #expect(host.contains("metalView.draw()"), "must draw synchronously per tick")
        guard let branch = host.range(of: "if inLiveResize, coordinator.presentationResizeActive"),
              let ret = host.range(of: "return", range: branch.upperBound ..< host.endIndex),
              let rebase = host.range(of: "rebaseForResize(oldFrame: old") else { Issue.record("layout wiring missing"); return }
        #expect(branch.lowerBound < ret.lowerBound && ret.lowerBound < rebase.lowerBound,
                "the presentation branch must early-return BEFORE the normal per-tick rebaseForResize")
    }

    // 9 — the settle on release does NOT reflow/snap: a width change settles to the resize anchor at the release
    // width (so the settled grid lands where the live frame left it) and it does NOT call rebaseForResize.
    @Test func settleSyncsClipWithoutReflowSnap() {
        let host = src("MetalGridScrollHost.swift")
        guard let dr = host.range(of: "func windowDidEndLiveResize()") else { Issue.record("windowDidEndLiveResize missing"); return }
        let db = String(host[dr.lowerBound ..< (host.index(dr.lowerBound, offsetBy: 2000, limitedBy: host.endIndex) ?? host.endIndex)])
        #expect(db.contains("coordinator.endPresentationResize()"))
        #expect(db.contains("coordinator.windowResizeReleaseScrollY()"), "the width settle must use the resize anchor (bottom-pinned ⇒ last row, else centre)")
        #expect(!db.contains("rebaseForResize("), "settle must NOT reflow/re-anchor (that was the snap)")
        #expect(host.contains("NSWindow.didEndLiveResizeNotification") && host.contains("selector(windowDidEndLiveResize)"))
    }

    // MARK: - Bottom-pin + corner (adaptive resize anchor)

    // 9a — BOTTOM-PIN DETECTION: a resize that began with the grid scrolled to (within a row of) the newest end is
    // bottom-pinned; one scrolled up into the middle is not. Bottom-pinned holds the LAST row at the viewport bottom
    // (no empty band below); centre-pinned holds the centre. Pure + boundary.
    @Test func resizeBottomPinDetection() {
        // scrolled to the very bottom (scrollY == maxScroll = content − viewport) ⇒ pinned.
        #expect(MetalGridCoordinator.resizeIsBottomPinned(scrollY: 4100, contentHeight: 5000, viewportHeight: 900))
        // within the 2pt tolerance of the bottom ⇒ still pinned.
        #expect(MetalGridCoordinator.resizeIsBottomPinned(scrollY: 4099, contentHeight: 5000, viewportHeight: 900))
        // scrolled up into the middle ⇒ NOT pinned (hold the centre).
        #expect(!MetalGridCoordinator.resizeIsBottomPinned(scrollY: 2000, contentHeight: 5000, viewportHeight: 900))
        // content shorter than the viewport (maxScroll = 0, scrollY 0) ⇒ pinned (degenerate bottom).
        #expect(MetalGridCoordinator.resizeIsBottomPinned(scrollY: 0, contentHeight: 400, viewportHeight: 900))
    }

    // 9b — the presentation + settle pick the anchor from the bottom-pin flag: `drawPresentationResize` scales about
    // H (last row) when pinned else H/2 (centre); the settle scroll routes through `windowResizeReleaseScrollY`
    // (bottom-anchored vs centre-anchored). Begin captures BOTH anchors + the flag.
    @Test func resizeAnchorIsAdaptiveBottomOrCentre() {
        let coord = src("MetalGridCoordinator.swift")
        guard let dr = coord.range(of: "func drawPresentationResize") else { Issue.record("drawPresentationResize missing"); return }
        let db = String(coord[dr.lowerBound ..< (coord.index(dr.lowerBound, offsetBy: 1600, limitedBy: coord.endIndex) ?? coord.endIndex)])
        #expect(db.contains("presentationResizeBottomPinned ? H : H / 2"), "the scale anchor must be the last row when bottom-pinned, else the centre")
        #expect(coord.contains("func windowResizeReleaseScrollY()") && coord.contains("presentationResizeBottomPinned ? bottomAnchoredScroll() : centerAnchoredScroll()"),
                "the release scroll must be bottom-anchored when pinned, else centre-anchored")
        guard let bp = coord.range(of: "func beginPresentationResize()") else { Issue.record("beginPresentationResize missing"); return }
        let bb = String(coord[bp.lowerBound ..< (coord.index(bp.lowerBound, offsetBy: 1500, limitedBy: coord.endIndex) ?? coord.endIndex)])
        #expect(bb.contains("presentationResizeBottomPinned = Self.resizeIsBottomPinned"), "begin must record the bottom-pin state")
        #expect(bb.contains("captureBottomAnchor()") && bb.contains("captureCenterAnchor()"), "begin must capture BOTH anchors so either can settle")
    }

    // 9c — CORNER FIX: the vertical counter-scroll slide applies ONLY to a pure-height drag. When the WIDTH is also
    // changing (a corner drag) the tiles SCALE and the resize anchor already places the content vertically — adding
    // the slide double-counts and snaps back on release. So `layout()` gates the slide off when the width changes.
    @Test func cornerResizeGatesVerticalShift() {
        let host = src("MetalGridScrollHost.swift")
        guard let lr = host.range(of: "override func layout()") else { Issue.record("layout() missing"); return }
        let lb = String(host[lr.lowerBound ..< (host.index(lr.lowerBound, offsetBy: 2600, limitedBy: host.endIndex) ?? host.endIndex)])
        #expect(lb.contains("widthChanging ? 0 : verticalCounterScroll("),
                "the vertical slide must be gated off while the width is changing (corner drag)")
    }

    // 10 — the duplicate content-size callback is FROZEN during the presentation (no spacer/scroll churn per tick).
    @Test func contentSizeCallbackFrozenDuringPresentation() {
        let host = src("MetalGridScrollHost.swift")
        guard let range = host.range(of: "coordinator.onContentSizeChange = {") else { Issue.record("onContentSizeChange wiring missing"); return }
        let body = String(host[range.lowerBound ..< (host.index(range.lowerBound, offsetBy: 240, limitedBy: host.endIndex) ?? host.endIndex)])
        #expect(body.contains("presentationResizeActive"), "applyContentSize must be gated off while presenting")
    }

    // MARK: - Release settle (detent-crossing reflow → animated "fly into place")

    // 11 — maxIndexedRectDelta is 0 for identical layouts (sub-detent ⇒ NO settle, instant) and large when a column
    // detent reflowed the grid (⇒ arm the animation). Index-keyed, so it measures real per-item movement.
    @Test func indexedRectDeltaDetectsReflow() {
        let a = [GridRenderSlot(index: 0, column: 0, row: 0, rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
                 GridRenderSlot(index: 1, column: 1, row: 0, rect: CGRect(x: 100, y: 0, width: 100, height: 100))]
        #expect(MetalGridCoordinator.maxIndexedRectDelta(source: a, target: a) == 0, "identical layouts ⇒ no settle")
        let b = [GridRenderSlot(index: 0, column: 0, row: 0, rect: CGRect(x: 0, y: 0, width: 80, height: 80)),
                 GridRenderSlot(index: 1, column: 0, row: 1, rect: CGRect(x: 0, y: 80, width: 80, height: 80))]
        #expect(MetalGridCoordinator.maxIndexedRectDelta(source: a, target: b) > 20, "a column reflow ⇒ a measurable delta")
    }

    // 12 — easeOutCubic is a clamped 0→1 fast-start / gentle-landing curve (the "fly into place").
    @Test func easeOutCubicShape() {
        #expect(abs(MetalGridCoordinator.easeOutCubic(0) - 0) < eps && abs(MetalGridCoordinator.easeOutCubic(1) - 1) < eps)
        #expect(MetalGridCoordinator.easeOutCubic(0.5) > 0.5, "easeOut leads linear at the midpoint")
    }

    // 13 — release arms the animated settle ONLY when a detent was crossed (source ≠ target), and the host drives it
    // to completion on the display tick. A sub-detent resize never arms it (settles instantly — no snap either way).
    @Test func releaseArmsAnimatedSettleWiring() {
        let coord = src("MetalGridCoordinator.swift")
        #expect(coord.contains("func beginResizeSettle(targetScrollY:") && coord.contains("maxIndexedRectDelta(source: source, target: target) > 1.5"),
                "begin must arm only when source ≠ target (a detent crossing)")
        #expect(coord.contains("if resizeSettleActive {") && coord.contains("drawResizeSettle(in: view"), "draw() must render the settle morph")
        let host = src("MetalGridScrollHost.swift")
        #expect(host.contains("coordinator.beginResizeSettle(targetScrollY: settledY)"), "release arms the settle with the settled scroll")
        #expect(host.contains("if coordinator.isResizeSettling { advanceResizeSettle() }") && host.contains("coordinator.resizeSettleProgress = CGFloat(t)"),
                "the display tick advances the settle to completion")
    }

    // MARK: - Vertical resize (counter-scroll slide)

    // 14 — the vertical counter-scroll SHARES the height loss: the DRAGGING edge clips the majority, the OPPOSITE
    // edge gives up fraction f. A shrink slides the grid UP (negative); growing flips it; f interpolates pure
    // edge-anchor (0) ↔ opposite-anchor (1).
    @Test func verticalCounterScrollSharesTheLoss() {
        let f: CGFloat = 1.0 / 3.0
        #expect(abs(MetalGridCoordinator.verticalCounterScrollShift(dH: 90, topEdgeDrag: false, fraction: f) - (-30)) < eps,
                "bottom-edge shrink slides up by f·dH")
        #expect(abs(MetalGridCoordinator.verticalCounterScrollShift(dH: 90, topEdgeDrag: true, fraction: f) - (-60)) < eps,
                "top-edge shrink slides up by (1−f)·dH")
        #expect(MetalGridCoordinator.verticalCounterScrollShift(dH: -90, topEdgeDrag: false, fraction: f) > 0, "growing flips the slide")
        #expect(MetalGridCoordinator.verticalCounterScrollShift(dH: 90, topEdgeDrag: false, fraction: 0) == 0, "f=0 ⇒ top fixed (pure edge-anchor)")
        #expect(abs(MetalGridCoordinator.verticalCounterScrollShift(dH: 90, topEdgeDrag: false, fraction: 1) - (-90)) < eps, "f=1 ⇒ bottom-anchored")
    }

    // 15 — a height change is the SAME stable surface, vertically SLID (tiles keep their size — NO scale):
    // drawPresentationResize offsets each scaled rect by presentationVerticalShift, and layout() presents BOTH axes
    // synchronously (the heightChanged fallback to the legacy per-tick rebase — the flicker — is gone).
    @Test func verticalDragSlidesTheSnapshotNoFallback() {
        let coord = src("MetalGridCoordinator.swift")
        guard let range = coord.range(of: "func drawPresentationResize") else { Issue.record("drawPresentationResize missing"); return }
        let body = String(coord[range.lowerBound ..< (coord.index(range.lowerBound, offsetBy: 1400, limitedBy: coord.endIndex) ?? coord.endIndex)])
        #expect(body.contains("presentationVerticalShift") && body.contains("offsetBy(dx: 0, dy: dy)"),
                "the vertical drag must SLIDE the scaled snapshot (tiles keep size)")
        let host = src("MetalGridScrollHost.swift")
        #expect(host.contains("verticalCounterScroll(start: liveResizeStartFrame, current: newFrame)"), "layout() sets the per-tick vertical slide (gated to pure-vertical)")
        #expect(!host.contains("if !heightChanged"), "the heightChanged fallback (the flicker path) must be gone")
    }

    // 16 — the settle is AXIS-AWARE: a WIDTH change settles CENTRE-anchored (+ the detent fly-into-place); a pure
    // VERTICAL change settles to the counter-scrolled scroll (start − slide), with NO animation.
    @Test func settleIsAxisAware() {
        let host = src("MetalGridScrollHost.swift")
        guard let dr = host.range(of: "func windowDidEndLiveResize()") else { Issue.record("windowDidEndLiveResize missing"); return }
        let db = String(host[dr.lowerBound ..< (host.index(dr.lowerBound, offsetBy: 1500, limitedBy: host.endIndex) ?? host.endIndex)])
        #expect(db.contains("widthChanged"), "the settle must branch on the resize axis")
        #expect(db.contains("presentationStartScrollY - coordinator.presentationVerticalShift"), "pure vertical settles to the counter-scrolled scroll")
        #expect(db.contains("widthChanged && coordinator.beginResizeSettle"), "the detent fly-into-place only applies to a width reflow")
    }

    // 17 — at the content edges the vertical slide CLAMPS the effective scroll to [0, maxScroll] (no void pulled
    // open below the last row / above the first): a grow at the bottom pins the last row and reveals older rows up
    // top, and vice-versa.
    @Test func verticalSlideClampsToContentBounds() {
        let host = src("MetalGridScrollHost.swift")
        guard let r = host.range(of: "func verticalCounterScroll(") else { Issue.record("verticalCounterScroll missing"); return }
        let body = String(host[r.lowerBound ..< (host.index(r.lowerBound, offsetBy: 1500, limitedBy: host.endIndex) ?? host.endIndex)])
        #expect(body.contains("spacer.frame.height") && body.contains("min(max(0, startScrollY - rawShift), maxScroll)"),
                "the vertical slide must clamp the effective scroll to the content bounds")
    }

    // MARK: - Sidebar open/close (scales the grid like a left-edge resize)

    // 18 — the RIGHT-anchored scale holds the content's RIGHT edge fixed and maps the left edge to the new inset
    // (sidebar open = a left-edge resize of the grid: the grid slides in from the right and scales).
    @Test func rightAnchoredScaleHoldsRightEdge() {
        let V: CGFloat = 1000, k: CGFloat = 0.75   // snapshot [0,V] → [250,V]
        let right = MetalGridCoordinator.presentationScaledRectRightAnchored(CGRect(x: V - 100, y: 0, width: 100, height: 100), scale: k, rightX: V, viewportH: 800)
        #expect(abs(right.maxX - V) < eps, "the content right edge stays at V")
        let left = MetalGridCoordinator.presentationScaledRectRightAnchored(CGRect(x: 0, y: 0, width: 100, height: 100), scale: k, rightX: V, viewportH: 800)
        #expect(abs(left.minX - 250) < eps, "the left edge maps to the new inset V·(1−k)")
        #expect(abs(left.width - 100 * k) < eps && abs(left.width - left.height) < eps, "tiles stay square, scaled by k")
    }

    // 19 — sidebar open/close SCALES the grid (no reflow during the slide): draw() renders drawSidebarResize via the
    // right-anchored scale; the host arms it on an inset change, drives it on the display tick, then commits + settles
    // (fly-into-place only if a detent reflowed). It commits the sidebar WIDTH (gap re-added), not the layout inset.
    @Test func sidebarOpenCloseScalesTheGrid() {
        let coord = src("MetalGridCoordinator.swift")
        #expect(coord.contains("func beginSidebarResize(") && coord.contains("presentationScaledRectRightAnchored"),
                "the sidebar scale must be right-anchored")
        #expect(coord.contains("if presentationSidebarActive {") && coord.contains("drawSidebarResize(in: view"), "draw() renders the sidebar scale")
        #expect(coord.contains("sidebarObstructionInset = presentationSidebarToEventInset"), "commit the sidebar WIDTH (engine re-adds the gap), not the layout inset")
        #expect(coord.contains("func endSidebarResize()") && coord.contains("maxIndexedRectDelta(source: source, target: target) > 1.5"),
                "end commits + arms the fly-into-place only on a detent reflow")
        #expect(coord.contains("bottomAnchoredScroll()"), "the sidebar settle bottom-anchors (no bottom-row jump when scrolled to the newest end)")
        #expect(coord.contains("if presentationSidebarActive { cancelSidebarResize() }"), "a new toggle / window resize supersedes the in-flight sidebar scale")
        let host = src("MetalGridScrollHost.swift")
        #expect(host.contains("coordinator.beginSidebarResize(fromInset: oldValue, toInset: eventLeadingInset)"), "an inset change arms the sidebar scale")
        #expect(host.contains("if coordinator.isSidebarResizing { advanceSidebarResize() }") && host.contains("coordinator.presentationSidebarProgress = CGFloat(t)"),
                "the display tick drives the sidebar scale")
    }

    // 22 — STANDARD OUTER MARGIN (= the level's inter-tile gap) so photos don't butt against the window edge: the
    // LEFT margin folds into the leading inset (render offset + hit-test), the RIGHT margin trims the layout width.
    // Applied at the coordinator (render inset + width trim) — the engine is untouched, so the lattice/seam hold.
    // The outer gutter is a CONSTANT (level-independent), so `layoutWidth` does NOT change between levels. This is
    // the regression guard for the pinch/± release-jump: the commit computes the anchored scroll at the gesture-
    // START level's width but the settled grid renders at the TARGET level's width — a level-dependent gutter made
    // those widths differ and drifted the anchor by many rows deep in the library. Reverting the gutter to the
    // per-level `gap` (the old code) re-breaks this and fails the test.
    @Test func gridHasConstantOuterMargin() {
        let coord = src("MetalGridCoordinator.swift")
        #expect(coord.contains("static let standardOuterMargin"), "the outer gutter must be a named constant")
        #expect(coord.contains("func gridHorizontalMargin(forLevel") && coord.contains("Self.standardOuterMargin"),
                "the outer margin must be the CONSTANT gutter (level-independent ⇒ layoutWidth level-independent), 0 on overviews")
        #expect(!coord.contains("monthLabels ? 0 : engine.metrics(level: lvl).gap"),
                "the gutter must NOT be the per-level gap (that made layoutWidth level-dependent → the pinch/± commit jump)")
        #expect(coord.contains("sidebarObstructionInset + gap + gridHorizontalMargin(forLevel: lvl)"), "the LEFT margin folds into the leading inset")
        #expect(coord.contains("fullViewportWidth - leadingObstructionInset - gridHorizontalMargin(forLevel: level)"), "the RIGHT margin trims the layout width")
    }
}
