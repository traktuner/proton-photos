# Proton Photos Universal Core Contract v0.1

## Authority

Every agent working on Proton Photos architecture MUST follow this contract before editing code. If this contract conflicts with Apple documentation, Apple documentation wins. If it conflicts with current implementation, the agent must either update the implementation safely or stop and report the conflict.

### Required Apple References

- [Configuring a multiplatform app target](https://developer.apple.com/documentation/xcode/configuring-a-multiplatform-app-target)
- [Food Truck: Building a SwiftUI Multiplatform App](https://developer.apple.com/documentation/swiftui/food-truck-building-a-swiftui-multiplatform-app)
- [HIG — Layout](https://developer.apple.com/design/human-interface-guidelines/layout)
- [TN3192: Migrating your app from the deprecated UIRequiresFullScreen key](https://developer.apple.com/documentation/technotes/tn3192-migrating-your-app-from-the-deprecated-uirequiresfullscreen-key)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [Metal](https://developer.apple.com/documentation/metal)
- [MTKView](https://developer.apple.com/documentation/metalkit/mtkview)

## Architectural Layers

### Core

- MUST compile for macOS 26+, iOS 26+, and iPadOS 26+.
- MUST NOT import AppKit, UIKit, SwiftUI, AVKit, MetalKit view-hosting UI, NSImage, UIImage, NSView, UIView, NSWorkspace, NSOpenPanel, UIApplication, or NSApplication.
- MAY use Foundation, CoreGraphics value types, CryptoKit, Security, ImageIO only when available cross-platform and guarded by tests.
- Owns domain models, provider protocols, pure algorithms, byte caches, cryptographic storage primitives, metadata models, diagnostics event schemas, and performance-neutral utilities.
- MUST prefer value types, Sendable protocols, actor-isolated services, dependency injection, clocks, and explicit stores over global mutable state.

### Shared UI/UX

- MAY use SwiftUI only when the code is truly platform-adaptive and compiles on Mac, iPhone, and iPad.
- MUST use standard Apple components where possible so Liquid Glass and platform behavior are inherited from the system.
- MUST avoid hard-coded desktop assumptions, fixed window-only layouts, and custom glass/chrome unless a platform-specific reason is documented.

### Platform UI

- Owns AppKit/UIKit bridges, NSViewRepresentable/UIViewRepresentable, NSScrollView/UIScrollView, NSOpenPanel, PhotosPicker, window commands, menu commands, platform file pickers, platform accessibility bridges, and platform-specific Liquid Glass/chrome.
- MUST adapt to safe areas, scene size changes, orientation, keyboard/pointer/trackpad, iPad multitasking, and dynamic resizing.

### Rendering

- Pure grid geometry and render plans belong in Core or RenderingCore.
- Metal renderer/shaders may be shared if they compile on all target platforms.
- Metal view hosting, scroll physics, gesture intake, pointer behavior, and accessibility host objects are platform UI.

### Telemetry

- Core MAY define platform-neutral telemetry event types and a `TelemetrySink` protocol.
- Core MUST NOT depend on a concrete telemetry backend, OSLog-only implementation, network exporter, or platform UI lifecycle.
- Telemetry implementation is a separate task.

## Purity Rules — Enforced Boundary

The `PhotosCore` target is the universal Core foundation. Its platform purity is enforced by `PhotosCorePlatformPurityTests` in `Packages/ProtonPhotosKit/Tests/PhotosCoreTests/PhotosCorePlatformPurityTests.swift`.

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
- `AVKit`
- `MetalKit`

### Forbidden Tokens in Core

These types must not appear anywhere in `Sources/PhotosCore`:

- `NSImage`
- `UIImage`
- `NSView`
- `UIView`
- `NSWorkspace`
- `NSOpenPanel`
- `UIApplication`
- `NSApplication`

### Enforcement

The `PhotosCorePlatformPurityTests` scan every `.swift` file under `Sources/PhotosCore/` at test time and fail loudly if:
1. A forbidden framework is imported.
2. A forbidden token appears in any source file.
3. An import outside the allowed-framework allowlist is introduced.

A new import requires updating `PhotosCorePlatformPurityTests.allowedFrameworkImports` AND confirming the framework compiles on macOS 26+, iOS 26+, and iPadOS 26+.

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
