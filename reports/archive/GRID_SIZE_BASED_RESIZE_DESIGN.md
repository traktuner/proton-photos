# Grid Resize/Sidebar Redesign — SUPERSEDED (the accepted model is FIXED-COLUMNS + width-fill)

> **STATUS 2026-06-28: SUPERSEDED. The accepted model is FIXED-COLUMNS-PER-LEVEL + WIDTH-FILL.**
> Each level HOLDS its `nominalColumns` (3,5,7,9,20,30); the square tile fills the viewport width
> (`slotSide = (width − gap·(cols−1))/cols`). A window resize / sidebar toggle SCALES the tile and the column
> count changes ONLY on a zoom — never on resize. This matches the shipping code
> (`SquareTileGridEngine.resolvedForLevel` passes `fixedColumns: m.nominalColumns`) and the green
> `GridSizeBasedResizeTests` (columns == nominal across widths). BOTH models described below are REJECTED: the
> 2026-06-27 "adaptive round+fill / bounded breathing" revision (columns adapt to width) AND the original
> "constant size + trailing reveal margin / does-not-fill-width" model. The resize PRESENTATION mechanism that
> actually shipped is the CPU snapshot-scale presentation layer — see `RESIZE_PRESENTATION_LAYER_DESIGN.md` and
> §10 of `docs/metalgrid-engine-contract.md`.

> **[REJECTED REVISION — kept for history] 2026-06-27 REVISION — WIDTH-FILLING (round + fill) supersedes "no breathing".**
> The new Apple reference (`apple resize and sidebar animations.mov` + the All-Photos screenshot) proves the
> grid **always fills the available width — there is no trailing gutter**. The original "constant photo size +
> leading-aligned + trailing reveal margin (< one pitch)" model is REJECTED: at the largest levels one pitch is
> a ~25%-of-window blank gutter (the rejected screenshots). Implemented model:
> - `columnsForFixedSide` uses **round-to-nearest** (not floor): pick the column count whose width-filling tile
>   is closest to the level's reference size.
> - `resolved()` then sizes the square slot to **FILL the width exactly** (`nominalSlotSide`), so the trailing
>   gutter is ~0 at every multi-column width.
> - The tile therefore **breathes within a small BOUNDED band** (±9% at L3 … ±26% at L0). This *reverses* the
>   old "non-negotiable: no breathing" — bounded fill-breathing is what Apple does and is the accepted product
>   behavior; only the old *unbounded* fixed-columns rescale stays forbidden.
> - Slots stay **square**; media still **aspect-fits inside the square slot** (default `aspectFitInsideSquare`,
>   the observed Apple look) — variable visible image sizes come from content fit, NOT a justified outer layout.
> - The live pinch lattice (`apparentSlotSide` / `GridZoomTransaction`) interpolates the **filled** per-level
>   sides, so an integer detent's apparent size equals the settled size → the commit seam closes at any width
>   (guarded by `pinchCommitSeamHoldsAtNonReferenceWidths`).
> - The full Apple-default **aspect-justified** (variable-width) layout is explicitly OUT of scope this pass.
>
> Below sections §2–§7 still describe the (now superseded) fixed-size/trailing-margin model and the lock-step
> couplings; read §5/§6 for the still-valid couplings, but the "constant size / trailing margin" framing is
> historical.

**Status:** SUPERSEDED (see the banner at the top). The adaptive round+fill kernel described in the 2026-06-27 revision was NOT the accepted outcome — the settled engine ships FIXED-COLUMNS (`SquareTileGridEngine.resolvedForLevel` passes `fixedColumns: m.nominalColumns`). The live-transaction lock-step and regression-test discipline below remain useful history; the column-model framing is historical.

**Goal (user-confirmed, frame-by-frame from the Apple/Proton videos):** a photo's on-screen size is **constant during any live resize**. On *any* resize path — horizontal edge, vertical edge, **corner**, or sidebar toggle — photos keep their exact size; the window/sidebar **clips or reveals** content; the **column count** steps **discretely**. No tile breathing/rescaling. The grid is leading(left)-aligned; a trailing reveal margin (< one tile) carries the sub-column remainder. Pinch zoom is the only thing that changes photo size.

## Product override (supersedes strict Apple copying)

The target is **Apple-like feel and interaction quality**, NOT a literal copy of Apple's column caps. Per the explicit product decision:

- **Zoom levels are a feel, not a fixed column count.** "L0" = *Apple's largest-photo feel*, not "exactly 3 columns everywhere." On a narrow window it may look like ~3 columns; on a wide / 8K display it may show **more** large thumbnails if that is the better responsive product. The level→size policy **may be responsive** across wide displays, compact windows, iPad, and iPhone.
- **All responsiveness is DISCRETE.** A level's photo size may differ between viewport *size classes* (compact / regular / wide / ultra, or by device idiom), but it changes only in **discrete steps at breakpoints** — never a continuous rescale tracking the drag. Within a size class, the size is constant and only the column count steps.
- **Caps are allowed but must not breathe.** If a sparse level is bounded (e.g. a max column count so an 8K display doesn't spread one zoom across 12 tiles), the surplus width becomes **margin / clip-reveal** (leading-aligned or centered), or a **discrete size breakpoint** — never a continuous tile stretch.

**Non-negotiable forbidden behaviors (any platform, any path):** thumbnail squeezing/stretching; continuous tile breathing during resize; abrupt jumps; black frames / topology pops; wrong hit-testing behind the sidebar.

**Architecture constraints:** the layout core stays **platform-neutral** (a pure value-type engine that takes viewport size + a size-class/idiom hint and returns geometry — no AppKit/UIKit, reusable for future iOS/iPadOS). The **renderer stays a dumb quad renderer** — all column/size/margin derivation lives in the engine, never in the renderer.

---

## 1. The model inversion

| | Today (column-based) | Target (size-based, Apple) |
|---|---|---|
| A level fixes… | column count (3/5/7/9/20/30) | **photo size** (points) |
| Resize changes… | photo size (`width ÷ columns`) | **column count** (`floor(width ÷ size)`) |
| Fills width? | yes (stretches) | **no** — fixed size, leading-aligned, trailing reveal margin |
| Result on resize | everything rescales ("breathing") | photos hold size, columns step, edge clips/reveals |

**Where it lives (small kernel, but 3 lock-step couplings):** every downstream query — `placement`, `visibleSlots`, `hitTest`, `visibleHeaders`, `contentHeight`, `columnPhase`, `cursorColumn`, `anchoredScrollOffset`, the resize rebase, the commit bridge — consumes only the *resolved* `(columns, slotSide, gap, pitch)` tuple and is **agnostic to how it was derived**. So the inversion is concentrated in `SquareTileGridEngine.resolved()` (line 432-433) + `resolvedForLevel()` (line 467-476), but **three derivations must move in lock-step or the pinch snaps**:
1. the settled `resolved()` column rule,
2. the live transaction's integer-detent column rule (`GridZoomTransaction` line 121-126),
3. `committedPhase` re-derivation on a column-changing resize.

All three route through **one shared helper** `columnsForFixedSide(side:gap:width:)` so they can never diverge (this is the #1 risk mitigation — see §5).

---

## 2. Per-level photo size — a responsive, platform-neutral policy (§ required: "stable slot/photo size")

Introduce a pure, AppKit-free **`GridSizePolicy`**: `(level, viewportWidth, sizeClass/idiom) → (slotSide, gap, maxColumns?)`. The engine calls it to get the **fixed** photo size for the current frame; the result is **constant for the whole of a live resize within one size class** and changes only in discrete steps at size-class breakpoints. This is the platform-neutral seam (desktop today, phone/iPad later) and replaces today's "size = width/nominalColumns."

Concretely: add a stored `slotSide: CGFloat` and optional `maxColumns: Int?` to `GridLevelMetrics` (line 65), produced by the policy. `AppleGridLevelSpec.nominalColumns` (line 48) is **retained** only as (a) the seed that derives the desktop/regular size and (b) the spec-guard literal — never a runtime column source.

**Regular (desktop) size table — derive once at a density-anchor width:**

```
slotSide(L, regular) = (W_ref + gap_L) / nominalColumns_L − gap_L − ε      (ε ≈ 0.5 pt)
```

`W_ref` = the width that reproduces **today's** density. Recommend **W_ref = 1280** (L3 ≈ 135 pt, matching the documented "slotSide 140" default).

| Level | nominalCols | gap | **slotSide @ regular (W_ref=1280)** |
|---|---|---|---|
| L0 | 3 | 16 | ≈ 416 pt |
| L1 | 5 | 12 | ≈ 246 pt |
| L2 | 7 | 10 | ≈ 174 pt |
| L3 | 9 | 8 | ≈ 135 pt |
| L4 | 20 | 2 | ≈ 62 pt |
| L5 | 30 | 1 | ≈ 42 pt |

- **The `−ε` is mandatory** (critique-verified): the naïve exact-fill side floor-inverts to `nominalColumns − 1` for L2 (→6) and L5 (→29) due to FP truncation. With `−ε` all six round-trip to their nominalColumns at `W_ref`, and the ladder stays strictly monotone (416 > 246 > 174 > 135 > 62 > 42).
- **Knife-edge fix:** use `ε ≈ 0.5 pt`; treat `W_ref` as the *bottom* of the band so the anchor width sits inside a column step, not on its edge. Round-trip guard spans a ±40 px band.

**Responsive size classes (discrete, optional, future-facing for iPad/iPhone):** the policy may return a *scaled* size per class so big displays get bigger tiles and phones get smaller ones — e.g. `compact ×0.62`, `regular ×1.0`, `wide ×1.15`, `ultra ×1.3`, selected by `viewportWidth` breakpoints (or `idiom` on iOS). Crossing a breakpoint is **one discrete size step** (allowed); inside a class the size is constant. Desktop ships with `regular` only initially; the seam exists so iOS can plug in `compact`/`regular` without re-plumbing the engine.

**Optional per-level column cap (breathing-free):** `maxColumns(L)` bounds a sparse level so an 8K display doesn't spread one zoom across a dozen tiles. When the cap binds, `columns = maxColumns` at the **fixed** `slotSide`; the surplus width is **margin** (leading-aligned, or centered — a render-time choice), NOT a tile stretch. Default: **no cap** (the largest level shows *more* big photos on wide screens — the chosen product behavior); a generous cap can be added later purely as a margin policy with zero breathing.

- **Consequence (intentional):** the absolute on-screen size at the user's current width differs from today whenever width ≠ W_ref within a class. That is the point — constant size, discrete columns.

Rejected: a single global fixed constant per level with no size-class seam (works for desktop but blocks the iOS responsiveness the product wants).

---

## 3. Column count from width (§ required: "column count vs width")

In `resolved()` (line 424-465), repurpose `fixedColumns` to an **optional hard override** used only by the live-lattice over-zoom; the settled path passes `nil` and a `maxColumns`:

```
fit      = columnsForFixedSide(side: target, gap: g, width: w)   // = max(1, Int(floor((w + g)/(target + g))))
columns  = max(1, fixedColumns ?? min(maxColumns ?? .max, fit))
slotSide = target            // the FIXED slotSide from GridSizePolicy — DELETE the line-433 re-stretch
pitch    = slotSide + gap
```

`resolvedForLevel()` (467-476) passes `targetSide: m.slotSide` (from the policy) + `m.maxColumns` and **stops passing `fixedColumns`** — this single switch stops the breathing.

- **Leading alignment is already intrinsic** (`placement`/`visibleSlots` lay out from `x=0`, lines 338/375). The reveal margin lands on the trailing/right edge automatically. (If a future "centered when capped" look is wanted, it's a single render-time x-offset in the coordinator's draw chokepoint — still not a tile resize, renderer stays dumb.)
- **Min:** `max(1, …)` → a viewport narrower than one tile still shows 1 column (degenerate, x-scroll stays 0).
- **Cap binds (very wide + a capped sparse level):** `columns = maxColumns` at the fixed size; surplus width is margin (clip/reveal), no stretch.
- **No cap (default):** columns keep growing on wide displays — more big photos; trailing margin ∈ `[0, pitch)`.
- **`nominalSlotSide()` is kept** (seeds `referenceSlotSide`, used by the rubber-band) but no longer called per-resolve for the settled side.
- **One-helper rule (critique):** `columnsForFixedSide` is the *single* definition; replace the inline `Int((w+g)/(target+g))` at engine line 432 **and** `GridZoomTransaction` line 124 with calls to it. A source-guard test asserts no inline `Int((…+g)/(…+g))` survives outside the helper (prevents the `Int()`-vs-`floor()` lock-step from silently breaking).

---

## 4. Content height (§ required)

**No formula change.** `resolved()` already computes `rows = ceil((count + emptyTopLeft)/columns)` per section and `contentHeight = Σ(headerHeight + rows·pitch)` (lines 442-459). It is already width-dependent via `columns`; with `columns` now from the fixed size it simply recomputes correctly. `contentSize.width` **stays = full viewport width** (recommended): the document spacer spans the full area (events captured across it), `hasHorizontalScroller=false`, and the trailing margin is empty background that clears to the grid color. Grep confirmed only `contentHeight` is read for vertical clamping.

---

## 5. Edge-aware anchoring across width / height / sidebar / corner (§ required)

**The moving edge clips/reveals; the stationary edge holds.** This is explicit per the product clarification: a left-edge drag must NOT slide content as if the grid were permanently left-origin. The policy has three independent parts — a horizontal presentation alignment, a vertical scroll anchor, and a calm column-step — all driven by *which edge moved* (the host already detects `movedLeftEdge/movedRightEdge/movedTopEdge/movedBottomEdge` in `GridViewportResizeDelta`).

**(a) Horizontal presentation alignment `xAlign` (NEW).** The engine lays columns out leading (from x=0), `contentWidth = columns·pitch − gap`, `margin = layoutWidth − contentWidth ∈ [0, pitch)`. The coordinator applies a **uniform render-time x-offset** (on top of the existing `+inset` translate — renderer stays dumb) so the column block sits against the **stationary** edge:
  - **Right-edge drag** (or default / settled / sidebar-on-left): `xAlign = 0` → margin on the **right**; left edge fixed, right clips/reveals. ✓
  - **Left-edge drag** (right edge stationary): `xAlign = margin` → margin on the **left**; the right column block stays put in screen space, the left edge clips/reveals. This is the fix for the left-edge "feel".
  - **Corner / both-horizontal-edges:** hold the dominant stationary edge; symmetric → `xAlign = margin/2` (centered).
  `xAlign` is presentation only — it never changes the wrap (item→column) or the hit-test math (the coordinator subtracts `xAlign` on input just as it subtracts `inset`). Slots stay square; no stretch.

**(b) Vertical scroll anchor (item-identity rebase).** `GridViewportResizeRebase` already anchors on an **item identity** (`flatIndex` + in-slot local fraction), not a raw scroll-Y, so it survives a column rewrap: the anchor item's content-Y is recomputed from its *new* slot rect (`anchoredScrollOffset`). Per stationary vertical edge (`resizeAnchorFraction`): bottom-edge moved → hold top (0); top-edge moved → hold bottom (1); pure width → hold top (0); symmetric corner → hold the visual center (0.5) or the dominant stationary edge.

**(c) Calm column step (NEW — the "no hard pop" requirement).** A column add/drop is allowed but must not read as a jump:
  - **Threshold hysteresis** in the column resolve: add a small dead-band so a column doesn't add/drop repeatedly while the width hovers on a threshold (resolve uses `floor((w+g)/(side+g) + h)` with a hysteresis `h` biased by drag direction, or a sticky last-column-count held until the width is clearly past the boundary). Pure function; unit-testable.
  - **Rebase smoothing:** at the instant a column count changes, the anchor item is re-pinned (parts a+b) so the *anchored region stays visually stable* across the step; the residual (the rest of the grid reflowing by one column) is the unavoidable discrete change and is eased via the existing `GridScrollRebase` short interpolation, never via tile scaling.
  - This is explicitly NOT continuous tile breathing — size is constant; only the column count changes, once, calmly.

**(d) Phase on resize — case-split (critique fix).** Today `committedPhase` is carried verbatim; with variable columns the same Int names a different leading-empty count, silently shifting the anchor's column.
  - `committedPhase == nil` (common, no prior cursor-zoom): **leave nil** — bottom-right wrap is column-count-relative and self-corrects; recomputing would *introduce* a horizontal jump.
  - `committedPhase != nil` (prior cursor-aligned zoom): recompute to preserve the **anchor item's column** at the new column count; thread back via an extended `GridViewportResizeResult`.

**Required test scenarios (each: no squeeze, no breathe, no jump, no black frame; the chosen stationary region stays visually stable):**
- **right-edge shrink & grow** — left/top region pixel-stable; right clips/reveals; columns step at thresholds.
- **left-edge shrink & grow** — right/top region stable; left clips/reveals (validates `xAlign = margin`).
- **sidebar reveal & hide** — grid region stable; a column is dropped/added (not a rescale); anchor item under the same viewport point before/after.
- **corner resize** — the held corner stays put; size constant; columns + visible rows both adapt; no diagonal slide.
- **pure-height** (control) — zero width-derived change (no column reflow, no `slotSide` change).

---

## 6. Live pinch detents + continuous pinch stay stable (§ required)

The pinch stack is structurally compatible because **a single gesture holds width constant** → every level resolves to one fixed integer column count for the gesture's lifetime. So `columnPhase` cursor-anchoring, focus-row fan-out, and the `prev-q=1 == next-q=0` seam are preserved. Lock-step edits:

- `GridZoomTransaction.lattice` / `apparentSlotSide`: interpolate the **fixed per-level `referenceSlotSide`s** (width-independent) instead of `nominalSlotSide(nominalColumns, width)`; derive columns via the shared `columnsForFixedSide`. Rubber-band/over-zoom `baseSide` uses `referenceSlotSide(L0)`.
- Mirror the same edit in the engine's `apparentSlotSide` (line 593) **and** `zoomFramePlan` (line 493, the continuous-lens entry point used by `zoomUsesMetrics`) — both in lock-step with `resolved()` (critique: don't forget `zoomFramePlan`).
- **Endpoint equality & seam survive** because `pinchDetentParams` builds the target detent's `(phase, scroll)` and the commit adopts the same — both now read the same fixed-size column count at the same width. Add a **seam test at a non-reference width** (e.g. 1500, where columns ≠ nominal) asserting `maxMatchedIndexMoveX < pitch` at every detent (critique: the design's "columns match" check is necessary but not sufficient for the commit-snap tripwire).
- The eligible chain band / overview-boundary logic keys off `transitionKindToNext`, not column counts — unaffected.

---

## 7. columnPhase / focus-row / bottom-right reconciliation + sidebar inset (§ required 6 & 7)

- **columnPhase / cursorColumn / focus-row** read the *resolved* column count — no change needed beyond the resize-time recompute in §5.
- **Bottom-right anchoring vs leading-alignment:** the grid is **leading-aligned in X** (column 0 at x=0, trailing margin on the right) while keeping **bottom-right *wrap* anchoring** (newest item in the last *filled* column, oldest partial row top-left). "The corner" = the last filled column's bottom, with the reveal margin to its right (not flush to the viewport's right pixel). `GridBottomRightAnchorTests` rewrites from "flush to width" to "bounded trailing margin."
- **Sidebar inset — this is the win:** `leadingObstructionInset` already reduces `layoutWidth` (`fullWidth − inset`). Today that shrinks `slotSide` (breathing). Once `resolved()` is size-based, reduced `layoutWidth` → **fewer columns at the same size** = exactly the Apple sidebar behavior. The full-width render (`renderTranslate +inset`), the `x < inset` hit-test exclusion, and `cursorContentPoint` inset subtraction all keep working unchanged. The reveal margin now lands between the last column and the (full-width) right edge.
- **`normalLevelLeadingGap` (16 pt) caveat (critique):** it folds into `layoutWidth`, so it can ±1 the column count at boundary widths, and it toggles at the L3↔L4 boundary (monthLabels gate) — under fixed-size that can pop a column *at the overview boundary*. Recommend for this pass: keep it, but **quantify the L3↔L4 column delta at the user's width band first**; if it pops a column, render the gap as pure leading whitespace decoupled from the column budget.

---

## 8. Tests: invert / preserve / add (§ required) + parked-fix isolation (§ required 9)

**Must INVERT (currently assert the deleted "fills width / fixed columns" contract):**
- `SquareTileGridEngineTests.zoomOutFillsWidthAtEveryApparentLevel` (settled `maxX≈width` → bounded margin; live frames still fill)
- `GridViewportResizeTests.pureWidthResizeChangesTileSizeNotNominalColumns` (flip `slotSide(1000) != slotSide(1400)` → `==`; columns now change)
- `AppleGridLevelSpecAndContentModeTests.levelSpecsAreResolutionIndependent` (columns now width-dependent)
- `MetalGridContractGuardTests.nominalColumnsResolutionIndependenceGuard`
- `GridBottomRightAnchorTests` (no-black-on-right → bounded trailing margin; newest in last *filled* column)
- the resize diagnostics/perf expectations (`columnsBefore ≠ After`, `slotSide ==`)
- `OverviewLayerDissolveTests` literal `columns == 20` (see overview decision)
- enumerate every `(maxX − width) < 1.0` and `contentSize.width == w` assertion (grep ≈ 8 sites)

**FORBIDDEN regressions (must stay green, unchanged):**
- Pinch stability: `PinchLiveZoomDriverTests`, continuous scrub/detents/seam/commit.
- **The parked binding-echo fix: `LevelBindingReconciler.swift`, `LevelBindingReconcilerTests.swift`, `GridZoomAnchorIdentityTests` GUARANTEE-2..5, and the binding-echo hunks in `MetalGridScrollHost.swift` / `MetalProductionGridView.swift` / `GridZoomCommit.swift` — NEVER touched; these tests pass unchanged and double as the regression gate for cursorColumn/columnPhase/anchoredScrollOffset semantics.**
- Square slots at every level/width (`GridCanonicalGuardTests`, `MetalGridContractGuardTests.squareSlots`).
- Trailing margin is plain layout (leading-align + fewer columns), **never** edge-fill machinery (`GridCanonicalGuardTests.noEdgeFillHackInEngine`).
- Renderer stays layout-math-free (`engineOwnsSlotGeometryGuard`).
- Cursor-stays-under-cursor + phase persistence (`CursorAnchorZoomTests`, `GridLayoutPhaseTests`, `GridZoomCommitCorrectnessTests`).
- Pure-HEIGHT resize changes no width metric.
- Sidebar full-width-render / layout-space-inset model intact.

**NEW coverage:**
- `constantSlotSideOnHorizontalResize`, `noTileBreathingDuringResize`, `columnsAdaptDiscretelyWithWidth`, `leadingAlignedWithBoundedTrailingMargin`
- `referenceSlotSideRoundTripsAtWref` (±40 px band) + `referenceSidesMonotoneDecreasing`
- `resizeAcrossColumnThresholdKeepsAnchorColumn` (anchor item under same viewport point across a column add/remove)
- `sidebarToggleDropsExactlyOneColumnAtBoundary`, `clickInTrailingMargin → nil hitTest`
- non-reference-width commit-seam test (§6)

---

## Implementation plan (8 incremental, independently-testable steps)

1. **Additive:** add `referenceSlotSide` (+ both inits, seed at W_ref) and the `columnsForFixedSide` helper. No call site reads it yet → whole suite green. *(test: round-trip + monotone)*
2. **Flip the settled kernel** (`resolvedForLevel` passes `referenceSlotSide`, drop `fixedColumns`; `resolved` uses the helper + delete re-stretch). THE breathing fix. Add the new size-based resize tests; update the inverted settled guards in the same step.
3. Finish updating inverted settled guard tests; confirm bottom-right newest in last filled column.
4. **Resize rebase:** rewrite inverted doc comments; clamp anchor probe x into content; verify item-anchored vertical rebase round-trips when columns rewrap. (No phase change yet.)
5. **Phase-on-resize:** case-split nil vs non-nil (§5); extend `GridViewportResizeResult`; coordinator writes back. *(test: `resizeAcrossColumnThresholdKeepsAnchorColumn`)*
6. **Reconcile the live transaction in lock-step** (`GridZoomTransaction` columns + `apparentSlotSide` + rubber-band + engine `apparentSlotSide` + `zoomFramePlan` through the shared helper). *(seam + correctness + GUARANTEE-2..5 unchanged)*
7. Invert resize diagnostics/perf logging wording; optional column-threshold no-op gate in host `layout()`.
8. Remaining new coverage + overview/focus-row literal-column updates. Full suite incl. untouched parked tests.

---

## Top risks → mitigations

1. **Live-transaction columns diverge from settled → every pinch commit snaps.** → one shared `columnsForFixedSide`; non-reference-width seam test.
2. **`committedPhase` verbatim through a column change re-anchors wrong column.** → case-split recompute (§5).
3. **FP floor-truncation drops a column at W_ref.** → mandatory ε-nudge + `referenceSlotSideRoundTripsAtWref` guard.
4. **Discrete column "pop" during sidebar reveal reads as jarring** (vs today's smooth rescale). → it *is* the spec-correct constant-size feel; confirm with user (§7). Fallback: special-case only the sidebar animation to interpolate width while snapping columns at the threshold.
5. **Hidden caller assumes `contentSize.width` == content extent.** → keep `contentSize.width = fullViewportWidth`; grep confirms only height is read; add guard.

---

## Open decisions that need you (§7 of the ask)

- **D1 — wide-display largest zoom — RESOLVED (product override).** Pure constant-size is the default: on a wide/8K display the largest zoom shows **more** big photos (more columns, same size), never a stretched few. Responsiveness, if any, is **discrete** (size-class breakpoints in `GridSizePolicy`) and any cap is **margin/clip**, never breathing. No hard cap ships by default; the `maxColumns` seam exists if we later want to bound ultra-wide spread. Nothing here violates "no breathing."
- **D2 — overview levels L4/L5 — RESOLVED.** Same fixed-size / responsive model as L0–L3; no edge-to-edge exception unless later Apple-frame evidence proves otherwise. Consistency wins. (Needs `mapDissolveTargetLayer` scale re-derivation + the `==20` test update.)
- **D3 — reference width — RESOLVED.** `W_ref = 1280` is the **calibration seed only** (sets the regular-class absolute size; L3 ≈ 135 ≈ documented default), **not product law** — the responsive policy may override per size class.
- **D4 — anchor policy — RESOLVED.** Constant no-squeeze everywhere; **edge-aware** anchor policy (§5) is mandatory and must be tested, **especially left-edge**. The stationary edge holds; the moving edge clips/reveals.
- **D5 — discrete column step — RESOLVED (with guardrails).** Accept discrete steps initially, gated by regression tests + visual QA. If a step reads as a hard pop, refine via anchor/rebase/hysteresis/presentation smoothing (§5c) — **never** by reintroducing continuous tile scaling.

The uncommitted pinch binding-echo fix is **not touched** by any of this.
