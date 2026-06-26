# Edge/Corner Zoom Rebase — Animated Bridge (no abrupt snap)

Date: 2026-06-26 · Branch: `apple-normal-focusrow-transition`

## 1. Root cause (exact files/functions)

The reference video (`~/Desktop/Bildschirmaufnahme 2026-06-26 um 05.57.15.mov`) could **not** be opened by the
tooling — macOS TCC denies Desktop access to the shell/ffmpeg even with the sandbox disabled, so frame
extraction failed. The root cause was instead traced from the user's precise description (zoom-out from a
corner/edge → instant positional rebase) through the code.

There were **two instant (un-animated) scroll corrections**, both in the settled/commit path:

1. **`MetalGridCoordinator.drawEngineFrame` (settled branch).** When a zoom-out shrinks the content below
   the current camera, the settled render clamped the camera with an instant `clip.scroll(to: clampedY)`
   (`MetalGridCoordinator.swift`, the `else` settled branch). That is the visible snap.

2. **`MetalGridScrollHost.commitLivePinch` / `commitOverviewDissolve`.** On release, these hand off from the
   gesture's **cursor-anchored** frame to the **legal clamped** settled scroll via an instant
   `scrollView.contentView.scroll(to: committedY)`. At a corner/edge the anchored scroll is out of bounds, so
   `committedY = clamp(anchoredY)` differs from the displayed position → the grid jumps by `anchoredY − committedY`.

(The `.reflow` path already animates its rebase through the existing `GridZoomCommitBridge` — the transaction
bridge interpolates each item's rect transaction‑final → settled‑at‑`clampedY`. It was left as‑is.)

## 2. Minimal code change — a general, animated scroll‑rebase bridge

`GridEngine → presentation` is preserved: the engine still owns all geometry; the bridge only eases the **camera
Y** between two engine‑derived scrolls and ends exactly at the canonical settled scroll.

- **New `GridScrollRebase.swift`** (pure, deterministic): `shouldArm(fromY,toY)` (delta > `minPx` 1.5),
  quadratic `easeOut`, `scrollY(fromY,toY,progress)` (monotonic, `scrollY(…,1) == toY`), `progress(start,now)`,
  and a named `duration` of **150 ms** (within 120–180 ms). No bounce, no animation state in the engine.
- **`MetalGridCoordinator`**: a small rebase state + `beginScrollRebase(fromY:toY:)` / `isScrollRebasing`. The
  settled `drawEngineFrame` now (a) renders the grid at the eased interpolated scroll while a rebase is in
  flight, and (b) when it detects an out‑of‑bounds camera, **arms** the rebase and slides to legal instead of
  snapping. Identity‑stable: it is a uniform scroll translation of the same engine slots — no item is replaced;
  it draws the one continuous background plane of the normal settled render.
- **`MetalGridScrollHost`**: `commitLivePinch` and `commitOverviewDissolve` call
  `coordinator.beginScrollRebase(fromY: anchoredY, toY: committedY)` after committing — a no‑op when there is no
  clamp (normal commits), an animated slide at an edge/corner. The display tick keeps redrawing while
  `isScrollRebasing`, and the existing scroll‑lock now also holds during the rebase (`isScrollBlocking`).

Routing through the bridge is per the task: the `.reflow` path already used `GridZoomCommitBridge`; the
lattice/overview/settled‑clamp cases now also animate instead of snapping. No grid‑effect feature flag was
added (the production route guard test forbids it). No grid level/thumbnail/E2EE/cache/session/offline code was
touched.

## 3. Focused tests (`GridScrollRebaseTests.swift`)

| Test | Acceptance |
|---|---|
| `armsOnlyWhenSourceDiffersFromTarget` | (2) bridge armed only when source ≠ target; (6) normal commit = no bridge |
| `interpolatesMonotonicallyNoBounce` | (3) monotonic source→target, never overshoots (no bounce) |
| `finalFrameEqualsTargetExactly` | (4) bridge final == canonical settled scroll exactly |
| `easeOutIsClampedAndMonotonic` | ease‑out shape, clamped |
| `progressClampsToUnitInterval` | deterministic time→progress, duration within the 120–180 ms window |

Identity‑stability (5) holds by construction — the bridge renders the same engine slots at an interpolated
scroll (uniform translation), never a second layout model or a replacement. Rubber‑band over‑zoom (7) and the
no‑flag invariant (8) are covered by the existing `GridLiveZoomBoundsTests` and `ProductionRouteGuardTests`,
which still pass.

## 4. Full test result

`DEVELOPER_DIR=… swift test` → **Test run with 352 tests in 47 suites passed**, 0 failures. The accepted
`PinchLiveZoomDriverTests`, `GridTransitionControllerTests`, `GridTransitionScheduleTests`,
`OverviewLayerDissolveTests`, `GridLiveZoomBoundsTests`, and `Production route guards` suites all still pass —
no regression.

## 5. App build result

`xcodebuild build … -derivedDataPath build/DD.noindex …` → **BUILD SUCCEEDED**.

## 6. Installed app

**`/Applications/ProtonPhotos.app` was NOT touched** — the build output went to `build/DD.noindex`; I did not
run `scripts/rebuild.sh` or install/launch. Its mtime is unchanged (`Jun 26 05:56`, the prior build).

## Keychain note (separate issue — not touched)

The screenshot's Keychain prompt for `me.protonphotos.mac.session` is the expected one‑time prompt when a local
dev build's code signature / Keychain ACL changes. It must **not** be "fixed" with plaintext session storage,
and auth/session/E2EE were not touched in this task. If, after clicking "Immer erlauben" following the latest
stable signing/re‑save, the prompt still appears on **every** launch, that is a separate Keychain ACL/signing
issue to investigate on its own — unrelated to this grid‑animation change.
