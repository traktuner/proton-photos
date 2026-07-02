# Docs & Comments Refresh Report - 2026-06-28/29

Companion to `CONTRACT_REFRESH_REPORT.md`. Scope: stale inline comments + markdown, corrected toward the accepted
**fixed-columns + width-fill** model and the real (implemented) architecture. No behavior change.

## 1. Stale code comments found & fixed (all toward fixed-columns)

| File | What was stale | Fix |
|---|---|---|
| `SquareTileGridEngine.swift` header (17-19) | "(C)" model: "steps columns at a constant tile size … trailing reveal margin (< one pitch); does NOT stretch to fill" | fixed-columns + width-fill (holds nominalColumns, scales tile, fills width) |
| `SquareTileGridEngine.swift` spec/metrics docs (46-51, 71-73) | "(B)": "column count adapts to width … nominalColumns is NOT a runtime column source" | nominalColumns IS the runtime column count (fixed per level) |
| `SquareTileGridEngine.swift` `referenceSlotSide` (83-87) | "ADDITIVE … Step 2 flips the kernel" (an abandoned migration framed as imminent) | marked SIZE-BASED SCAFFOLDING, not adopted; the settled resolve overrides it via `fixedColumns` |
| `SquareTileGridEngine.swift` `appleLevelSpecs` (280-283) | "(B)": "column count adapts … breathes within a bounded band"; "no transition animation implemented" | fixed-columns + fill; transition kinds consumed by the (implemented) effect layer |
| `SquareTileGridEngine.swift` `resolved()` (463-469) | "(B)" + the false "no settled caller passes [fixedColumns]" | two branches documented: fixedColumns = settled/detents (production), columnsForFixedSide = over-zoom only |
| `SquareTileGridEngine.swift` `columnsForFixedSide` (308-318) | "THE single column-from-width rule - the **settled** resolve AND the detents both route through this" (false) | this round rule runs ONLY for the live over-zoom; settled + detents hold nominalColumns |
| `SquareTileGridEngine.swift` `GridTransitionKind` (35-36) | "transition effect is a FUTURE pass … NOT implemented" | effects are implemented OUTSIDE the engine; the engine animates nothing |
| `GridSizePolicy.swift` header (3-13) | "(B)/(C)": "photo size is CONSTANT … the grid never breathes" as the current rule | marked SIZE-BASED SCAFFOLDING (not adopted); shipping grid is fixed-columns |
| `GridZoomTransaction.swift` (101-104, 119-128) | "column count adapts (columnsForFixedSide) … the SAME rule the settled grid uses" while the code uses `nominalColumns` | detents hold nominalColumns (the fixed count the settled grid holds); only off-detent over-zoom uses columnsForFixedSide |
| `MetalGridScrollHost.swift` (279-282, 831-834) | `PHASE 1` labels + "vertical/corner falls back (Phase 2/3 scope)" (those axes ARE implemented) + "arm the sync present" (presentsWithTransaction is explicitly NOT used) | accurate live-resize presentation description, no phase labels |
| `MetalGridCoordinator.swift` (MARK 641, 1143) | `(Phase 1)` / `(Phase-B spike)` MARK labels | de-staled |
| `MetalGridTypes.swift` (97) | "the prototype … Phase 1 proves the architecture" | tunable streaming/overscan budgets |
| `GridTransitionComponentBuilder.swift` (71) | "spike scope" | removed |

**Kept as correct (auditors' flags were inverted by the wrong shared-context assumption):**
`resolvedForLevel` (514-517), `apparentSlotSide` (640-642), and `MetalGridCoordinator` resize-settle / draw
comments (1006-1012, 1089-1090) all say "fixed-columns / never reflows" - **correct** under the accepted model;
left unchanged. The resize-settle `plan.columns != startCols` guard is a defensive no-op under fixed-columns
(documented as such by the existing comment).

## 2. Markdown contradictions fixed

See `CONTRACT_REFRESH_REPORT.md` §3 for the full list. Highlights: contract §10 (resize) and §13.1 (transition)
described removed/wrong systems; both design docs claimed an unimplemented (or wrongly-implemented) status; the
master spec's "Grid resize truth" actively permitted the rejected adaptive behavior.

## 3. Root reports - classification (docs auditor, conservative; NO deletions)

`PHASE_B_GRID_EFFECTS_INTEGRATION.md` (the integration ground-truth) and `OFFLINE_THUMBNAIL_SECURITY_REPORT.md`
(security/crypto record) are CURRENT - keep as-is. `EDGE_CORNER_REBASE_REPORT`, `RUBBERBAND_OVERZOOM_REPORT`,
`LIQUID_GLASS_TOOLBAR_*`, `LOADING_VEIL_FIX`, `LOGO_INTEGRATION_REPORT` describe still-current behavior - keep. The
five `PHASE_B_*` spike reports + `LIQUID_GLASS_PHASE1_AUDIT` / `LIQUID_GLASS_UIUX_AUDIT` are forensic dev records of
now-integrated work - recommended "keep but historical." None met the bar for deletion (clearly obsolete AND
duplicated by a current doc), so none were deleted.

## 4. Intentionally retained historical comments / docs

- `GridSizePolicy` + `referenceSlotSide`: retained, comments now mark them not-adopted scaffolding (have tests).
- `GRID_SIZE_BASED_RESIZE_DESIGN.md` / `RESIZE_PRESENTATION_LAYER_DESIGN.md`: retained with SUPERSEDED/reconciliation
  banners (design history value).
- `columnsForFixedSide` round rule + the between-detent over-zoom code: retained - genuinely used by the live pinch.

## 5. Remaining risks

- A handful of low-priority markdown nits remain unedited (docs auditor "low" severity): `docs/grid-zoom-apple-model.md`
  §E references defunct NSCollectionView-era symbols (recommended: add a "superseded" banner); dangling doc links in
  `PHASE_B_OVERVIEW_LAYER_DISSOLVE_REPORT.md` to three reports not in this worktree. Cosmetic; not fixed.
- The presentation-layer lifecycle is still covered mostly by **source-string** guards (see
  `PERFORMANCE_DEAD_CODE_AUDIT.md` §5) - a comment refresh can't fix that; flagged for a future executable-test pass.
