# Phase B V3.7 - Entry/Exit Presentation Geometry Fix

Branch: `phaseb-pinch071-clickv2-420` (spike worktree). Main repo NOT modified. Not committed/merged.

## Root cause

`GridTransitionPlan.rect(for:)` interpolated a continuous rect ONLY when a key had both a real
`sourceRect` and a real `targetRect` (mixed/stable keys). For:
- source-only **exit** keys it returned the source rect unchanged,
- target-only **entry** keys it returned the target rect unchanged.

So side/new tiles had **no spatial path** - they faded in/out at a fixed grid position instead of
sliding/scaling with the grid, unlike the Apple Photos reference (verified: tiles continuously scale
and reflow during zoom). `GridTransitionComponentBuilder` only recorded real source/target rects from
the visible slots and never synthesized the missing endpoint.

## Geometry model implemented (single-lattice, slot-centric - no identity rect flights)

A presentation transform is fit ONCE per plan from the keys that have BOTH real rects (the
mixed/stable keys), then used to synthesize the missing endpoint for entries/exits:

- **Transform** `GridTransitionPresentationTransform` - per-axis **median scale** + **median
  translation** (robust): `sx = median(tgt.w/src.w)`, `sy = median(tgt.h/src.h)`,
  `tx = median(tgt.midX − sx·src.midX)`, `ty = median(tgt.midY − sy·src.midY)`. `forward` maps
  source-space → target-space, `inverse` maps target-space → source-space.
- **minCommon = 2** (the minimum to determine + cross-check per-axis scale/translation). Fewer common
  rects ⇒ `build()` returns nil ⇒ controller falls back to the **stable snap** (no guessing).
- **Presentation endpoints, filled for EVERY key:**
  - real source exists → `presentationSource = real source`; else `= inverse(real target)` (entry).
  - real target exists → `presentationTarget = real target`; else `= forward(real source)` (exit).
- `rect(for:)` now interpolates `presentationSource → presentationTarget` for ALL keys.

Occupancy/role/alpha are UNCHANGED: identity decisions still use `sourceOcc/targetOcc` + the real
rects; the previous full-slot-mix fidelity fix (opaque source + target α=lp) and the single
constant-background render are untouched. Entries/exits now MOVE geometrically; their alpha semantics
are unchanged. Settled endpoints stay exact (entry gated off at q=0, exit gated off at q=1).

## Files changed
- `GridTransitionPlan.swift` - added `presentationSourceRect`/`presentationTargetRect`; `rect(for:)`
  interpolates them.
- `GridTransitionComponentBuilder.swift` - added `GridTransitionPresentationTransform` (fit + forward
  + inverse + endpoints); `build()` fits it and fills presentation rects (abort→nil if insufficient);
  `assemble()` threads them into the plan; `GridTransitionLattice` carries them.
- `GridTransitionScheduleTests.swift` - updated the two synthetic lattice fixtures; added 5 tests.

NOT touched: `SquareTileGridEngine`, `TileContentFitter`, resize/rebase, `MetalGridRenderer` (blend),
the feature flag, live pinch.

## Tests added (all pass)
- `mixedKeyStillInterpolatesRealSourceToRealTarget` - mixed geometry unchanged (q0=real src, q1=real tgt, mid between).
- `targetOnlyEntryHasSyntheticSourceGeometry` - entry not drawn at q=0; 0<q<1 differs from final target; q=1 = real target.
- `sourceOnlyExitHasSyntheticTargetGeometry` - exit = real source at q=0; 0<q<1 moves; departed by q≈1.
- `settledEndpointsRemainExact` - q=0 no target-only entry visible; q=1 no source-only exit visible.
- `presentationTransformFitSynthesizeAndAbort` - fit recovers a known transform; synthesizes
  off-grid endpoints for entry/exit; aborts (nil) when too few common rects.
- All previous fidelity/scheduler/flag tests continue passing.

## Commands run and results
```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --target TimelineFeature  → ok
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test  --filter TimelineFeatureTests
  → 266 tests / 37 suites PASSED   (was 261; +5 geometry tests)
```

## App build/install
Rebuilt via `scripts/rebuild.sh` (xcodegen project + vendored `Vendor/sdk-swift` symlink already in
place) and installed to `/Applications/ProtonPhotos.app`; spike code confirmed in
`…/Contents/MacOS/ProtonPhotos.debug.dylib`. Flag `MetalGrid.singleLatticeTransition` already ON.

## Remaining caveats
- **On-device visual acceptance is the user's.** No product acceptance is claimed.
- At the extreme top (anchor on item 0, very few source tiles) the overlap is sparse (≈2 common
  keys) - the transition still runs but is subtle; this matches the earlier "more visible after a bit
  of scrolling" observation. Not a regression.
- **Live pinch remains out of scope / not wired.**
- The single-lattice model is slot-centric: each slot KEY flows along the lattice and occupant
  handoff is a crossfade - there is no single tile "flying" from old to new slot (by design / the
  frozen "no identity rect flights" constraint). The perception of motion comes from the per-key
  geometry flow + the crossfade.

**Product visual acceptance remains with the user.**
