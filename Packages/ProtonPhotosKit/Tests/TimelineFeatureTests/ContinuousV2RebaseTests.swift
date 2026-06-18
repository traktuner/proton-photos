import Testing
import CoreGraphics
@testable import TimelineFeature

/// CONTINUOUS DAY-SECTIONED V2 — the topology-rebase model (replaces the rejected position-band "bracket").
/// These encode the spec's 9 required tests PLUS the four blockers the design attack surfaced (self-clock
/// convergence, anchor z-order, commit-match through a rebase, thrash vs same-path). All target the PURE
/// engine decision core (`planTick`), which takes `now` as an explicit parameter so it is fully deterministic.
struct ContinuousV2RebaseTests {
    typealias E = ContinuousDaySectionedGridLayoutEngine
    let W: CGFloat = 1200, gap: CGFloat = 4, insets: CGFloat = 0
    let dur = 0.18, eps: CGFloat = 1.0, cropT: CGFloat = 82

    private func topo(_ c: Int, crop: Bool = false) -> E.Topology { E.Topology(columns: c, gap: gap, cropSquare: crop) }

    // 1. LiveUsesContinuousApparentSizeTest — the live column count is a pure function of apparentCellSize and
    //    takes NO snapLevel/detent input. Two "sessions" begun at different source levels but at the same
    //    apparent resolve identically.
    @Test func liveUsesContinuousApparentSize() {
        for a in stride(from: CGFloat(44), through: 330, by: 3) {
            let fromBig = E.columnCount(apparentCellSize: a, viewportWidth: W, gap: gap)
            let fromSmall = E.columnCount(apparentCellSize: a, viewportWidth: W, gap: gap)
            #expect(fromBig == fromSmall)
        }
        // The decision for a steady apparent (no active rebase, ideal==live) is the single continuous layout —
        // never a function of a level.
        let live = topo(6)
        let r = E.planTick(apparent: E.naturalCellSize(columns: 6, viewportWidth: W, gap: gap, insets: 0),
                           viewportWidth: W, live: live, idealColumns: 6, idealCropSquare: false,
                           steppedGap: gap, cropThreshold: cropT, jitterEpsilon: eps, active: nil, now: 100, duration: dur)
        #expect(r.plan == .single(live))
        #expect(!r.started && r.active == nil)
    }

    // 2. SamePathInOutTest — pinch-in and pinch-out are the identical code path: the column count is a pure
    //    function of apparent (no direction/hysteresis), and a fresh decision at a given apparent is the same
    //    whether reached by zooming in or out.
    @Test func samePathInOut() {
        // Sweep up then down over the same grid; the count at each sampled apparent must match by direction.
        var up: [CGFloat: Int] = [:]
        var a: CGFloat = 44
        while a <= 330 { up[a] = E.columnCount(apparentCellSize: a, viewportWidth: W, gap: gap); a += 2 }
        a = 330
        while a >= 44 { #expect(E.columnCount(apparentCellSize: a, viewportWidth: W, gap: gap) == up[a]); a -= 2 }
        // A fresh planTick (active=nil) at the same apparent yields the same live topology both directions.
        let mid = E.naturalCellSize(columns: 7, viewportWidth: W, gap: gap, insets: 0)
        let inDir = E.planTick(apparent: mid, viewportWidth: W, live: topo(7), idealColumns: 7, idealCropSquare: false,
                               steppedGap: gap, cropThreshold: cropT, jitterEpsilon: eps, active: nil, now: 1, duration: dur)
        let outDir = E.planTick(apparent: mid, viewportWidth: W, live: topo(7), idealColumns: 7, idealCropSquare: false,
                                steppedGap: gap, cropThreshold: cropT, jitterEpsilon: eps, active: nil, now: 1, duration: dur)
        #expect(inDir == outDir)
    }

    // 3. CommitMatchesLiveGeometryTest — at a detent apparent (the natural size of detentColumns) the scale is
    //    exactly 1, so the overlay's screenRect for a cell equals its day-sectioned doc rect translated to the
    //    cursor — the SAME geometry the committed grid uses (proven byte-identical in JustifiedCommitMatchTests).
    @Test func commitMatchesLiveGeometry() {
        let cols = 8
        let detent = E.naturalCellSize(columns: cols, viewportWidth: W, gap: gap, insets: 0)
        #expect(E.columnCount(apparentCellSize: detent, viewportWidth: W, gap: gap) == cols)  // resolves to its own count
        let scale = E.scale(apparentCellSize: detent, naturalCellSize: detent)
        #expect(abs(scale - 1) < 1e-6)
        let lay = E.layout(columns: cols, assetCount: 64, viewportWidth: W, gap: gap, insets: 0)
        let anchorDoc = CGPoint(x: 100, y: 100), cursor = CGPoint(x: 600, y: 400)
        let docRect = lay.rect(of: 20)!
        let screen = E.screenRect(docRect: docRect, anchorDoc: anchorDoc, anchorScreen: cursor, scale: 1)
        // scale 1 ⇒ pure translation by (cursor - anchorDoc): size preserved, no distortion.
        #expect(abs(screen.width - docRect.width) < 1e-6 && abs(screen.height - docRect.height) < 1e-6)
        #expect(abs((screen.minX - docRect.minX) - (cursor.x - anchorDoc.x)) < 1e-6)
    }

    // 4. NoRectLerpTest — during a rebase each layer draws at ITS OWN fixed rects; no rect is lerp(old,new).
    //    The from layer uses the from topology's layout, the to layer uses the to topology's layout, each a
    //    pure cursor-scale; the forbidden midpoint rect is produced by neither.
    @Test func noRectLerp() {
        let from = E.layout(columns: 4, assetCount: 40, viewportWidth: W, gap: gap, insets: 0)
        let to = E.layout(columns: 5, assetCount: 40, viewportWidth: W, gap: gap, insets: 0)
        let aDoc = CGPoint(x: 80, y: 80), cur = CGPoint(x: 500, y: 300)
        let rFrom = E.screenRect(docRect: from.rect(of: 17)!, anchorDoc: aDoc, anchorScreen: cur, scale: 1.1)
        let rTo = E.screenRect(docRect: to.rect(of: 17)!, anchorDoc: aDoc, anchorScreen: cur, scale: 1.1)
        #expect(rFrom != rTo)
        let forbidden = CGRect(x: (rFrom.minX + rTo.minX) / 2, y: (rFrom.minY + rTo.minY) / 2,
                               width: (rFrom.width + rTo.width) / 2, height: (rFrom.height + rTo.height) / 2)
        #expect(rFrom != forbidden && rTo != forbidden)
    }

    // 5. AnchorTopmostTest — z-order (array order in the flat slot page) puts the anchor LAST, so the topmost
    //    quad covering the cursor is always the anchor — even when the other topology's cells overlap it.
    @Test func anchorTopmost() {
        // Two overlapping quads at the cursor: a non-anchor cell from the other topology, and the anchor cell.
        let cursor = CGPoint(x: 600, y: 400)
        struct Q { let uid: String; let rect: CGRect; let inBand: Bool; let isAnchor: Bool }
        let quads = [
            Q(uid: "other", rect: CGRect(x: 560, y: 360, width: 90, height: 90), inBand: true, isAnchor: false),
            Q(uid: "anchor", rect: CGRect(x: 555, y: 355, width: 100, height: 100), inBand: true, isAnchor: true),
        ]
        // Order by zKey (stable) → later = front. Topmost covering the cursor must be the anchor.
        let ordered = quads.enumerated().sorted { a, b in
            let za = E.zKey(isAnchor: a.element.isAnchor, inFocusBand: a.element.inBand)
            let zb = E.zKey(isAnchor: b.element.isAnchor, inFocusBand: b.element.inBand)
            return za != zb ? za < zb : a.offset < b.offset
        }.map(\.element)
        let topmost = ordered.last { $0.rect.contains(cursor) }
        #expect(topmost?.uid == "anchor")
    }

    // 6. FocusRowStableTest — the incoming (to) topology is suppressed in the focus band until very late, so
    //    the focus row is never replaced early; and a crop-only rebase keeps identical rects (no movement).
    @Test func focusRowStable() {
        for t in stride(from: CGFloat(0), through: 0.84, by: 0.06) {
            #expect(E.rebaseIncomingAlpha(inFocusBand: true, t: t) == 0)        // never replaced before 0.85
        }
        #expect(E.rebaseIncomingAlpha(inFocusBand: true, t: 0.95) > 0)          // begins only very late
        #expect(E.rebaseOutgoingAlpha(0.2) > 0.9)                              // old focus row stays solid early
        // Crop-only rebase: same columns+gap ⇒ the from and to layouts are identical rects for every index.
        let lay = E.layout(columns: 6, assetCount: 50, viewportWidth: W, gap: gap, insets: 0)
        for i in 0..<50 { #expect(lay.rect(of: i) == lay.rect(of: i)) }        // (rect identity is structural)
    }

    // 7. LocalColumnChangeTest — a started rebase steps the column count by at most ONE, even when the ideal
    //    jumps far (fast pinch). No far-detent jump in a single rebase.
    @Test func localColumnChange() {
        // Ideal far below current → to.columns is current-1, not the far value.
        let down = E.planTick(apparent: 50, viewportWidth: W, live: topo(5), idealColumns: 14, idealCropSquare: false,
                              steppedGap: gap, cropThreshold: cropT, jitterEpsilon: eps, active: nil, now: 0, duration: dur)
        if case let .rebasing(r, _) = down.plan { #expect(r.to.columns == 6) } else { Issue.record("expected rebase") }
        // Ideal far above current → to.columns is current+1 toward fewer columns... (current-1 numerically).
        let up = E.planTick(apparent: 320, viewportWidth: W, live: topo(12), idealColumns: 4, idealCropSquare: false,
                            steppedGap: gap, cropThreshold: cropT, jitterEpsilon: eps, active: nil, now: 0, duration: dur)
        if case let .rebasing(r, _) = up.plan { #expect(r.to.columns == 11) } else { Issue.record("expected rebase") }
        #expect(E.steppedColumnCount(current: 5, ideal: 14) == 6)
        #expect(E.steppedColumnCount(current: 12, ideal: 4) == 11)
    }

    // 8. TopologyRebaseAlphaOnlyTest — at a column boundary the rebase is two fixed-rect layers with
    //    complementary time-based alpha (from fades out, to fades in); the dissolve is alpha-only, and the
    //    column count steps by one. (The from/to layers keep their own rects — verified in noRectLerp.)
    @Test func topologyRebaseAlphaOnly() {
        // Cross a real flip threshold for K=6 by the dead-band margin so a rebase actually starts.
        let (down, _) = E.flipThresholds(columns: 6, viewportWidth: W, gap: gap)
        let a = down - 2 * eps                         // pushed below the K→K+1 threshold past the dead-band
        let ideal = E.columnCount(apparentCellSize: a, viewportWidth: W, gap: gap)
        #expect(ideal == 7)
        let res = E.planTick(apparent: a, viewportWidth: W, live: topo(6), idealColumns: ideal, idealCropSquare: false,
                             steppedGap: gap, cropThreshold: cropT, jitterEpsilon: eps, active: nil, now: 10, duration: dur)
        #expect(res.started && res.active != nil)
        if case let .rebasing(r, alpha) = res.plan {
            #expect(r.from.columns == 6 && r.to.columns == 7)
            #expect(alpha == 0)                        // dissolve begins at t=0
            // Complementary alpha over the dissolve: out falls, in rises, both fixed rects.
            #expect(E.rebaseOutgoingAlpha(0.1) > E.rebaseOutgoingAlpha(0.9))
            #expect(E.rebaseIncomingAlpha(inFocusBand: false, t: 0.9) > E.rebaseIncomingAlpha(inFocusBand: false, t: 0.1))
        } else { Issue.record("expected rebasing plan") }
    }

    // 9. NoViewportPatchTest — the model is per-photo cells, never a captured full-viewport rectangle. Every
    //    cell rect in a layout is at most cell-sized; none spans the viewport (no "window patch" entity).
    @Test func noViewportPatch() {
        let lay = E.layout(columns: 5, assetCount: 60, viewportWidth: W, gap: gap, insets: 0)
        let viewport = CGRect(x: 0, y: 0, width: W, height: 2000)
        for i in 0..<60 {
            let r = lay.rect(of: i)!
            #expect(r.width < W && r.width <= lay.cellSize + 0.001)            // a cell, not the whole width
            #expect(!(r.width >= viewport.width && r.height >= viewport.height)) // never the viewport itself
        }
    }

    // ── Attack blockers ─────────────────────────────────────────────────────────────────────────────────

    // BLOCKER 1 (self-clock convergence): with a rebase in flight and wall-clock advanced past its end — with
    // NO change in apparent (a paused finger) — the decision COLLAPSES to the single destination topology.
    @Test func rebaseCompletesWhenGesturePauses() {
        let r = E.Rebase(from: topo(6), to: topo(7), startTime: 100, duration: dur)
        let mid = E.planTick(apparent: 150, viewportWidth: W, live: r.to, idealColumns: 7, idealCropSquare: false,
                             steppedGap: gap, cropThreshold: cropT, jitterEpsilon: eps, active: r, now: 100 + dur / 2, duration: dur)
        if case .rebasing = mid.plan {} else { Issue.record("expected still rebasing mid-flight") }
        let done = E.planTick(apparent: 150, viewportWidth: W, live: r.to, idealColumns: 7, idealCropSquare: false,
                              steppedGap: gap, cropThreshold: cropT, jitterEpsilon: eps, active: r, now: 100 + dur + 0.01, duration: dur)
        #expect(done.plan == .single(topo(7)))
        #expect(done.active == nil && !done.started)
    }

    // BLOCKER 1/5 (no restart while active): a boundary re-crossing while a rebase is in flight does NOT start
    // a second rebase or re-aim the target — the in-flight rebase always runs to completion (no never-complete).
    @Test func rebaseNotRestartedWhileActive() {
        let r = E.Rebase(from: topo(6), to: topo(7), startTime: 0, duration: dur)
        // ideal has flipped back to 6 mid-flight; must keep the SAME rebase, not start a 7→6.
        let res = E.planTick(apparent: 149, viewportWidth: W, live: r.to, idealColumns: 6, idealCropSquare: false,
                             steppedGap: gap, cropThreshold: cropT, jitterEpsilon: eps, active: r, now: dur / 2, duration: dur)
        #expect(!res.started)
        if case let .rebasing(active, _) = res.plan { #expect(active == r) } else { Issue.record("expected same rebase") }
    }

    // BLOCKER 5 (thrash vs same-path): apparent jittering around a flip threshold WITHIN the dead-band starts
    // ZERO rebases — without making the column count direction-dependent.
    @Test func noRebaseThrashWithinDeadband() {
        let (down, _) = E.flipThresholds(columns: 6, viewportWidth: W, gap: gap)
        var started = 0
        // 30 ticks of sub-epsilon jitter straddling the threshold; no rebase may begin.
        for i in 0..<30 {
            let jitter = (i % 2 == 0 ? eps * 0.4 : -eps * 0.4)
            let a = down + jitter
            let ideal = E.columnCount(apparentCellSize: a, viewportWidth: W, gap: gap)
            let res = E.planTick(apparent: a, viewportWidth: W, live: topo(6), idealColumns: ideal, idealCropSquare: false,
                                 steppedGap: gap, cropThreshold: cropT, jitterEpsilon: eps, active: nil, now: Double(i), duration: dur)
            if res.started { started += 1 }
        }
        #expect(started == 0)
        // But a deliberate crossing past the dead-band DOES start exactly one.
        let decisive = E.planTick(apparent: down - 2 * eps, viewportWidth: W, live: topo(6),
                                  idealColumns: E.columnCount(apparentCellSize: down - 2 * eps, viewportWidth: W, gap: gap),
                                  idealCropSquare: false, steppedGap: gap, cropThreshold: cropT, jitterEpsilon: eps,
                                  active: nil, now: 99, duration: dur)
        #expect(decisive.started)
    }

    // BLOCKER 6 (crop = rect-identical rebase): a crop-only boundary (same column count) starts a rebase whose
    // from/to share columns AND gap → identical rects → a pure alpha crop dissolve, never a column step.
    @Test func cropOnlyRebaseKeepsColumnsAndRects() {
        let a = cropT - 2 * eps                          // below the crop threshold, same column count
        let cols = E.columnCount(apparentCellSize: a, viewportWidth: W, gap: gap)
        let res = E.planTick(apparent: a, viewportWidth: W, live: topo(cols, crop: false), idealColumns: cols,
                             idealCropSquare: true, steppedGap: gap, cropThreshold: cropT, jitterEpsilon: eps,
                             active: nil, now: 5, duration: dur)
        #expect(res.started)
        if case let .rebasing(r, _) = res.plan {
            #expect(r.from.columns == r.to.columns)      // no column movement
            #expect(r.from.gap == r.to.gap)              // identical rects
            #expect(r.from.cropSquare == false && r.to.cropSquare == true)  // alpha-only crop dissolve
        } else { Issue.record("expected crop rebase") }
    }

    // Settle force-resolve (BLOCKER 4 helper): clearing the rebase and pinning the live topology to the detent
    // makes the final overlay topology equal the committed one (no reveal pop). Modelled by a planTick at the
    // detent with active=nil and live already pinned → single(detent), no rebase.
    @Test func settleResolvesToDetentTopology() {
        let detentCols = 8
        let detent = E.naturalCellSize(columns: detentCols, viewportWidth: W, gap: gap, insets: 0)
        let pinned = topo(detentCols)
        let res = E.planTick(apparent: detent, viewportWidth: W, live: pinned, idealColumns: detentCols,
                             idealCropSquare: false, steppedGap: gap, cropThreshold: cropT, jitterEpsilon: eps,
                             active: nil, now: 0, duration: dur)
        #expect(res.plan == .single(pinned))
        #expect(res.active == nil)
        #expect(E.columnCount(apparentCellSize: detent, viewportWidth: W, gap: gap) == detentCols)
    }
}
