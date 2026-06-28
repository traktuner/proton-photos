# Resize/Sidebar — Apple-Parity Live Presentation Layer (MEASURED SPEC)

**Status:** SPEC, awaiting approval. No implementation yet. Prereq `round+fill` (width-filling square slots) is
on this branch and is the basis for the scale segments + the resting layout. The ineffective perf patch
(suppress-flag + reentrancy-guard) is reverted (no dead code).

## 0. Measurement basis

490 frames @ 10fps over the full reference video (`apple resize and sidebar animations.mov`), measured by 8
parallel per-window agents + 1 consolidation agent, then **cross-checked by hand** on the cited clearest frames.
Verdict: **confirmed surface transform** (Apple transforms an already-rendered surface during the drag; it does
NOT re-lay-out per frame). Hand-verified A/B:
- Horizontal: frame 0287 (wide, ~7 cols, large tiles) → 0296/0300 (narrow window, **same 7 cols, same scene,
  tiles uniformly shrunk**). The whole grid scales like a photo; columns held.
- Vertical: frame 0073 (tall, fire-trucks top row) → 0079 (short, fire-trucks scrolled off, kids row at top,
  **identical tile size**). Clip/reveal at constant size; content bottom-anchored, top counter-scrolls ~1:1.

Caveat (carried, not hidden): some windows reported "column reflow at constant tile size"; on re-read those were
artifacts of a simultaneous **zoom-level switch** to the dense "Alle Fotos 2" view + 10fps mislabeling — NOT a
resize reflow. One genuine residual: a widen can show a single-detent column delta co-existing with the scale
(expected — a column boundary crossing, see §1). No pure width-constant sidebar toggle exists in the corpus, so
sidebar is inferred from compound gestures (high but not direct confidence).

## 1. Measured behavior (the contract to replicate)

| Gesture | Mechanic | Anchor | Columns | Tile size | Settle |
|---|---|---|---|---|---|
| **Horizontal edge** (width) | **uniform surface SCALE** (grid scales like a photo) | the **stationary** edge (grid origin pinned to it; left in all captured drags) | **held**, ±1 detent at a width threshold | **tracks width** (scales) | **instant** (0–1 frame); no column snap |
| **Vertical edge** (height) | **CLIP / REVEAL** at constant size (add/remove rows) | the **stationary** edge | constant | **constant** | instant (~1 frame) |
| **Corner** | horizontal SCALE **and** vertical CLIP/REVEAL, independent + simultaneous | width→stationary-x, height→stationary-y | held ±1 | scales with width only | instant |
| **Sidebar open/close** | **like horizontal** — grid uniform-scales to the new content width; **no separate fade/slide/snapshot** of the grid (sidebar panel fades its own labels) | content left origin | ±1 detent | scales with content width | instant |

**Vertical counter-scroll:** the content stays anchored to the **stationary** edge, so the opposite side
counter-scrolls **~1:1** with the height delta. Direction depends on the anchored edge: bottom-edge drag with
bottom-anchored content → top counter-scrolls ~1.0; top-edge drag with top-pinned content → no counter-scroll
(~0), rows reveal/clip at the bottom. (This is exactly the engine's existing stationary-edge anchor policy.)

**Key identity that makes this exact, not approximate:** rendering the grid at width `W0` with `n` columns and
then uniform-scaling by `s = W/W0` yields a grid that fills width `W` with `n` columns — i.e. it **equals the
round+fill layout at `W` for the held column count** (the small exception is the gap, which a uniform scale
scales but round+fill holds constant — a sub-pixel-to-few-pt delta corrected imperceptibly at settle). So
"scale the surface" and "round+fill at the new width" are the **same layout** between column thresholds. Apple's
single-detent column changes happen exactly where round+fill's `round()` column count flips. ⇒ **round+fill
defines the scale-segment boundaries; the scale IS the layout.**

## 2. What happens DURING a live resize/sidebar gesture

Render the grid into an **oversized offscreen canvas once** at gesture start (and re-render it only when a
horizontal column threshold is crossed). Each frame, the coordinator draws that canvas with a transform — **no
engine resolve, no content-size pass, no per-frame quad rebuild, no SwiftUI relayout.**

1. **Gesture start** (`willStartLiveResize`; or sidebar-inset-change start):
   - Capture `renderWidth = currentLayoutWidth`, `renderColumns`, `renderScrollY`.
   - Render the grid into an **offscreen MTLTexture** sized to the start viewport **+ generous overscan** (target
     ≈ screen bounds), so vertical *reveal* and horizontal *stretch* show already-rendered content. (The renderer
     already has an offscreen path — the overview dissolve.)
   - `metalView.autoResizeDrawable = false` (AppKit bounds changes no longer realloc the drawable or fire
     `drawableSizeWillChange`).
2. **Per frame** (while `inLiveResize` / sidebar animating): build a transform from start→current geometry and
   draw the canvas textured-quad with it (one GPU quad):
   - **Horizontal:** uniform scale `s = currentLayoutWidth / renderWidth` about the **stationary** edge
     (right-edge drag → anchor x=0; left-edge drag → anchor right; sidebar → content left origin).
   - **Vertical:** translate so the stationary edge holds; the moving edge reveals overscan rows / clips; the
     opposite side shows the ~1:1 counter-scroll (a translation).
   - **Corner:** compose (scale `s` + vertical translate).
   - **Horizontal column threshold:** when `round((curW+g)/(side+g))` (the round+fill column rule) differs from
     `renderColumns`, **re-render the offscreen canvas** at the new width/columns and reset `renderWidth=curW`,
     `s→1`. Rare (once per detent); a single re-render, not per frame.
3. Because the per-frame op is a CALayer/encoder transform that commits **inside the window's resize
   transaction**, the Metal content is **automatically synced to the window border** — the rubber-band/trailing
   disappears with no `presentsWithTransaction` juggling needed during the drag.

## 3. What happens at RELEASE / SETTLE

`didEndLiveResize` (or sidebar animation end):
1. `metalView.autoResizeDrawable = true`.
2. **One** engine re-resolve at the final width → round+fill (`resolved()`), rebase scroll via the existing
   item-identity rebase (`GridViewportResizeRebase`), draw once normally.
3. No column snap (columns were tracked live at their thresholds); the only correction is the tiny gap delta
   (§1), which lands within ~1 frame — matching Apple's measured instant settle. No settle animation needed; if
   QA ever shows a flicker at a boundary, ease only that boundary frame via the existing `GridScrollRebase`.

## 4. Which layers must be FROZEN / BYPASSED / SYNCHRONIZED

| Layer | Action | Why |
|---|---|---|
| **`MTKView` drawable** | **FREEZE** during gesture (`autoResizeDrawable=false`); draw the offscreen canvas with a transform; re-enable on settle | the per-frame drawable realloc + async present is the rubber-band; a transform of a stable texture is sync'd by the window's resize transaction |
| **`MetalGridCoordinator` draw / engine resolve** | **BYPASS** during gesture: draw canvas-with-transform; resolve only at start, H-thresholds, and settle | per-frame engine resolve + content-size is the main-thread cost |
| **`MetalGridScrollHost.layout()`** | **BYPASS** the resolve/content-size/scroll-rebase path while `inLiveResize`; only update the transform | same |
| **`MetalProductionGridView.updateNSView`** | **GATE** on `inLiveResize` — skip the heavy reconcile while a gesture is active (the host owns the transform) | stops SwiftUI churn re-entering the host per frame |
| **`GeometryReader` (MainView detail)** | **HOIST** the O(library) work out of `TimelineView.body` (`filteredSections` / `flatMap(\.items)` / `dateMarkers` — TimelineView.swift:67–80) so a geometry re-eval can't recompute the whole library per frame; compute on `sections`-change only | a per-frame full-library recompute is the "pre-Metal" feeling; must not run during resize |
| **Glass — `GridTopFrost` within-window `NSVisualEffectView`** (MainView:895) | **SYNCHRONIZE / lever:** with the Metal side now a cheap canvas-transform the compositor should keep up; if QA still shows jank, **suspend GridTopFrost while `inLiveResize`** and restore on end | it blurs the live Metal layer every frame at changing geometry; it is the one *within-window* vibrancy we control |
| **Glass — native toolbar + floating sidebar** | leave to the system; their cost drops once the Metal content is cheap to produce | system-managed Liquid Glass; not ours to freeze |
| **Sidebar inset path (`applyLeadingInsetChange`)** | route through the SAME presentation lifecycle, driven by the 0.22s sidebar animation start/end (not per inset tick) | sidebar = a horizontal width change of the content area |

## 5. Which current dirty changes to REVERT vs KEEP

- **KEEP** — `round+fill` (`SquareTileGridEngine.columnsForFixedSide` round + `resolved()` fill;
  `GridZoomTransaction` filled-side lattice) and its inverted/added layout tests. It is the resting layout AND
  the scale-segment boundary rule (§1). Without it the horizontal scale would smear a trailing gutter.
- **KEEP** — L0–L3 default `aspectFitInsideSquare` (your screenshot call). Orthogonal to resize.
- **ALREADY REVERTED** (done, no dead code) — `suppressContentSizeCallback` (coordinator + host) and the
  `isProgrammaticResizeScroll` reentrancy guard + their perf-guard tests. They were the wrong fix (host-internal,
  imperceptible) and are fully superseded by this presentation layer.
- **NOTHING ELSE** dirty remains. The dirty diff is now only round+fill + tests + this doc.

## 6. Exact tests to add (with the implementation)

Pure-logic (engine/host helpers, no UI):
1. `presentationScaleEqualsWidthRatio` — for a horizontal step W0→W within one column segment, the transform
   scale == W/W0 about the stationary edge.
2. `scaledSurfaceEqualsRoundFillWithinSegment` — the scaled layout at W (held columns n) equals `resolved()` at W
   for the same n (modulo the gap delta), proving the scale IS the layout between thresholds.
3. `columnThresholdMatchesRoundFill` — the re-render trigger fires exactly when `columnsForFixedSide(width)`
   changes (the round() boundary), and only then.
4. `verticalGestureAppliesNoScaleOnlyTranslate` — height-only step ⇒ scale==1; translate == counter-scroll;
   counter-scroll fraction == the engine's `resizeAnchorFraction` for the moved edge (bottom→1.0 top-counter,
   top→0).
5. `cornerComposesScaleAndTranslateIndependently` — width drives scale, height drives translate, no cross-term.
6. `settleResolvesRoundFillOncePerGesture` — exactly one `resolved()` at `didEndLiveResize`; zero during
   `inLiveResize` except at a column threshold.
7. `sidebarToggleUsesHorizontalScalePath` — the sidebar inset change enters the presentation lifecycle and scales
   (no separate transition path).

Source/structure guards:
8. `noEngineResolvePerFrameDuringLiveResize` — host `layout()` while `inLiveResize` does not call the
   resolve/content-size path (only the transform).
9. `timelineBodyDoesNotRecomputeLibraryPerGeometry` — `filteredSections`/`flatMap(\.items)`/`dateMarkers` are
   hoisted out of `TimelineView.body` (computed on a `sections`/`filter` change, not on every geometry eval).
10. `mtkViewFreezesDrawableDuringResize` — the gesture path sets `autoResizeDrawable=false` on start and restores
    on end.

Forbidden regressions (must stay green): all pinch/scroll/round+fill/binding-echo suites; the round+fill
fill-width + seam invariants; pure-height-resize-changes-no-width-metric.

QA matrix (manual, after build): left edge, right edge, top edge, bottom edge, all four corners, sidebar
open/close, fast drag, drag while thumbnails still stream — each must be smooth, no rubber-band, no blank, no
gutter, no pop; settle instant; pinch/click zoom unaffected.

## 7. Phasing (each independently testable + QA-able)

1. **Offscreen canvas + horizontal scale** (the headline win): start/threshold/settle lifecycle, canvas render,
   uniform scale about the stationary edge. Proves the surface-transform model + kills the horizontal stutter.
2. **Vertical clip/reveal + counter-scroll** via canvas translate (reuses the lifecycle + the engine anchor).
3. **Corner** = compose 1+2.
4. **Sidebar** routed through the same lifecycle (driven by the 0.22s animation).
5. **Shell de-cost:** gate `updateNSView` on `inLiveResize`; hoist the `TimelineView.body` library work; measure;
   apply the `GridTopFrost`-suspend lever only if QA still needs it.

## 8. Residual open items (low-risk, settle during implementation)
- Exact overscan size for the canvas (screen bounds vs start+margin) — pick screen bounds; fall back to a live
  re-render for the rare drag beyond it.
- Whether the gap should scale with the drag (Apple's "photo scale" look) or stay constant — recommend scale
  during the drag (matches the measured uniform scale), snap to constant at settle (imperceptible).
- The single residual genuine reflow component on widen (§0 caveat) is just a column-threshold crossing — already
  modeled by §1/§2.
