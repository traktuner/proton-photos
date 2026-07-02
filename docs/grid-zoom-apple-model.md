# Observed Apple Grid Zoom Model (macOS Photos)

> **Status: REFERENCE (observations current; §E mapping historical).** Sections A–D (the frame-by-frame Apple observations) remain valid reference material. The §E mapping onto the ProtonPhotos engine predates the shipped `GridZoomTransaction` live-zoom model - see [grid-zoom-transaction.md](grid-zoom-transaction.md) and `SquareTileGridEngine.zoomFramePlan` for the current implementation.

Derived **frame-by-frame** from two Apple Photos screen recordings (German locale, macOS 26),
both with a **stable window** - only the in-grid zoom changes:

- `foto-zoom-apple.mov` - full **sweep**: largest aspect level → densest square overview → back. 654 frames @120fps.
- `grid zoom.mov` - **near toggle**: repeated switch between the *second-to-last* and *last* (largest) levels. 567 frames.

Motion-signal segmentation (consecutive-frame diff) located the stable plateaus (detents) vs. the active
transitions; clean plateau frames + dense filmstrips + vertical/horizontal strips were read to derive the
behavior below. This is observed, not assumed.

---

## A. Zoom detent model

Apple uses a **small set of discrete logical levels (detents)**. A pinch glides *through* them; on release it
**snaps to the nearest** one. Two distinct **layout families**:

| Family | Cells | Gap | Crop | Where |
|---|---|---|---|---|
| **Aspect** (near/large) | variable-aspect cells, justified rows (uniform row-height, widths = photo aspect) | visible gap | no crop, no letterbox | the larger / "detail" levels - incl. the last two levels in `grid zoom.mov` (~5 and ~6 columns) |
| **Square** (dense/far) | uniform square tiles | ~0 gap (tight mosaic) | center-crop to square | the dense "overview" levels (month/year labels appear), ~14→~30 columns |

Observed column counts at the extremes (Apple window width): largest aspect ≈ **5 cols**; near-toggle pair ≈
**6 ↔ 5 cols** (Δ = **1 column**); densest square ≈ **20–30 cols**. The top aspect detents are spaced **one
column apart** - this is *why* the near transition is so calm (small reflow).

> **Base-layout caveat for ProtonPhotos:** Apple's aspect levels use **justified, variable-aspect cells with
> no letterbox bars**. ProtonPhotos' current grid uses **uniform square cells with `aspectFit` letterbox**
> (the photo centered with bars). That is a *base-layout* difference, independent of the zoom transitions in
> this pass. Flagged as the top remaining visual gap; see the report.

---

## B. Transition model (between adjacent detents)

There are exactly **two transition families**, plus a degenerate one:

### B1. Aspect ↔ Aspect (adjacent, small Δcolumns): **focus-preserving per-slot crossfade**
- Thumbnails **geometrically scale** (grow/shrink) anchored at the cursor. Verified in the near vertical-strip:
  the focus-column photos (including the selected, blue-outlined one) are the **same identities, just growing** -
  **no vertical sliding, no photo travels into another slot**.
- Because column count changes by 1, rows must re-wrap. Apple does **not** slide tiles. Instead each **screen
  slot cross-dissolves its content in place** from the old item to the new item.
- **The chronological "slip" at a slot ≈ (its row-distance from the anchor row) × Δcolumns.** So:
  - the **anchor row barely changes** (slip < 1 row) → reads as *static*;
  - rows farther from the anchor change more → visible in-place crossfade to the chronologically-correct photo.
- This is the logic the user asked to characterize: **the focus row is held; above/below, individual photos are
  crossfaded in place to restore correct chronological order for the new column count.**

### B2. Family change (Aspect ↔ Square) and dense Square ↔ Square (large Δcolumns): **full-grid crossfade / whoosh**
- When the *whole* layout changes (aspect+gaps → square-no-gap, or a big column jump), Apple does a **short,
  simultaneous crossfade over the entire grid** (verified: sweep frame ~235 shows both families overlapping at
  once; the sec-3/4 peaks are global). Reads as one continuous photo wall changing density - not per-photo motion.

### B3. Same columns, size-only: **geometric scale only** (degenerate; rarely hit).

**Key unifying insight:** B1 and B2 are the *same mechanism* with a different alpha policy. Render the **source
topology and target topology both anchored at the same world point and scaled to one shared apparent cell
size**, then cross-dissolve:
- near the anchor the two topologies show ~the same photos at ~the same place → crossfade is invisible (static);
- far from the anchor they differ → crossfade is visible (replacement);
- when the crop family differs, even the anchor changes appearance → reads as a whoosh.
The family is just **how the per-slot alpha is weighted by focus-distance** (B1 = focus protected, B2 = global).

---

## C. Anchor model

- The anchor is the **cursor position** (content point under the pointer at gesture start); for the +/− buttons,
  the **viewport center**.
- The **row under the cursor stays visually stable**: same photos, same place, only scaling. The **exact item
  under the cursor does not become a different photo** during the gesture.
- On release, snap to the nearest detent (velocity-biased); the result still reads as having zoomed into/out of
  the **same anchored region**. Settle continues the scale to land *exactly* on the detent - **no topology pop**.

---

## D. Forbidden behaviors (seen in prior ProtonPhotos attempts, NOT in Apple)

Never produce: rectangular viewport patch/box · old grid framed by a new grid · per-photo flying · jumps to
unrelated photos · ghost lattice/wall · black gaps / missing surface · a visible topology snap on release ·
hiding bad transitions behind blur/opacity only.

---

## E. Mapping onto the ProtonPhotos Metal production grid

The new Metal grid (`MetalGrid*`) already provides the foundation:
- `MetalGridLayout` - pure square-grid math (`metrics`, `frame`, `visibleCells`), per level from
  `JustifiedCollectionLayout.levels`.
- Shader supports **per-quad `alpha` + arbitrary `rect`** → crossfade + scale need **no shader change**.
- `MetalGridCoordinator.draw()` builds per-cell quads; `CADisplayLink` ticker can drive the animation.
- `MetalGridScrollHost.handleMagnify` currently fires **one discrete step** per pinch - to be replaced by
  continuous progress + snap-on-release.

### Detent ladder (seeded from the existing 6 levels; data-driven, easy to retune)
`JustifiedCollectionLayout.levels`: sizes 330/185/130/95 (`aspectFit`), 70/44 (`squareFill`, month labels).

### Transition matrix (per adjacent pair)
| Pair | cropMode | family |
|---|---|---|
| 0↔1, 1↔2, 2↔3 | aspectFit→aspectFit | **focusPreservingReplacement** (B1) |
| 3↔4 | aspectFit→squareFill | **squareToAspectWhoosh** (B2) |
| 4↔5 | squareFill→squareFill | **fullGridCrossfade** (B2) |

### Architecture (pure, testable core + thin Metal integration)
- `GridZoomDetent` / `GridZoomDetentModel` - fixed detents, neighbors, **snap** logic.
- `GridZoomTransitionPolicy` - adjacent pair → transition family.
- `GridZoomTransitionPlan` - source detent, target detent, progress, anchor, family + **per-slot
  (sourceAlpha, targetAlpha)** from focus-weight, and the **two-surface anchor-aligned scale transform**.
- Metal: when a transition is active, `draw()` composites **two anchor-aligned scaled surfaces** with per-quad
  crossfade alpha instead of the single-layout pass. Scroll frozen during the gesture; commit level + re-anchor
  scroll on settle (reusing `setLevel`'s anchor logic). Debug logs `[GridDetent] [GridAnchor] [GridTransition]
  [GridSettle]` + optional overlay.

### Invariants (enforced by tests)
Two known topologies only (never per-frame arbitrary reflow) · within a surface a slot's **item identity is
fixed** across progress (no oldRect→newRect travel of a different item) · both surfaces map the **anchor content
point to the same screen point** at every progress · snapped settle lands apparent size exactly on the detent.
