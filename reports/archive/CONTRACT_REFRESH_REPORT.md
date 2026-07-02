# Contract Refresh Report - 2026-06-28/29

Branch `perf-contract-cleanup-2026-06-28` (worktree), based on baseline `7707e61` off
`apple-normal-focusrow-transition`. No behavior change; comments/docs/tests only (+ 4 low-risk perf fixes, see
`PERFORMANCE_DEAD_CODE_AUDIT.md`).

## 1. The central contradiction found

The codebase described **three** mutually-exclusive grid resize models, scattered across code comments, docs, and
test names/assertions:

| Model | Where it was asserted | Verdict |
|---|---|---|
| **(A) Fixed-columns-per-level + width-FILL** - each level holds its `nominalColumns`; a resize SCALES the tile to fill the width; columns change only on zoom | `SquareTileGridEngine.resolvedForLevel` (the actual settled code, passes `fixedColumns: nominalColumns`); the GREEN test **assertions**; contract doc §6; coordinator resize-settle comments | **ACCEPTED (decided by user 2026-06-28)** |
| **(B) Adaptive round+fill** - column count adapts to width (round-to-nearest), tile "breathes" in a bounded band | engine header comments, `resolved()` comment, `GridSizePolicy`, several test **names/headers** (`...AddsColumns`, `...AdaptColumns`, `fillWidthAdaptiveColumnsGuard`), `GRID_SIZE_BASED_RESIZE_DESIGN.md` ("IMPLEMENTED"), master spec | **REJECTED** (superseded) |
| **(C) Constant photo size + trailing reveal margin** - fixed columns, fixed size, sub-column gutter, does-not-fill | engine header bullet, several test comments ("trailing reveal margin < one pitch") | **REJECTED** (we fill the width) |

The runtime + green assertions were always **(A)**. The drift was a large body of **(B)/(C)** *prose* - an
abandoned "size-based" migration (`referenceSlotSide` is admitted "ADDITIVE … no resolve reads it yet (Step 2
flips the kernel)"; Step 2 was never taken). The single executable truth - `resolvedForLevel` forcing
`fixedColumns: nominalColumns`, and every `GridSizeBasedResizeTests` assertion requiring `m.columns == nominal` -
was the tiebreaker, confirmed by the user's decision.

Confirmed by all four read-only auditors (comments/tests, architecture, both hot-path auditors, dead-code) and the
docs auditor; the contradiction was reproduced inside a single file (`resolved()` vs `resolvedForLevel()` comments)
and inside a single test file (`GridSizeBasedResizeTests` header vs its own assertions).

## 2. Final accepted contract

**FIXED-COLUMNS-PER-LEVEL + WIDTH-FILL.** Each of the six levels holds a fixed column count (3/5/7/9/20/30). The
square slot is sized to fill the viewport width exactly: `slotSide = (width − gap·(cols−1))/cols`. A window resize
or sidebar toggle **scales** the tile (wider window → larger tile, same columns) and **fills** the width (no
trailing gutter). The **column count changes only on a zoom**, never on a resize. Slots are square; media
aspect-fits inside the square (`aspectFitInsideSquare` default at L0–L3). The round rule `columnsForFixedSide`
survives but is used **only** by the live pinch over-zoom lattice (between detents / past the ends), never the
settled grid. A responsive size-class policy (`GridSizePolicy`) remains an **explicitly reserved, not-adopted**
future option.

Boundaries (verified clean, unchanged): engine = pure square geometry (`import CoreGraphics` only, value type);
renderer = draws supplied quads only; host = scroll/gesture/resize-sidebar lifecycle; coordinator = orchestration
+ the live resize/sidebar presentation layer; effects consume plans and never mutate engine geometry; search /
timeline derivation / cache / crypto do not depend on grid presentation.

## 3. Docs updated

- **`docs/metalgrid-engine-contract.md`** - §1 table (added the integrated transition system + presentation layer
  rows; demoted `GridViewportResizeRebase` to the settle/fallback role); §5 (transition kinds are consumed live,
  not "no effect implemented yet"); **§10 fully rewritten** (the snapshot-scale presentation layer is the primary
  live path, `windowResizeReleaseScrollY` settle anchor, `GridViewportResizeRebase` as the fallback);
  **§13.1 fully rewritten** (the removed `GridNormalZoomVisualPlanner` crossfade + its deleted flags replaced by
  the integrated Phase-B single-lattice/continuous-pinch + `OverviewLayerDissolve`); header historical note.
  **§6 was VERIFIED correct under fixed-columns and left unchanged.**
- **`docs/apple-photos-parity-master-spec.md`** - "Grid resize truth" rewritten to fixed-columns; removed the
  "previous fixed-column model is an implementation detail, not a product constraint" line; reframed the responsive
  policy as reserved-but-not-adopted; "Window resize truth" line corrected ("adapts columns discretely" → "scales
  the tile to fill at a constant column count").
- **`docs/grid-zoom-transaction.md`** - status `DESIGN ONLY / detent-only` → `IMPLEMENTED` (continuous pinch is the
  production default).
- **`GRID_SIZE_BASED_RESIZE_DESIGN.md`** - title + top banner mark it SUPERSEDED; the 2026-06-27 adaptive revision
  tagged `[REJECTED REVISION - kept for history]`; false "IMPLEMENTED" status corrected.
- **`RESIZE_PRESENTATION_LAYER_DESIGN.md`** - false "Status: … No implementation yet" → `IMPLEMENTED` (CPU
  snapshot-scale, not the offscreen-MTLTexture canvas it proposed); reconciliation banner (the resize holds columns,
  no width-threshold reflow); the false §5 "dirty diff is only round+fill + tests + this doc" line annotated stale.

## 4. Guard tests updated (names/comments → match fixed-columns assertions; assertions kept/strengthened)

- `MetalGridContractGuardTests`: `fillWidthAdaptiveColumnsGuard` → **`fillWidthFixedColumnsGuard`** (the canonical
  contract guard; its assertion was already `columns == nominal`).
- `AppleGridLevelSpecAndContentModeTests`: `levelSpecsFillWidthAndAdaptColumns` → **`levelSpecsFillWidthFixedColumns`**.
- `SquareTileGridEngineTests`: `windowResizeFillsWidthAndAddsColumns` → **`windowResizeFillsWidthFixedColumnsScalesTile`**;
  `visibleQueryIsLeadingAlignedWithBoundedTrailingMargin` → **`visibleQueryIsLeadingAlignedAndFillsWidth`** and its
  trailing-margin assertion **tightened** from `< plan.pitch` to `< 2.0` (true fill).
- `GridSizeBasedResizeTests`, `GridViewportResizeTests`, `GridBottomRightAnchorTests`: lead comments corrected from
  adaptive/"trailing reveal margin" to fixed-columns/fills-width; `GridBottomRightAnchorTests` bottom-row assertion
  tightened `< plan.pitch` → `< 2.0`.
- `GridResizePresentationTests`, `GridTransitionScheduleTests`: stale `PHASE 1` / "Phase-B spike / temporary spike
  reference set" labels removed (now production-default language). Tests and assertions otherwise unchanged.

All 414 TimelineFeatureTests / 416 full-package tests pass before and after.

## 5. Remaining historical docs (intentionally retained, marked superseded)

`GRID_SIZE_BASED_RESIZE_DESIGN.md` and `RESIZE_PRESENTATION_LAYER_DESIGN.md` are kept (banner-marked SUPERSEDED /
reconciled) because they hold useful design history (the lock-step seam discipline, the measured-Apple resize
forensics) even though their column-model framing is rejected. The Phase-B spike reports
(`PHASE_B_*`) and `LIQUID_GLASS_UIUX_AUDIT.md` are kept as forensic dev records; the docs auditor recommended no
deletions (see `DOCS_AND_COMMENTS_REFRESH_REPORT.md`).

## 6. Remaining risk / open product decision

- The `GridSizePolicy` + `referenceSlotSide` **scaffolding** for the not-adopted adaptive model is retained (it has
  `GridSizePolicyTests`; removing it is a behavior/test change beyond this no-code-change pass). Its comments now
  honestly mark it "scaffolding, not adopted." A future pass could delete it if the responsive direction is
  formally abandoned - flagged, not done.
