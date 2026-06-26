# Phase B — V3.9 Continuous Multi-Level Live Pinch

Makes the live trackpad pinch **chain continuously through multiple levels in one uninterrupted gesture**
(e.g. L3→L2→L1→L0 without lifting), instead of V3.8's one-adjacent-pair-then-settle. The grid is now one
continuous scrub surface across detents. Builds on V3.8 (`PHASE_B_PINCH_LIVE_DRIVER_REPORT.md`); the V3.7
**click path is unchanged** and everything stays behind the default-OFF `MetalGrid.singleLatticeTransition`
flag.

Branch `phaseb-pinch071-clickv2-420` (worktree `ProtonPhotos-phaseb-spike`).

---

## What changed vs V3.8

V3.8 modeled ONE adjacent pair per gesture and *latched* near the target (so you had to lift and re-pinch for
the next level — exactly the behavior to remove). V3.9 replaces the capture-latch with a **floor(x)-based
segment model + continuous scrub + release-settle**:

| File | Change |
|---|---|
| `PinchLiveZoomDriver.swift` | **Rewritten.** Continuous chaining: active segment = `[floor(x), floor(x)+1]`; `segmentQ = (floor(x)+1) − x`; detent hysteresis; velocity from global x; release→nearest detent. No capture phase. |
| `GridTransitionTuning.swift` | Pinch tunables updated: removed the two capture thresholds, added `pinchDetentHysteresisQ`. |
| `MetalGridCoordinator.swift` | `eligiblePinchChainBand`, `pinchDetentParams` (start=actual / others=cursor-aligned), `tryBuildPinchSegment(source,target)`, `commitPinchChain(toLevel:)` — replace V3.8's single-target build/commit. |
| `MetalGridScrollHost.swift` | First-direction lattice-vs-reflow decision; segment rebuild on each detent crossing; release-settle + commit of the final detent; `finishInFlightPinchSettle` retained. |

---

## Exact state machine

The host feeds the physical pinch position as a continuous level `x` (level units across the ladder) + the
wall-clock `dt`. The driver owns the **active segment** and **segmentQ**.

```
              begin(startLevel, chainLo, chainHi)        // chain band = contiguous focusRowRelayout run
                              │                          // (normal levels ⇒ [0,3])
                              ▼
   ┌──────────────────────── .scrub ─────────────────────────────────────────────┐
   │  x ← clamp(rawX, chainLo, chainHi)                                            │
   │  velocity ← EMA(|Δx|/dt)            (GLOBAL x ⇒ continuous across crossings)   │
   │  seg ← interval index for x, moved one detent at a time with hysteresis:      │
   │          while seg>lo  and  seg − x  > hyst : seg--                           │
   │          while seg<hi-1 and x − (seg+1) > hyst : seg++      (fast flick loops) │
   │  segmentSource = seg+1 (denser)   segmentTarget = seg (larger)                 │
   │  segmentQ = clamp((seg+1) − x, 0, 1)            ← 1:1 with the finger          │
   │                                                                               │
   │  • finger still  ⇒ x const ⇒ segmentQ const (grid still)                      │
   │  • cross a detent⇒ seg changes ⇒ host rebuilds the segment plan (seam-cont.)   │
   │  • out-of-band   ⇒ x clamped ⇒ holds at the boundary detent                   │
   └───────────────────────────────────────────┬───────────────────────────────────┘
                                       release() (fingers up)
                                                │  nearest detent:
                                                │   segmentQ ≥ releaseCommitQ ? target : source
                                                ▼
                                    ┌──────── .settling ────────┐
                                    │ ramp segmentQ → 0 / 1 at  │
                                    │ clamp(velEMA, min, max)q/s │
                                    └─────────────┬──────────────┘
                                                  ▼
                                            .committed (finalLevel)
                                            host commits that detent, reset()
```

Two clocks, never double-counted: `update(x,dt)` picks the interval + sets `segmentQ` (scrub) and tracks
velocity; `advance(dt)` (display tick) only runs the post-release settle ramp. There is **no mid-gesture
latch** — the grid follows the finger until release.

### How `segmentQ` is derived from the global continuous level

The global position `x` (from the trackpad magnification, the same quantity the legacy reflow uses) is
authoritative. The active interval is the integer bracket of `x`; within it, `segmentQ = (floor(x)+1) − x` —
a pure 1:1 mapping. So `x = 2.35` ⇒ interval `[2,3]`, `segmentQ = 0.65` (65% of the way from L3 toward L2);
`x = 1.72` ⇒ `[1,2]`, `segmentQ = 0.28`. As `x` sweeps `3 → 0`, the displayed segment walks
`[3→2] → [2→1] → [1→0]`, each q sweeping `0 → 1`, with no settle in between.

### How segment "rebasing" (the seam) works

Each detent `D` has a **deterministic** presentation frame for the whole gesture (`pinchDetentParams`):
- the gesture-**START** detent keeps the **actual on-screen** (phase, scroll) — so q at the start matches the
  live screen, and returning lands exactly back;
- every **other** detent uses the **cursor-aligned** phase + anchored scroll — so the photo under the cursor
  stays pinned through the whole chain.

Because a detent's frame is a pure function of the (fixed) gesture anchor + the detent, **any two adjacent
segments that share a detent get the IDENTICAL frame there.** Therefore the previous segment at `q=1` and the
next at `q=0` render the same detent identically: a continuous seam with **no blank frame, no commit bridge,
and no hard snap** between segments. Crossing a detent just rebuilds the plan for the new interval (cheap; only
on a crossing). Nothing is committed mid-gesture — the actual scroll view stays frozen at the gesture-start
origin and each segment renders the crossfade in viewport space; only the **final** detent is committed +
scrolled to on release.

### What happens at the ineligible overview boundary

The single-lattice transition is only defined for adjacent **normal-level** steps (`L0↔L1↔L2↔L3`,
`transitionKindToNext == .focusRowRelayout`). The chain is bounded to that contiguous band. On the **first**
resolved direction the host decides:
- in-band step ⇒ **lattice** (continuous chaining within `[0,3]`);
- out-of-band step (e.g. `L3→L4` toward the dense overview) or flag OFF ⇒ the **legacy
  `GridZoomTransaction` reflow** (V3.8 fallback, byte-unchanged).

Once in lattice mode, pinching *past* the band boundary clamps at the boundary detent (the grid holds there);
to continue into the overview levels the user lifts and re-pinches (which the reflow handles). **Overview
crossfade is intentionally not implemented** (per the Non-Goals) — documented fallback.

---

## Tests added (all green)

`PinchLiveZoomDriverTests.swift` (rewritten for V3.9):
chains **L3→L2→L1→L0 without reset** · reverse chains **L0→L1→L2→L3** · slow scrub tracks 1:1 · still finger
holds grid · **segmentQ resets cleanly at a detent crossing** · **seam shares the crossed detent** · reversal
across a boundary is stable · fast flick jumps to the final segment · release mid-segment settles the nearest
detent · settle is velocity-aware (no instant snap) · large-advance force-finish · band-edge clamp · rest
dead-band · release-before-move commits start · interior start chains both ways · reset.

`GridTransitionScheduleTests.swift`:
**chaining seam — adjacent segments sharing a detent render it identically** (`[3→2]@q=1 == [2→1]@q=0`) ·
single-segment endpoint seam (q=0 source frame / q=1 target frame on real engine geometry) · lattice
eligibility boundary (L0–L2 eligible, L3→overview not).

`GridTransitionControllerTests.swift`: the V3.8 pinch-plan tests (host-driven q, reversible, flag gating)
remain valid. The **V3.7 click + engine/contract tests are unchanged and still pass.**

## Commands run

```
cd Packages/ProtonPhotosKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build --target TimelineFeature   # clean
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test  --filter TimelineFeatureTests
#   → 294 tests / 38 suites PASSED  (289 + 5 added from the review fixes below)
```

## Adversarial review

Ran a 3-lens adversarial review (driver math · seam/coordinator · host/contract), each finding independently
verified by a skeptic. **5 confirmed, 2 refuted** — notably the "shared-detent seam is discontinuous" claim was
**refuted** as a control-flow misreading, confirming the seam design. None of the confirmed code findings fire
in the default config; all fixed regardless:

| Sev | Finding | Action |
|---|---|---|
| minor | `pinchDisplayLowPassAlpha < 1` would smear `segmentQ` across a detent crossing (carrying the old segment's value), bypassing the shared-detent seam. Inert at the default 1.0. | **FIXED** — the low-pass now resets to `rawQ` on an interval swap. (+test) |
| minor | A mid-chain segment-build failure would strand the active `.pinch` plan (frozen frame). Unreachable — the eligible band guarantees every in-band step builds — but latent. | **FIXED** — `abortPinchPlan()` tears the plan down before handing to reflow on the same frame. |
| nit | `begin()` on a degenerate band (`lo == hi`, overview start) computed an out-of-band interval. Unreachable (the host routes degenerate bands to reflow). | **FIXED** — `chainable` guard makes a degenerate band inert. (+test) |
| minor | Band first-direction decision / overview fallback under-tested. | **ADDRESSED** — added the pure chain-band structure test (mirrors `eligiblePinchChainBand`); the live host decision remains GPU-bound (see caveats). |
| minor | Reversal/release tested only mid-band. | **ADDRESSED** — added release-at-exactly-0.5 tie-break (→ target) and release-at-chain-extreme tests. |

## App rebuild status

- **Package target builds clean** and the **full suite is green (294/294)**.
- **Full app REBUILT + INSTALLED + LAUNCHED** with the review fixes: `xcodegen generate` + `Scripts/rebuild.sh`
  → **BUILD SUCCEEDED**, installed as the single canonical `/Applications/ProtonPhotos.app` (Spotlight finds
  exactly one bundle) and launched.
- **Feature flag ENABLED:** `defaults write me.protonphotos.mac MetalGrid.singleLatticeTransition -bool YES`.
- **Installed binary verified:** `strings`/`nm` on `…/ProtonPhotos.app/Contents/MacOS/ProtonPhotos.debug.dylib`
  contain `PinchLiveZoomDriver`, the V3.9-only `pinchDetentHysteresisQ` tunable, and the V3.9 coordinator
  methods `tryBuildPinchSegment` / `commitPinchChain` / `eligiblePinchChainBand` / `abortPinchPlan`.

---

## Remaining visual tuning caveats

1. **No on-device acceptance yet.** Verified headlessly (unit tests + build). The chaining feel, the detent
   hysteresis (`0.02`), the release-settle band (`1.8–8.0` q/s), and the rest dead-band (`0.02`) are first-pass
   tunables in `GridTransitionTuning` to dial in on device. **Final visual acceptance remains with the user.**
2. **Overview boundary uses the reflow (by design).** A single gesture chains continuously only within the
   normal band `[L0–L3]`; the `L3↔overview` step uses the legacy `GridZoomTransaction` reflow, and a gesture is
   either lattice (in-band first step) or reflow (out-of-band first step) — it does not switch mid-gesture.
   Extending the continuous crossfade across the overview boundary is a documented follow-up.
3. **Fast multi-level flicks skip intermediate crossfades.** If `x` jumps several levels in one ~16 ms frame,
   the driver lands directly on the final segment (the intermediate levels had no frame to render) — the same
   limitation any 1:1 input has. Normal-speed pinches render every segment.
4. **Flag default OFF.** Flag off or any out-of-band/ineligible step ⇒ the accepted geometry-only reflow,
   byte-for-byte unchanged. Phase B remains a spike: modular, flag-gated, tunable, reversible. **No merge.**

_Final visual/product acceptance remains with the user._
