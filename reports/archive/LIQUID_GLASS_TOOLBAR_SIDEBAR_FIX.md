# Native Liquid-Glass Toolbar + Unboxed Sidebar — Fix Report

> **Status: SUPERSEDED** — the native toolbar/sidebar contracts described here are now the live, guard-tested baseline; see [LIQUID_GLASS_PHASE2_REBASE_2026-06-30.md](LIQUID_GLASS_PHASE2_REBASE_2026-06-30.md). Kept for historical reference.

**Branch:** `apple-normal-focusrow-transition`
**Scope:** UI/UX correction only. No grid geometry, pinch/zoom, E2EE, keychain, cache, thumbnail, SDK, upload/download, or data-model changes.
**File touched:** `App/Views/MainView.swift` (27 insertions, 35 deletions — net **−8 lines**).

---

## 1. What was wrong

The grid toolbar *faked* Liquid Glass instead of using the real thing, and that fake leaked onto the sidebar:

| Symptom | Root cause in code (pre-fix) |
| --- | --- |
| Top bar reads as a dark **opaque strip** with a perceptible separate fade | `gridToolbarGlassFade` = a full-width `Rectangle().fill(.bar)` masked by a `LinearGradient`, placed via `.overlay(alignment: .top)` on the grid content (a hand-painted scroll-edge effect living in the **content** layer) |
| Right/search area doesn't feel like glass over content | `.toolbarBackground(AnyShapeStyle(.bar), for: .windowToolbar)` forced an opaque `.bar` material as the toolbar background in grid mode |
| Sidebar looks **boxed/framed** at the top | The same forced `.bar` window-toolbar background paints a band across the **whole** window toolbar — including the `NavigationSplitView` sidebar's titlebar region — so the sidebar's top differs from its body → a boxed seam |

The sidebar list itself (`SidebarView` = `List` + `.listStyle(.sidebar)`) was already clean: no custom border, box, `clipShape`, or wrapper. The boxing was a *symptom* of the forced toolbar band, not the sidebar code.

---

## 2. Required research — Apple guidance and its implications

Sources read (Apple dev docs + HIG + WWDC25/310 & /323). Canonical doc pages serve a JS-only shell to fetchers; substance was recovered from the WWDC25 session content and the HIG Materials/Sidebars/Color pages. Findings are unanimous and directly on-point:

- **The toolbar glass is automatic.** Recompiling against the macOS 26 SDK makes `NSToolbar` (and SwiftUI `.toolbar` items) sit on a content-adaptive Liquid Glass surface that "changes its appearance to suit the brightness of the content behind it." *You do not draw a toolbar background.* (WWDC25/310, /323)
- **The scroll-edge effect is automatic.** `NSScrollView` draws the separation between edge-to-edge content and the floating toolbar — a soft-edge progressive fade/blur or a hard-edge backing — and adapts as chrome comes and goes. **This is exactly what `gridToolbarGlassFade` was hand-rolling.** (WWDC25/310, /323)
- **Remove custom chrome backgrounds.** "If your app has any extra backgrounds or darkening effects behind the bar items, make sure to remove them, as these will interfere with the effect." "Remove custom backgrounds or darkening layers behind system sheets, sidebars, and toolbars." "Prefer to remove custom effects and let the system determine the background appearance." (WWDC25/323, HIG Materials, *Adopting Liquid Glass*)
- **Sidebars now float on glass.** A `NavigationSplitView` sidebar is presented as "a pane of glass that floats above the window's content"; legacy sidebar materials (`NSVisualEffectView`) "will prevent the glass material from showing through… remove these." Don't box/frame the sidebar — it's an inset, edge-to-edge floating surface. (WWDC25/310, /356, HIG Sidebars)
- **Never stack glass on glass** — "glass cannot properly sample other glass." Both the fake `.bar` fade and the forced `.toolbarBackground` are material layered over the system's own toolbar/sidebar glass → invalid. (HIG, WWDC25/219)
- **Active/inactive is system-driven.** Active windows render crisp, inactive ones fade via system opacity. Don't compute your own state dimming; use semantic colors. (HIG Color)

**Implication:** the correct fix is *subtractive* — delete the fakes and let the system render native glass. No new painted chrome.

---

## 3. The fix

All in `App/Views/MainView.swift`:

1. **Deleted `gridToolbarGlassFade`** (the `Rectangle().fill(.bar)` + `LinearGradient` view) and the `.overlay(alignment: .top) { … }` that applied it.
2. **Replaced** the two `.toolbarBackground(…)` calls with a single small `ViewModifier`, `WindowToolbarChrome(isViewer:)`:
   - **Grid mode → applies nothing.** The system renders the native macOS Liquid Glass toolbar, which samples the photos scrolling under it (the window is already `fullSizeContentView` with a transparent titlebar — `ProtonPhotosApp.swift:96–98` — and the grid keeps `.ignoresSafeArea(.container, edges: .top)`).
   - **Viewer mode → keeps the deliberate opaque warm bar** (`ViewerVisualConstants.backgroundColor` + `.visible`). This is Apple's sanctioned escape hatch ("remove custom backgrounds *unless the product explicitly needs them*") — the single-photo viewer is a focused, distraction-free surface, matching Apple Photos' own viewer chrome.
3. **Sidebar:** left as the native `List(.sidebar)`. With the forced `.bar` band gone, it renders as one continuous floating glass surface from the top-left rounded corner down. No sidebar code change was needed (and none was added — Apple says *don't* add a box to "fix" it).

What stayed (all intentional, all required by the spec/guard tests):
- `NavigationSplitView(columnVisibility:)`, `.navigationSplitViewColumnWidth(…)`, `.searchable(text: $searchText, placement: .toolbar)`, `.toolbar { toolbarContent }`.
- The single native sidebar toggle (no custom toolbar toggle button) — unchanged.
- The loading/empty states already use the dark grid surface (`MetalGridPalette.background` + skeleton), not a black screen — left untouched.
- Semantic styles only (no hardcoded active/inactive text opacity).

No private APIs. No unguarded macOS-27-only symbols. The only public API removed (`.toolbarBackground`) is retained for the viewer case.

---

## 4. Verification

| Check | Command | Result |
| --- | --- | --- |
| Package tests (Xcode 26.5) | `swift test` | ✅ **356 tests / 48 suites passed** — incl. `ProductionRouteGuardTests.mainViewUsesNativeSplitViewChrome` |
| App build (Xcode 26.5 / macOS 26 SDK) | `xcodebuild build … -scheme ProtonPhotos` | ✅ exit 0 |
| Package build (Xcode-beta 27.0) | `swift build` | ✅ Build complete — confirms no unguarded macOS-27-only API |

Static acceptance (re-grepped on the final file):
- ✅ No `gridToolbarGlassFade`, no `Rectangle().fill`, no toolbar `LinearGradient`, no `.overlay(alignment: .top)` (only a doc-comment mentions the removed patterns).
- ✅ No custom sidebar border / rounded enclosing container / overlay line / card wrapper anywhere in `App/` or `Packages/.../Sources`.
- ✅ No private Apple API; no `#available(macOS 27…)`-gated or unguarded 27-only symbol.

---

## 5. Open item — must be confirmed visually on a real macOS 26 build

> **Does the native toolbar glass actually sample the Metal grid?**
>
> The grid is a `CAMetalLayer`-backed `MTKView` behind a *transparent* `NSScrollView` (`MetalGridScrollHost`). Apple's docs describe glass sampling "the content behind it," but every documented example is an ordinary AppKit/SwiftUI view — none addresses a separately-rendered Metal layer. In the expected (and most likely) case the compositor includes the `MTKView` in the glass backdrop and you get the full Apple-Photos effect: photos visible-but-blurred behind the bar, glass tinting to bright vs. dark photos. The theoretical failure mode is the glass sampling the dark window background instead.
>
> Either way this change is **strictly better** than the fake opaque strip. If on-device review shows the glass isn't sampling the photos, the sanctioned next step (not applied preemptively) is `backgroundExtensionEffect()` / `NSBackgroundExtensionView`, not re-introducing a painted bar.

**Please verify visually** (a screen recording per our usual flow works): grid toolbar transparency over photos, the soft fade beginning high in the toolbar band, the search capsule reading as glass, the sidebar running continuously top-to-bottom with no box, and a single sidebar toggle.
