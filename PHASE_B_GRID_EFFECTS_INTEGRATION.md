# Phase-B Grid Effects — Integrated as Production Default (No Flags)

Date: 2026-06-25 · Branch: `apple-normal-focusrow-transition`

The accepted Phase-B grid effect system (developed in the `phaseb-pinch071-clickv2-420` worktree) is now
integrated into this branch and is the **production-default** behavior. There is **no feature flag** of any
kind gating normal grid effects.

## What was integrated

Effect layer (new, pure modules consuming engine `GridFramePlan`s):
- **`PinchLiveZoomDriver`** — continuous multi-level live-pinch scrub driver (V3.9 chaining across detents).
- **`ClickZoomTransitionScheduler`** / **`PinchZoomTransitionScheduler`** — click (CLICKV2_420) / pinch (PINCH071) progress profiles.
- **`GridTransitionController`** — builds/holds the single-presentation-lattice click+pinch plan, with eligibility gates.
- **`GridTransitionComponent(Builder)`**, **`GridTransitionPlan`**, **`GridTransitionScheduler`**, **`GridTransitionSelectionEligibility`**, **`GridTransitionRendererInput`**, **`GridTransitionTuning`**, **`LocalAlphaCurve`** — the lattice/plan/eligibility/tuning kernels.
- **`OverviewLayerDissolve`** — the L3↔L4 / L4↔L5 overview boundary two-layer offscreen cross-dissolve.

Wiring (consuming the effect layer — `GridEngine → Effect/Transition Layer → Renderer`):
- `SquareTileGridEngine` — **additive only**: `adjacentTransitionKind(_:_:)` + `isOverviewBoundary(_:_:)` (pure geometry; frozen-contract guard tests still pass).
- `MetalGridCoordinator` — owns the `GridTransitionController`; `tryBeginClickTransition` / `tryBuildPinchSegment` / `beginOverviewDissolve` drive the effect; the renderer draws supplied composition.
- `MetalGridScrollHost` — the live-pinch gesture routes through `PinchLiveZoomDriver` (lattice chain) / overview dissolve, falling back to legacy reflow only for ineligible steps.
- `MetalGridRenderer` — draws supplied render/composition commands (offscreen/layer dissolve where accepted); no layout policy.

## No flag — production default

- The `MetalGrid.singleLatticeTransition` UserDefaults flag and its `MetalGridSingleLatticeTransitionFlag`
  enum were **removed entirely**. Every gate (`GridTransitionController.beginClick/beginPinch`,
  `MetalGridCoordinator.tryBeginClickTransition/tryBuildPinchSegment/beginOverviewDissolve`,
  `MetalGridScrollHost`'s live-pinch route) now proceeds unconditionally.
- **Safety fallbacks remain only for invalid/ineligible geometry**, never as a switch: a single-lattice
  plan falls back to the clean instant snap / legacy reflow when the lattice build fails, the selection
  relocates, the plan is degenerate, or the step is out of the eligible band. The clean instant settle is
  kept ONLY for those invalid cases.
- The rejected `MetalGrid.focusRowTransition` two-grid crossfade stays **deleted** (it was a different,
  rejected path — not reintroduced).
- The `ProductionRouteGuardTests` source guard now forbids `singleLatticeTransition` /
  `MetalGridSingleLatticeTransitionFlag` (as well as `focusRowTransition` / `anim-tuning` / `TuningView` /
  `AnimationTuning.shared`) from reappearing in production code.

## Preserved from this branch

The security/offline-thumbnail work is untouched and intact (disjoint file set): encrypted
thumbnail/preview cache, `hasUsableDiskData` validated presence, the shared account-configured cache,
mandatory newest→oldest crawl, viewport debounce, dev-session + in-memory SDK-secret hardening. See
`OFFLINE_THUMBNAIL_SECURITY_REPORT.md`.

## Verification

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test    # → 339 tests / 45 suites passed
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build   # → Build complete
scripts/rebuild.sh                                                     # → BUILD SUCCEEDED; installed + launched
strings /Applications/ProtonPhotos.app/Contents/MacOS/ProtonPhotos.debug.dylib \
  | grep -E "PinchLiveZoomDriver|OverviewLayerDissolve|GridTransitionController|ClickZoomTransitionScheduler"
```

Results:
- `swift test` → **339 tests in 45 suites passed**, 0 failures (incl. `PinchLiveZoomDriverTests`, `OverviewLayerDissolveTests`, `GridTransitionScheduleTests`, and the rewritten always-on `GridTransitionControllerTests`).
- Full app `xcodebuild` + `rebuild.sh` → **BUILD SUCCEEDED**, installed to `/Applications/ProtonPhotos.app`, launched.
- Installed-binary `strings`: **present** → `PinchLiveZoomDriver`, `OverviewLayerDissolve`, `GridTransitionController`, `ClickZoomTransitionScheduler`. **Absent** → `singleLatticeTransition`, `focusRowTransition`, `MetalGridSingleLatticeTransitionFlag`, `anim-tuning`.
- App launches with only the normal window (no animation tuning window).

Detailed acceptance forensics for each accepted effect: `PHASE_B_SPIKE_REPORT.md`,
`PHASE_B_PINCH_LIVE_DRIVER_REPORT.md`, `PHASE_B_PINCH_MULTI_LEVEL_REPORT.md`,
`PHASE_B_OVERVIEW_LAYER_DISSOLVE_REPORT.md`, `PHASE_B_ENTRY_EXIT_GEOMETRY_REPORT.md`.

**Remaining:** visual QA in the running app (pinch / click +/- / overview L4–L5) to confirm the accepted
effects render as in the Phase-B captures — this requires a human looking at the screen.
