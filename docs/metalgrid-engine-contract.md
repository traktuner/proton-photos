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

> Historical note: the resize and zoom-level semantics in this contract were rewritten to match the
> fixed-columns-per-level + width-fill product model and the implemented resize-presentation / continuous-pinch
> systems (see §6, §10, §13). Earlier "adaptive columns" and "focusRowRelayout crossfade" framings are superseded.

---

## 1. Current architecture

The production timeline grid is **MetalGrid only**. There is no NSCollectionView grid, no `PhotoGridView`, no
justified/aspect-row layout, and no detent/`GridZoomMath` path. One `MTKView` renders the whole grid; an
overlaid transparent `NSScrollView` document spacer provides physics + pointer events.

| Component | File | Role |
|---|---|---|
| `SquareTileGridEngine` | `SquareTileGridEngine.swift` | Pure value type. **All** outer grid geometry. |
| `GridZoomTransaction` | `GridZoomTransaction.swift` | Live pinch zoom / cursor-anchor transaction. |
| `GridTransitionController` (+ `GridTransitionPlan`/`Scheduler`/`Component`) | `GridCore/GridTransition*.swift` | Integrated Phase-B single-lattice click+pinch transition (production default, no flag). |
| `PinchLiveZoomDriver` | `GridCore/PinchLiveZoomDriver.swift` | Continuous multi-level live-pinch scrub driver (chains across detents). |
| `OverviewLayerDissolve` | `OverviewLayerDissolve.swift` | L3↔L4 / L4↔L5 offscreen two-layer cross-dissolve. |
| `GridViewportResizeRebase` | `GridViewportResizeRebase.swift` | Resize/sidebar scroll rebase (pure) - the **settle/fallback** path under the presentation layer. |
| `TileContentFitter` | `TileContentFitter.swift` | How media fits **inside** a square slot (content only). |
| `GridTextureBudget` | `GridCore/GridTextureBudget.swift` | Portable texture budget shape; platform adapters inject concrete values. |
| `MetalGridCoordinator` | `MetalGridCoordinator.swift` | Composes engine geometry + textures + fitting; owns camera state (level, committed phase) **and the live resize/sidebar presentation layer** (snapshot-scale). |
| `MetalGridGlyphRasterizing` | `MetalGridTextureCore/MetalGridGlyphRasterizer.swift` | Platform-neutral badge glyph request contract; platform adapters inject native rasterizers. |
| `AppKitMetalGridGlyphRasterizer` | `MetalGridTextureAppKitAdapter/AppKitMetalGridGlyphRasterizer.swift` | macOS SF Symbol → `CGImage` badge rasterization injected into the texture cache. |
| `UIKitMetalGridGlyphRasterizer` | `MetalGridTextureUIKitAdapter/UIKitMetalGridGlyphRasterizer.swift` | iOS/iPadOS SF Symbol → `CGImage` badge rasterization adapter; not used by the macOS production host. |
| `UIKitMetalGridTexturePolicies` | `MetalGridTextureUIKitAdapter/UIKitMetalGridTexturePolicy.swift` | Conservative iOS-family texture-budget presets resolved from viewport surface class. |
| `UIKitMetalGridTextureCacheFactory` | `MetalGridTextureUIKitAdapter/UIKitMetalGridTextureCacheFactory.swift` | iOS/iPadOS cache assembly over the shared generic `MetalGridTextureCache<ID>`. |
| `MetalGridTextureCache<ID>` | `MetalGridTextureCore/MetalGridTextureCache.swift` | Generic per-item `MTLTexture` cache over `GridTextureResidencyPolicy<ID>`; the macOS coordinator binds `ID == PhotoUID`. |
| `MetalGridRenderer` | `MetalRenderingCore/MetalGridRenderer.swift` | Draws the quads it is handed. No layout math; `TimelineFeature` owns only the `MTKView` adapter extension. |
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

**`GridTextureBudget` owns:** the portable shape of texture streaming policy: upload burst, resident texture
capacity, and overscan fraction. Concrete defaults are platform-adapter policy, not Core behavior.
macOS keeps `MetalGridBudget.default` via `MetalGridTextureAppKitAdapter`; iOS/iPadOS starts from
`UIKitMetalGridTexturePolicies` until measured real-device tuning replaces or refines those values.

**`MetalGridTextureCache<ID>` owns:** real GPU texture residency, bounded per-frame upload from decoded `CGImage`,
placeholder texture lifetime, badge glyph texture caching, and byte/upload counters. It is generic over item
identity and must not import photo-domain packages. Platform adapters bind the ID type, provide decoded images,
inject concrete budgets, and inject glyph rasterizers.
The AppKit and UIKit adapter factories prove this assembly path without duplicating texture-cache logic.

**`MetalGridTextureCore` owns:** reusable Metal texture upload/cache code and the platform-neutral glyph request
contract. It may depend on `GridCore` policy and use `Metal`/`CoreGraphics`, but it must not own render command
encoding, MetalKit views, platform glyph implementations, photo IDs, media feeds, or platform budget defaults.

**`MetalGridGlyphRasterizing` owns:** the platform-specific conversion from a glyph request to a `CGImage`.
macOS uses `AppKitMetalGridGlyphRasterizer` from `MetalGridTextureAppKitAdapter`; iOS/iPadOS can use
`UIKitMetalGridGlyphRasterizer` from `MetalGridTextureUIKitAdapter`. `NSImage`/`UIImage` logic must stay in
platform adapters, not in the texture cache or renderer.

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

- **`slotRect`** - the OUTER cell. **Always square.** Produced **only** by `SquareTileGridEngine`. It is the
  single authority for layout, hit testing, selection, visible queries, content size, zoom anchor, and column
  phase. It is **independent of media aspect ratio**.
- **`contentRect` / UV** - where the photo/video draws *inside* the square slot. Produced **only** by
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
classifies each adjacent step (`focusRowRelayout` / `overviewWarp` / `denseOverviewZoom`) and is consumed live by
the integrated transition system: `focusRowRelayout` steps drive the single-lattice click/pinch transition, the
overview boundaries drive `OverviewLayerDissolve` (see §13.1). Production profiles do not need to duplicate this
classification in plist data: the loader derives it from adjacent level semantics and rejects explicit mismatches.

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
layout switch. It changes only `contentRect`/UV - never `slotRect`, columns, gap, pitch, content size, hit
testing, visible slots, anchor, or phase. Availability: L0–L3 support both; **L4–L5 force `squareFillCrop`**.
Default preference = `aspectFitInsideSquare`. There is **no** aspect-row / justified outer layout.

---

## 8. Cursor-anchor zoom rule (trackpad pinch)

A trackpad pinch anchors on the **item under the cursor**. `beginZoomTransaction` resolves the anchor in the
*displayed* grid (i.e. with the current committed phase), so the photo under the cursor stays under the cursor
through begin → live frames → commit → first settled frame. The commit lands that item in the cursor's column
(cursor-aligned phase) so it does not fly horizontally on release.

## 9. `+/−` viewport-center zoom rule

Toolbar/keyboard `+/−` anchor on the **item at the grid viewport centre** (`bounds.width/2, origin.y + vh/2`) -
**never** the toolbar-button mouse location, a stale hover point, or the viewport top. Resolved with the current
committed phase, like the pinch.

## 10. Resize / sidebar rebase rule

Resize is **not** zoom. A window resize or sidebar toggle keeps the same level / phase / content mode /
nominalColumns / gap. Because each level holds its **fixed** columns, a width change **scales the square slot to
fill the new width** (`slotSide = (width − gap·(cols−1))/cols`) - the column count never changes on resize (only
on a zoom); a height change clips/reveals rows.

**Primary live path - the presentation layer.** On gesture start the host (`windowWillLiveResize`, or a sidebar
inset change) calls `MetalGridCoordinator.beginPresentationResize` / `beginSidebarResize`, which snapshots the
resolved slot rects ONCE. Each tick `drawPresentationResize` / `drawSidebarResize` CPU-scales that snapshot about
the stationary edge (`presentationScaledRect` / `presentationScaledRectRightAnchored`), plus a vertical
counter-scroll for a pure-height drag - with **no per-frame engine resolve and no content-size callback** (both
frozen while `presentationResizeActive` / `isSidebarResizing`). (This is a CPU snapshot-scale of resolved rects,
NOT an offscreen MTLTexture canvas.) At SETTLE (`windowDidEndLiveResize` / `endPresentationResize`) the engine
re-resolves once and the scroll lands on `windowResizeReleaseScrollY` - the **resize anchor**: a bottom-pinned
grid keeps its last row at the viewport bottom, otherwise the centre item is re-centred. A **manual window resize
detaches the bottom-pin** (`stickToBottom = false`).

**Fallback path.** When the presentation cannot run (a zoom/commit transaction is in flight, a transition is
active, or there is no window yet), `MetalGridScrollHost.layout()` / `applyLeadingInsetChange` rebase the scroll
via `GridViewportResizeRebase` (`rebaseForResize`) to a **normalized viewport anchor** (`anchorFractionY = 0.5`),
preserving a bottom-pinned grid, so the first frame after the resize is already correct.

Resize must **never** start a `GridZoomTransaction` / commit bridge, reuse raw scrollY after `slotSide` changed,
or restore a stale scroll origin. Guarded by `GridResizePresentationTests` + `GridViewportResizeTests`.

## 11. Production background / styling rule

The production grid is **one uniform Apple-like dark-gray surface** (`MetalGridPalette.background`, ~#1f1f1f),
used for the renderer clear colour, the host layer, and the inter-cell gaps. There are **no per-cell card
backgrounds** for resident images (a placeholder card is drawn only while an image is genuinely missing), **no
grid lines**, and **no debug tile colours** in production. `aspectFit` letterbox bands reveal the same surface.
Production (`renderRealSlots`) must not use debug/tile colours. (The former synthetic/debug render path was removed.)

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

Apple-style level-transition effects are **consumers** of the existing contract - they add NO geometry
ownership and cross NONE of the boundaries above.

**Inputs an effect may consume:** the source `GridFramePlan`, the target `GridFramePlan`, the
`GridZoomTransaction` focus row/frame, and the level `transitionKind` (`focusRowRelayout` / `overviewWarp` /
`denseOverviewZoom`).

**An effect may:** in-place fade/crossfade per cell · target-slot fade-in · source-slot fade-out · an overview
"warp" for L3→L4 · a dense-overview transition for L4→L5.

**An effect must NOT:** animate a thumbnail *identity* flying from its old slot to a new slot · reintroduce
`sourcePlate`/`targetBackdrop` · compute any geometry in the renderer · derive outer rects from media aspect
ratio · change the engine/fitter/resize ownership boundaries above.

### 13.1 Implemented: the integrated normal-level transition (single-lattice click + continuous pinch)

The production normal-level transition (L0↔L1↔L2↔L3) is the **integrated Phase-B single-lattice** effect - the
production default with **no feature flag** (see `reports/archive/PHASE_B_GRID_EFFECTS_INTEGRATION.md`):

- **Click `+/-`** runs through `GridTransitionController` + the transition scheduler/component layer
  (`GridTransitionScheduler` / `GridTransitionComponentBuilder` / `GridTransitionPlan`) - a per-region
  source⇄target dissolve over a single presentation lattice; the committed level/scroll/phase are set
  synchronously, so the settled end-state is byte-identical to a plain snap.
- **Continuous trackpad pinch** runs `PinchLiveZoomDriver` - a host-driven progress scrub that chains across
  multiple normal detents in one gesture and commits the nearest detent on release. The seam closes because each
  detent's presentation frame is deterministic (prev-q=1 == next-q=0).
- The transition planner lives in `GridCore`. `TimelineFeature` owns only the macOS host/renderer plumbing:
  diagnostics injection, texture lookup, and conversion from `GridTransitionDraw` to Metal quads.
- Eligibility is gated to adjacent normal levels whose derived/stored `transitionKindToNext == .focusRowRelayout`
  (the `MetalGridCoordinator` chain-band logic); an ineligible / degenerate step falls back to a clean instant
  settle. The transition kind is semantic metadata of the two levels, not renderer-specific animation policy in the
  production plist.

The earlier `GridNormalZoomVisualPlanner` two-grid crossfade and its `MetalGrid.focusRowTransition` /
`MetalGrid.singleLatticeTransition` feature flags were **removed**; `ProductionRouteGuardTests` forbids them from
reappearing. `focusRowRelayout` now survives ONLY as the `transitionKindToNext` enum-case **classification**
consumed by the pinch chain-band logic - the *name* is live, the old crossfade *effect* is gone.

The overview boundaries (L3↔L4 / L4↔L5) run `OverviewLayerDissolve` (an offscreen two-layer cross-dissolve), not
the normal lattice. Effects honour the §13 boundaries: they compute no engine geometry and consume only plans.
