# Proton Photos Universal Core Contract v0.2

## Authority

Every agent working on Proton Photos architecture MUST follow this contract before editing code. If this contract conflicts with Apple documentation, Apple documentation wins. If it conflicts with current implementation, the agent must either update the implementation safely or stop and report the conflict.

### Required Apple References

- [Configuring a multiplatform app target](https://developer.apple.com/documentation/xcode/configuring-a-multiplatform-app-target)
- [Food Truck: Building a SwiftUI Multiplatform App](https://developer.apple.com/documentation/swiftui/food-truck-building-a-swiftui-multiplatform-app)
- [HIG — Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [TN3192: Migrating your app from the deprecated UIRequiresFullScreen key](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [UIKit and AppKit apps](https://developer.apple.com/documentation/technologyoverviews/uikit-appkit)
- [UIWindowScene](https://developer.apple.com/documentation/uikit/uiwindowscene)
- [UITraitCollection](https://developer.apple.com/documentation/uikit/uitraitcollection)
- [UIView.safeAreaLayoutGuide](https://developer.apple.com/documentation/uikit/uiview/safearealayoutguide)
- [Metal](https://developer.apple.com/documentation/metal)
- [MTLTexture](https://developer.apple.com/documentation/metal/mtltexture)
- [MTKView](https://developer.apple.com/documentation/metalkit/mtkview)
- [CGImage](https://developer.apple.com/documentation/coregraphics/cgimage)
- [Using Metal to draw a view's contents](https://developer.apple.com/documentation/metal/using-metal-to-draw-a-view%27s-contents)

Agents must re-check official Apple documentation before changing architecture, UI adaptation, rendering
boundaries, or platform availability. Rumors or assumed future hardware do not become product requirements.
Future devices are handled by the same rule Apple already requires for modern Apple platforms: adapters supply
current scene size, safe area, traits, input mode, scale, and capability facts; Core consumes facts, never device
rumors or platform-name branches.

## Architectural Layers

### Core-Native Principle

Core-native means shared where it is truly portable and native where Apple platform behavior matters. It does
not mean moving every file into one Core target. The app must be decomposed so features can be added, removed, or
disabled by changing adapters, injected providers, profile configuration, or feature availability policy rather
than by forking Core behavior.

The mandatory layers are:

1. Universal Core: deterministic data, algorithms, policies, storage primitives, and render/transition plans.
2. Photos-dependent Core: reusable app-domain logic that may depend on `PhotosCore` but still has no UI,
   rendering, platform-hosting, or concrete backend dependency.
3. MetalRenderingCore: shared Metal renderer/shader layer with its own gate, separate from Universal Core.
4. MetalGridTextureCore: shared Metal texture upload/cache layer with its own gate, dependent only on GridCore.
5. Shared UI/UX: SwiftUI only where genuinely adaptive across Mac, iPhone, and iPad.
6. Platform Adapters: AppKit/UIKit/SwiftUI hosts, scroll, gestures, safe areas, traits, accessibility, budgets,
   native controls, platform glyph rasterization, and concrete telemetry/export backends.

Every new module must declare which layer it belongs to before code moves.

### Universal Core

- MUST compile for macOS 26+, iOS 26+, and iPadOS 26+.
- MUST NOT import AppKit, UIKit, SwiftUI, MapKit view-hosting UI, AVKit, Metal, MetalKit view-hosting UI,
  NSImage, UIImage, NSView, UIView, NSWorkspace, NSOpenPanel, UIApplication, or NSApplication.
- MAY use Foundation, CoreGraphics value types, CryptoKit, Security, ImageIO only when available cross-platform and guarded by tests.
- Owns domain models, provider protocols, pure algorithms, byte caches, cryptographic storage primitives, metadata models, diagnostics event schemas, and performance-neutral utilities.
- MUST prefer value types, Sendable protocols, actor-isolated services, dependency injection, clocks, and explicit stores over global mutable state.
- MUST be performant on the lowest supported iPhone/iPad class, not merely buildable. Mac-only CPU/RAM/GPU
  assumptions are forbidden here.

### Photos-Dependent Core

- MAY depend on `PhotosCore` plus lower-level universal Core targets.
- MUST obey the same UI/import/token bans as Universal Core.
- Owns reusable photo-domain state machines, ID-based coordination, app-domain routing models, and provider
  contracts that are not specific to macOS, iOS, or iPadOS hosts.
- MUST keep SDK, network, file picker, platform image wrapper, and concrete persistence backends behind injected
  protocols or adapter targets.

### Shared UI/UX

- MAY use SwiftUI only when the code is truly platform-adaptive and compiles on Mac, iPhone, and iPad.
- MUST use standard Apple components where possible so Liquid Glass and platform behavior are inherited from the system.
- MUST avoid hard-coded desktop assumptions, fixed window-only layouts, and custom glass/chrome unless a platform-specific reason is documented.
- MUST adapt from scene/container facts, not device-name assumptions. A narrow Mac window, iPad split view,
  external display, future foldable surface, and iPhone portrait surface must all be expressible by the same
  viewport/trait/capability model.

### Platform UI

- Owns AppKit/UIKit bridges, NSViewRepresentable/UIViewRepresentable, NSScrollView/UIScrollView, NSOpenPanel, PhotosPicker, window commands, menu commands, platform file pickers, platform accessibility bridges, and platform-specific Liquid Glass/chrome.
- MUST adapt to safe areas, scene size changes, orientation, keyboard/pointer/trackpad, iPad multitasking, and dynamic resizing.
- MUST map platform facts into Core-neutral profiles and policies: layout viewport, safe-area insets, display
  scale, input mode, size traits, memory/GPU budget tier, motion policy, and feature availability.
- MAY choose platform-specific budgets and strategy defaults, but MUST inject them into Core-facing policy types
  rather than hard-coding them in Core.

### Rendering

- Pure grid geometry and render plans belong in Core or RenderingCore.
- Metal renderer/shaders may be shared if they compile on all target platforms.
- Metal view hosting, scroll physics, gesture intake, pointer behavior, and accessibility host objects are platform UI.

### MetalRenderingCore (Separate Gate)

`MetalRenderingCore` is not Universal Core. It is the shared rendering target for Apple platforms where Metal is
available. It has its own purity gate, separate from the Universal Core gate.

Allowed:
- `Metal`, portable shader source, `CoreGraphics` value types, `simd`, and minimal `QuartzCore` drawable value
  types only when they compile on macOS, iOS, and iPadOS.
- A narrow render-target abstraction supplied by platform adapters. It may wrap `CAMetalDrawable` and
  `MTLRenderPassDescriptor`, but it must not know about scenes, windows, scroll views, gestures, or accessibility.

Forbidden:
- `MetalKit`, `MTKView`, AppKit, UIKit, SwiftUI, `NSView`, `UIView`, `NSImage`, `UIImage`, platform scroll hosts,
  gesture/event routing, accessibility hosts, platform glyph rasterization, and concrete `PhotoUID` or
  `MediaCache` feed lookups.
- Creating or owning `CAMetalLayer`/`MTKView`; adapters create surfaces and pass draw targets in.

Renderer strategy may vary by adapter policy (simple per-texture path, argument-buffer path, texture-array path),
but strategy choice must be explicit, test-covered, and measurable. Do not hide macOS-only fast paths in shared
renderer code.

### MetalGridTextureCore (Separate Gate)

`MetalGridTextureCore` is not Universal Core and is not the renderer. It is the shared texture-resource target
for Apple platforms where Metal is available. It may own reusable `MTLTexture` resources, decoded-`CGImage` upload
mechanics, generic per-item texture cache state, glyph request value types, and cache accounting. It may depend
on `GridCore` for portable residency/streaming policy.

Allowed:
- `Metal`, `CoreGraphics`, and `GridCore`.
- Generic item identity (`ID: Hashable & Sendable`) and Core-injected policy values such as
  `GridTextureBudget`.

Forbidden:
- `MetalKit`, `MTKView`, AppKit, UIKit, SwiftUI, platform view/scroll/gesture/accessibility objects, concrete
  glyph rasterization implementations, `PhotosCore`, `PhotoUID`, `PhotoItem`, `MediaCache`, and
  `ThumbnailFeed`.
- Render command encoding, draw targets, `CAMetalDrawable`, `MTLRenderPassDescriptor`, or renderer strategy
  selection. Those belong to `MetalRenderingCore` or adapters.

Platform adapters bind item IDs, supply decoded images, inject measured budgets, and provide native glyph
rasterizers. macOS may bind `PhotoUID`; iOS/iPadOS may bind the same cache to its adapter ID without forking
texture upload or residency logic.

### Telemetry

- Core MAY define platform-neutral telemetry event types and a `TelemetrySink` protocol.
- Core MUST NOT depend on a concrete telemetry backend, OSLog-only implementation, network exporter, or platform UI lifecycle.
- Telemetry implementation is a separate task.

### Feature Modularity

- Core features must be enabled through explicit capability/configuration objects, provider availability, or
  profile selection. No hidden singleton state may decide whether a Core feature exists.
- Removing a feature should remove an adapter, provider, profile, or feature policy without requiring unrelated
  Core rewrites.
- Optional features must fail closed with typed unsupported states, not silently fall back to desktop defaults.

## Purity Rules — Enforced Boundary

The `PhotosCore` target is the universal Core foundation. Its platform purity is enforced by `PhotosCorePlatformPurityTests` in `Packages/ProtonPhotosKit/Tests/PhotosCoreTests/PhotosCorePlatformPurityTests.swift`.

All universal Core targets are additionally covered by the shared `CoreArchitectureGateTests` in `Packages/ProtonPhotosKit/Tests/PhotosCoreTests/CoreArchitectureGateTests.swift`. This shared gate is the source of truth for the current universal Core target list, per-target import allowlists, one-way Core dependency rules, and platform UI / hardware-policy token bans.

### Allowed Frameworks in Core

| Framework | Status | Notes |
|-----------|--------|-------|
| `Foundation` | Permitted | Cross-platform. Value types, collections, URLs, Codable. |
| `CoreGraphics` | Permitted | Cross-platform value types: `CGFloat`, `CGRect`, `CGSize`, `CGPoint`. |
| `AVFoundation` | Permitted | Cross-platform media (available on macOS/iOS/iPadOS). Used by `VideoStreaming.swift` for `AVURLAsset` streaming. Not a UI framework. |
| `CryptoKit` | Permitted | Cross-platform. Use when needed. |
| `Security` | Permitted | Cross-platform. Use when needed. |
| `ImageIO` | Permitted | Cross-platform. Use when needed. |

### Forbidden Imports in Core

These imports would drag in platform UI / view-hosting concerns and break the universal-Core contract:

- `AppKit`
- `UIKit`
- `SwiftUI`
- `MapKit`
- `AVKit`
- `Metal`
- `MetalKit`

### Forbidden Tokens in Core

These types must not appear anywhere in universal Core sources:

- `NSImage`
- `UIImage`
- `NSView`
- `UIView`
- `NSWorkspace`
- `NSOpenPanel`
- `UIApplication`
- `NSApplication`
- `MTKView`
- `ProcessInfo.processInfo.physicalMemory` (hardware sizing is platform-adapter policy)
- `ProcessInfo.processInfo.activeProcessorCount` (hardware sizing is platform-adapter policy)

Render/GPU-surface + presentation types (added in Phase 3.9 — kept out of Core even though the `CoreGraphics`
value types and, where allowlisted, `QuartzCore` value math are permitted):

- `CAMetalDrawable`, `CAMetalLayer`, `CAMetalDisplayLink` (QuartzCore-sourced Metal surfaces)
- `CADisplayLink`, `CALayer` (QuartzCore presentation/timer types)
- `MTLDevice`, `MTLTexture`, `MTLBuffer`, `MTLCommandQueue`, `MTLCommandBuffer`, `MTLRenderPassDescriptor`, `MTLRenderCommandEncoder` (Metal resource objects)

GridCore-scoped only (the pure grid-geometry target additionally bans CoreGraphics *drawing* types; these stay
legitimate in the image-decoding Core targets, so the ban is not global):

- `CGContext`, `CGImage`, `CGColorSpace`, `CGLayer`

### Enforcement

The target-local purity tests scan their corresponding source trees at test time. `CoreArchitectureGateTests` repeats the contract centrally for all universal Core targets and fails loudly if:
1. A forbidden framework is imported.
2. A forbidden token appears in any source file.
3. An import outside the allowed-framework allowlist is introduced.
4. A universal Core target depends on an adapter, feature, or UI target.
5. A universal Core target is not published as a matching library product.

A new Core import requires updating the relevant target-local allowlist AND `CoreArchitectureGateTests`, then confirming the framework compiles on macOS 26+, iOS 26+, and iPadOS 26+.

## Observations

### StreamingVideoAsset.asset: AVURLAsset

`VideoStreaming.swift` exposes `public let asset: AVURLAsset` through the `StreamingVideoAsset` class. This is acceptable because:
- `AVFoundation` is available on macOS 26+, iOS 26+, and iPadOS 26+.
- `AVURLAsset` is a media type, not a UI/view type.
- The contract does not forbid `AVFoundation`.

Flagged for potential future hardening: if Core should avoid all non-Foundation/non-CoreGraphics types in public API, `StreamingVideoAsset` could be refactored to hide `AVURLAsset` behind a forward-declared protocol. Not required for Phase 1.

### PhotoDiagnostics.shared (grandfathered)

`Diagnostics.swift` contains `public static let shared = PhotoDiagnostics()` — a singleton with a private `init()`. This pattern predates this contract and is grandfathered for now. Future phases should evaluate refactoring toward injected diagnostics sinks per the Core preference for "dependency injection and clocks over singletons."

### SwiftPM Platform Declaration

SwiftPM uses `.iOS(...)` for both iPhone and iPad. There is no `.iPadOS` platform specifier. The package manifest declares:
```swift
platforms: [.macOS("26.0"), .iOS("26.0")]
```

## Regression Safety

Agents MUST:

1. Start with `git status --short --branch`.
2. Stop before editing any dirty file not created by the current task.
3. Keep behavior unchanged unless the task explicitly asks for behavior changes.
4. Add or update guard tests for every architectural boundary changed.
5. Run focused tests and platform-build checks, or document exactly why they could not run.
6. Never silence platform failures with empty stubs, fake no-op implementations, or broad `#if os(...)` hiding broken architecture.

## Phase Roadmap

### Phase 1 — Universal Core (this phase)

Make `PhotosCore` a strict universal Core target suitable for macOS 26+, iOS 26+, and iPadOS 26+ consumers without changing app behavior.

- Add iOS 26+ to `Package.swift` platforms.
- Add `PhotosCorePlatformPurityTests` guard tests.
- Document the Core contract (this file).
- Verify: no forbidden imports/tokens, macOS tests pass, PhotosCore builds for `generic/platform=iOS`.

### Phase 2 (recommended) — MediaCache byte-cache vs. image-decoding split

Separate the platform-neutral byte-caching layer in `MediaCache` from platform-specific image decoding, so the byte cache can be consumed by iOS/iPadOS targets without dragging in AppKit/UIKit image representations.

#### Phase 2.1 — MediaByteCache target

`MediaByteCache` is the universal byte-cache package boundary. It may depend on `PhotosCore`, `Foundation`, `CryptoKit`, and `Security`; it must not import UI, view-hosting, graphics-decoding, or rendering frameworks such as `AppKit`, `UIKit`, `SwiftUI`, `AVKit`, `MetalKit`, or `ImageIO`.

`MediaByteCache` owns encrypted on-disk blob storage, plaintext in-process byte caching, cache-key storage protocols, authenticated blob encryption, cheap disk-presence checks, usable/decryptable disk probes, cache clearing, stats, and byte-cap eviction. It must not expose decoded image types such as `NSImage`, `UIImage`, or `CGImage`, and it must not choose platform hardware policy such as RAM or CPU sizing. Platform adapters inject byte-cache budgets through `ThumbnailCacheConfiguration`.

`MediaCache` remains the macOS thumbnail/feed layer for now. It depends on `MediaByteCache` and re-exports the existing byte-cache names as compatibility aliases so current macOS callsites can keep using `ThumbnailCache` through `MediaCache` while future iOS/iPadOS code can import `MediaByteCache` directly.

The performance contract from the existing feed remains unchanged: background coverage checks may use cheap file-existence probes (`has`) where decrypting every blob would block the feed actor, while network-skip decisions must use decryptable probes (`hasUsableDiskData`). Any future decoder split must preserve that distinction.

#### Phase 2.2 — MediaDecodingCore target

`MediaDecodingCore` is the universal image-decoding boundary. It may depend on `Foundation`, `CoreGraphics`, and `ImageIO`; it must not import platform UI frameworks or expose platform UI image wrappers. The shared decode output is `DecodedThumbnail`, backed by `CGImage` plus pixel dimensions, aspect ratio, and decoded byte-cost metadata.

`MediaCache` remains the macOS feed/adapter layer. It adapts `DecodedThumbnail` to the current macOS `NSImage` API through `MacThumbnailImageDecoder`, so existing Timeline, Viewer, and Filmstrip callsites remain source-compatible while the actual ImageIO downsample implementation is universal and buildable for iOS/iPadOS.

`ThumbnailFeed` must not own ImageIO primitives directly. It may continue to own queueing, priority, diagnostics, and macOS decoded-image RAM caching until the feed API is split, but decoder implementation changes belong in `MediaDecodingCore` plus thin platform adapters.

#### Phase 2.3 — MediaFeedCore target

`MediaFeedCore` is the universal thumbnail-feed pipeline. It may depend on `PhotosCore`, `MediaByteCache`, `MediaDecodingCore`, and `Foundation`; it must not import platform UI frameworks, expose platform image wrappers, or make direct hardware-policy decisions such as physical-RAM or CPU-count sizing. Platform targets inject those decisions through `ThumbnailFeedCoreConfiguration`.

`MediaFeedCore` owns platform-independent queueing, priority ordering, disk/network decisions, bounded disk-to-RAM decode warmup, background crawl state, adaptive download concurrency, decoded `CGImage` residency, and feed diagnostics. Its decoded image cache stores `DecodedThumbnail`, not `NSImage` or `UIImage`.

`MediaCache.ThumbnailFeed` is now the macOS adapter. It keeps the existing macOS `NSImage` API, records aspect ratios, and chooses macOS-specific RAM/CPU budgets before constructing `ThumbnailFeedCore`. Future iOS/iPadOS adapters must use the same core and provide their own conservative platform budgets, so a feed bug is fixed once in `MediaFeedCore` and platform policy remains outside Core.

The performance contract from the existing Metal grid is preserved and tightened: render/upload paths should read `CGImage` directly from the shared decoded core cache where possible. Platform image wrapper creation (`NSImage`, future `UIImage`) must stay in platform adapters and must not be required for Metal upload eligibility checks.

#### Phase 2.4 — MediaLocationCore target

`MediaLocationCore` is the universal location-index boundary. It may depend on `PhotosCore`, `Foundation`, `CryptoKit`, and `Observation`; it must not import platform UI frameworks, MapKit view-hosting code, platform image/view types, or direct hardware-policy sizing.

`MediaLocationCore` owns the encrypted GPS index store, in-memory coordinate index, and low-priority GPS crawl scheduler. Platform map UI belongs outside this target: macOS uses `MapFeature`/MapKit/AppKit today, while future iOS/iPadOS map UI must consume the same `PhotoLocationIndex`, `PhotoLocationStore`, and `LocationCrawl`.

#### Phase 2.5 — Universal Core regression gate

`CoreArchitectureGateTests` is the shared no-regression gate for the current universal Core set: `PhotosCore`, `MediaByteCache`, `MediaDecodingCore`, `MediaFeedCore`, `MediaLocationCore`, and `GridCore`. New reusable Core targets must be added to this gate before they are treated as universal Core.

The executable local gate is `scripts/verify-universal-core.sh`. It runs the shared architecture tests and builds every current universal Core target for `generic/platform=iOS` and `generic/platform=macOS`. Because SwiftPM models iPadOS through the iOS platform declaration, this iOS-family build is the package-level iPadOS compatibility check until separate iPad UI targets exist.

Agents MUST run `scripts/verify-universal-core.sh` before committing a change that modifies universal Core boundaries, package target dependencies, Core imports, platform purity rules, or cross-platform cache/feed/location behavior. If the gate cannot run, the final report must name the exact command, failure, and residual risk.

### Phase 3 — MetalGrid boundary split

#### Phase 3.1 — MetalGrid boundary audit

The Phase 3.1 audit is recorded in `docs/metalgrid-boundary-audit.md`. It is audit-only: no production grid behavior changes, no file moves, and no renderer rewrites.

Future MetalGrid extraction work MUST use that audit as input. Pure geometry/zoom/transition/value-policy code may move toward a future `GridCore`; `MTKView`, `NSView`/`UIView`, scroll physics, gesture intake, accessibility hosts, platform glyph rasterization, `MediaCache` feed adapters, and concrete platform texture-budget defaults must remain in platform adapters. Portable budget shapes may live in Core only when the adapter still injects the actual values.

#### Phase 3.2 — Initial universal GridCore extraction

`GridCore` is the universal, UI-free grid model boundary. It owns square-slot geometry, zoom transaction math,
viewport resize rebase math, scroll rebase easing, tile-content fitting, size-policy scaffolding, and the
overview layer dissolve plan. It intentionally has no package dependencies and may import only portable Apple
frameworks needed for value math (`CoreGraphics`, `simd`). (`QuartzCore` was dropped from the allowlist in
Phase 3.9 — GridCore uses injected clocks rather than `CACurrentMediaTime`, so it needs no QuartzCore symbol,
and excluding it removes the QuartzCore-sourced Metal-surface entry path into Core.)

`TimelineFeature` now depends on `GridCore` and remains the macOS adapter around it. The adapter owns
`MTKView`, AppKit scroll/gesture hosting, renderer composition, real `MediaCache` feed access, header and
accessibility overlays, texture budgets, and glyph/image rasterization. Do not move those concerns into
`GridCore` to make iOS compile; split another adapter or rendering target instead.

Moving additional grid code into `GridCore` requires the same gate as any other universal Core change:
`scripts/verify-universal-core.sh` must pass, including `GridCore` builds for `generic/platform=iOS` and
`generic/platform=macOS`.

#### Phase 3.3 — Viewport-scoped GridCore layout profiles

`GridCore` may define reusable `GridLevelProfile` values, but their names and behavior must describe viewport
classes rather than platforms. The current shared profiles are `regularTimeline` and `compactTimeline`.
Platform adapters choose a profile from scene size, safe-area, trait, and capability context; Core must not branch
on device idiom, orientation, or operating system.

The regular timeline profile preserves the shipped six-level production ladder exactly: `3/5/7/9/20/30`,
default level `3`, normal levels `0...3`, and overview levels `4...5`. The compact profile keeps the same
transition topology but starts with a one-column large-thumbnail level for narrow scene surfaces. Renderer code
must remain profile-agnostic and draw the `GridFramePlan` it receives.

#### Phase 3.4 — Config-driven production grid profiles

Production grid profiles are app/adapter configuration, not Core defaults. `TimelineFeature` owns the bundled
`Resources/GridProfiles.plist` and validates it at load time before constructing `GridLevelProfile` values.
Invalid profile data must fail validation rather than silently falling back or clamping product behavior.

`MetalGridCoordinator` and `MetalGridScrollHost` must be initialized with an explicit `GridLevelProfile`; they
must not carry hidden regular/desktop defaults. UI decisions that depend on level semantics, such as month-label
visibility, must read `GridLevelMetrics`/`GridLevelProfile` properties instead of hard-coded level thresholds.

Adjacent grid transition kinds are derived from level semantics (`aspectThumbnail` vs. `squareOverview`) during
profile load. The production plist may omit `transitionKindToNext`; if it supplies one, validation must reject any
value that does not match the semantic derivation. This keeps profile data generic and prevents renderer behavior
from becoming a manually duplicated per-level table.

The bundled plist is a build-time product resource. Do not present editing the signed app bundle as a supported
customization mechanism; if user-facing profile changes are added later, load them from a validated settings or
support directory path and keep the same validation gate.

#### Phase 3.5 — GridCore profile-change rebase

`GridCore` owns `GridProfileRebase`, the pure camera rebase used when a viewport class switches from one
`GridLevelProfile` ladder to another for the same logical timeline data. It maps the current source level to a
target level, preserves the logical item at a normalized viewport anchor, and keeps bottom-pinned timelines
pinned to the target bottom.

This is still Core math only. It must not decide when an app should use `regularTimeline`, `compactTimeline`,
or any future profile. Platform adapters provide that policy from scene/viewport facts.

#### Phase 3.6 — Viewport-resolved production profile selection

`TimelineFeature` resolves the active production grid profile from validated `GridProfiles.plist` selection
rules. The current production rule is viewport-based: layout widths up to `640pt` use `compactTimeline`; wider
layout surfaces fall back to the default `regularTimeline`.

Profile selection rules must name viewport classes, not platforms or device families. A future iPhone, iPad,
Mac, foldable, Stage Manager, split-view, external-display, or resized-window surface must be expressible by the
same layout/safe-area/trait facts rather than `if macOS` / `if iPad` branches in Core.

`MetalGridScrollHost` applies profile changes only at stable boundaries. It defers selection changes during
live window resize, sidebar presentation, pinch zoom, commit bridge, scroll rebase, overview dissolve, and resize
settle. Once stable, it calls `GridProfileRebase` through `MetalGridCoordinator.applyGridProfile` before swapping
engines, then syncs the SwiftUI level binding through the same echo guard used by pinch commits.

This pass intentionally leaves the macOS host in `TimelineFeature`; it does not make `MetalGridScrollHost` a
universal UI host. Future iOS/iPadOS hosts must reuse the same `GridCore` profile/rebase math and implement their
own UIKit/SwiftUI scroll, gesture, safe-area, accessibility, and texture-budget policy.

#### Phase 3.7 — Semantic grid transition derivation

Grid transition classification is Core semantics, not platform UI policy. `GridCore` owns `GridLevelSemanticRole`
and `GridTransitionKind.semantic(from:to:)`: adjacent aspect-thumbnail levels derive `focusRowRelayout`,
aspect-thumbnail to square-overview derives `overviewWarp`, and square-overview to square-overview derives
`denseOverviewZoom`.

Production profile configuration should describe level geometry and supported content modes, then let validation
derive the transition kind. Explicit `transitionKindToNext` values are compatibility input only and must match the
derived semantic value. A future profile with new level semantics must add a new Core role/derivation rule plus
tests instead of hard-coding one platform's animation choice in app configuration.

Normal-level click/pinch transition planning may use a single common presentation rect as a valid transform fit
when source/target slot sizes are known. This is required for some fixed-column phase changes, including the
regular `9 ↔ 7` normal-level step, and keeps the fallback-to-snap path reserved for genuinely degenerate plans.

#### Phase 3.8 — GridCore transition planning

`GridCore` owns the pure normal-level transition planning stack: `GridTransitionController`,
`GridTransitionPlan`, `GridTransitionComponentBuilder`, `GridTransitionScheduler`,
`ClickZoomTransitionScheduler`, `PinchZoomTransitionScheduler`, `GridTransitionRendererInput`,
`LocalAlphaCurve`, `GridTransitionTuning`, `GridTransitionSelectionEligibility`, and
`PinchLiveZoomDriver`.

This stack is UI-free and renderer-free. It consumes `GridFramePlan` values and emits draw intents plus optional
string-keyed transition telemetry through an injected event sink. It must not import `PhotosCore`, `MediaCache`,
`Metal`, `MetalKit`, `AppKit`, `UIKit`, or `SwiftUI`.

`TimelineFeature` remains the macOS adapter. It owns `MTKView` hosting, scroll/gesture intake, texture streaming,
real UID lookup, platform diagnostics wiring, and conversion of `GridTransitionDraw` into Metal quads. Future
iOS/iPadOS adapters must use the same `GridCore` transition plan and provide their own host/renderer plumbing
instead of forking transition math.

#### Phase 3.9 — Render-boundary / adapter-boundary hardening

Audit + guard hardening only; no production grid behavior changed.

`MetalGridRenderer` now draws through a narrow `MetalGridDrawableTarget` (a `CAMetalDrawable`, an
`MTLRenderPassDescriptor`, and a `presentsWithTransaction` flag). `render(to:)` / `renderLayerDissolve(to:)`
take the target; the `MTKView`-taking methods are thin edge adapters that build it via
`MetalGridDrawableTarget(view:)` — the single `MTKView` → draw seam. This removes the `MTKView` entry-point that
previously blocked `MetalRenderingCore`. Phase 4.4 created the package gate and moved draw primitives; Phase 4.5
moved the renderer/shader implementation behind that gate. The `MTKView` conversion remains adapter-owned in
`TimelineFeature`.

`GridCore` gains a platform-neutral telemetry seam in `CoreTelemetry.swift`: the value type
`CoreTelemetryEvent` (a name plus `[String: String]` fields, `Sendable`) and
`CoreTelemetrySink = (CoreTelemetryEvent) -> Void`. `GridTransitionController` emits string-keyed transition
events through an injected optional sink; the macOS adapter binds the concrete diagnostics backend. `GridCore`
still imports no `PhotosCore` and no concrete telemetry backend, per the Telemetry layer rule above.

`GridCore` also owns the pure `GridSelectionController<ID>` selection state and the pure
`GridTextureResidencyPolicy` (residency, formerly `MetalGridTextureLRU`) and `GridTextureStreamingPolicy`
(per-frame upload selection). `TimelineFeature` keeps `MetalGridSelectionController` as the macOS/`PhotoUID`
selection adapter and keeps `MetalGridTextureCache<ID>` as the adapter-owned real Metal texture cache over those
Core policies; concrete platform texture-budget defaults and glyph rasterization remain adapter-owned.

Gate hardening (the deliverable): the shared gate previously banned `MetalKit` and `MTKView` but not the base
`Metal` import, the QuartzCore-sourced Metal surface types, or `MTL*` resource types. Because `QuartzCore` was an
allowed `GridCore` import, a `CAMetalDrawable`/`CAMetalLayer`/`CADisplayLink` could have entered Core past both
the import allowlist and the token gate. Phase 3.9 closes this: `CoreArchitectureGateTests` now bans the `Metal`
import, bans the render/GPU-surface + presentation token set listed under "Forbidden Tokens in Core" above,
GridCore-scopes a ban on CoreGraphics drawing types (`CGContext`/`CGImage`/`CGColorSpace`/`CGLayer`), and drops
`QuartzCore` from GridCore's import allowlist (its one dead `import QuartzCore` was removed). Every current Core
target still passes the gate and builds for iOS and macOS.

### Phase 4 — Core-native architecture

#### Phase 4.0 — Core-native contract

Contract-only pass. No production behavior changed.

Core-native is now defined as a layered architecture, not as a mandate to move all implementation into
Universal Core. Universal Core remains the lowest shared boundary and is deliberately `Metal`-free. Reusable
photo-domain logic that depends on `PhotosCore` may move into Photos-dependent Core. Shared Metal rendering may
move only into `MetalRenderingCore` with its own gate. Platform adapters remain responsible for native
Apple behavior: scene/window/view hosting, safe areas, traits, scroll physics, gestures, accessibility, native
controls, concrete telemetry/export backends, platform texture budgets, and glyph rasterization.

Future Apple form factors are handled generically. The contract does not encode rumors or device names. Any Mac,
iPhone, iPad, external display, split view, Stage Manager surface, resized window, or future foldable-like scene
must be described by facts the adapter can observe: layout size, safe-area insets, display scale, size traits,
input mode, pointer precision, memory/GPU budget tier, motion policy, and feature availability. Core consumes
those facts through profile selection, injected policies, and capability objects. Core must not branch on
`if macOS`, `if iPad`, or device marketing names to choose behavior.

Modularity is explicit: features are enabled by provider availability, capability/configuration objects, adapter
wiring, or validated profile configuration. Optional features fail closed with typed unsupported states. Removing
a feature must not require unrelated Core rewrites, duplicated algorithms, or parallel platform-specific Core
paths.

Performance remains part of the architecture contract. Universal Core and Photos-dependent Core must be viable
on the lowest supported iPhone/iPad class, not merely buildable. Platform-specific performance policy belongs in
adapters and is injected into Core-facing policy types such as `GridTextureBudget`. macOS may choose higher
budgets and different renderer strategies, but those choices must not become Universal Core defaults. Actual
renderer optimization, draw-call strategy, texture arrays, argument buffers, and device-specific budget tuning
are future measured tasks after the boundaries and gates exist.

#### Phase 4.1 — Small pure GridCore extraction

Small production-code move with no behavior change.

`GridVisualConstants.swift` and `MetalGridGeometry.swift` moved from `TimelineFeature` into `GridCore` because
both are pure `CoreGraphics` helpers. `GridVisualConstants` owns the package-visible thumbnail corner radius used
by the Metal grid adapter. `MetalGridGeometry` owns package-visible content-to-viewport rectangle conversion; the
name is historical and does not imply a renderer dependency.

This pass deliberately did not move `MetalGridCoordinator`, `MetalGridScrollHost`, `MetalGridRenderer`,
`MetalGridTextureCache`, AppKit accessibility/header code, gesture routing, texture budgets, or data-source/feed
adapters. Those remain platform adapter or `MetalRenderingCore` work under the Phase 4.0 layer rules.

#### Phase 4.2 — Pure zoom commit bridge extraction

Small production-code split with no behavior change.

`GridZoomCommitBridge.swift` was added to `GridCore` because the zoom trigger semantics, release-commit bridge,
commit delta measurement, and `SquareTileGridEngine.commitDelta(...)` extension are pure `CoreGraphics`/grid
geometry. The implementation owns no renderer, no texture cache, no photo loading, no diagnostics backend, and
no platform view state.

`TimelineFeature/GridZoomCommit.swift` remains the macOS timeline diagnostics adapter. It keeps
`GridZoomAnchorLog`, `GridLevelSyncLog`, `GridResizeLog`, `MetalGridPerfLog`, and `GridZoomCommitLog` because
those write through `PhotoDiagnostics`. This pass left `GridProxy` as adapter/shell seam code until separate
classification. It deliberately did not move coordinators, hosts, renderer, cache, gesture intake, AppKit
accessibility, or data-source/feed adapters into Core.

#### Phase 4.3 — Generic shell/grid seam extraction

Small API split with no intended behavior change.

`GridProxy.swift` moved from `TimelineFeature` to `GridCore` as `GridProxy<ItemID>`. The proxy is the
platform-neutral command/event seam between the app shell and a grid host: window/cell-frame query by item ID,
scroll commands, zoom commands, content-mode commands, and first-content-ready notification. It deliberately
owns no renderer, host view, image/cache object, platform framework, or photo-domain model.

`GridScrollAnchor.swift` moved to `GridCore` as `GridScrollAnchor<ItemID>`. `TimelineFeature` now uses
`GridProxy<PhotoUID>` and `GridScrollAnchor<PhotoUID>`, keeping photo identity binding at the adapter edge while
leaving the Core seam generic and reusable for iOS/iPadOS. `TimelineFeature` still owns `GridInitialViewport`,
native host placement, AppKit coordinate conversion, `MetalGridScrollHost`, data-source wiring, renderer/cache
integration, diagnostics, gestures, and accessibility.

#### Phase 4.4 — MetalRenderingCore package gate and draw primitives

Small rendering-boundary split with no intended behavior change.

`MetalRenderingCore` is now a separate SwiftPM target/product, distinct from Universal `GridCore`. It may import
`Metal`, `QuartzCore`, `CoreGraphics`, and `simd`, but it is guarded against `MetalKit`, AppKit, UIKit, SwiftUI,
photo-domain IDs, media-feed/cache APIs, platform views, scroll/gesture hosts, platform glyph rasterization, and
adapter hardware-policy sizing.

The first moved code is only the renderer's Metal draw primitives and narrow drawable target:
`MetalGridQuadMode`, `MetalGridQuad`, `MetalGridRenderGroup`, and `MetalGridDrawableTarget`. The `MTKView`
conversion remains in `TimelineFeature` as an adapter extension, so shared rendering can accept a drawable/pass
descriptor while platform adapters continue to own view hosting. `MetalGridRenderer` still lives in
`TimelineFeature`; moving it is a later measured step after this gate proves the package boundary on macOS and
iOS.

#### Phase 4.5 — MetalGridRenderer into MetalRenderingCore

Small renderer-boundary move with no intended behavior change.

`MetalGridRenderer.swift` moved from `TimelineFeature` into `MetalRenderingCore`. The shared target now owns
shader compilation, Metal pipeline creation, command encoding, vertex-buffer pooling, steady-frame draw encoding,
and overview layer-dissolve compositing. The renderer exposes only drawable-target entry points based on
`MetalGridDrawableTarget`; it does not import `MetalKit` and does not reference `MTKView`, AppKit, UIKit,
PhotosCore, MediaCache, `PhotoUID`, or platform glyph rasterization.

`TimelineFeature` keeps `MetalGridRenderer+MTKView.swift`, the thin adapter extension that converts `MTKView`
state into `MetalGridDrawableTarget` and delegates to the rendering core. Production also injects
`MetalGridPalette.clearColor` when constructing the renderer, keeping surface-color policy at the adapter edge
while the shared renderer stores only the `MTLClearColor` value it receives.

#### Phase 4.6 — Grid texture budget shape into GridCore

Small policy-boundary split with no intended behavior change.

`GridTextureBudget.swift` was added to `GridCore` because the budget shape itself is a portable value type:
per-frame upload count, resident-texture capacity, and overscan fraction. It contains no Metal resource,
platform UI, media feed, hardware query, default value, or photo-domain identity.

`TimelineFeature` keeps the concrete macOS defaults as `MetalGridBudget.default`, now a compatibility alias over
`GridTextureBudget`. This preserves current macOS behavior while preventing aggressive desktop RAM/GPU
assumptions from becoming Universal Core policy. Future iOS/iPadOS adapters must construct their own measured
`GridTextureBudget` values and inject them into the same coordinator/cache seam.

#### Phase 4.7 — Metal grid glyph rasterizer seam

Small adapter-boundary split with no intended behavior change.

`MetalGridTextureCache` still belongs to the macOS `TimelineFeature` adapter because it owns real `MTLTexture`
objects. It no longer owns native SF Symbol rasterization. Instead it takes a
`MetalGridGlyphRasterizing` dependency, asks it for a `CGImage`, then uploads that image through the same texture
path used before.

`AppKitMetalGridGlyphRasterizer` is the current macOS implementation. It is the only Metal-grid glyph file that
may use `NSImage`, `NSColor`, and `NSFont`. Future iOS/iPadOS adapters should add a UIKit implementation that
conforms to the same protocol and inject it at their platform edge, without forking the texture-cache upload or
residency policy.

#### Phase 4.8 — Generic texture-cache item identity

Small cache-boundary split with no intended behavior change.

`MetalGridTextureCache` is now generic over `ID: Hashable & Sendable` and no longer imports `PhotosCore` or
mentions photo-domain models. The cache still owns real `MTLTexture` objects, GPU upload accounting, placeholder
textures, glyph texture caching, and the adapter-injected glyph rasterizer. Its residency bookkeeping continues
to use `GridTextureResidencyPolicy<ID>`.

The macOS timeline adapter binds the generic cache as `MetalGridTextureCache<PhotoUID>` inside
`MetalGridCoordinator`. Future iOS/iPadOS adapters must bind the same cache implementation to their item ID type,
inject platform-appropriate `GridTextureBudget` values, and provide a UIKit glyph rasterizer. This keeps one
Metal cache implementation shared across Apple platforms while leaving concrete photo-domain identity and native
policy at the adapter edge.

#### Phase 5.0 — MetalGridTextureCore package gate

Boundary-only split. No production behavior changed.

`MetalGridTextureCore` is now a dedicated SwiftPM target/product, distinct from `GridCore` and
`MetalRenderingCore`. It depends only on `GridCore` and is guarded against `MetalKit`, AppKit, UIKit, SwiftUI,
photo-domain IDs, media-feed/cache APIs, platform views, glyph rasterization implementations, draw targets, and
render command encoding.

This phase intentionally moves no production cache code. `MetalGridTextureCache<ID>` and
`MetalGridGlyphRasterizing` remain in `TimelineFeature` until the new target gate is proven on macOS and iOS.
The next extraction may move the generic cache and glyph request contract into this target while keeping
`AppKitMetalGridGlyphRasterizer`, `PhotoUID` binding, platform budgets, `MTKView`, and scroll/gesture hosts in
the macOS adapter.
