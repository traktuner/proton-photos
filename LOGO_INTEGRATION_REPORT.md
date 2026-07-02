# ProtonPhotos Logo + Loading Mark Integration - Report

**Branch:** `apple-normal-focusrow-transition`

## Summary
- The **full-color** logo (`ProtonPhotos.svg`) is now the macOS **app icon** (Dock / Finder / app bundle).
- The **single-ink** logo (`ProtonPhotos-mono.svg`) is now the **loading mark** in the Liquid-Glass launch veil, with a soft bright highlight that flows diagonally (top-left → bottom-right) **inside the logo strokes only** (masked), honoring Reduce Motion.

There was no asset catalog or app icon in the project before - both were created from scratch. `rsvg-convert` (librsvg) was used to rasterize/vectorize the SVGs; the source SVGs are kept in the repo under `Branding/`.

## Files changed / added
| Path | What |
| --- | --- |
| `Branding/ProtonPhotos.svg`, `Branding/ProtonPhotos-mono.svg` | Source SVGs kept in-repo (per spec) |
| `Branding/ProtonPhotos-mono-cropped.svg` | Mono SVG with a tight `viewBox` so the mark fills its frame |
| `Branding/ProtonPhotosMono.pdf` / `.png`, `Branding/icon/*.png` | Generated intermediates |
| `App/Assets.xcassets/AppIcon.appiconset/` (+ `Contents.json`, 7 PNGs 16–1024) | New macOS app-icon set from the full-color SVG |
| `App/Assets.xcassets/Contents.json` | New catalog root |
| `Packages/ProtonPhotosKit/Sources/DesignSystem/Resources/Branding.xcassets/ProtonPhotosMono.imageset/` | Mono mark as a **template vector PDF** (`preserves-vector-representation` + `template-rendering-intent`) |
| `Packages/ProtonPhotosKit/Package.swift` | `DesignSystem` target gains `resources: [.process("Resources")]` |
| `Packages/ProtonPhotosKit/Sources/DesignSystem/LoadingVeil.swift` | `LoadingMark` rewritten to the masked-shimmer mono logo |
| `project.yml` | App target gains `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` |

## Implementation approach

### App icon
`rsvg-convert` rendered the full-color SVG to PNGs at 16/32/64/128/256/512/1024 px, wired into a standard macOS `AppIcon.appiconset`. `project.yml` sets `ASSETCATALOG_COMPILER_APPICON_NAME=AppIcon`; xcodegen regenerates the project and the build compiles `Assets.car` + sets `CFBundleIconName`.

### Loading mark (exactly the requested SwiftUI structure)
`LoadingMark` (in `DesignSystem`, used by the window-level launch veil):
- `Image("ProtonPhotosMono", bundle: .module)` (a template vector PDF) is rendered twice from one shaping: once as the **base ink** (`.foregroundStyle(.primary).opacity(0.28)` - subtle, adapts to light/dark), and once as the **mask**.
- A moving `LinearGradient` (`clear → .primary @0.95 → clear`) whose `startPoint`/`endPoint` slide diagonally so the bright midpoint travels from off the top-left to off the bottom-right, then `.mask(theLogo)` so the highlight appears **only inside the logo strokes** - no rectangle, no glow, no halo, no shadow, no blurred aura.
- Period ≈ 1.6 s, linear, off-screen at both ends (seamless loop). `@Environment(\.accessibilityReduceMotion)` → static ink, no shimmer.

The loading screen itself is unchanged (the existing frosted, behind-window Liquid-Glass launch veil over a transparent window): no black screen, desktop/window context visible through the glass, minimal text.

## Verification - build/tests
```
swift test (Xcode 26.5)                → 356 tests / 48 suites passed
xcodebuild app (Xcode 26.5, macOS 26)  → BUILD SUCCEEDED  (Assets.car + CFBundleIconName=AppIcon present)
swift build (Xcode-beta 27.0)          → Build complete   (no unguarded 27-only API)
```
Confirmed in the built bundle: `Contents/Resources/Assets.car`, `CFBundleIconName=AppIcon`, and the mono mark inside `ProtonPhotosKit_DesignSystem.bundle/Contents/Resources/Assets.car` (asset name `ProtonPhotosMono`).

## Verification - visual QA (live app, computer-use)
To inspect the brief loading mark I temporarily pinned the veil on, rebuilt, captured frames, then reverted the timings (no temp values remain - grep-clean). Observed and confirmed:
- ✅ Whole window is frosted Liquid Glass; the **desktop wallpaper is visible/blurred through it**.
- ✅ The mono logo is **centered**.
- ✅ The bright highlight **travels diagonally top-left → bottom-right inside the logo strokes only** (verified across a frame burst; off-screen pause between loops).
- ✅ **No outer glow / halo / drop shadow / blurred aura**; no visible sweeping rectangle.
- ✅ App **transitions cleanly** from the loading veil to the real library (and the 8 s safety timeout dismisses it if a load hangs).

Screenshots of each loading frame are shown inline in this conversation (the shimmer sweep across 5 frames). The frosted-glass + masked-shimmer behavior is a window-server effect, so it can't be unit-tested - the live capture is the proof.

## Caveats / tunables
- The mark is intentionally subtle (base opacity 0.28; spec range 0.20–0.35). Over a very bright wallpaper it reads faint between highlight passes - `baseOpacity` / `highlightOpacity` / `period` in `LoadingMark` are one-line tweaks if you want it stronger.
- During the *final* library-load instant (backend ready, MainView built, grid still loading) the glass toolbar can appear above the veil; during the longer pre-shell phases there is no toolbar and the veil covers the whole window.
