# Toolbar Frost Gradient — Measured 1:1 Match to Apple Photos

**Branch:** `apple-normal-focusrow-transition`
**File:** `App/Views/MainView.swift` (`GridTopFrost`, `WithinWindowBlur`, + the `.overlay(alignment:.top)` on the grid detail).

## Root cause
After the earlier Liquid-Glass pass, the grid toolbar was **fully transparent**: the native macOS toolbar glass / scroll-edge effect can't sample the production grid, because it's a `CAMetalLayer`-backed `MTKView` behind a transparent `NSScrollView`, not an AppKit/SwiftUI scroll view the system recognizes. So "let the system do it" yields no frost at all.

## Fix
A **public-AppKit bridge**, scoped to the grid (detail) only — never the sidebar, never a flat opaque strip, never blocking pointer/scroll:
- `WithinWindowBlur` = `NSVisualEffectView(blendingMode: .withinWindow, material: .headerView)`. Within-window vibrancy **does** sample + blur the Metal grid behind it (verified live), and adapts to content + active/inactive state on its own.
- Masked by a vertical `LinearGradient` whose **alpha profile was measured pixel-by-pixel from Apple Photos**, not guessed.

## How the profile was measured
Captured Apple Photos (dark mode) at full retina res (`screencapture`, 4112×2658) with a landscape photo's **uniform blue sky** under the toolbar, then sampled luminance down a column in the title→controls gap (a small Swift/CGImage tool — no deps). Modeling `lum = (1−α)·sky + α·material` with clear sky L≈0.565 and full-frost L≈0.205 recovers the frost opacity α at each row:

| band fraction t | α (Apple) |
| --- | --- |
| 0.00 – 0.40 | ≈1.00 (hold — full frost behind the controls) |
| 0.52 | 0.78 |
| 0.62 | 0.64 |
| 0.66 | 0.56 |
| 0.73 | 0.31 (steep) |
| 0.80 | 0.18 |
| 0.92 | 0.05 |
| 1.00 | 0.00 (clear) |

Key findings (vs. a naïve "frosted→clear"):
- **It holds at FULL frost for the top ~40%** of the band (behind the controls), *then* fades — it does not start fading from the very top.
- The fade is an **S-curve** (gentle, then steep around t≈0.66–0.80, then a soft tail), not linear.
- In dark mode the material **darkens** the photos (sky 0.565 → 0.205), it doesn't lighten them.
- Band geometry: window-content top at retina y≈138; full frost to y≈195; clear by y≈281 → **band height ≈ 72 pt = toolbar (~52) + ~20 pt fade tail**; hold = 40 %.

These map directly to the `GridTopFrost` mask stops and `height = topBarInset + 20`.

## Verification that the match is faithful
Measured the **same way** on the shipped ProtonPhotos build:
- Full-frost luminance **≈0.20** (Apple ≈0.205) — `.headerView` darkness matches.
- Band top at retina y≈138 (same as Apple).
- Fade completes by retina y≈280 (Apple ≈281).
- Visually: the top photos are frosted/blurred and fade to clear into the grid; controls sit on the frosted part; the sidebar is untouched.

## Constraints honored
No `Rectangle().fill(.bar)` strip, no opaque toolbar background, no overlay over the sidebar, no private API, no unguarded macOS-27 API. The frost is one small commented view; the gradient shape is applied with SwiftUI `.mask` (no AppKit coordinate-flip to reason about).

## Tunables
`GridTopFrost`'s mask stops + `height` and `WithinWindowBlur`'s `material` are the knobs. If a future macOS point-release changes the toolbar height, the band tracks it via `topBarInset`.
