# Phase B App Spike - PINCH071 + CLICKV2_420_FULLER_CORNER

Approval token verified: `APPROVE_APP_SPIKE candidate=PINCH071_CLICKV2_420_FULLER_CORNER`.
Foundation tag `metalgrid-engine-v1` verified (annotated `a621109…` → commit `0e06e07…`).
Branch `phaseb-pinch071-clickv2-420` created in a clean worktree off the Foundation tag.

## Implementation summary

A **separate, modular transition layer** that consumes the engine's settled `GridFramePlan` and
produces immutable per-frame draw intent (full-slot mix of source⇄target occupants). It does NOT
touch `SquareTileGridEngine`, `TileContentFitter`, `GridViewportResizeRebase`, square-slot layout,
or the renderer's geometry. Host owns the canonical progress `q`; component `localProgress` is a
pure function of `q` (reversible, no timers, no per-frame graph build). Feature-flagged, default OFF.

## Files changed

New source (`Packages/ProtonPhotosKit/Sources/TimelineFeature/`):
- `LocalAlphaCurve.swift` - C1 slope-limited linear-core α (a=0.20, peak slope 1.25).
- `GridTransitionTuning.swift` - centralized tunables + the feature flag.
- `GridTransitionComponent.swift` - `RelativeSlotKey`, relocation component.
- `GridTransitionPlan.swift` - immutable plan + `renderIntent(at q)` (full-slot mix).
- `GridTransitionScheduler.swift` - click q(t), area-weighted allocation, centre-out, W071 windows.
- `ClickZoomTransitionScheduler.swift` - CLICKV2_420_FULLER_CORNER plan builder.
- `PinchZoomTransitionScheduler.swift` - PINCH071 (W071) plan builder.
- `GridTransitionComponentBuilder.swift` - lattice + components from source/target frame plans.
- `GridTransitionSelectionEligibility.swift` - conservative double-outline-safe rule.
- `GridTransitionRendererInput.swift` - resolved slots → alpha-weighted draws.
- `GridTransitionController.swift` - coordinator-side driver (build / eligibility / host-q / fallback / diagnostics).

Modified (additive, flag-gated):
- `MetalGridCoordinator.swift` (+106): `gridTransition` member; `tryBeginClickTransition(...)`;
  a `draw(in:)` branch (only entered when a transition is active); `drawTransition` + `renderTransitionDraws`
  (two image quads per dissolving slot via the existing `MetalGridQuad.alpha`).
- `MetalGridScrollHost.swift` (+13): toolbar/keyboard +/- tries the transition first; nil ⇒ existing snap.

New tests (`Tests/TimelineFeatureTests/`): `GridTransitionScheduleTests.swift`, `GridTransitionControllerTests.swift`.

## Feature flag

`MetalGridSingleLatticeTransitionFlag` - UserDefaults key **`MetalGrid.singleLatticeTransition`**,
**default OFF**. When OFF, `tryBeginClickTransition` returns nil and `gridTransition` is never
started, so `draw(in:)`'s transition branch is never entered ⇒ the accepted stable instant-snap
behaviour is byte-for-byte unchanged (proven: all 254 pre-existing engine/contract tests still pass).

## Tuning location

All transition constants live in `GridTransitionTuning` (single struct). Tunable without architecture
change: `clickDurationMs=420`, `clickRampFraction=0.20`, `c1EdgeFraction=0.20`,
`minFocusInteriorSamples60=4`, `minCornerInteriorSamples60=2`, `maxSimultaneousPartialComponents=1`,
`pinchWidthQ=0.0706`, `pinchFollowerOmegaN=27.8`, lead-in/out + edge-zone + min-width. Marked as
TEMPORARY SPIKE CONSTANTS (from V3.4–V3.6 evidence).

## Tests added (all pass; `swift test`, 257 tests / 37 suites green)

- Alpha curve: endpoints exact, derivative≈0 at ends, monotone, reversible f(1-u)=1-f(u), peak slope ≤1.26.
- Allocation reproduces the V3.6 splits exactly (360→{5,3,3,2,2,2,2}, 420→{5,3,3,3,3,3,2}, 450→{5,3,3,3,3,3,3}).
- Click windows: disjoint+touching, no terminal q-sliver, **cid0 focus ≥4 interior @60**, **cid5 corner ≥2 interior @60**, no atomic component, **max simultaneous partial = 1** (50 phases ×60/120 Hz).
- Render intent: q=0 == source settled, q=1 == target settled, dissolve weights complementary (full-slot mix), reverse equality, no completion seam.
- Selection eligibility: empty/stable animate; relocating / mixed ⇒ snap.
- Feature flag default OFF; flag-ON builds plan + draws + settles; relocating selection ⇒ fallback.
- Builder on real `SquareTileGridEngine` geometry: focus row stable, components exist, one-partial-per-frame.
- Pinch windows: W071 width, disjoint. Perf: scheduling is one-shot.

## Commands run

`git worktree add -b phaseb-pinch071-clickv2-420 … metalgrid-engine-v1`;
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --target TimelineFeature`;
`… swift test --filter TimelineFeatureTests` → **257 tests / 37 suites passed**.

## Exact fallback behavior

Flag OFF, or single-level step not `.focusRowRelayout`, or lattice build fails, or any selected
identity relocates, or the schedule is degenerate ⇒ `tryBeginClickTransition` returns nil and the
host uses the **stable instant snap** (`settleScrollOffsetY`, unchanged). The controller records a
`GridTransitionFallbackReason` and emits `[GridTransition] FALLBACK reason=…`. On success it emits
`PLAN_BUILT … candidate=CLICKV2_420_FULLER_CORNER`; on settle, `SETTLED`.

## Known limitations (honest)

1. **Live pinch (PINCH071) logic is implemented + unit-tested (W071 windows, plan, full-slot mix) but
   NOT yet wired into the live `GridZoomTransaction` render path.** The CLICK path is fully wired
   end-to-end (host → coordinator → controller → render); the pinch render hook (drive q from the
   follower over the live transaction) is the documented next integration step. The accepted
   geometry-only live pinch is unchanged.
2. **No on-device visual validation.** This was implemented + verified headlessly (unit tests only).
   The live GPU crossfade cadence, anchor/scroll alignment during the 420 ms click, and the manual
   review checklist (60 Hz click in/out, reverse mid-transition, corner behaviour, pinch) require
   running the app - the prompt's separate manual-review step. **No visual/product acceptance is claimed.**
3. ~~The two-texture α-over-background mix approximates full-slot mix~~ **[FIXED 2026-06-25]** -
   QA found the two-translucent-layer blend bled background (≈25% bg at lp=0.5). A mixed source↔target
   dissolve now draws the **source occupant opaque** (alpha 1) as the base and the **target at alpha
   lp**, so premultiplied source-over composites to the exact full-slot mix `src·(1-lp)+tgt·lp` with no
   background bleed. Single-sided background dissolves keep their (1-lp)/lp weight. +4 render-fidelity
   tests; no renderer blend-mode change.

Phase B remains a spike: modular, feature-flagged (default OFF), tunable, reversible. **No merge.**
Changes are uncommitted on the branch for review.
