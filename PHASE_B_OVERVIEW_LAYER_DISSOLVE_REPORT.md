# PHASE_B_OVERVIEW_LAYER_DISSOLVE_REPORT

**Date:** 2026-06-25 · **Worktree/branch:** `ProtonPhotos-phaseb-spike` @ `phaseb-pinch071-clickv2-420`
**Flag:** `MetalGrid.singleLatticeTransition` (default OFF) · See also `PHASE_B_OVERVIEW_REJECTION_ANALYSIS.md`, `PHASE_B_OVERVIEW_WARP_FORENSICS.md`

> **V3.10 overview warp is REJECTED and removed.** It is replaced by the **Overview Layer Dissolve**: two
> complete settled grid layers blended by opacity via an **offscreen compositor** (now implemented, approved
> 2026-06-25). The correct linear mix is proven by math tests; the rejected single-pass background-bleed is
> proven absent. Flag-gated, L0–L3 untouched. **Pending user visual QA.**

## 0. Status (2026-06-25, updated): IMPLEMENTED
- Rejected warp routing **removed**; overview no longer runs `GridTransitionController`.
- New `OverviewLayerDissolvePlan` model (two settled plans + opacity) + **offscreen two-layer compositor** in `MetalGridRenderer` (`renderLayerDissolve` → render source→texA, target→texB, then `mix(A,B,ease(q))`).
- Live **pinch** across L3↔L4 / L4↔L5 routes to `PinchMode.overviewDissolve`. **Click** overview left unchanged (instant snap) — documented below.
- 9 deterministic tests incl. the math proof of "no `(1−q)²` darkening / no background bleed". Full suite **303 pass**. App rebuilt.

## 1. What was removed/disabled from the rejected V3.10

The rejected path reused the normal-level relocation machinery for overview (root cause of the fragmentation/black-holes, see rejection analysis). **All of it is removed** from the source; overview no longer runs the `GridTransitionController` path:

- `MetalGridCoordinator`: removed `overviewWarpActive` + `onOverviewWarpStateChanged`; removed `tryBeginOverviewWarp(...)`; reverted `tryBeginClickTransition` to `focusRowRelayout`-only; reverted `renderTransitionDraws` to `effectiveDisplayMode` (no global square force); reverted `endPinchTransition` + the click-settle reset.
- `MetalGridScrollHost`: removed `PinchMode.overviewWarp` + its state; reverted `driveLivePinch` routing to `else → .reflow`; removed `driveOverviewWarp`/`advanceOverviewWarpSettle`/`commitOverviewWarp`; reverted `endLivePinch`/`step()`/`finishInFlightPinchSettle`.
- `MetalGridHeaderRenderer` / `MetalProductionGridView`: reverted the label-hide gate + the callback wiring.
- Tests: deleted `OverviewWarpTests.swift`.

**Net effect:** overview boundaries (L3↔L4, L4↔L5) revert to the pre-V3.10 **legacy reflow** (the original baseline) until the layer dissolve renderer lands. The accepted **V3.7 click** and **V3.9 L0–L3 pinch** paths are byte-for-byte unchanged. The previous report (`PHASE_B_OVERVIEW_WARP_REPORT.md`) is banner-marked REJECTED.

Kept (harmless, reused by the new model): the engine predicates `adjacentTransitionKind` / `isOverviewBoundary`.

## 2. The exact new overview layer model — `OverviewLayerDissolve.swift`

`OverviewLayerDissolvePlan` (immutable; built **once** at gesture start):

| Field | Meaning |
|---|---|
| `sourceLevel`, `targetLevel` | adjacent overview-boundary levels |
| `source: GridFramePlan` | the **complete settled** source grid (its own scroll + display mode) |
| `target: GridFramePlan` | the **complete settled** target grid, in **final positions** (anchored scroll) |
| `sourceDisplayMode` | the source's own mode — **NOT** forced square |
| `targetDisplayMode` | `squareFillCrop` (overview is square-only) |
| `targetScrollY`, `targetColumnPhase` | target commit info |
| `q` | dissolve progress: 0 = pure source, 1 = pure target |

`sourceOpacity = 1 − ease(q)`, `targetOpacity = ease(q)` (smootherstep). `withProgress(q)` changes **only** the blend — both rasters and modes are fixed, so **the target is in its final positions at every q**. Built by the pure `SquareTileGridEngine.overviewLayerDissolvePlan(from:to:…)` from two settled `framePlan`s + the engine's anchor math. **No `GridTransitionComponentBuilder`, no relocation, no entry/exit, no identity handoff** (enforced by a guard test).

This is a **layer/raster dissolve, not a slot handoff**: rendering draws every visible source slot from `source` and every visible target slot from `target`, blended by opacity. A source cell and a target cell never share identity.

## 3. Renderer — offscreen compositing is REQUIRED (proven) and now IMPLEMENTED.

The desired blend is `out = A·(1−q) + B·q`, where `A` = source-layer-over-bg and `B` = target-layer-over-bg (both include the uniform dark background in their gaps/letterbox).

The current renderer (`MetalGridRenderer`) is **single-pass premultiplied source-over to one drawable**, cleared to the background (`sourceRGB=.one`, `destRGB=.oneMinusSourceAlpha`). Compositing the two layers **sequentially** into that one framebuffer gives, in any region covered by both layers:

```
out = tgt·q + src·(1−q)² + bg·q(1−q)      (NOT  src·(1−q) + tgt·q)
```

i.e. the source is under-weighted by a factor (1−q) — a **background-bleed darkening that peaks at q=0.5** (`0.25·src + 0.5·tgt + 0.25·bg` instead of `0.5·src + 0.5·tgt`). No ordering of source-over passes over a *shared* framebuffer can reproduce `A·(1−q)+B·q` for **partially-covered** layers — independent compositing of each layer is mathematically required. (This is the exact premultiplied-alpha artifact the existing per-slot code avoids with its "opaque source base + target at alpha lp" trick — which only works when source and target occupy the **same** cell, which a two-different-layout layer dissolve does not.)

**Therefore a correct, artifact-free, direction-symmetric layer dissolve needs OFFSCREEN render textures.** Implemented exactly as the math requires:

- `MetalGridRenderer.renderLayerDissolve(in:viewportSize:sourceGroups:targetGroups:t:)`:
  1. lazily create/reuse two `MTLTexture`s (`bgra8Unorm`, `[.renderTarget,.shaderRead]`, `.private`), drawable-sized; recreate on size change (`ensureLayerTextures`).
  2. pass 1 → texA: clear bg, draw `sourceGroups` (source display mode) — `encodeLayerPass`.
  3. pass 2 → texB: clear bg, draw `targetGroups` (square).
  4. pass 3 → drawable: fullscreen triangle, `out = mix(texA, texB, t)` where `t = ease(q)` (new `metalGridComposite*` shaders, opaque pipeline, blending disabled).
- Because each layer is composited over the bg **independently** before the mix, the result is exactly `A·(1−t)+B·t` — **no `(1−t)²` term, no background bleed**. The bg clear is opaque (`MetalGridPalette.clearColor` α=1), so each layer texture is opaque and `mix` on `.rgb` is exact.
- The normal `render(...)` path is **untouched** — it now shares the extracted `configure`/`encode` helpers (same Metal calls in the same order), and the offscreen textures/passes run **only** during a dissolve. So normal renderer performance/behavior is unaffected (constraint satisfied). Cost: ~2× drawable texture memory (lazy, after first overview pinch); 3 passes only during the transient gesture.

### Wiring
- Live **pinch**: `PinchMode.overviewDissolve` in `MetalGridScrollHost` — the overview-boundary `else` branch now calls `coordinator.beginOverviewDissolve(...)`; `q` maps from pinch magnitude; release runs a 0.16 s linear settle to the nearer endpoint, then `commitOverviewDissolve(toTarget:)`. The accepted `.lattice` (L0–L3) routing is untouched.
- `MetalGridCoordinator`: `overviewDissolve` plan state; `beginOverviewDissolve` / `setOverviewDissolveProgress` / `commitOverviewDissolve`; `drawOverviewDissolve` builds each layer's groups via the shared `buildRealGroups(…, displayMode:)` and calls `renderLayerDissolve`. A top-of-`draw(in:)` branch renders the dissolve and returns.
- **Click** overview (+/−): left unchanged for now (instant snap to the target level) — documented; the dissolve plan/compositor could drive it later with click timing if wanted.

## 4. Files changed
- `MetalGridRenderer.swift` — extracted `configure`/`encode` helpers (normal `render` unchanged); added `compositePipeline`, `layerA/B`, `ensureLayerTextures`, `encodeLayerPass`, `renderLayerDissolve`, and the `metalGridComposite{Vertex,Fragment}` shaders.
- `MetalGridCoordinator.swift` — `overviewDissolve` state; `beginOverviewDissolve`/`setOverviewDissolveProgress`/`commitOverviewDissolve`/`drawOverviewDissolve`; extracted `buildRealGroups(…, displayMode:)` from `renderRealSlots`; top-of-`draw` dissolve branch.
- `MetalGridScrollHost.swift` — `PinchMode.overviewDissolve` + state; overview routing in `driveLivePinch`; `driveOverviewDissolve`/`advanceOverviewDissolveSettle`/`commitOverviewDissolve`; `endLivePinch`/`step()`/`finishInFlightPinchSettle` handle the mode.
- `OverviewLayerDissolve.swift` — `OverviewLayerDissolvePlan` + `engine.overviewLayerDissolvePlan(...)` + `overviewDissolveEase` + pure `overviewDissolveMix` / `overviewDissolveSinglePassBleed` (for the math proof).
- `SquareTileGridEngine.swift` — kept predicates `adjacentTransitionKind` / `isOverviewBoundary`.
- Tests: **new** `OverviewLayerDissolveTests.swift` (9); **deleted** `OverviewWarpTests.swift`; updated `GridBackgroundStyleTests` guards #2/#4 to scan the extracted `buildRealGroups` (intent unchanged).
- The rejected-warp routing was already removed (Phase B) from the coordinator/host/header/view.

## 5. Tests (9) + results
`OverviewLayerDissolveTests`: builds only for overview boundaries; **plans stable across q**; **target positions final at every q**; **source keeps its mode, target square**; opacity endpoints + complementarity; **`mix` is linear with no background term**; **mid-fade has no `(1−q)²` darkening vs the single-pass bleed formula**; **renderer uses offscreen + linear `mix`**; **no relocation machinery**.

```
swift build --target TimelineFeature        → complete
swift test  --filter TimelineFeatureTests   → 303 tests / 39 suites PASSED
```
Accepted V3.7 click + V3.9 L0–L3 pinch suites remain green.

## 6. App rebuild
Rebuilt + installed + launched `/Applications/ProtonPhotos.app` (flag ON for QA). The offscreen overview layer dissolve is live on the pinch path.

## 7. Visual QA checklist
1. **Overview pinch out (L3→L4):** the source grid should **dissolve into the already-laid-out square overview** — a clean opacity crossfade, **no fragmentation, no black holes, no reorder**. Mid-fade should NOT darken toward the background.
2. **L4↔L5** both directions, and **L5→L4 / L4→L3** zoom-in: same clean dissolve.
3. **Source not square-cropped:** while zooming OUT, the fading source (normal level) keeps its aspect/letterbox look (if your content-mode preference is aspect); only the target is square.
4. **Release mid-pinch:** settles to the nearer end (source or target) without a hard snap/flash.
5. **L0–L3 pinch + +/− click:** confirm **unchanged** (accepted V3.9/V3.7). +/- across the overview boundary is an instant snap (click dissolve not wired — by design).
6. Flag OFF (`defaults write me.protonphotos.mac MetalGrid.singleLatticeTransition -bool NO`, relaunch): overview reverts to the legacy reflow; everything else unchanged.

## 8b. V3.12 — bottom-pin / clamp fix (2026-06-25)

**Defect:** at the bottom of the library, zooming out into L4/L5 looked good during the dissolve but the grid **jumped downward at settle**. Cause: the target layer was built from the **raw anchored** `targetScrollY`, while the settled render clamps/bottom-fills — so the dissolve target and the committed target used different scrolls.

**Rule (in `engine.overviewLayerDissolvePlan`, applied BEFORE building `targetPlan` and storing it):**
```
viewportH      = viewportSize.height
sourceMaxY     = max(0, contentSize(sourceLevel, phase: sourcePhase).height − viewportH)
targetMaxY     = max(0, contentSize(targetLevel, phase: targetPhase).height − viewportH)
bottomPinned   = abs(sourceScrollY − sourceMaxY) ≤ 1.0          // ~the settled scroll-clamp tolerance
targetScrollY  = bottomPinned ? targetMaxY
                              : min(max(0, rawAnchoredTargetScrollY), targetMaxY)
```
- `targetMaxY` is `0` when the target content is shorter than the viewport ⇒ a short target settles at `0` (never stretched/faked).
- `targetPlan` is built from this final `targetScrollY`; `commitOverviewDissolve(toTarget:)` returns the **same** stored `targetScrollY` (`MetalGridCoordinator.swift:729`) ⇒ the dissolve target layer and the commit scroll are identical ⇒ no jump.
- Inference is deterministic in the engine (the host's `stickToBottom` is already cleared by gesture start); the epsilon mirrors the settled scroll-clamp behavior. Nothing else changed — compositor blend math, layer model, and L0–L3 paths are untouched.

**Tests (5, all green) — `OverviewLayerDissolveTests`:** `bottomPinnedSourceTargetsTargetBottom` (→ `targetMaxY`); `targetPlanBuiltFromCommitScroll` (target plan == settled plan rebuilt at `targetScrollY`); `rawTargetScrollIsClampedIntoBounds` (out-of-range → clamped, top anchor → ~0); `nonBottomPinnedDoesNotSnapToBottom` (mid anchor settles mid-content); `targetShorterThanViewportSettlesAtZero` (→ 0). Full suite **308 pass**.

## 8c. V3.13 — direction-aware anchor (cursor wins on pinch-in) (2026-06-25)

**Defect:** the V3.12 bottom-fill was unconditional, so **pinch-IN** from the overview (whose short content is usually bottom-pinned) was forced to the overview bottom → the zoom returned to the *old zoom-out origin* instead of the content under the cursor.

**Rule (direction-aware, in `engine.overviewLayerDissolvePlan`):**
```
isZoomingOut  = targetLevel > sourceLevel        // density ladder is monotonic ⇒ t>s ⟺ zoom out
targetScrollY = (isZoomingOut && sourceBottomPinned) ? targetMaxY
                                                     : clamp(rawCursorAnchoredScrollY, 0...targetMaxY)
```
- **Cursor anchoring always wins.** The target scroll keeps the cursor's item (resolved in the *source* overview grid) under the cursor, clamped to bounds; `targetColumnPhase` is derived from that same cursor anchor item.
- The **bottom-fill override is now zoom-OUT-only** — a direction-specific protection against the down-jump when zooming out from a truly bottom-pinned source (V3.12 preserved). It is **never** applied on pinch-in.
- Commit uses the same stored `targetScrollY` + `targetColumnPhase` as the dissolve layer (no snap). Direction is derived from the levels — the coordinator already passes the correct `source→target`, so no new parameter is threaded.

**Tests (5, all green):** `overviewPinchInUsesCursorAnchorNotBottomPin` (bottom-pinned L4→L3, top cursor ⇒ cursor-anchored, ≫ off the bottom); `overviewPinchOutFromBottomStillBottomFills` (L3→L4 bottom ⇒ `targetMaxY`); `overviewPinchInCommitMatchesDissolveEndpoint`; `overviewPinchInClampsOnlyWhenAnchorExceedsBounds` (interior stays anchored; last-item/top-cursor clamps); `nonBottomPinchInStaysAnchored`. Full suite **313 pass**.

## 8. Notes / follow-ups
- **Labels:** during the dissolve the month/year overlay behaves as the settled path leaves it (no special handling this pass); a per-progress label fade is still a follow-up if wanted.
- **Click overview** uses an instant snap (the dissolve is wired for pinch only).
- **Memory:** the two offscreen textures are ~2× the drawable, allocated lazily on first overview pinch.
- Final visual acceptance is yours.
