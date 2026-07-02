# Resize/Sidebar - Apple-Parity Live Presentation Layer (IMPLEMENTED SPEC)

**Status:** IMPLEMENTED. The live resize/sidebar presentation layer shipped on this branch
(`MetalGridCoordinator.captureSnapshot` / `beginPresentationResize` / `drawPresentationResize` /
`beginSidebarResize` + host `windowWillLiveResize` / `advanceSidebarResize` / `advanceResizeSettle`), guarded by
`GridResizePresentationTests`. NOTE: it shipped as a per-tick CPU **snapshot-scale of resolved slot rects**, NOT
the offscreen-MTLTexture canvas this spec's §4 proposed.

> **RECONCILIATION (2026-06-28):** this spec originally assumed the rejected adaptive round+fill model and an
> offscreen texture compositor. The accepted and implemented model is **FIXED-COLUMNS + width-fill**: each level
> holds its columns and a resize SCALES the tile to fill the width. There is no column reflow and no width-threshold
> column flip during resize/sidebar gestures. The shipped implementation scales a captured slot snapshot on the CPU
> each tick; it does not freeze an offscreen MTLTexture.

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
artifacts of a simultaneous **zoom-level switch** to the dense "Alle Fotos 2" view + 10fps mislabeling - NOT a
resize reflow. No pure width-constant sidebar toggle exists in the corpus, so sidebar is inferred from compound
gestures (high but not direct confidence).

## 1. Measured behavior (the contract to replicate)

| Gesture | Mechanic | Anchor | Columns | Tile size | Settle |
|---|---|---|---|---|---|
| **Horizontal edge** (width) | **uniform surface SCALE** (grid scales like a photo) | the **stationary** edge (grid origin pinned to it; left in all captured drags) | **held** | **tracks width** (scales) | **instant** (0–1 frame); no column snap |
| **Vertical edge** (height) | **CLIP / REVEAL** at constant size (add/remove rows) | the **stationary** edge | constant | **constant** | instant (~1 frame) |
| **Corner** | horizontal SCALE **and** vertical CLIP/REVEAL, independent + simultaneous | width→stationary-x, height→stationary-y | held | scales with width only | instant |
| **Sidebar open/close** | **like horizontal** - grid uniform-scales to the new content width; **no separate fade/slide/snapshot** of the grid (sidebar panel fades its own labels) | content left origin | held | scales with content width | instant |

**Vertical counter-scroll:** the content stays anchored to the **stationary** edge, so the opposite side
counter-scrolls **~1:1** with the height delta. Direction depends on the anchored edge: bottom-edge drag with
bottom-anchored content → top counter-scrolls ~1.0; top-edge drag with top-pinned content → no counter-scroll
(~0), rows reveal/clip at the bottom. (This is exactly the engine's existing stationary-edge anchor policy.)

**Key identity that makes this exact, not approximate:** rendering the grid at width `W0` with `n` fixed columns
and then uniform-scaling by `s = W/W0` yields a grid that fills width `W` with the same `n` columns. That is the
settled fixed-column layout at the release width, except for the tiny gap delta caused by scaling the captured
gaps while the settled grid reuses the level's constant gap. The implemented release guard avoids animating that
gap delta as a fake reflow.

## 2. What happens DURING a live resize/sidebar gesture

Capture the resolved visible slots once at gesture start with generous overscan. Each frame, the coordinator maps
that captured slot snapshot through a uniform transform - **no engine resolve, no content-size pass, no SwiftUI
relayout, and no texture/cache/decode churn.**

1. **Gesture start** (`willStartLiveResize`; or sidebar-inset-change start):
   - Capture `renderWidth = currentLayoutWidth`, `renderColumns`, `renderScrollY`.
   - Resolve the visible slots once into `presentationSnapshotSlots` with generous overscan so vertical reveal and
     horizontal scale show already-laid-out content.
2. **Per frame** (while `inLiveResize` / sidebar animating): build a transform from start→current geometry and
   draw the canvas textured-quad with it (one GPU quad):
   - **Horizontal:** uniform scale `s = currentLayoutWidth / renderWidth` about the **stationary** edge
     (right-edge drag → anchor x=0; left-edge drag → anchor right; sidebar → content left origin).
   - **Vertical:** translate so the stationary edge holds; the moving edge reveals overscan rows / clips; the
     opposite side shows the ~1:1 counter-scroll (a translation).
   - **Corner:** compose (scale `s` + vertical translate).
3. There is no horizontal column-threshold re-render under the accepted fixed-column model. Columns change only on
   zoom level changes, not on resize/sidebar gestures.

## 3. What happens at RELEASE / SETTLE

`didEndLiveResize` (or sidebar animation end):
1. **One** engine re-resolve at the final width with the same fixed column count.
2. The host applies the release scroll (`windowResizeReleaseScrollY` for width/corner, counter-scrolled value for
   pure vertical resize), then draws normally.
3. No column snap is expected. `beginResizeSettle` is retained defensively for a future responsive policy that
   genuinely changes column count; fixed-column resize normally does not arm it.

## 4. Which layers must be FROZEN / BYPASSED / SYNCHRONIZED

| Layer | Action | Why |
|---|---|---|
| **`MTKView` draw** | present synchronously from `layout()` using the scaled slot snapshot | keeps the Metal frame moving with the window border without per-frame engine resolve |
| **`MetalGridCoordinator` draw / engine resolve** | **BYPASS** engine resolve during gesture: draw the captured slot snapshot with a transform; resolve only at start and settle | per-frame engine resolve + content-size is the main-thread cost |
| **`MetalGridScrollHost.layout()`** | **BYPASS** the resolve/content-size/scroll-rebase path while `inLiveResize`; only update the transform | same |
| **`MetalProductionGridView.updateNSView`** | **GATE** on `inLiveResize` - skip the heavy reconcile while a gesture is active (the host owns the transform) | stops SwiftUI churn re-entering the host per frame |
| **`GeometryReader` (MainView detail)** | **HOIST** the O(library) work out of `TimelineView.body` (`filteredSections` / `flatMap(\.items)` / `dateMarkers` - TimelineView.swift:67–80) so a geometry re-eval can't recompute the whole library per frame; compute on `sections`-change only | a per-frame full-library recompute is the "pre-Metal" feeling; must not run during resize |
| **Glass - `GridTopFrost` within-window `NSVisualEffectView`** (MainView:895) | **SYNCHRONIZE / lever:** with the Metal side now a cheap canvas-transform the compositor should keep up; if QA still shows jank, **suspend GridTopFrost while `inLiveResize`** and restore on end | it blurs the live Metal layer every frame at changing geometry; it is the one *within-window* vibrancy we control |
| **Glass - native toolbar + floating sidebar** | leave to the system; their cost drops once the Metal content is cheap to produce | system-managed Liquid Glass; not ours to freeze |
| **Sidebar inset path (`applyLeadingInsetChange`)** | route through the SAME presentation lifecycle, driven by the 0.22s sidebar animation start/end (not per inset tick) | sidebar = a horizontal width change of the content area |

## 5. Which current dirty changes to REVERT vs KEEP

- **KEEP** - fixed-columns + width-fill (`resolvedForLevel` passes `fixedColumns: nominalColumns`) and its tests.
  `columnsForFixedSide` remains only for live over-zoom / future responsive scaffolding, not the settled resize rule.
- **KEEP** - L0–L3 default `aspectFitInsideSquare` (your screenshot call). Orthogonal to resize.
- **ALREADY REVERTED** (done, no dead code) - `suppressContentSizeCallback` (coordinator + host) and the
  `isProgrammaticResizeScroll` reentrancy guard + their perf-guard tests. They were the wrong fix (host-internal,
  imperceptible) and are fully superseded by this presentation layer.
- **NOTE (stale):** this line predated implementation - the presentation layer described here is now implemented
  and committed, so "the dirty diff is only round+fill + tests + this doc" no longer holds.

## 6. Exact tests to add (with the implementation)

Pure-logic (engine/host helpers, no UI):
1. `presentationScaleEqualsWidthRatio` - for a horizontal step W0→W, the transform scale == W/W0 about the
   stationary edge.
2. `scaledSurfaceEqualsFixedColumnsAtReleaseWidth` - the scaled layout at W (held columns n) equals `resolved()` at
   W for the same n, modulo the constant-gap delta.
3. `fixedColumnResizeDoesNotArmColumnReflowSettle` - release settle remains dormant while columns are unchanged.
4. `verticalGestureAppliesNoScaleOnlyTranslate` - height-only step ⇒ scale==1; translate == counter-scroll;
   counter-scroll fraction == the engine's `resizeAnchorFraction` for the moved edge (bottom→1.0 top-counter,
   top→0).
5. `cornerComposesScaleAndTranslateIndependently` - width drives scale, height drives translate, no cross-term.
6. `settleResolvesFixedColumnsOncePerGesture` - exactly one `resolved()` at `didEndLiveResize`; zero during
   `inLiveResize`.
7. `sidebarToggleUsesHorizontalScalePath` - the sidebar inset change enters the presentation lifecycle and scales
   (no separate transition path).

Source/structure guards:
8. `noEngineResolvePerFrameDuringLiveResize` - host `layout()` while `inLiveResize` does not call the
   resolve/content-size path (only the transform).
9. `timelineBodyDoesNotRecomputeLibraryPerGeometry` - `filteredSections`/`flatMap(\.items)`/`dateMarkers` are
   hoisted out of `TimelineView.body` (computed on a `sections`/`filter` change, not on every geometry eval).
10. `synchronousDrawDuringResize` - the gesture path presents from `layout()` without waiting for async redraw
    coalescing.

Forbidden regressions (must stay green): all pinch/scroll/binding-echo suites; fixed-column fill-width + seam
invariants; pure-height-resize-changes-no-width-metric.

QA matrix (manual, after build): left edge, right edge, top edge, bottom edge, all four corners, sidebar
open/close, fast drag, drag while thumbnails still stream - each must be smooth, no rubber-band, no blank, no
gutter, no pop; settle instant; pinch/click zoom unaffected.

## 7. Phasing (each independently testable + QA-able)

1. **Snapshot + horizontal scale** (the headline win): start/settle lifecycle, captured slots, uniform scale about
   the stationary edge. Proves the surface-transform model + kills the horizontal stutter.
2. **Vertical clip/reveal + counter-scroll** via canvas translate (reuses the lifecycle + the engine anchor).
3. **Corner** = compose 1+2.
4. **Sidebar** routed through the same lifecycle (driven by the 0.22s animation).
5. **Shell de-cost:** gate `updateNSView` on `inLiveResize`; hoist the `TimelineView.body` library work; measure;
   apply the `GridTopFrost`-suspend lever only if QA still needs it.

## 8. Residual open items
- Overscan budget remains a tuning lever for extreme drags beyond the captured slot snapshot.
- The gap scales visually during the drag because the captured slot rects are uniformly scaled; the settled grid
  restores the level's constant gap on release. The fixed-column guard avoids animating that tiny gap delta as a
  fake reflow.
