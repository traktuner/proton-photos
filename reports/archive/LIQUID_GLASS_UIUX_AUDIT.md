# Native Liquid Glass UI/UX Audit - ProtonPhotos (macOS)

> **Status: SUPERSEDED** - replaced by [LIQUID_GLASS_PHASE2_REBASE_2026-06-30.md](LIQUID_GLASS_PHASE2_REBASE_2026-06-30.md). Kept for historical reference.

Date: 2026-06-25 · Scope: **full app**, documentation only.
**No UI was changed in this pass.** This audit inventories every surface, flags where it deviates from
native AppKit/SwiftUI primitives (especially any hand-rolled "glass"/blur), and recommends a native-first
direction so the app inherits macOS 27 Liquid Glass automatically.

## Methodology & principles

- **Baseline = Apple Photos parity**, not pixel copying; photos dominate, chrome stays calm and content-first.
- **Prefer native primitives** (`.toolbar`, `.glassEffect`, `.regularMaterial`, `List(.sidebar)`, `Form`, `Menu`, `ContentUnavailableView`, `NavigationSplitView`, `.searchable`, `.inspector`, `.confirmationDialog`) so the app rides system appearance + future Liquid Glass for free.
- **Do not fake glass** with custom blur/overlays unless no native API fills the role.
- 35 surfaces were inventoried across grid, viewer, sidebar, login, settings, upload/export, albums/favorites/trash, info panel, popovers/sheets/menus, search, selection, empty/loading/error, and developer windows.

## Verdict at a glance

The app is **already substantially native-glass** - the viewer, grid toolbar, settings, save/open panels,
menus, and most overlays use real `.glassEffect`/`.regularMaterial`/`.bar`/native controls. The gaps are
concentrated in four themes, none of which is a widespread fake-glass problem:

1. **Three genuine custom/legacy "glass" surfaces** (the only real glass deviations).
2. **Hardcoded colors & fonts** (`ProtonColors`/`ProtonComponents`) reimplementing semantic system styles → won't render correctly over Liquid-Glass vibrancy and won't track appearance/Dynamic Type.
3. **Hand-rolled containers** where a native one exists (`NavigationSplitView`, `ContentUnavailableView`, `.inspector`, `Form`).
4. **Missing native affordances** (`.contextMenu`, `.confirmationDialog`, `.searchable`) - gaps, not violations.

Plus one global lever: `.preferredColorScheme(.dark)` is force-locked app-wide, which prevents every native
material from adapting to system light/dark/contrast.

| Severity | Count | Meaning |
|---|---|---|
| aligned | ~13 | Already native; inherits Liquid Glass for free |
| minor | ~12 | Cosmetic native-ization (semantic fonts/colors, small swaps) |
| moderate | ~9 | Structural: adopt a native container / replace a hand-rolled one |
| major | 0 | - |

---

## Priority 1 - The only genuine custom/legacy "glass" surfaces

These are the surfaces that fake or use pre-Liquid-Glass materials and therefore will **not** inherit
macOS 27 Liquid Glass automatically. Everything else in the app that looks like glass already uses the
native API.

| Surface | What it does today | Why it deviates | Native direction |
|---|---|---|---|
| **Grid month/date header pill** - `TimelineFeature/GridHeaderViews.swift:14-49` | Hand-built AppKit `NSVisualEffectView` (`material=.hudWindow`) + manual `cornerRadius`, overlaid on the Metal grid by `MetalGridHeaderRenderer` | Uses **legacy vibrancy** (`.hudWindow`), not the new glass material - reads slightly different from the app's `.glassEffect` pills and won't auto-adopt Liquid Glass | `NSGlassEffectView` (AppKit, macOS 26+) for the pill, or render the label through SwiftUI `.glassEffect(in: Capsule())`. Moderate (lives in the Metal overlay layer). |
| **Viewer center title pill** - `App/Views/MainView.swift:504-521` | `VStack` of two `Text` lines with `.background(.white.opacity(0.09), in: Capsule())` + hardcoded white text | A **flat translucent-white fill**, not a material - a hand-rolled fake-glass capsule | `.glassEffect(in: Capsule())` (already used elsewhere) or a native principal toolbar title; semantic text styles. Minor. |
| **Upload queue popover** - `UploadFeature/UploadQueuePanel.swift:28` | Native `.popover` whose panel sets `.background(.regularMaterial)` on top of the popover's own material | **Double-stacks materials** - the popover already provides a vibrant background; the extra `.regularMaterial` + fixed size fights popover auto-sizing and can look heavier/darker than native | Drop the explicit `.regularMaterial`; let the popover own its material. Moderate. |

---

## Priority 2 - Hardcoded design tokens vs semantic system styles

`DesignSystem` reimplements parts of the system palette/typography. Fixed hex/px values don't render
vibrantly over Liquid-Glass materials and don't track appearance or Dynamic Type.

| Item | Today | Native direction |
|---|---|---|
| `ProtonColors.swift:8-34` | ~20 hardcoded sRGB hex tokens (brand + **neutrals**: backgrounds/text/borders) | Keep brand purple + signal colors (legitimately custom); replace **neutrals** (`backgroundNorm/Weak/Strong`, `textNorm/Weak/Hint`, `borderNorm/Weak`) with semantic system colors (`.primary`/`.secondary`, `NSColor.windowBackgroundColor`/`.separatorColor`) so foregrounds inherit material vibrancy |
| `ProtonComponents.swift:5-25` `ProtonPrimaryButtonStyle` | Custom rounded-fill button | Largely **dead** - the live sites already use `.glassProminent` (`TimelineView.swift:108`, `LoginView.swift:64`, `ProtonPhotosApp.swift:165`). Tint `.glassProminent` with brand purple and delete this style |
| `ProtonComponents.swift:30-56` `ProtonSpinner` | Hand-built rotating arc | `ProgressView().tint(ProtonColor.primary)` - already what `ProtonLoadingView` and every overlay actually use. Delete `ProtonSpinner` |
| Fixed `.font(.system(size:))` across `LoginView`, `SettingsView`, `TimelineView`, viewer chrome, sheets | Pixel-locked type | Semantic `Font` styles (`.largeTitle`/`.headline`/`.callout`/`.caption`) + `.foregroundStyle(.primary/.secondary)` for Dynamic Type + contrast |
| Grid background `TimelineView.swift:74` | `ProtonColor.backgroundNorm` (#16141C) | A native semantic window background so the chrore region reads correctly under toolbar glass |

---

## Priority 3 - Hand-rolled containers where a native one exists

| Surface | Today | Native direction |
|---|---|---|
| **Sidebar** - `MainView.swift:64-80, 772-835, 839-867` | Native `List(.sidebar)` **content**, but wrapped in a manual `HStack` + bespoke `SidebarResizeHandle` (Rectangle + `DragGesture` + `NSCursor`) + opacity/width collapse, inside `NavigationStack` | `NavigationSplitView` - provides native sidebar material, system collapse/expand toggle, native column resize with the standard divider/cursor, and persisted width. Deletes the custom handle. Moderate. |
| **Info / metadata panel** - `InfoPanelView.swift:27`, `PhotoViewerView.swift:73-90`, `ViewerChromeLayout.swift` | Surface is native `.regularMaterial` + native `Map` + glass close button, but the panel is **hand-placed** via `HStack` + width arithmetic; labels use hardcoded `.white` | `.inspector(isPresented:)` for system-managed material edges + resize; semantic foreground styles. Minor-moderate. |
| **Backend error / retry** - `ProtonPhotosApp.swift:146-174` | Hand-rolled centered `VStack` + SF Symbol + fixed fonts | `ContentUnavailableView("Couldn't open your library", systemImage:, description:)` with the existing glass Retry/Sign-out actions |
| **Grid empty state** - `TimelineView.swift:79-92` | Hand-rolled `VStack` (`photo.on.rectangle.angled` + two `Text`) | `ContentUnavailableView("No Photos", systemImage:)` - the exact native API |
| **Grid / upload-queue error & empty** - `TimelineView.swift:94-113`, `UploadQueuePanel.swift:52-62` | Hand-rolled error/empty `VStack`s | `ContentUnavailableView` (keep the glass Retry as its action) |
| **Upload destination sheet** - `UploadDestinationSheet.swift:22-63` | Native controls (radioGroup `Picker`, checkbox `Toggle`, roundedBorder `TextField`, keyboard-shortcut buttons) in a **fixed-width hand-spaced `VStack`** | Wrap in a grouped `Form`; move Cancel/Upload to `.toolbar(confirmationAction/cancellationAction)` for standard sheet metrics |
| **Developer tuning window** - `TuningView.swift:11-41` | Native `Slider`s in an ungrouped `VStack`/`ScrollView` | Grouped `Form` to match the Settings panes (dev-only, low priority) |

---

## Priority 4 - Missing native affordances (coverage gaps, not deviations)

| Affordance | State | Native direction |
|---|---|---|
| **Context menus** | `.contextMenu` appears **nowhere** in the app | Right-click `.contextMenu` on grid cells (Favorite / Download / Move to Trash) and sidebar album rows (Rename / Delete) - Apple Photos parity |
| **Confirmation dialogs** | Only one native `.alert` (delete offline cache); bulk **trash fires optimistically with no confirmation** | `.confirmationDialog` before multi-select trash |
| **Search** | No search anywhere (`.searchable`/`NSSearchField` absent) | `.searchable(text:)` on the timeline/sidebar when search is built - gives the native search field + Liquid-Glass search treatment |
| **Favorites/Trash** | Server-backed, surfaced via native toolbar buttons + sidebar filters (correct) | Add the context-menu + confirmation affordances above |

---

## Cross-cutting: the global dark lock

`App/ProtonPhotosApp.swift:15,81` forces `.preferredColorScheme(.dark)` on the root `WindowGroup` (and the
lab window). This pushes **every** native material - sheets, popovers, sidebar, menus, the toolbar bar -
into dark regardless of the system setting, blocking the appearance/contrast adaptation that Liquid Glass
relies on. The titlebar treatment itself is already correct (`titlebarAppearsTransparent` + `.fullSizeContentView`
+ native `.bar` toolbar background = glass-under-toolbar). **Recommendation:** if a dark look is a brand
requirement, prefer per-surface tint over a global scheme lock so native materials can still adapt.

---

## Already aligned (no change needed)

These surfaces already use the right native primitives and inherit Liquid Glass for free:

- **Grid toolbar** (`.toolbar` + `.toolbarBackground(.bar)`, `ControlGroup` zoom stepper, `Menu`, SF Symbols) - `MainView.swift:88-96, 582-595`.
- **Selection mode** - expressed through native toolbar `Button`/`Label` with `.disabled()` gating; blue outline drawn in the Metal grid.
- **Viewer nav arrows & action buttons** - `.glassEffect(.regular.tint(...).interactive(), in: Circle())` over SF Symbols - `PhotoViewerView.swift:203-216`.
- **Viewer loading/error & export cards** - real `.glassEffect(in: RoundedRectangle/Circle)` around native `ProgressView` - `PhotoViewerView.swift:117-174`, `MainView.swift:153-160`.
- **Settings + cache-status panes** - native grouped `Form`, `Toggle`, destructive `.alert`, `TabView` settings - `SettingsView.swift`.
- **Upload entry points & download/export** - native `CommandGroup`, `Menu`, `NSOpenPanel`/`NSSavePanel` with content-type filtering, native zip via `NSFileCoordinator`.
- **Upload refresh toast** - `.regularMaterial` in `Capsule` (no native toast exists; this is the accepted approximation).
- **Albums module** - no custom-glass UI; listing rides the native sidebar `List`; unsupported writes honestly gated with disabled items + a lock `Label`.
- **Toolbar controls** - native `ControlGroup`/`Menu`/`ToolbarItemGroup` with `.help()` tooltips.

---

## Suggested sequencing (when UI work is greenlit - not this pass)

1. **Quick native-ization wins** (low risk, high consistency): swap the three Priority-1 glass surfaces to native glass; delete dead `ProtonPrimaryButtonStyle`/`ProtonSpinner`; `ContentUnavailableView` for the empty/error states.
2. **Token migration**: replace neutral `ProtonColors` with semantic system colors and fixed fonts with semantic `Font` styles app-wide.
3. **Container migration**: `NavigationSplitView` for the sidebar; `.inspector()` for the info panel; `Form` for the upload sheet.
4. **Affordance gaps**: grid `.contextMenu`, bulk-trash `.confirmationDialog`, `.searchable`.
5. **Re-evaluate the global `.dark` lock** against brand requirements.

Each step keeps the app fully native AppKit/SwiftUI so it inherits Liquid Glass behavior changes in
macOS 27+ automatically through the native primitives, per the goal.
