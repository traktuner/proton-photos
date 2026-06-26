# Rubber-band Over-Zoom at the Largest Grid Level — Fix Report

Date: 2026-06-25 · Branch: `apple-normal-focusrow-transition`

## Root cause

Pinching IN at the largest-thumbnail detent (level 0) drives the raw continuous level negative, which falls
to the live `GridZoomTransaction` reflow path (correct). The apparent-metric model already contains the
rubber-band — `GridZoomTransaction.apparentSlotSide(at:width:)` returns `side(0) * (1 - x * 0.6)` for `x <= 0`,
which GROWS the tile — but `MetalGridCoordinator.updateLiveZoom(continuousLevel:)` hard-clamped the level:

```swift
zoomTransactionLevel = min(max(x, 0), CGFloat(engine.levelCount - 1))   // max(x, 0) killed the overshoot
```

So `x < 0` never reached the transaction → no visible rubber-band. (Confirmed the routing exactly as
described: `handleMagnify` computes `pos < 0`; `driveLivePinch` resolves `next == -1` → not lattice/overview →
`.reflow` → `updateLiveZoom(pos)` → the clamp.)

Secondary issue for "no hard snap": the `.reflow` release commits via `finishLiveZoom` → `beginCommitBridge`,
which **instant-commits** when the matched-index move exceeds a sub-cell tolerance. An over-zoomed frame
differs from level 0 by more than that, so releasing would have snapped.

## Fix (minimal, no flag)

1. **`GridLiveZoomBounds.swift` (new, named + tested).** Maps the raw pinch level to the bounded visual level:
   in-band / densest passes through (clamped to the densest detent); the over-zoom region (`x < 0`) gets
   iOS-style elastic resistance `x / (1 - x/cap)` with diminishing return, asymptotically approaching
   `-maxOverZoom` (`0.30` level units — a named constant, not an inline magic number) so an aggressive pinch
   cannot produce absurd tile sizes.
2. **`MetalGridCoordinator.updateLiveZoom`** now uses `GridLiveZoomBounds.visualLevel(...)` instead of the
   `max(x, 0)` clamp, so a bounded negative visual level reaches `GridZoomTransaction.frame(...)` → the
   rubber-band renders, anchored under the cursor (the transaction pins the anchor at `anchorViewportPoint`
   at any level, including negative). Added `setLiveVisualLevel(_:)` for the spring-back. The COMMIT stays
   clamped: `finishLiveZoom` does `max(0, min(target, levelCount-1))` and `beginCommitBridge` does
   `engine.clampLevel(...)` — a temporarily-negative visual level never commits a negative level.
3. **`MetalGridScrollHost`** — release spring-back (no hard snap): when a `.reflow` gesture is released from an
   over-zoom (`liveZoomLevel < 0`), instead of an instant commit it runs a short (~0.18 s smoothstep) ramp of
   the visual level back to 0 via the existing display tick, then `finishLiveZoom(target: 0)` — seamless,
   because at level 0 the live frame equals the settled frame. Contained to the `.reflow` over-zoom case;
   the accepted single-lattice / overview-dissolve / in-band pinch paths are untouched.

The over-zoom is reached only via `pos < 0`, which only happens at level 0 (or chaining down through it), so
the change affects exclusively the largest-detent edge motion. No feature flag, no developer tuning UI.

## Files changed

- `Packages/ProtonPhotosKit/Sources/TimelineFeature/GridLiveZoomBounds.swift` (new)
- `Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridCoordinator.swift` (`updateLiveZoom`, `setLiveVisualLevel`)
- `Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridScrollHost.swift` (`endLivePinch`/`step`/`finishInFlightPinchSettle` + `advanceReflowOverZoomSettle`)
- `Packages/ProtonPhotosKit/Tests/TimelineFeatureTests/GridLiveZoomBoundsTests.swift` (new)

## Tests & build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test    # in Packages/ProtonPhotosKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build
```

Result: **344 tests in 46 suites passed**, 0 failures. Full app `xcodebuild` → **BUILD SUCCEEDED**. The
accepted `PinchLiveZoomDriverTests` / `GridTransitionControllerTests` / `GridTransitionScheduleTests` /
`OverviewLayerDissolveTests` still pass (no regression to the Phase-B effects).

`GridLiveZoomBoundsTests` proves the acceptance criteria:
1. `overZoomGrowsTileBeyondLevel0` — `apparentSlotSide(at: negative)` > `side(at: 0)`.
2. `visualLevelKeepsBoundedNegativeOverZoom` — negative visual level preserved (not clamped to 0), bounded by the cap, monotonic.
3. `releaseFromOverZoomCommitsToLevel0` — a negative live level rounds/clamps to committed level 0.
4. `anchorStaysUnderCursorDuringOverZoom` — the anchor item's rect centre stays at the cursor at `x = 0` and `x = -0.2`.
5. `inBandLevelsPassThroughUnchanged` — positive levels unchanged (clamped only at the densest end).

## Manual QA checklist

- [ ] Start at the largest-thumbnail grid level (level 0).
- [ ] Pinch in further → grid elastically enlarges around the cursor/finger; the photo under the cursor stays put.
- [ ] Release → springs smoothly back to level 0, no scroll jump, no hard snap.
- [ ] Normal pinch through levels still works (single-lattice in-band).
- [ ] +/- click zoom still works.
- [ ] Overview L4/L5 behavior unchanged.
