# Liquid Glass UI/UX Rebase — 2026-06-30

Scope: current app state after the grid/cache/security cleanup. This is a UIUX-only rebase of the older
Liquid Glass audit docs; it does not change grid geometry, cache policy, E2EE storage, upload/download,
or backend behavior.

## Current Contracts Now Guarded

- The app uses the native unified macOS toolbar and does not globally force `.preferredColorScheme(.dark)`.
- The startup state uses the window-level frosted launch veil, not a black loading screen.
- The library shell is a native `NavigationSplitView` with the system sidebar, not a custom HStack/sidebar
  resize handle.
- The grid detail still renders under the floating sidebar, while events/layout are protected by the
  leading-obstruction inset.
- The Metal grid toolbar uses the measured `GridTopFrost` bridge because the native toolbar glass cannot
  reliably sample a `CAMetalLayer`; the bridge uses public `NSVisualEffectView` within-window material,
  follows the active window state, and does not draw a flat custom toolbar background.
- Search is a native toolbar `.searchable` field and the search text is debounced before filtering.
- Destructive trash actions use a native confirmation dialog.
- Grid and upload empty/error states use `ContentUnavailableView`.
- The upload queue popover does not paint a second material over native popover glass.
- `ProtonColor` neutrals map to semantic system colors; only the Proton brand/signal colors remain fixed.
- Removed custom UI primitives must stay removed: no `ProtonPrimaryButtonStyle`, no custom `ProtonSpinner`,
  no custom sidebar resize handle, no old `gridToolbarGlassFade`.

These contracts are pinned by `ProductionRouteGuardTests.liquidGlassChromeUsesNativeContracts`.

## Older Audit Statements That Are Now Stale

- "Search absent" is no longer true. Search exists in the toolbar and is wired to the timeline.
- "Global dark lock" is no longer true. The app root no longer forces dark mode.
- "ProtonColors is dark-only" is no longer true for neutrals. Neutral tokens are semantic system colors.
- "Sidebar is manual HStack + custom resize handle" is no longer true. The shell uses `NavigationSplitView`.
- "Upload queue empty is bespoke" is no longer true. It uses `ContentUnavailableView`.
- "Trash has no confirmation" is no longer true. Toolbar/viewer trash goes through `confirmationDialog`.
- "Remove all toolbar frost overlays" is superseded by the Metal-specific finding: native toolbar glass does
  not reliably sample the `CAMetalLayer`, so the public within-window `GridTopFrost` bridge is the accepted
  current implementation.

## Remaining UIUX Work

1. **Visual QA pass, not blind code churn**
   - Capture screenshots/short videos of grid, sidebar open/closed, loading veil, viewer, settings, upload
     popover, empty states, and error states in both active and inactive window states.
   - Compare against Apple Photos references for the toolbar frost, sidebar material, spacing, search field,
     and viewer chrome.
   - Any correction must be tied to a visible diff, not a theoretical "more glass" change.

2. **Typography cleanup**
   - Replace remaining fixed `.system(size:)` calls in `LoginView`, `SettingsView`, viewer overlays, upload
     row actions, and toolbar title pills with semantic styles where the visual result remains Apple-like.
   - Keep deliberately fixed icon geometry where it stabilizes toolbar/viewer controls.

3. **Inspector migration**
   - `InfoPanelView` is still a hand-placed right panel. Evaluate a native `.inspector` migration in its own
     branch because it changes viewer layout, transitions, and pinch-dismiss interaction.

4. **Context menus**
   - Add native `.contextMenu` affordances for grid items and sidebar albums only where actions are already
     real and wired: Favorite/Unfavorite, Download original, Move to Trash, Restore from Trash, Set Album Cover.
   - Do not add decorative or future controls.

5. **macOS 27 hooks**
   - Keep stable macOS 26 builds clean. Add macOS 27-only toolbar behavior such as `toolbarMinimizeBehavior`
     only behind `#available(macOS 27.0, *)` and only after a successful Xcode 27 beta build.

## Non-Goals

- No grid resize/sidebar presentation changes in this UIUX pass.
- No cache/E2EE/session behavior changes.
- No private Apple APIs.
- No fake glass: no painted `.bar` rectangles behind toolbar/sidebar, no stacked materials inside popovers,
  no custom blur layer over a native glass surface unless the Metal sampling limitation requires it.
- No broad redesign into a feature-dense "Swiss army knife"; the UI remains Apple Photos-like and content-first.

## Verification For The Next UIUX Pass

Run at minimum:

```bash
cd /Users/thomas/Developer/repos/personal/proton-photos/Packages/ProtonPhotosKit
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProductionRouteGuardTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

If App files changed, also run:

```bash
cd /Users/thomas/Developer/repos/personal/proton-photos
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/rebuild.sh
```

Then perform visual QA on the rebuilt app before accepting the UI change.
