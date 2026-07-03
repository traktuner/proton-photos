# iOS grid pinch transition — status & scoped follow-up (2026-07-03)

## Summary

The iOS grid pinch is **continuous, anchored, and eased**, and meets every concrete acceptance
criterion in the parity task. It runs entirely on shared **GridCore** geometry — the same Core the
macOS host drives — with the iOS host (`UIKitTimelineGridHost.swift`) owning only UIKit plumbing.

What is *not* yet on iOS is the macOS **source→target crossfade effect layer** (single-lattice
relocation dissolve + overview layer dissolve). That is a bounded but non-trivial follow-up, scoped
below. It was deliberately **not** attempted in this slice because it would require adopting the
macOS live-pinch *scrub-driver* architecture on iOS — a broad change that either discards the
just-landed `GridZoomTransaction` path or half-refactors it, both of which the task's constraints
("do not redesign the whole renderer", "do not half-refactor", "macOS must not regress") forbid.

## Acceptance criteria — current state

All satisfied by the geometry path that landed in commit `10a45d7d` ("Use Core live zoom for iOS
grid pinch"):

| Criterion | Status | Mechanism |
|---|---|---|
| Pinch no longer feels like a hard snap | ✅ | `GridZoomCommitBridge` eases transaction-final → settled over 160 ms (`UIKitTimelineGridHost.commitLiveZoom` / `renderNow` bridge branch) |
| Target/source frames align at release | ✅ | cursor-aligned `columnPhase` + `anchoredScrollOffset` computed at commit; threaded into every settled query |
| No missing outer photo during rubberband / limit pinch | ✅ | `GridLiveZoomBounds.visualLevel` clamps over-zoom with an elastic asymptote; overscan-bounded visible set |
| No scroll jump after commit | ✅ | committed scroll-Y clamped and applied before the settled frame; `pinchLockedOffsetY` holds the axis during the gesture |
| No per-photo CPU animation explosion | ✅ | geometry-only frames (`GridZoomTransaction.frame`); no per-slot timers/animators |
| No full-library work during gesture | ✅ | visible-only slot resolution; soft→sharp upgrade + warm gated off while `isInteracting` |
| No hard-coded L3/L4/L5 semantics | ✅ | levels are index-based with semantic metadata on `GridLevelProfile` / `GridLevelMetrics`; the iOS host never names a level |

## What is missing (the effect layer) and where it lives

macOS renders two extra effects *on top of* the same geometry, both already in shared Core:

1. **Single-lattice relocation dissolve** (normal-level focus-row relayout) —
   `GridCore/GridTransitionController.swift`, `GridTransitionComponentBuilder.swift`,
   `GridTransitionPlan.swift`, gated by `GridTransitionSelectionEligibility.swift`.
2. **Overview layer dissolve** (overview boundaries) —
   `GridCore/OverviewLayerDissolve.swift` (`OverviewLayerDissolvePlan`) rendered via the **already
   shared** `MetalRenderingCore/MetalGridRenderer.renderLayerDissolve(...)` (takes a
   `MetalGridDrawableTarget`, which the iOS host already constructs).

The **renderer already supports both on iOS** (`renderLayerDissolve` is `package` in
`MetalRenderingCore`, not macOS-only) — so no renderer redesign is required. The gap is the **host
orchestration**: macOS drives these through `TimelineFeature/MetalGridCoordinator.swift` using a
segment-based scrub driver (`GridCore/PinchLiveZoomDriver.swift`) that tracks a per-segment
`(source, target)` and switches between relocation and dissolve per level step. The iOS host does not
use that driver; it maps the live pinch straight onto a single `GridZoomTransaction`.

## Scoped follow-up (do this next, in isolation)

1. Introduce the segment model on iOS: drive the live pinch through `PinchLiveZoomDriver` (or an
   equivalent per-segment source/target tracker) instead of the single continuous `GridZoomTransaction`
   level, mirroring `MetalGridCoordinator.setPinchProgress` / `pinchSegmentSource/Target`.
2. Per segment, choose the effect from level metadata (already abstracted, profile-driven):
   - `adjacentTransitionKind == .overviewWarp / .denseOverviewZoom` → build
     `engine.overviewLayerDissolvePlan(from:to:...)` and render via `renderer.renderLayerDissolve(...)`
     in `UIKitTimelineGridHost.renderNow` (new branch alongside the commit-bridge/zoom-transaction
     branches).
   - otherwise → build a `GridTransitionPlan` via `GridTransitionComponentBuilder` and render its
     `currentDraws()` groups; enforce `GridTransitionSelectionEligibility` (no effect if a selected
     item relocates → fall back to the current geometry commit).
3. Commit exactly as macOS does (`commitPinchChain` / `commitOverviewDissolve`): adopt target
   level/phase/scroll, keep the 160 ms bridge as the non-effect fallback.
4. Tests to mirror on the iOS host (all Core policy already tested for macOS): overview-boundary
   detection, selection-eligibility gate, per-segment source/target selection.

Estimated surface: `UIKitTimelineGridHost.swift` (host branches + segment driver wiring) plus new
`TimelineUIKitFeatureTests`. No changes to GridCore/MetalRenderingCore effect code (reused as-is).
Keep macOS untouched.
