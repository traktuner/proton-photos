# Performance & Dead-Code Audit - 2026-06-28/29

Worktree `proton-photos-perf-contract-audit`, branch `perf-contract-cleanup-2026-06-28`, baseline `7707e61`.
Driven by 6 read-only auditors (2 hot-path, architecture, dead-code, comments/tests, docs) + main-agent verification.

## 1. Hot paths inspected

`MetalGridScrollHost.layout()` / `scrolled()` / `step()`; `MetalProductionGridView.updateNSView`;
`MetalGridCoordinator.draw()` + settled `drawEngineFrame`; the live resize/sidebar presentation lifecycle
(`begin/draw/capture/end` + `windowDidEndLiveResize` + `verticalCounterScroll`); the pinch path
(`PinchLiveZoomDriver`, `GridZoomTransaction`, commit bridge); texture streaming;
`TimelineView.body`; `TimelineViewModel` / `TimelineSearch` (search typing).

### Verified CLEAN (no action - recorded so they are not "fixed" needlessly)
- **Live resize / sidebar draw paths**: present a once-captured snapshot uniformly scaled - **no per-tick engine
  resolve**, **no content-size callback** (gated off via `presentationResizeActive` / `isSidebarResizing`), **no
  texture upload / decode / cache crawl**, **no synchronous file IO**. `layout()` early-returns during a live resize
  doing only pure transform math + `metalView.draw()`.
- **`framePlan`** is O(visible rows), not O(library). No full-library recompute on any drawn frame.
- **Search typing** is correctly insulated: debounced (`committedSearchText`, ~280 ms in `MainView`); `TimelineView`
  keys off `committedSearchText`, never the live `searchText`; `filteredSections` short-circuits on an empty query.
  Typing cannot block on full-library filtering. (`ViewportRequestDebouncerTests` / `TimelineSearchFilterTests`.)
- **`updateNSView`** gates the expensive `setDataSource` / marker rebuild on a `dataToken` change; pinch does not
  push `level` per frame (commits on settle).
- **`ppResizeLog`** does **not exist** anywhere - the suspected per-frame logging debt was already removed (verified
  by `rg`). Recorded as a non-issue.

## 2. Proven performance issues - FIXED (low-risk, behavior-preserving)

1. **Unconditional Metal redraw from `updateNSView`** (`MetalGridCoordinator.setSelectionMode` / `setFavorites`,
   no equality guard → `needsDisplay = true` every SwiftUI pass). **Fix:** equality-guard all three setters
   (`setSelection` too) so a no-op pass does not force an idle GPU frame.
2. **`monthMarkers` computed at every level** (`TimelineView.body`) but consumed only at L4/L5. A full-library month
   scan + DateFormatter allocations ran at the common normal levels (L0–L3). **Fix:** `level >= 4 ? dateMarkers(…) : []`.
3. **`DateFormatter` allocated per marker** (`MetalGridProductionAdapter.label`, one new formatter per month
   boundary). **Fix:** build one formatter per `dateMarkers` call (`makeFormatter`) and reuse it across the loop -
   identical output, dozens→one allocation on a multi-year library.
4. **Per-frame diagnostic builds a payload string in RELEASE** (`drawEngineFrame` `GridZoomCommitLog.frame`, ~10 Hz
   during a live pinch; the emit's field/payload build ran outside the `#if DEBUG`). **Fix:** wrap the call site in
   `#if DEBUG` so it is compiled out of release. Release build re-verified clean.

## 3. Suspected / real-but-NOT-fixed (documented, deferred to honor "no behavior change / no regression")

- **`streamingTick` CADisplayLink never paused at idle** (`MetalGridScrollHost`): `step()` fires at refresh rate
  whenever the grid is on screen, even fully idle. **Recommended:** pause when no animation/streaming flag is set and
  resume at the `needsDisplay` sites. Deferred: async thumbnail arrival currently relies on the always-on tick noticing
  `hasPendingVisibleThumbnails`; pausing risks a "thumbnail doesn't appear until next interaction" regression unless
  every arrival path is taught to resume the tick - higher risk than the idle-power win justifies here.

## 4. Dead-code / redundancy - result: the codebase is unusually clean

- **No dead spike code / rejected-model leftover symbols.** `GridZoomV3`, banded-transition, focusRow-crossfade,
  `singleLattice` symbols and the `MetalGrid.focusRowTransition` / `MetalGrid.singleLatticeTransition` flags exist
  ONLY as forbidden-token assertions in `ProductionRouteGuardTests` (guarding against re-introduction). `focusRowRelayout`
  is a LIVE transition-kind classification, not a leftover.
- **`MetalGridLab` / `MetalGridLabBridge`** - DELETED 2026-06-29 (debug-tooling cleanup): the Debug-menu grid
  prototype + its App wiring + the orphaned `SyntheticMetalGridDataSource` are gone.
- **`SquareGridDebugMode` + `MetalGrid.debugGrid`** - DELETED 2026-06-29: the synthetic colored-square render mode,
  its `debugSyntheticGrid` flag, `renderSyntheticSlots`, and the draw-path gates were removed.
- **`columnsForFixedSide` round branch** - reachable only from the live pinch over-zoom (`GridZoomTransaction`), NOT
  dead. KEEP (comment corrected to say so).
- **`TimelineViewModel.sectionAspects` / `structureToken`** - DELETED 2026-06-29: leftover from the older
  aspect/justified-layout path. `AspectRegistry` itself remains live in `ThumbnailFeed`; production layout does not
  consume media aspect.
- **`TimelineView.body` visible-content derivation** - now memoized in `TimelineViewModel.visibleContent(...)`, keyed
  on visible-content generation, committed search text, active filter/favorites context, and whether overview month
  markers are requested. This keeps filtering / `flatMap(\.items)` / marker derivation out of unrelated body
  reevaluations.

**Code deleted:** Metal Grid Lab, synthetic debug grid, stale aspect-layout memo. **Code extracted:** none. (See §5.)

## 5. Code NOT extracted (architecture) - deferred with rationale

`MetalGridCoordinator` (1669 LOC) does contain a cohesive ~430-LOC live-resize/sidebar **presentation subdomain**
(`captureSnapshot` … `drawSidebarResize`, lines ~641-1077) that is extractable behind a narrow `GridResizePresentation`
API (architecture auditor: `safe-merge`). **Not done this pass** because: (a) the user scoped this as no-behavior-change;
(b) that subdomain's only test coverage is `GridResizePresentationTests`, which is ~59/70 **source-substring** guards
(`String.contains` over `MetalGridCoordinator.swift`) - an extraction would break them all and force a test rewrite,
trading one risk for another. **Recommended sequence for a future pass:** first add *executable* lifecycle coverage
(drive begin→present→settle through pure entry points, assert produced `GridRenderSlot` rects), then extract behind
the executable contract. The engine, renderer, effects, cache/crypto, and search boundaries were verified CLEAN and
should be left alone.

## 6. Residual risks

- The deferred idle-tick perf item (§3) and the deferred extraction (§5) are genuine but intentionally not taken under the
  no-regression mandate.
- The presentation layer's behavioral contract remains source-string-guarded (brittle to a rename, blind to a
  substring-preserving regression).
- `GridSizePolicy` scaffolding remains in the tree (not adopted) - see `reports/archive/CONTRACT_REFRESH_REPORT.md` §6.

## 7. Tests run

- `swift test --filter SecureThumbnailCacheTests`: **14 tests / 1 suite - PASS**.
- `swift test --filter ProductionRouteGuardTests`: **6 tests / 1 suite - PASS**.
- `swift test` (full package): **422 tests / 53 suites - PASS** (plus the XCTest localization skips expected in plain SwiftPM).
- `xcodebuild -project ProtonPhotos.xcodeproj -scheme ProtonPhotos -configuration Debug -destination 'platform=macOS'
  CODE_SIGNING_ALLOWED=NO -skipPackagePluginValidation -skipMacroValidation build`: **BUILD SUCCEEDED**
  (plain `xcodebuild` is blocked by ProtonCore SwiftLint package-plugin validation on this machine).
- `git diff --check`: clean.
- Manual visual QA: **NOT performed** (see the session summary's QA checklist - requires running the app).
