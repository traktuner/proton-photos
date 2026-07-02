// swift-tools-version: 6.0
import PackageDescription

// Swift-6.2 runtime defect swiftlang/swift#76804: the compiler-inserted DYNAMIC actor-isolation assertion
// (`swift_task_isCurrentExecutor` → `SerialExecutorRef::isMainExecutor`) SIGSEGVs once a Live-Photo motion
// `AVPlayer`'s CoreMedia threads corrupt the main-thread executor's PAC state. It fires on EVERY `@MainActor`
// SwiftUI body / Cocoa-callback update that reads our `@Observable` model, so structural fixes only RELOCATE
// the crash (GeometryReader child → plain body → …). This frontend flag stops the compiler EMITTING those
// dynamic checks at all — it removes the faulting CALL (unlike the env-var override, which only changed the
// call's decision while the computation still segfaulted). Safe here: static Swift-6 isolation already proves
// these run on the main actor; the dynamic check was pure belt-and-suspenders and is currently a liability.
// `.unsafeFlags` is fine because this package is consumed as a LOCAL PATH dependency, never version-resolved.
// REMOVE once the toolchain ships the #76804 fix (Xcode 26.2 line) — re-test the live AVPlayer path first.
let disableDynamicActorIsolation: [SwiftSetting] = [
    .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"])
]

// Pure-Swift feature modules. Deliberately has NO dependency on ProtonDriveSDK,
// so it stays free of the SDK's `unsafeFlags` linker constraints. SDK-coupled glue
// (HttpClient/AccountClient/Bridge) lives in the app target instead.
let package = Package(
    name: "ProtonPhotosKit",
    // Source language for every package String Catalog. Required by SwiftPM before a target may carry
    // localized resources; unsupported languages fall back to this (English).
    defaultLocalization: "en",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "PhotosCore", targets: ["PhotosCore"]),
        .library(name: "DesignSystemCore", targets: ["DesignSystemCore"]),
        .library(name: "DesignSystemAppKitAdapter", targets: ["DesignSystemAppKitAdapter"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "ProtonAuth", targets: ["ProtonAuth"]),
        .library(name: "MediaByteCache", targets: ["MediaByteCache"]),
        .library(name: "MediaDecodingCore", targets: ["MediaDecodingCore"]),
        .library(name: "MediaFeedCore", targets: ["MediaFeedCore"]),
        .library(name: "MediaLocationCore", targets: ["MediaLocationCore"]),
        .library(name: "MediaCacheCore", targets: ["MediaCacheCore"]),
        .library(name: "MediaCacheAppKitAdapter", targets: ["MediaCacheAppKitAdapter"]),
        .library(name: "MediaCacheUIKitAdapter", targets: ["MediaCacheUIKitAdapter"]),
        .library(name: "GridCore", targets: ["GridCore"]),
        .library(name: "MetalRenderingCore", targets: ["MetalRenderingCore"]),
        .library(name: "MetalGridTextureCore", targets: ["MetalGridTextureCore"]),
        .library(name: "MetalGridTextureAppKitAdapter", targets: ["MetalGridTextureAppKitAdapter"]),
        .library(name: "MetalGridTextureUIKitAdapter", targets: ["MetalGridTextureUIKitAdapter"]),
        .library(name: "MediaCache", targets: ["MediaCache"]),
        .library(name: "TimelineCore", targets: ["TimelineCore"]),
        .library(name: "TimelineUIKitAdapter", targets: ["TimelineUIKitAdapter"]),
        .library(name: "TimelineFeature", targets: ["TimelineFeature"]),
        .library(name: "PhotoViewerCore", targets: ["PhotoViewerCore"]),
        .library(name: "PhotoViewerUIKitAdapter", targets: ["PhotoViewerUIKitAdapter"]),
        .library(name: "PhotoViewerFeature", targets: ["PhotoViewerFeature"]),
        // Modular feature foundation: album management + the upload queue/state-machine. Both are
        // pure (no SDK/HTTP) and drive injected backend protocols the app implements.
        .library(name: "AlbumCore", targets: ["AlbumCore"]),
        .library(name: "AlbumsFeature", targets: ["AlbumsFeature"]),
        .library(name: "UploadCore", targets: ["UploadCore"]),
        .library(name: "UploadFeature", targets: ["UploadFeature"]),
        // Library map: MapKit (native Apple Maps) view over the shared encrypted location index.
        // Platform UI layer — macOS now; an iOS/iPad UIKit variant reuses the same MediaLocationCore.
        .library(name: "MapUIKitAdapter", targets: ["MapUIKitAdapter"]),
        .library(name: "MapFeature", targets: ["MapFeature"]),
    ],
    targets: [
        // PhotosCore owns the package-wide localization catalog (Resources/Localizable.xcstrings),
        // resolved via `L10n` / `Bundle.module`. Every package module depends on PhotosCore, so this is
        // the single source of truth for package strings.
        .target(name: "PhotosCore", resources: [.process("Resources")], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "PhotosCoreTests", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "DesignSystemCore", swiftSettings: disableDynamicActorIsolation),
        .target(name: "DesignSystemAppKitAdapter", dependencies: ["DesignSystemCore"], resources: [.process("Resources")], swiftSettings: disableDynamicActorIsolation),
        .target(name: "DesignSystem", dependencies: ["DesignSystemCore", "DesignSystemAppKitAdapter"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "ProtonAuth", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "ProtonAuthTests", dependencies: ["ProtonAuth"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaByteCache", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "MediaByteCacheTests", dependencies: ["MediaByteCache", "PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaDecodingCore", swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "MediaDecodingCoreTests", dependencies: ["MediaDecodingCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaFeedCore", dependencies: ["PhotosCore", "MediaByteCache", "MediaDecodingCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "MediaFeedCoreTests", dependencies: ["MediaFeedCore", "PhotosCore", "MediaByteCache", "MediaDecodingCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaLocationCore", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "MediaLocationCoreTests", dependencies: ["MediaLocationCore", "PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaCacheCore", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "GridCore", swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "GridCoreTests", dependencies: ["GridCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MetalRenderingCore", swiftSettings: disableDynamicActorIsolation),
        .target(name: "MetalGridTextureCore", dependencies: ["GridCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MetalGridTextureAppKitAdapter", dependencies: ["MetalGridTextureCore", "GridCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MetalGridTextureUIKitAdapter", dependencies: ["MetalGridTextureCore", "GridCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaCacheAppKitAdapter", dependencies: ["PhotosCore", "MediaByteCache", "MediaDecodingCore", "MediaFeedCore", "MediaCacheCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaCacheUIKitAdapter", dependencies: ["PhotosCore", "MediaByteCache", "MediaDecodingCore", "MediaFeedCore", "MediaCacheCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaCache", dependencies: ["MediaByteCache", "MediaLocationCore", "MediaCacheCore", "MediaCacheAppKitAdapter"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "TimelineCore", dependencies: ["PhotosCore", "GridCore"], resources: [.process("Resources")], swiftSettings: disableDynamicActorIsolation),
        .target(name: "TimelineUIKitAdapter", dependencies: ["GridCore", "TimelineCore", "MetalRenderingCore"], swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "TimelineFeature",
            dependencies: ["PhotosCore", "DesignSystem", "MediaCache", "GridCore", "TimelineCore", "MetalRenderingCore", "MetalGridTextureCore", "MetalGridTextureAppKitAdapter"],
            swiftSettings: disableDynamicActorIsolation
        ),
        .target(name: "PhotoViewerCore", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "PhotoViewerUIKitAdapter", dependencies: ["PhotoViewerCore"], swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "PhotoViewerFeature",
            dependencies: ["PhotosCore", "DesignSystem", "MediaCache", "PhotoViewerCore"],
            swiftSettings: disableDynamicActorIsolation
        ),
        .testTarget(name: "PhotoViewerFeatureTests", dependencies: ["PhotoViewerFeature", "PhotoViewerCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "TimelineFeatureTests",
            dependencies: ["TimelineFeature", "TimelineCore", "GridCore", "MetalRenderingCore", "MetalGridTextureCore", "MetalGridTextureAppKitAdapter", "MetalGridTextureUIKitAdapter", "MediaCache", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation
        ),
        // Albums: universal management protocols + repository over an injected backend. The app's
        // current backend routes reads via direct HTTP and reports album writes as unsupported until
        // Proton's SDK exposes the album-write API.
        .target(name: "AlbumCore", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        // Backward-compatible feature product for app targets already importing AlbumsFeature.
        .target(name: "AlbumsFeature", dependencies: ["AlbumCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "AlbumsFeatureTests", dependencies: ["AlbumCore", "AlbumsFeature", "PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        // UploadCore: pure queue + state machine + folder enumeration over an injected upload backend.
        .target(name: "UploadCore", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        // UploadFeature: SwiftUI adapter over UploadCore. No DesignSystem dependency; the native
        // presentation chrome stays owned by the host platform.
        .target(name: "UploadFeature", dependencies: ["UploadCore", "PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "UploadFeatureTests", dependencies: ["UploadCore", "PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        // Map: UIKit/AppKit MapKit views + clustering over PhotoLocationIndex (MediaLocationCore).
        .target(name: "MapUIKitAdapter", dependencies: ["PhotosCore", "MediaLocationCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MapFeature", dependencies: ["PhotosCore", "MediaLocationCore", "DesignSystem"], swiftSettings: disableDynamicActorIsolation),
    ]
)
