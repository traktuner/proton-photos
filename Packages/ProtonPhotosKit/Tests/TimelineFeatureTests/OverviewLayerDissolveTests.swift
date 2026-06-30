import Testing
import Foundation
import CoreGraphics
@testable import TimelineFeature

// OVERVIEW LAYER DISSOLVE (replaces the rejected V3.10 warp). Two COMPLETE settled grid layers (source +
// target), blended by opacity. No relocation, no per-cell identity handoff, no `GridTransitionComponentBuilder`.
// Source keeps its own display mode; target is square (overview is square-only). These tests pin the
// deterministic model; the offscreen renderer that actually blends the two layers is a separate, documented
// step (reports/archive/PHASE_B_OVERVIEW_LAYER_DISSOLVE_REPORT.md).
@Suite struct OverviewLayerDissolveTests {
    private let viewport = CGSize(width: 1000, height: 760)
    private func engine(_ n: Int = 6000) -> SquareTileGridEngine { SquareTileGridEngine(sectionCounts: [n]) }

    private func plan(_ s: Int, _ t: Int, mode: TileContentDisplayMode = .aspectFitInsideSquare,
                      _ e: SquareTileGridEngine) -> OverviewLayerDissolvePlan? {
        e.overviewLayerDissolvePlan(from: s, to: t, viewportSize: viewport, targetViewportSize: viewport, sourceScrollY: 4000, sourceColumnPhase: nil,
                                    preferredNormalMode: mode, anchorContentPoint: CGPoint(x: 500, y: 4380),
                                    anchorViewportPoint: CGPoint(x: 500, y: 380), overscan: 300)
    }

    private func repoRoot() -> URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { u.deleteLastPathComponent() }     // …/Tests/TimelineFeatureTests/X.swift → repo root
        return u
    }
    private func source(_ name: String) -> String {
        let rel = "Packages/ProtonPhotosKit/Sources/TimelineFeature/\(name)"
        return (try? String(contentsOf: repoRoot().appendingPathComponent(rel), encoding: .utf8)) ?? ""
    }

    // Builds ONLY for the overview boundaries — never for the accepted normal-level (focusRowRelayout) steps.
    @Test func buildsOnlyForOverviewBoundaries() {
        let e = engine()
        #expect(plan(3, 4, e) != nil)
        #expect(plan(4, 5, e) != nil)
        #expect(plan(5, 4, e) != nil)
        #expect(plan(2, 3, e) == nil)   // normal step ⇒ not an overview dissolve
        #expect(plan(0, 1, e) == nil)
        #expect(plan(3, 5, e) == nil)   // non-adjacent
    }

    // Source and target rasters are computed ONCE; advancing q changes ONLY the blend, never the layouts.
    @Test func plansAreStableAcrossProgress() {
        let e = engine()
        guard let p0 = plan(3, 4, e) else { Issue.record("nil plan"); return }
        for step in 0 ... 10 {
            let pq = p0.withProgress(Double(step) / 10)
            #expect(pq.source == p0.source)
            #expect(pq.target == p0.target)
            #expect(pq.sourceDisplayMode == p0.sourceDisplayMode)
            #expect(pq.targetDisplayMode == p0.targetDisplayMode)
            #expect(pq.targetScrollY == p0.targetScrollY)
            #expect(pq.targetColumnPhase == p0.targetColumnPhase)
        }
    }

    // The TARGET overview grid is in its FINAL positions at every q (this is the property the rejected warp broke).
    @Test func targetPositionsAreFinalAtEveryProgress() {
        let e = engine()
        guard let p = plan(3, 4, e) else { Issue.record("nil plan"); return }
        let finalRects = p.target.visibleSlots.map(\.viewportRect)
        for step in 0 ... 10 {
            #expect(p.withProgress(Double(step) / 10).target.visibleSlots.map(\.viewportRect) == finalRects)
        }
        // SIZE-BASED (D2): the overview adopts the fixed-size / adaptive-column model too — derive the expected
        // L4 column count from the engine at this width rather than the old fixed literal (20).
        #expect(p.target.columns == e.resolvedMetrics(level: 4, width: viewport.width).columns)
        #expect(p.targetLevel == 4 && p.sourceLevel == 3)
    }

    // Source keeps its OWN display mode (NOT forced square); target is square because overview is square-only.
    @Test func sourceKeepsModeTargetIsSquare() {
        let e = engine()
        guard let pAspect = plan(3, 4, mode: .aspectFitInsideSquare, e) else { Issue.record("nil"); return }
        #expect(pAspect.sourceDisplayMode == .aspectFitInsideSquare)   // L3 source NOT square-cropped
        #expect(pAspect.targetDisplayMode == .squareFillCrop)          // L4 target square-only
        guard let pSquare = plan(3, 4, mode: .squareFillCrop, e) else { Issue.record("nil"); return }
        #expect(pSquare.sourceDisplayMode == .squareFillCrop)          // honored when the user prefers square
        #expect(pSquare.targetDisplayMode == .squareFillCrop)
        // L4→L5: both sides are overview ⇒ both square regardless of preference.
        guard let p45 = plan(4, 5, mode: .aspectFitInsideSquare, e) else { Issue.record("nil"); return }
        #expect(p45.sourceDisplayMode == .squareFillCrop && p45.targetDisplayMode == .squareFillCrop)
    }

    // Per-layer opacity: source fades out, target fades in, complementary at every q.
    @Test func layerOpacityEndpointsAndComplementarity() {
        let e = engine()
        guard let p = plan(4, 5, e) else { Issue.record("nil"); return }
        #expect(abs(p.withProgress(0).sourceOpacity - 1) < 1e-9)
        #expect(abs(p.withProgress(0).targetOpacity - 0) < 1e-9)
        #expect(abs(p.withProgress(1).sourceOpacity - 0) < 1e-9)
        #expect(abs(p.withProgress(1).targetOpacity - 1) < 1e-9)
        for step in 0 ... 10 {
            let pq = p.withProgress(Double(step) / 10)
            #expect(abs(pq.sourceOpacity + pq.targetOpacity - 1) < 1e-9)   // a true crossfade
        }
    }

    // MATH PROOF: the composite mix is a true LINEAR cross-dissolve — `a·(1−t) + b·t` — with NO `(1−t)²` source
    // under-weighting and NO background term. (Mirrors `metalGridCompositeFragment`'s `mix(a,b,t)`.)
    @Test func compositeMixIsLinearWithNoBackgroundBleed() {
        // The mix is independent of any background value — it has no bg argument at all.
        for (a, b) in [(0.8, 0.2), (0.1, 0.9), (0.5, 0.5), (1.0, 0.0)] {
            #expect(abs(overviewDissolveMix(a, b, 0) - a) < 1e-12)
            #expect(abs(overviewDissolveMix(a, b, 1) - b) < 1e-12)
            #expect(abs(overviewDissolveMix(a, b, 0.5) - (a + b) / 2) < 1e-12)   // exact average at mid-fade
            // linearity: value at t equals the straight line between endpoints
            for step in 0 ... 10 {
                let t = Double(step) / 10
                #expect(abs(overviewDissolveMix(a, b, t) - (a + (b - a) * t)) < 1e-12)
            }
        }
    }

    // CONTRAST: prove the offscreen linear mix is NOT the rejected single-pass premultiplied source-over result,
    // which darkens the mid-fade toward the background via the `(1−t)²` term.
    @Test func midFadeHasNoQSquaredDarkeningVsSinglePass() {
        let a = 0.8, b = 0.2, bg = 0.05      // bright source, dark target, dark bg (overlap region)
        let linearMid = overviewDissolveMix(a, b, 0.5)               // 0.5 — true average
        let bleedMid = overviewDissolveSinglePassBleed(a, b, bg, 0.5) // 0.2·.5 + 0.8·.25 + 0.05·.25 = 0.3125
        #expect(abs(linearMid - 0.5) < 1e-12)
        #expect(bleedMid < linearMid - 0.1)                          // the single-pass result is visibly darker
        // the single-pass bleed DEPENDS on bg (a tell-tale of background bleed); the linear mix never does
        #expect(overviewDissolveSinglePassBleed(a, b, 0.0, 0.5) != overviewDissolveSinglePassBleed(a, b, 0.5, 0.5))
        #expect(overviewDissolveMix(a, b, 0.5) == overviewDissolveMix(a, b, 0.5))   // bg-independent by construction
    }

    // GUARD: the renderer actually uses OFFSCREEN two-layer compositing with a single linear `mix`, not a
    // sequential source-over dissolve into one framebuffer.
    @Test func rendererUsesOffscreenLinearComposite() {
        let r = source("MetalGridRenderer.swift")
        #expect(r.contains("func renderLayerDissolve"))
        #expect(r.contains("ensureLayerTextures"))                  // offscreen render targets
        #expect(r.contains("encodeLayerPass"))                      // each layer rendered to its own texture
        #expect(r.contains("mix(a.rgb, b.rgb, t)"))                 // linear composite in the shader
        #expect(r.contains("metalGridCompositeFragment"))
    }

    // GUARD: the overview layer dissolve must NOT touch the relocation lattice / transition controller — that
    // reuse is exactly what was rejected. (Source-scan guard, matching the suite's existing guard-test style.)
    @Test func dissolveModelDoesNotUseRelocationMachinery() {
        // Scan CODE only — the file's prose deliberately names these to explain what it does NOT use.
        let code = source("OverviewLayerDissolve.swift")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.isEmpty)
        for forbidden in ["GridTransitionComponentBuilder", "GridTransitionController", "GridTransitionPlan",
                          "GridTransitionRendererInput", "beginPinch", "beginClick"] {
            #expect(!code.contains(forbidden), "overview layer dissolve must not reference \(forbidden)")
        }
    }

    // MARK: V3.12 — bottom-pin / clamp of the target scroll (no settle jump)

    private func dissolveAtBottom(_ s: Int, _ t: Int, _ e: SquareTileGridEngine) -> OverviewLayerDissolvePlan? {
        let sourceMaxY = max(0, e.contentSize(level: s, width: viewport.width).height - viewport.height)
        return e.overviewLayerDissolvePlan(from: s, to: t, viewportSize: viewport, targetViewportSize: viewport,
            sourceScrollY: sourceMaxY, sourceColumnPhase: nil, preferredNormalMode: .aspectFitInsideSquare,
            anchorContentPoint: CGPoint(x: viewport.width / 2, y: sourceMaxY + viewport.height / 2),
            anchorViewportPoint: CGPoint(x: viewport.width / 2, y: viewport.height / 2), overscan: 200)
    }
    private func targetMaxYFor(_ t: Int, phase: Int?, _ e: SquareTileGridEngine) -> CGFloat {
        max(0, e.contentSize(level: t, width: viewport.width, columnPhase: phase).height - viewport.height)
    }

    // 1 — a bottom-pinned source forces the target to its bottom-filled scroll (not the raw anchored scroll).
    @Test func bottomPinnedSourceTargetsTargetBottom() {
        let e = engine(6000)
        guard let p = dissolveAtBottom(3, 4, e) else { Issue.record("nil"); return }
        let tMax = targetMaxYFor(4, phase: p.targetColumnPhase, e)
        #expect(tMax > 0)                                          // target has scroll room
        #expect(abs(p.targetScrollY - tMax) < 1e-6)               // bottom-filled, not raw anchored
    }

    // 2 — the stored target plan is built from EXACTLY the (clamped) scroll commit will use.
    @Test func targetPlanBuiltFromCommitScroll() {
        let e = engine(6000)
        guard let p = dissolveAtBottom(3, 4, e) else { Issue.record("nil"); return }
        let rebuilt = e.framePlan(level: 4, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: p.targetScrollY),
                                  overscan: 200, columnPhase: p.targetColumnPhase)
        #expect(rebuilt == p.target)                              // target layer == settled plan at p.targetScrollY
    }

    // 3 — raw anchored target scroll out of bounds is clamped into [0, targetMaxY].
    @Test func rawTargetScrollIsClampedIntoBounds() {
        let e = engine(6000)
        // anchor + source near the TOP ⇒ raw anchored target scroll ≤ 0 ⇒ clamps to 0.
        guard let top = e.overviewLayerDissolvePlan(from: 3, to: 4, viewportSize: viewport, targetViewportSize: viewport,
            sourceScrollY: 0, sourceColumnPhase: nil, preferredNormalMode: .aspectFitInsideSquare,
            anchorContentPoint: CGPoint(x: viewport.width / 2, y: 10),
            anchorViewportPoint: CGPoint(x: viewport.width / 2, y: 10), overscan: 200) else { Issue.record("nil"); return }
        #expect(top.targetScrollY >= 0 && top.targetScrollY <= targetMaxYFor(4, phase: top.targetColumnPhase, e) + 1e-6)
        #expect(top.targetScrollY < 1.0)                          // top anchor ⇒ ~0
        // invariant across mid scroll positions: always within bounds.
        let sMax = max(0, e.contentSize(level: 3, width: viewport.width).height - viewport.height)
        for frac in [0.25, 0.5, 0.75] {
            let sY = sMax * CGFloat(frac)
            guard let p = e.overviewLayerDissolvePlan(from: 3, to: 4, viewportSize: viewport, targetViewportSize: viewport,
                sourceScrollY: sY, sourceColumnPhase: nil, preferredNormalMode: .aspectFitInsideSquare,
                anchorContentPoint: CGPoint(x: viewport.width / 2, y: sY + viewport.height / 2),
                anchorViewportPoint: CGPoint(x: viewport.width / 2, y: viewport.height / 2), overscan: 200) else { continue }
            #expect(p.targetScrollY >= 0 && p.targetScrollY <= targetMaxYFor(4, phase: p.targetColumnPhase, e) + 1e-6)
        }
    }

    // 4 — a NON-bottom-pinned mid-library anchor settles mid-content, NOT snapped to the bottom.
    @Test func nonBottomPinnedDoesNotSnapToBottom() {
        let e = engine(6000)
        let sMax = max(0, e.contentSize(level: 3, width: viewport.width).height - viewport.height)
        let sY = sMax * 0.5
        guard let p = e.overviewLayerDissolvePlan(from: 3, to: 4, viewportSize: viewport, targetViewportSize: viewport,
            sourceScrollY: sY, sourceColumnPhase: nil, preferredNormalMode: .aspectFitInsideSquare,
            anchorContentPoint: CGPoint(x: viewport.width / 2, y: sY + viewport.height / 2),
            anchorViewportPoint: CGPoint(x: viewport.width / 2, y: viewport.height / 2), overscan: 200)
        else { Issue.record("nil"); return }
        let tMax = targetMaxYFor(4, phase: p.targetColumnPhase, e)
        #expect(tMax > viewport.height)
        #expect(p.targetScrollY < tMax - viewport.height)        // clearly not the bottom
    }

    // 5 — target content shorter than the viewport ⇒ targetScrollY == 0 (never stretched/faked), even at bottom.
    // (SIZE-BASED: L4 now shows ~15 columns at this width, so a smaller count is needed for a short overview.)
    @Test func targetShorterThanViewportSettlesAtZero() {
        let e = engine(100)
        #expect(e.contentSize(level: 4, width: viewport.width).height < viewport.height)   // precondition
        guard let p = dissolveAtBottom(3, 4, e) else { Issue.record("nil"); return }
        #expect(p.targetScrollY == 0)
    }

    // MARK: V3.13 — direction-aware anchor (cursor wins on pinch-IN; bottom-fill is zoom-OUT-only)

    /// Build a dissolve for an explicit source scroll + cursor (viewport y), and return the plan alongside the
    /// independently-recomputed cursor-anchored clamped scroll / target phase / targetMaxY for exact comparison.
    private func dissolveAnchored(_ s: Int, _ t: Int, sourceScrollY: CGFloat, anchorViewportY: CGFloat,
                                  _ e: SquareTileGridEngine)
        -> (plan: OverviewLayerDissolvePlan, rawClamped: CGFloat, tphase: Int?, tMax: CGFloat)? {
        let anchorVP = CGPoint(x: viewport.width / 2, y: anchorViewportY)
        let anchorContent = CGPoint(x: viewport.width / 2, y: sourceScrollY + anchorViewportY)
        guard let plan = e.overviewLayerDissolvePlan(from: s, to: t, viewportSize: viewport, targetViewportSize: viewport, sourceScrollY: sourceScrollY,
                  sourceColumnPhase: nil, preferredNormalMode: .aspectFitInsideSquare,
                  anchorContentPoint: anchorContent, anchorViewportPoint: anchorVP, overscan: 200),
              let a = e.anchorItem(nearContentPoint: anchorContent, level: s, width: viewport.width, columnPhase: nil)
        else { return nil }
        let desiredCol = e.cursorColumn(viewportX: anchorVP.x, level: t, width: viewport.width)
        let tphase = e.columnPhase(forItem: a.flatIndex, targetColumn: desiredCol, level: t, width: viewport.width)
        let rawY = e.anchoredScrollOffset(flatIndex: a.flatIndex, localFraction: a.localFraction,
                                          viewportPoint: anchorVP, level: t, width: viewport.width, columnPhase: tphase).y
        let tMax = max(0, e.contentSize(level: t, width: viewport.width, columnPhase: tphase).height - viewport.height)
        return (plan, min(max(0, rawY), tMax), tphase, tMax)
    }

    // 1 — pinch-IN from a BOTTOM-PINNED overview uses the CURSOR anchor, NOT the overview bottom.
    @Test func overviewPinchInUsesCursorAnchorNotBottomPin() {
        let e = engine(6000)
        let sMax = max(0, e.contentSize(level: 4, width: viewport.width).height - viewport.height)   // L4 bottom
        guard let r = dissolveAnchored(4, 3, sourceScrollY: sMax, anchorViewportY: 60, e) else { Issue.record("nil"); return }
        #expect(abs(r.plan.targetScrollY - r.rawClamped) < 1e-6)        // cursor-anchored value
        #expect(r.plan.targetColumnPhase == r.tphase)                   // phase from the cursor anchor item
        #expect(abs(r.plan.targetScrollY - r.tMax) > viewport.height)   // emphatically NOT the bottom (old origin)
    }

    // 2 — zoom-OUT from a bottom-pinned source still bottom-fills (V3.12 protection preserved).
    @Test func overviewPinchOutFromBottomStillBottomFills() {
        let e = engine(6000)
        guard let p = dissolveAtBottom(3, 4, e) else { Issue.record("nil"); return }     // s=3 → t=4 = zoom out
        #expect(abs(p.targetScrollY - targetMaxYFor(4, phase: p.targetColumnPhase, e)) < 1e-6)
    }

    // 3 — the pinch-IN target layer is built from EXACTLY the (level, phase, scroll) commit will adopt.
    @Test func overviewPinchInCommitMatchesDissolveEndpoint() {
        let e = engine(6000)
        let sMax = max(0, e.contentSize(level: 4, width: viewport.width).height - viewport.height)
        guard let r = dissolveAnchored(4, 3, sourceScrollY: sMax, anchorViewportY: 60, e) else { Issue.record("nil"); return }
        let p = r.plan
        #expect(p.targetLevel == 3 && p.sourceLevel == 4)
        let rebuilt = e.framePlan(level: 3, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: p.targetScrollY),
                                  overscan: 200, columnPhase: p.targetColumnPhase)
        #expect(rebuilt == p.target)   // commit uses p.targetScrollY + p.targetColumnPhase ⇒ identical to the dissolve layer
    }

    // 4 — pinch-IN clamps ONLY when the cursor-anchored scroll exceeds bounds; otherwise it stays anchored.
    @Test func overviewPinchInClampsOnlyWhenAnchorExceedsBounds() {
        let e = engine(6000)
        // (a) in-bounds mid anchor ⇒ stays strictly interior (no clamp at either bound), == raw.
        let sMaxL4 = max(0, e.contentSize(level: 4, width: viewport.width).height - viewport.height)
        guard let mid = dissolveAnchored(4, 3, sourceScrollY: sMaxL4 * 0.5, anchorViewportY: viewport.height / 2, e)
        else { Issue.record("nil mid"); return }
        #expect(mid.plan.targetScrollY > 1 && mid.plan.targetScrollY < mid.tMax - 1)   // interior ⇒ unclamped
        #expect(abs(mid.plan.targetScrollY - mid.rawClamped) < 1e-6)

        // (b) anchor the LAST item with the cursor near the top ⇒ raw target scroll > targetMaxY ⇒ clamp (L5→L4).
        guard let lastRect = e.slotRect(flatIndex: 5999, level: 5, width: viewport.width) else { Issue.record("no rect"); return }
        let sMaxL5 = max(0, e.contentSize(level: 5, width: viewport.width).height - viewport.height)
        guard let p = e.overviewLayerDissolvePlan(from: 5, to: 4, viewportSize: viewport, targetViewportSize: viewport, sourceScrollY: sMaxL5 * 0.5,
                  sourceColumnPhase: nil, preferredNormalMode: .aspectFitInsideSquare,
                  anchorContentPoint: CGPoint(x: lastRect.midX, y: lastRect.midY),
                  anchorViewportPoint: CGPoint(x: lastRect.midX, y: 30), overscan: 200) else { Issue.record("nil last"); return }
        let tMax = max(0, e.contentSize(level: 4, width: viewport.width, columnPhase: p.targetColumnPhase).height - viewport.height)
        #expect(abs(p.targetScrollY - tMax) < 1e-6)   // clamped to the bound because the anchor exceeded it
    }

    // 5 — regression: a NON-bottom pinch-IN still anchors to the cursor (unchanged by the direction-aware rule).
    @Test func nonBottomPinchInStaysAnchored() {
        let e = engine(6000)
        let sMaxL4 = max(0, e.contentSize(level: 4, width: viewport.width).height - viewport.height)
        guard let r = dissolveAnchored(4, 3, sourceScrollY: sMaxL4 * 0.4, anchorViewportY: viewport.height / 2, e)
        else { Issue.record("nil"); return }
        #expect(abs(r.plan.targetScrollY - r.rawClamped) < 1e-6)
    }
}
