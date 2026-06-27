# MetalGrid Engine Contract

**Status: ENGINE CONTRACT, subordinate to product parity.** This document describes the production photo-grid
architecture on macOS. It is a *contract*, not a tutorial: each section states who owns what and what is
forbidden. The boundaries below are enforced by `MetalGridContractGuardTests` (and the older
`GridCanonicalGuardTests` / `LegacyGridRemovalGuardTests`). Change the contract -> update both this doc and the
guard tests in the same PR.

Product-level Apple Photos parity is defined in
[`apple-photos-parity-master-spec.md`](apple-photos-parity-master-spec.md). If this engine contract conflicts
with observed Apple Photos behavior or the master spec, this contract is stale and must be changed. Architecture
follows Apple behavior, not the other way around.

> Historical note: behavior was once accepted as of the `grid: 6-level model, aspect/square toggle, uniform
> background, viewport-resize camera + perf` commit. Later Apple reference analysis may supersede parts of this
> contract, especially resize and zoom-level semantics.

---

## 1. Current architecture

The production timeline grid is **MetalGrid only**. There is no NSCollectionView grid, no `PhotoGridView`, no
justified/aspect-row layout, and no detent/`GridZoomMath` path. One `MTKView` renders the whole grid; an
overlaid transparent `NSScrollView` document spacer provides physics + pointer events.

| Component | File | Role |
|---|---|---|
| `SquareTileGridEngine` | `SquareTileGridEngine.swift` | Pure value type. **All** outer grid geometry. |
| `GridZoomTransaction` | `GridZoomTransaction.swift` | Live pinch zoom / cursor-anchor transaction. |
| `GridViewportResizeRebase` | `GridViewportResizeRebase.swift` | Window/sidebar resize camera rebase (pure). |
| `TileContentFitter` | `TileContentFitter.swift` | How media fits **inside** a square slot (content only). |
| `MetalGridCoordinator` | `MetalGridCoordinator.swift` | Composes engine geometry + textures + fitting; owns camera state (level, committed phase). |
| `MetalGridRenderer` | `MetalGridRenderer.swift` | Draws the quads it is handed. No layout math. |
| `MetalGridScrollHost` | `MetalGridScrollHost.swift` | AppKit host: scroll physics, gesture intake, resize entry, calls the engine helpers. |
| `MetalGridPalette` | `MetalGridPalette.swift` | The single uniform grid surface colour. |

---

## 2. Responsibility boundaries (ownership)

**`SquareTileGridEngine` owns:** level specs · `nominalColumns` · `gap` · `slotSide` calculation · `pitch` ·
`columns` · `contentSize` · section/flat item mapping · `visibleSlots` · hit testing · anchor-item resolution ·
committed column phase math · settled `GridFramePlan`.

**`GridZoomTransaction` owns:** the live zoom transaction · cursor anchor · focus row/band behaviour ·
source→target level transition topology · keeping the item under the cursor pinned · (via the host/coordinator)
the viewport-centre anchor for `+/−` zoom.

**`GridViewportResizeRebase` owns:** window-resize rebase · sidebar show/hide rebase · the normalized
viewport-anchor (`anchorFractionY`, 0.5) rebase · bottom-pinned preservation · the scrollY that makes the
**first frame after a resize** already correct.

**`TileContentFitter` owns:** `aspectFitInsideSquare` · `squareFillCrop` · `contentRect` (always inside
`slotRect`) · the UV/crop window / letterbox. It **never** produces or alters `slotRect`.

**`MetalGridRenderer` owns:** drawing supplied quads · the clear/background colour · placeholders · overlays.
It performs **no** layout math and never sees media aspect ratio.

---

## 3. Data flow

```
Timeline data (PhotoItem…)
   → MetalGridDataSource         (flatUIDs + sectionCounts; production flattens to ONE continuous section)
   → SquareTileGridEngine        (resolve geometry for level + width + committed phase)
   → GridFramePlan               (visible square slots in content space, contentSize, headers)
   → MetalGridCoordinator        (map slot → viewport rect; fit media via TileContentFitter; bind textures)
   → MetalGridRenderer           (draw the quads)
```

Live zoom and resize are *camera* transforms layered on this flow:
- **Live pinch** swaps the settled `GridFramePlan` for a `GridZoomTransaction` frame (engine-owned) until commit.
- **Resize/sidebar** recomputes the scrollY via `GridViewportResizeRebase` before the next frame; the data flow
  is otherwise unchanged.

---

## 4. `slotRect` vs `contentRect`

- **`slotRect`** — the OUTER cell. **Always square.** Produced **only** by `SquareTileGridEngine`. It is the
  single authority for layout, hit testing, selection, visible queries, content size, zoom anchor, and column
  phase. It is **independent of media aspect ratio**.
- **`contentRect` / UV** — where the photo/video draws *inside* the square slot. Produced **only** by
  `TileContentFitter`. May depend on media aspect ratio. **Always contained inside `slotRect`.** Changing it
  (or the content mode) must never change `slotRect`, columns, gap, pitch, content size, hit testing, visible
  slots, or anchor behaviour.

---

## 5. The six zoom levels

Exactly **six** Apple-like levels (`SquareTileGridEngine.appleLevelSpecs`), keyed by density:

| Level | nominalColumns | gap | content modes | labels | transition→next |
|---|---|---|---|---|---|
| L0 | 3 | 16 | aspectFit + squareFill | – | focusRowRelayout |
| L1 | 5 | 12 | aspectFit + squareFill | – | focusRowRelayout |
| L2 | 7 | 10 | aspectFit + squareFill | – | focusRowRelayout |
| L3 | 9 | 8 | aspectFit + squareFill | – | overviewWarp |
| L4 | 20 | 2 | **squareFill only** | month | denseOverviewZoom |
| L5 | 30 | 1 | **squareFill only** | year/month | – |

L3 is the default density. L0–L3 are normal photo levels; L4–L5 are dense square overviews. `transitionKindToNext`
is **stored classification only** — no transition effect is implemented yet.

---

## 6. The nominalColumns model (resolution independence)

A level is a **density**, not a fixed pixel size. `slotSide` is derived from the level's `nominalColumns` and
the current width:

```
slotSide = (availableGridWidth − gap · (nominalColumns − 1)) / nominalColumns
pitch    = slotSide + gap
```

Consequence: a wider viewport keeps the **same column count** and makes tiles **physically larger** (viewport
height only changes how many rows are visible). The settled resolve passes `nominalColumns` directly
(`fixedColumns`) so column counts are exact and never float-truncate.

---

## 7. The aspect/square toggle is content fitting only

The toolbar toggle switches `TileContentDisplayMode` between `aspectFitInsideSquare` (full media letterboxed
inside the square) and `squareFillCrop` (fill + centre-crop). It is a **`TileContentFitter` mode switch**, not a
layout switch. It changes only `contentRect`/UV — never `slotRect`, columns, gap, pitch, content size, hit
testing, visible slots, anchor, or phase. Availability: L0–L3 support both; **L4–L5 force `squareFillCrop`**.
Default preference = `aspectFitInsideSquare`. There is **no** aspect-row / justified outer layout.

---

## 8. Cursor-anchor zoom rule (trackpad pinch)

A trackpad pinch anchors on the **item under the cursor**. `beginZoomTransaction` resolves the anchor in the
*displayed* grid (i.e. with the current committed phase), so the photo under the cursor stays under the cursor
through begin → live frames → commit → first settled frame. The commit lands that item in the cursor's column
(cursor-aligned phase) so it does not fly horizontally on release.

## 9. `+/−` viewport-center zoom rule

Toolbar/keyboard `+/−` anchor on the **item at the grid viewport centre** (`bounds.width/2, origin.y + vh/2`) —
**never** the toolbar-button mouse location, a stale hover point, or the viewport top. Resolved with the current
committed phase, like the pinch.

## 10. Resize / sidebar rebase rule

Resize is **not** zoom. A window resize or sidebar toggle keeps the same level / phase / content mode /
nominalColumns / gap; only `slotSide` (→ pitch, content height) is recomputed from the new **width**. The scroll
is rebased via `GridViewportResizeRebase` to preserve the content at a **normalized viewport anchor**
(`anchorFractionY = 0.5`, centre) — a continuous camera rebase, not a rigid one-edge pin. Bottom-pinned grids
stay bottom-pinned. A **manual window resize detaches the bottom-pin** (`willStartLiveResize` →
`stickToBottom = false`) so the rebase runs even on a freshly-opened grid. The first frame after the resize
already uses the rebased scrollY (no late jump). Resize must **never** start a `GridZoomTransaction`/commit
bridge, reuse raw scrollY after metrics change, or restore a stale scroll origin.

## 11. Production background / styling rule

The production grid is **one uniform Apple-like dark-gray surface** (`MetalGridPalette.background`, ~#1f1f1f),
used for the renderer clear colour, the host layer, and the inter-cell gaps. There are **no per-cell card
backgrounds** for resident images (a placeholder card is drawn only while an image is genuinely missing), **no
grid lines**, and **no debug tile colours** in production. `aspectFit` letterbox bands reveal the same surface.
The synthetic/debug path (`renderSyntheticSlots`) may use colours; production (`renderRealSlots`) must not.

---

## 12. Forbidden old paths

Production `TimelineFeature` source must **never** reintroduce any of:

- `PhotoGridView`, `PhotoGridItem`, the NSCollectionView grid, or an `MetalGrid`-disable fallback flag
- `JustifiedCollectionLayout` / justified or aspect-row **outer** layout
- `GridZoomMath`, `GridDetentLayout`, `GridZoomDetentModel`
- `sourcePlate` / `targetBackdrop` / `targetWall` / `exposedLeftRect` / edge-fill machinery
- computing **outer** slot geometry from media aspect ratio
- computing layout math in the renderer

---

## 13. Transition effects

Apple-style level-transition effects are **consumers** of the existing contract — they add NO geometry
ownership and cross NONE of the boundaries above.

**Inputs an effect may consume:** the source `GridFramePlan`, the target `GridFramePlan`, the
`GridZoomTransaction` focus row/frame, and the level `transitionKind` (`focusRowRelayout` / `overviewWarp` /
`denseOverviewZoom`).

**An effect may:** in-place fade/crossfade per cell · target-slot fade-in · source-slot fade-out · an overview
"warp" for L3→L4 · a dense-overview transition for L4→L5.

**An effect must NOT:** animate a thumbnail *identity* flying from its old slot to a new slot · reintroduce
`sourcePlate`/`targetBackdrop` · compute any geometry in the renderer · derive outer rects from media aspect
ratio · change the engine/fitter/resize ownership boundaries above.

### 13.1 Implemented: normal-level `focusRowRelayout` crossfade (L0↔L1↔L2↔L3)

The FIRST effect ships: `GridNormalZoomVisualPlanner` (`GridNormalZoomVisualPlan.swift`) — a **pure**,
AppKit-free planner that turns a discrete +/- step between adjacent NORMAL levels into an Apple-like crossfade.

- **Trigger:** the discrete +/- (toolbar/keyboard) path only, in the non-bottom-pinned state, gated by
  `MetalGridFocusRowTransitionFlag` (default ON; flip via `MetalGrid.focusRowTransition`). The continuous
  trackpad pinch (already an anchored uniform scale via `GridZoomTransaction`) is untouched. The committed
  level/scroll/phase are set SYNCHRONOUSLY exactly as before — the crossfade is a transient visual overlay, so
  the settled end-state is byte-identical to the prior snap.
- **Model (verified against Apple Photos macOS):** the focus band (the anchor's row, from the live
  `GridZoomTransaction`) holds identity-stable + anchored under the cursor (it *scales* in place, never flies);
  zoom-out fades NEW side neighbours IN, zoom-in fades outer neighbours OUT; outside the focus band, regions
  crossfade by spatial overlap (target-only → fade-in, source-only → fade-out, occupant-change → replacement
  crossfade). **Every tile's rect is taken VERBATIM from the source plan / target plan / transaction frame —
  never a fresh `lerp(oldRect, newRect)`.** A UID may appear in two places mid-crossfade (its source rect
  fading out + its target rect fading in); after the transition each UID appears only where the target says.
- **Boundaries honoured:** the planner computes no slotSide/gap/pitch/columns/contentSize, does no hit-testing,
  and never calls `TileContentFitter` — so the aspect/square toggle cannot change a single transition rect,
  alpha, role, or the focus band. Content fitting + per-tile `alpha` stay in the renderer
  (`MetalGridCoordinator.renderTransitionTiles`, reusing the existing `MetalGridQuad.alpha`). Diagnostics:
  `[GridTransition]` (begin/frame/end) with `flyingIdentityDetected` / `maxIdentityMovementPx`.
- **Guards:** `FocusRowRelayoutTransitionTests` (no-fly, focus-anchor-stable, zoom-in-drops / zoom-out-adds
  neighbours, target/source fade, replacement crossfade, focus-replacement-suppressed, content-mode geometry
  invariance, engine-geometry-only, overview-kinds-refused).

**Still future / NOT implemented:** the overview transitions `overviewWarp` (L3→L4) and `denseOverviewZoom`
(L4→L5). The normal planner explicitly REFUSES them (returns an empty, `handled == false` plan) so an overview
step can never accidentally use the normal crossfade.
