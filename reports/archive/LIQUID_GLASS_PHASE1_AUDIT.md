# ProtonPhotos - Native Liquid Glass UI/UX Audit (Phase 1)

> **Status: SUPERSEDED** - replaced by [LIQUID_GLASS_PHASE2_REBASE_2026-06-30.md](LIQUID_GLASS_PHASE2_REBASE_2026-06-30.md), which records these Phase-1 findings as resolved and guard-tested. Kept for historical reference.

Date: 2026-06-26 · Stable SDK macOS **26.5** (Xcode.app) · Beta SDK macOS **27.0** (Xcode-beta.app)
Scope: every user-facing surface. Excludes the Metal grid engine/renderer/pinch internals (per non-goals).
89 audit rows: **8 high · 16 medium · 65 low**; 6 fake-glass, 2 nonfunctional, 45 accessibility gaps, 5 copy notes.

## Visual references

The two Apple Photos reference screenshots (`/var/folders/.../TemporaryItems/...`) are **TCC-blocked** to the
tooling (same `Operation not permitted` as the Desktop video) - I cannot open them. Targets below follow the
documented Apple Photos macOS layout + HIG; any spot where the screenshot would change a call is flagged.

## macOS 26 / 27 compatibility (verified against both SDKs)

| API | In stable 26.5? | Use |
|---|---|---|
| `ToolbarSpacer`, `toolbarItemHidden`, `toolbarVisibility`, `ContentUnavailableView`, `NavigationSplitView`, `.inspector`, `.searchable`, `LabeledContent`, `.glassProminent`, `.glassEffect`, native materials/semantic colors | **yes** | use directly, no guard - these inherit macOS 27 refined diffusion/tint/transparency automatically on recompile |
| `toolbarMinimizeBehavior` (native toolbar auto-minimizing) | **no** (27-only) | **defer** - do NOT reference in stable-build code; on 26 use `ToolbarSpacer` + `toolbarItemHidden`; document as `#available(macOS 27.0, *)` hook |

No fake glass will be introduced; no unguarded macOS 27 symbols in stable-build code.

## The 8 HIGH-risk / high-impact items

| # | Surface | Issue | Native target | Risk |
|---|---|---|---|---|
| 1 | Global `.preferredColorScheme(.dark)` (`ProtonPhotosApp.swift:15,74`) | App is locked dark; Liquid Glass + Apple Photos adapt to appearance | Remove the lock - but only after the palette can adapt (see #2/#3) | high |
| 2 | `ProtonColors` is dark-only (no light variants) | Root enabler of the dark lock - palette can't adapt | Asset-catalog light+dark variants, or map to semantic system colors | high |
| 3 | `ProtonColor` neutral ramp reimplements semantic colors | One-off hex for background/text/border | Collapse neutrals to semantic system colors; keep brand purple | high |
| 4 | Sidebar = manual `HStack` + custom `SidebarResizeHandle` (`MainView.swift:68-83,777-840`) | Reimplements `NavigationSplitView` (collapse/resize/divider/material) | `NavigationSplitView(columnVisibility:)` + `.navigationSplitViewColumnWidth` | high |
| 5 | Library shell split layout | Same as #4 | Same | high |
| 6 | (resize handle, folded into #4) | | | high |
| 7 | **Search ABSENT** | Apple Photos always exposes search | `.searchable` + a real filtered-timeline path (date/type now; filename needs a metadata index) | high |
| 8 | Info panel = hand-rolled inspector (`InfoPanelView.swift`) | Bespoke card/width/close vs native | native `.inspector` + `Form`/`LabeledContent` | high |

## Cross-cutting findings

- **Accessibility (45 rows):** the dominant, lowest-risk gap - icon-only toolbar/viewer/queue buttons carry `.help()` tooltips but **no `.accessibilityLabel`** (VoiceOver reads the SF Symbol name or nothing). The aspect/square toggle is the model that already does it right. Toggles/state buttons (favorite, info) don't expose AX value/state.
- **Fake glass (3 genuine):** viewer centered title pill = `.white.opacity(0.09)` capsule (`MainView.swift:503-520`); upload queue popover paints a redundant `.regularMaterial` inside a popover that already has one (`UploadQueuePanel.swift:27`); viewer toolbar opaque warm fill (deliberate Apple-Photos choice - keep, but centralize the color).
- **Nonfunctional control:** the **Offline-Mediathek toggle** (`SettingsView.swift:30-43`) is near-nonfunctional - its own caption admits thumbnails always load encrypted regardless. Reword/disable so it doesn't imply behavior it lacks. (The sibling "Originale offline" toggle is honestly disabled "Demnächst" - fine.)
- **Empty/error states:** grid empty/error (`TimelineView.swift:79-113`) and upload-queue empty (`UploadQueuePanel.swift:52`) are bespoke `VStack`s → `ContentUnavailableView`.
- **Destructive actions:** trash (toolbar + viewer, incl. multi-select) fires on one click with **no confirmation** - add `.confirmationDialog`. (The Settings cache-delete `.alert` is the model.)
- **Context menus:** none anywhere - Apple Photos has right-click menus on cells + sidebar albums.
- **Dead code:** `ProtonPrimaryButtonStyle`, `ProtonSpinner`, `ProtonColor.primaryHover/primaryActive` - superseded by `.glassProminent`/native `ProgressView`; delete.
- **Typography:** pervasive fixed `.system(size:)` instead of semantic `Font` styles (no Dynamic Type) across login/settings/viewer/error states.
- **Already native (preserve):** `.windowToolbarStyle(.unified)`, grid `.toolbarBackground(.bar)`, sidebar `List(.sidebar)`, native `.toolbar`/`Menu`/`ControlGroup`, native `NSOpenPanel`/`NSSavePanel`, native `.sheet`/`.popover`/`.alert`, `AVPlayerView` video, native `Map`, `.glassEffect` viewer cards, native `Form`/`Toggle`/`Picker` in Settings + upload sheet. **All sidebar categories + upload destinations are real-capability-backed (no decorative controls).**

## Security copy

Mostly precise. The offline-cache delete `.alert` copy is the model (states exactly what is/ isn't removed).
The one fix: the **Offline-Mediathek toggle wording** must not imply thumbnails stop loading. Login
"end-to-end encrypted" / "Encrypted by default" is acceptable at the storage level. No security
implementation will change.

## Phased implementation plan

- **Phase 2A - SAFE, no product decision, low risk (implement first):** accessibility labels on every icon-only control; the 3 fake-glass fixes; `ContentUnavailableView` for empty/error/queue-empty; delete dead DesignSystem code; destructive-trash `.confirmationDialog`; `LabeledContent` for Settings metric rows; offline-toggle wording; semantic `Font` styles (Dynamic Type).
- **Phase 2B - native toolbar grouping:** decompose the single `ToolbarItemGroup` into title/zoom/actions/(search) regions with `ToolbarSpacer`; `toolbarItemHidden` for narrow widths; `#available(macOS 27.0,*)` `toolbarMinimizeBehavior` hook (not referenced in stable build).
- **Phase 3 - structural (higher risk, sequenced):** (a) adaptive color system + remove the `.dark` lock [needs the light-mode product decision]; (b) `NavigationSplitView` migration; (c) native `.searchable` with a real filter; (d) native `.inspector` for the info panel; (e) context menus.

Full 89-row inventory is in the workflow output; this doc captures the actionable synthesis.
