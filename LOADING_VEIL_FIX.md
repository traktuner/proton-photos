# Window-Level Frosted Launch Veil — Implementation Report

**Branch:** `apple-normal-focusrow-transition`
**Model:** Apple/Codex-style startup veil. During initial session/library preparation the **whole window** becomes a frosted, behind-window Liquid-Glass surface — you see straight through it to the **desktop and other windows** (the app shell is not drawn behind it) — with a small animated mark centered. When the library is ready it **quickly fades into the real library window**.

## Files
- `App/AppModel.swift` — readiness signal (`isPreparing`, `libraryReady`, `markLibraryReady()`).
- `App/ProtonPhotosApp.swift` — `.launchVeil(active:)` at the WindowGroup root; `LaunchVeilModifier` + `WindowTransparency`.
- `App/Views/MainView.swift` — calls `markLibraryReady()` when the timeline settles.
- `Packages/ProtonPhotosKit/Sources/DesignSystem/LoadingVeil.swift` — `FrostedGlassBackground` (behind-window `NSVisualEffectView`) + `LoadingMark` (animated lattice).
- `Packages/ProtonPhotosKit/Sources/DesignSystem/ProtonComponents.swift` — `ProtonLoadingView` reduced to a quiet fallback spinner.

## How it meets the spec

| Requirement | Implementation |
| --- | --- |
| Cover the **complete window** | `.launchVeil` is applied at the WindowGroup root; the frosted overlay `.ignoresSafeArea()` and spans the full content (under the transparent titlebar). |
| **Nothing of the app** behind it | A behind-window `NSVisualEffectView` renders the blurred desktop and occludes the app views beneath it; the root shows no shell while preparing. |
| **Liquid-glass transparent but frosted — desktop/other windows visible** | `NSVisualEffectView(blendingMode: .behindWindow, material: .fullScreenUI)` **plus** the window made non-opaque (`isOpaque = false`, `backgroundColor = .clear`) by `WindowTransparency` while the veil shows. Behind-window vibrancy samples what's *behind the window* = the desktop. |
| Small, subtle, semi-transparent, animated, original mark | `LoadingMark`: a 2×2 lattice of rounded photo-tile outlines pulsing `0.28…0.78` in a `sin()` wave (`TimelineView(.animation)`), monochrome/vibrant, abstract — not Proton/Apple-Photos/camera/cloud/lock/Codex. |
| **Quick fade into the real library** | When `isPreparing` clears, `withAnimation(.easeOut(0.3)) { visible = false }` crossfades the veil out; `WindowTransparency` restores the opaque window so the real (opaque) library is revealed. |
| Min duration / anti-flicker | Held ≥ `minShown = 0.5 s` from first appearance before it may dismiss. |
| No black screen | The window is frosted-desktop while preparing; the fallback `ProtonLoadingView` is a quiet spinner, never black. |
| Avoid heavy text | No text in the veil; the old "Preparing Library"/"Decrypting metadata…" card was removed. |

## Readiness logic (`AppModel.isPreparing`)
Veil is **active** while: `auth == .checking`, **or** signed-in with backend `.idle`/`.preparing`, **or** signed-in + `.ready` but `facade == nil || !libraryReady`. It is **inactive** for signed-out/authenticating (→ login) and backend `.failed` (→ error). `libraryReady` is set by `MainView` when the timeline first settles (loaded/empty/failed), and reset on sign-out and on each fresh backend build (so re-login shows the veil again).

**Safety net:** a `maxShown = 8 s` hard-dismiss guarantees the veil can never trap the user behind a frosted screen if a first load hangs — it fades regardless, revealing whatever's behind (the fallback spinner or an error).

## Native / public APIs only
`NSVisualEffectView` (`.behindWindow`, `.fullScreenUI`, `.state`), `NSWindow.isOpaque`/`backgroundColor`, `TimelineView(.animation)`, `RoundedRectangle.strokeBorder(.primary)`, `.onChange(of:)`, `withAnimation`. No private APIs; no unguarded macOS-27-only symbols. The original window opacity/background are captured once and restored, so the real library window is left exactly as before.

## Verification

| Check | Result |
| --- | --- |
| `swift test` (Xcode 26.5) | ✅ 356 tests / 48 suites passed |
| `xcodebuild` app (Xcode 26.5 / macOS 26 SDK) | ✅ exit 0 |
| `swift build` (Xcode-beta 27.0) | ✅ no unguarded 27-only API |

## Must confirm by actually running (not unit-testable)
Window transparency + behind-window vibrancy are compositor behaviors. On launch you should see the entire window as frosted glass over your **desktop/other windows**, the 2×2 mark shimmering centered, then a quick crossfade into the real opaque library once the grid is ready. `material: .fullScreenUI` is a one-line tweak if you want a lighter/heavier frost.
