# MetalGrid Boundary Audit (Phase 3.1 origin; results through Phase 3.9)

Status: audit only. No production behavior changes.

This document records the current MetalGrid boundaries before any cross-platform extraction. It is subordinate
to `docs/core-architecture-contract.md` and `docs/metalgrid-engine-contract.md`.

## Apple references used

- Metal documentation: https://developer.apple.com/documentation/metal
- Metal sample index: https://developer.apple.com/metal/sample-code/
- `MTKView`: https://developer.apple.com/documentation/metalkit/mtkview
- Drawing through MetalKit: https://developer.apple.com/documentation/metal/using-metal-to-draw-a-view%27s-contents
- Resource storage modes: https://developer.apple.com/documentation/metal/setting-resource-storage-modes

Implication for this app: Metal itself can be shared, but view hosting and event/scroll integration must stay
platform-specific. Shared rendering code should prefer `Metal` primitives and avoid `MetalKit` view types in
Core-style targets. Platform adapters own `MTKView`, `NSView`/`UIView`, scroll physics, gestures, symbols, and
safe-area behavior.

## Current production path

The current production path is still:

```text
TimelineView
  -> MetalProductionGridView
  -> MetalGridScrollHost
  -> MetalGridCoordinator
  -> MetalGridRenderer
```

`docs/metalgrid-engine-contract.md` remains accurate on the non-negotiable product invariants:

- Production timeline is MetalGrid-only.
- `SquareTileGridEngine` owns all outer square-slot geometry.
- `TileContentFitter` owns only media fitting inside a square slot.
- `MetalGridRenderer` must not compute layout.
- `MetalGridScrollHost` owns the macOS AppKit scroll/gesture host.

## Boundary inventory

### Now in `GridCore` (extracted)

These files have been extracted into the universal `GridCore` target (zero package dependencies) and are covered
by the shared `CoreArchitectureGateTests`. They use only portable value frameworks (`CoreGraphics`, `simd`):

- `SquareTileGridEngine.swift`
- `GridSizePolicy.swift`
- `GridLiveZoomBounds.swift`
- `GridScrollRebase.swift`
- `GridViewportResizeRebase.swift`
- `GridZoomTransaction.swift`
- `GridZoomCommitBridge.swift` (Phase 4.2 pure zoom trigger + release-commit geometry)
- `GridProfileRebase.swift` (Phase 3.5)
- `GridTransitionComponent.swift`
- `GridTransitionComponentBuilder.swift`
- `GridTransitionController.swift`
- `GridTransitionPlan.swift`
- `GridTransitionRendererInput.swift`
- `GridTransitionScheduler.swift`
- `GridTransitionSelectionEligibility.swift`
- `GridTransitionTuning.swift`
- `PinchLiveZoomDriver.swift`
- `PinchZoomTransitionScheduler.swift`
- `ClickZoomTransitionScheduler.swift`
- `OverviewLayerDissolve.swift`
- `TileContentFitter.swift`
- `LocalAlphaCurve.swift`
- `GridSelectionController.swift` (pure selection state; split out of the macOS `MetalGridSelectionController` adapter)
- `GridTextureResidencyPolicy.swift` (formerly `MetalGridTextureLRU`; pure residency policy, no `Metal`)
- `GridTextureStreamingPolicy.swift` (pure per-frame upload budget)
- `CoreTelemetry.swift` (Phase 3.9 platform-neutral telemetry seam)

### Remaining pure candidates still in `TimelineFeature`

Not yet moved. `GridProxy.swift` imports `PhotosCore` and is a shell/grid command seam with window-frame and
route-restoration semantics. It needs a separate classification before any Core extraction:

- `GridProxy.swift` (imports `PhotosCore`)

Extraction rule: move only pure value types and algorithms first. Do not move `TimelineFeature` view hosts,
`MediaCache` adapters, AppKit event code, or `MTKView` delegates with them.

### Candidate for a future `MetalRenderingCore`, not general Core

These are cross-platform Metal candidates only after view-hosting is split away:

- `MetalGridRenderer.swift`
- `MetalGridTypes.swift`
- shader source embedded in `MetalGridRenderer`

Entry-point blocker RESOLVED (Phase 3.9, commit 4259c6e): `MetalGridRenderer` now exposes a narrow
`MetalGridDrawableTarget` (a `CAMetalDrawable`, an `MTLRenderPassDescriptor`, and a `presentsWithTransaction`
flag) plus `render(to:)` / `renderLayerDissolve(to:)` overloads that take it. The `MTKView`-taking methods are
now thin edge adapters that build the target via `MetalGridDrawableTarget(view:)` — the single `MTKView` → draw
seam — and delegate to the `to:` overloads, which never reference `MTKView`. The remaining `MetalRenderingCore`
prerequisite is packaging, not the render entry point: the renderer file still lives in `TimelineFeature` and
still imports `Metal`/`MetalKit`, so split it into a Metal-only target with the `MTKView` adapter left behind.

### Must remain platform adapter until split

These files are macOS-specific today:

- `MetalProductionGridView.swift`: `SwiftUI`, `AppKit`, `NSViewRepresentable`, `MediaCache`.
- `MetalGridScrollHost.swift`: `NSView`, `NSScrollView`, `NSClipView`, AppKit events, window live-resize
  notifications, `CADisplayLink`, and `MTKView` hosting.
- `MetalGridView.swift`: `MTKView` subclass.
- `MetalGridAccessibilityProvider.swift`: AppKit accessibility.
- `MetalGridHeaderRenderer.swift`: AppKit overlay labels.
- `MetalGridInteractionController.swift`: AppKit click/modifier routing.
- `GridHeaderViews.swift`: AppKit headers.
- `AspectSquareToggleModel.swift`: AppKit state/input layer.
- `MetalGridDataSource.swift`: `MediaCache.ThumbnailFeed` adapter and main-actor macOS production feed bridge.
- `MetalGridTextureCache.swift`: real `MTLTexture` cache plus AppKit-only SF Symbol rasterization through
  `NSImage`, `NSColor`, and `NSFont`.
- `MetalGridPalette.swift`: shared RGBA values are portable, but the current file exposes `NSColor`.

## Performance findings

### Confirmed no new regression in this audit

Phase 3.1 made no production code changes, so runtime performance is unchanged.

### Existing positive design choices

- `MetalGridRenderer` already pools steady-frame vertex buffers with a three-frame ring and a semaphore.
- Offscreen overview dissolve uses private render targets.
- `GridTextureResidencyPolicy` (formerly `MetalGridTextureLRU`, now in `GridCore`) is pure and unit-testable.
- `RealMetalGridDataSource` reads decoded `CGImage` directly from the feed (`memoryCGImage`) rather than
  creating platform image wrappers for upload eligibility.
- The display link is demand-driven and idles when no scroll, transition, thumbnail streaming, or resize work is
  active.

### iOS/iPadOS risk 1: fixed texture budgets copied unchanged

Current defaults are `maxUploadsPerFrame = 48`, `maxCachedTextures = 1200`, and `maxTexturePixels = 320`.
Worst-case residency for 1200 square RGBA textures at 320px is roughly 491 MB before driver overhead. This is
acceptable as a macOS product budget only if profiling says so; it must not become universal Core policy.

Solutions:

1. Keep `MetalGridBudget` injected by platform adapters. macOS can keep the current budget; iPhone/iPad should
   start with conservative budgets and tune with Instruments on real devices.
2. Replace fixed texture capacity with a viewport-derived budget: visible cells plus overscan plus a small
   hysteresis window. Derive `maxTexturePixels` from rendered slot size and screen scale, capped per platform.

### iOS/iPadOS risk 2: one draw call per thumbnail texture

`MetalGridRenderGroup.Source.perQuadTexture` currently binds one texture and issues one draw call per thumbnail.
This is simple and works on macOS, but dense iPad/iPhone overview levels can make CPU-side encoding overhead a
real bottleneck before the GPU is busy.

Solutions:

1. Introduce a texture-array or argument-buffer path for thumbnail textures so one encoded draw can cover many
   cells while still allowing per-cell UV/crop data.
2. Keep the simple path for macOS initially but add a renderer strategy chosen by platform capability and
   measured visible-cell count. This keeps risky Metal changes out of pure geometry Core and allows staged A/B
   profiling.

### iOS/iPadOS risk 3: AppKit glyph rasterization in the texture cache

`MetalGridTextureCache` renders SF Symbol badges through `NSImage`, `NSColor`, and `NSFont`. This cannot be
shared with iOS/iPadOS unchanged.

Solutions:

1. Inject a `GridGlyphRasterizer` from the platform adapter: AppKit implementation on macOS, UIKit implementation
   on iOS/iPadOS, shared texture upload after rasterization.
2. Replace rasterized SF Symbol badge textures with renderer-native vector/SDF badge primitives for heart, video,
   empty check, and filled check. This removes platform image APIs from the shared renderer path.

## Recommended next extraction order

1. `GridCore` target: pure geometry, zoom, resize, transition plans, selection, texture LRU policy, and renderer
   input value types that do not import `Metal`, `MetalKit`, `AppKit`, `UIKit`, `SwiftUI`, or `MediaCache`.
2. `GridCore` layout profiles must stay viewport-scoped (`regularTimeline`, `compactTimeline`, etc.). Platform
   adapters map scene size, safe areas, traits, and hardware capability to a profile; the renderer just draws
   the resulting `GridFramePlan`.
3. Production profile values are loaded from the adapter's validated `GridProfiles.plist`, not from renderer
   defaults. Invalid profile data must fail validation rather than silently falling back to a desktop profile.
4. macOS `TimelineFeature` adapter keeps `MetalProductionGridView`, `MetalGridScrollHost`, header/accessibility,
   real data source, and AppKit symbol rasterization.
5. `MetalRenderingCore` target only after the Phase 4.0 separate rendering gate exists. The `MTKView` entry-point
   blocker is resolved; the remaining work is to split the Metal-only renderer/shader package from the
   `MTKView`/AppKit adapter and prove it builds on macOS, iOS, and iPadOS.
6. iOS/iPadOS adapter: `UIViewRepresentable`/`UIView`, `UIScrollView` or SwiftUI scroll host, platform
   safe-area/input policy, platform `MetalGridBudget`, and platform glyph rasterizer.

## Stop conditions for Phase 3.2

- Do not move `MetalGridCoordinator` wholesale. At 1600+ lines it mixes camera state, texture streaming,
  AppKit clip view state, resize presentation, and renderer composition.
- Do not move `MetalGridScrollHost` into Core. It is the macOS host.
- Do not copy macOS texture budgets into a universal target.
- Do not introduce `#if os(iOS)` stubs to make a target compile. Split the boundary instead.
- Do not change square-slot geometry, zoom anchoring, resize behavior, or production route selection while
  extracting pure files.

## Phase 3.2 result

The first `GridCore` cut moved only pure, already-tested value math:

- `SquareTileGridEngine.swift`
- `TileContentFitter.swift`
- `GridSizePolicy.swift`
- `GridZoomTransaction.swift`
- `GridViewportResizeRebase.swift`
- `GridLiveZoomBounds.swift`
- `GridScrollRebase.swift`
- `OverviewLayerDissolve.swift`

The new target has no package dependencies and is covered by the universal Core gate. `TimelineFeature` imports
it as the macOS grid adapter. Transition controllers, Metal renderer input orchestration, selection controller,
texture residency policy, renderer code, and platform hosts were deliberately left out of this pass because
their module boundary still needed a separate API/access audit. The pure transition stack was moved in Phase 3.8.
The pure selection state (`GridSelectionController<ID>`) and the pure texture residency/streaming policy
(`GridTextureResidencyPolicy`, `GridTextureStreamingPolicy`) were moved in Phase 3.9; the Metal renderer code and
platform hosts remain adapter-owned. `TimelineFeature` keeps `MetalGridSelectionController` and
`MetalGridTextureCache` as thin macOS adapters over those Core types.

## Phase 3.5 result

`GridCore` now owns `GridProfileRebase`: a pure profile-switch camera rebase for dynamic viewport classes.
It maps the source level to a target level, captures the logical item at a normalized source viewport anchor,
and resolves the same item/local Y in the target engine before clamping. The default level mapping chooses the
closest visual slot size while preserving the normal-vs-overview/month-label role when possible.

No macOS production adapter currently switches profiles automatically. `TimelineFeature` still injects the
validated production profile explicitly; future adapter work must call the Core rebase before swapping engines
so `regularTimeline`/`compactTimeline` changes do not jump.

## Phase 3.6 result

`TimelineFeature` now owns viewport-resolved production profile selection. `GridProfiles.plist` may define
validated `selectionRules`; the shipped rule selects `compactTimeline` at layout widths up to `640pt` and falls
back to the configured default profile (`regularTimeline`) above that.

The production macOS adapter applies profile changes through `MetalGridCoordinator.applyGridProfile`, which uses
`GridCore.GridProfileRebase` before swapping the engine. The host defers this work while live resize, sidebar
presentation, pinch zoom, commit bridge, scroll rebase, overview dissolve, or resize-settle work is active. This
keeps dynamic scene-size changes profile-aware without mixing the profile switch into active animation frames.

Performance impact should be neutral in steady state: profile resolution is a tiny rule scan on layout/update,
and the O(1)-style rebase runs only when the resolved profile id changes. Narrow macOS windows now use the
compact ladder; wide windows keep the existing regular ladder.

## Phase 3.7 result

`GridCore` now exposes semantic grid-level roles and a pure derivation rule for adjacent transition kinds. Production
`GridProfiles.plist` no longer duplicates `transitionKindToNext`; `TimelineFeature` derives it during validated
profile loading and rejects explicit values that disagree with the adjacent level roles.

The normal-level single-lattice planner now accepts one common presentation rect when fitting the source/target
transform. Fixed-column geometry supplies the scale from rect sizes and the translation from rect centers, so this
removes an unnecessary snap fallback on the regular `9 ↔ 7` step without adding per-frame work.

Performance impact is neutral to positive: semantic derivation runs only while loading profiles, and the planner
change avoids a fallback path but does not increase steady-state rendering cost.

## Phase 3.8 result

`GridCore` now owns the pure normal-level transition stack: component/lattice construction, click and pinch
schedulers, local alpha curve, transition draw-intent generation, the host-progress controller, and the continuous
multi-level `PinchLiveZoomDriver`.

The move did not make Metal rendering universal. `TimelineFeature` still owns `MTKView`, `NSScrollView`/AppKit
gesture intake, texture streaming, real `PhotoUID` lookup, and Metal quad emission. The macOS adapter injects
`PhotoDiagnostics.shared.emit` into the Core transition controller through a platform-neutral string event sink,
so `GridCore` remains free of `PhotosCore`.

Performance impact should be neutral: files moved across targets, but plan construction and per-frame draw-intent
logic are unchanged. The only additional runtime work is one optional closure call for transition diagnostics at
plan/fallback/settle events, not per rendered thumbnail.

## Phase 3.9 result

Render-boundary / adapter-boundary hardening. Audit + guards + doc sync only; no production behavior changed.

- Renderer drawable boundary (commit 4259c6e): `MetalGridRenderer` now renders through `MetalGridDrawableTarget`
  (a `CAMetalDrawable`, an `MTLRenderPassDescriptor`, and a `presentsWithTransaction` flag). `render(to:)` /
  `renderLayerDissolve(to:)` take the target; the `MTKView` methods are thin edge adapters. This removes the
  `MTKView` entry-point blocker for a future `MetalRenderingCore`, but the renderer file still imports
  `Metal`/`MetalKit` and stays in `TimelineFeature`, so the remaining split work is packaging.
- Core telemetry seam (commit 3f58dbc): `GridCore` owns `CoreTelemetry.swift` — `CoreTelemetryEvent` (name +
  `[String: String]` fields, `Sendable`) and `CoreTelemetrySink = (CoreTelemetryEvent) -> Void`.
  `GridTransitionController` emits string-keyed events through an injected optional sink; `MetalGridCoordinator`
  wires the platform diagnostics backend. `GridCore` stays free of `PhotosCore`.
- Selection + texture policy now in `GridCore`: pure `GridSelectionController<ID>`, `GridTextureResidencyPolicy`
  (formerly `MetalGridTextureLRU`), and `GridTextureStreamingPolicy`. `TimelineFeature` keeps
  `MetalGridSelectionController` and `MetalGridTextureCache` as thin macOS/`PhotoUID` adapters over them.
- Latent boundary hole CLOSED: the shared gate banned `MetalKit` but not the base `Metal` import, the
  QuartzCore-sourced Metal surface types (`CAMetalDrawable`, `CAMetalLayer`, `CAMetalDisplayLink`), the
  presentation types (`CADisplayLink`, `CALayer`), or the `MTL*` resource objects. Because `QuartzCore` was an
  allowed `GridCore` import, such a surface type could have entered `GridCore` undetected by both the import
  allowlist and the token gate. `CoreArchitectureGateTests` now bans the `Metal` import and those tokens
  (word-boundary matched), GridCore-scopes a ban on CoreGraphics drawing types
  (`CGContext`/`CGImage`/`CGColorSpace`/`CGLayer` — `CGImage` stays legal in the decode Cores), and drops
  `QuartzCore` from GridCore's import allowlist to close the hole structurally. A negative-control file confirmed
  every added guard fires; all current Core targets still pass the gate and build for iOS and macOS.
- Dead import removed: `GridCore/GridScrollRebase.swift` imported `QuartzCore` but used only `CFTimeInterval`
  (resolved via `CoreGraphics`); it was the only QuartzCore importer in `GridCore`. Removing it enabled dropping
  `QuartzCore` from the GridCore allowlist.

## Phase 4.0 result

Core-native contract. Documentation only; no production behavior changed.

- "Core-native" now means layered native architecture, not "put everything in Universal Core." `GridCore` stays
  pure and `Metal`-free. Photo-domain reusable logic that needs `PhotosCore` belongs in Photos-dependent Core.
  Shared Metal rendering belongs in a future `MetalRenderingCore` with its own gate.
- `MetalRenderingCore` is explicitly separate from the Universal Core gate. It may use `Metal` and narrow
  drawable/pass-descriptor targets, but it must not import `MetalKit`, AppKit, UIKit, SwiftUI, `MTKView`,
  `NSView`, `UIView`, platform scroll/gesture/accessibility hosts, platform glyph rasterization, `PhotoUID`, or
  `MediaCache`.
- Platform adapters map current Apple scene facts into Core-neutral policy: layout size, safe areas, display
  scale, traits, input mode, pointer precision, memory/GPU budget tier, motion policy, and feature availability.
  Future dynamic surfaces must be handled by those facts, never by hard-coded device or platform branches in Core.
- Performance policy remains adapter-injected. macOS can keep aggressive budgets; iPhone/iPad profiles must use
  their own measured budgets. Renderer optimization strategies are future measured tasks after the split/gate is
  in place.

## Phase 4.1 result

Small pure GridCore extraction. No behavior changed.

- `GridVisualConstants.swift` moved from `TimelineFeature` to `GridCore`. It remains a `CoreGraphics`-only,
  package-visible constant source for thumbnail corner radius.
- `MetalGridGeometry.swift` moved from `TimelineFeature` to `GridCore`. Despite the historical Metal-prefixed
  name, it contains only content-to-viewport `CGRect`/`CGPoint` coordinate conversion and imports no rendering,
  view-hosting, AppKit, UIKit, or Metal frameworks.
- `TimelineFeature` continues to consume both helpers as the macOS adapter. The extraction does not move
  `MetalGridCoordinator`, `MetalGridScrollHost`, renderer code, texture cache, AppKit accessibility, or gesture
  handling into Core.

## Phase 4.2 result

Pure commit-bridge extraction. No behavior changed.

- `GridZoomCommitBridge.swift` was added to `GridCore`. It owns `GridZoomAnchorMode`, `GridZoomTrigger`,
  `GridZoomCommitBridge`, `GridZoomCommitDelta`, and the `SquareTileGridEngine.commitDelta(...)` pure geometry
  extension.
- `TimelineFeature/GridZoomCommit.swift` now keeps only timeline diagnostics/logging over `PhotoDiagnostics`.
  It still imports `PhotosCore` by design and remains adapter-owned.
- The extraction does not move `GridProxy`, `MetalGridCoordinator`, `MetalGridScrollHost`, renderer code,
  texture cache, gesture intake, AppKit accessibility, or data-source/feed adapters into Core.
- `CoreArchitectureGateTests` now guards that the pure commit bridge stays in `GridCore` with only a
  `CoreGraphics` import.
