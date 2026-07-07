// swift-tools-version: 6.0
import PackageDescription

// Xcode 26.x currently crashes in dynamic actor-isolation checks on the Live Photo AVPlayer path.
// Keep the workaround local to this path dependency and re-test it before removing the flag on a newer toolchain.
let disableDynamicActorIsolation: [SwiftSetting] = [
    .unsafeFlags(["-Xfrontend", "-disable-dynamic-actor-isolation"])
]

let sdkBackendSwiftSettings: [SwiftSetting] = disableDynamicActorIsolation + [
    // ProtonCore's public API still exposes process-global crypto state. Keep the SDK adapter in Swift 5
    // language mode while the pure Core/feature modules stay on the package default.
    .swiftLanguageMode(.v5),
]

// Pure Core/feature modules stay SDK-agnostic. SDK-coupled transport and feature composition live in the
// shared ProtonDriveBackend product, not in any platform app target.
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
        .library(name: "ProtonDriveBackend", targets: ["ProtonDriveBackend"]),
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
        .library(name: "MetalGridComposeCore", targets: ["MetalGridComposeCore"]),
        .library(name: "MediaCache", targets: ["MediaCache"]),
        .library(name: "TimelineCore", targets: ["TimelineCore"]),
        .library(name: "TimelineUIKitAdapter", targets: ["TimelineUIKitAdapter"]),
        .library(name: "TimelineUIKitFeature", targets: ["TimelineUIKitFeature"]),
        .library(name: "TimelineFeature", targets: ["TimelineFeature"]),
        .library(name: "PhotoViewerCore", targets: ["PhotoViewerCore"]),
        .library(name: "PhotoViewerUIKitAdapter", targets: ["PhotoViewerUIKitAdapter"]),
        .library(name: "PhotoViewerFeature", targets: ["PhotoViewerFeature"]),
        // Modular feature foundation: album management + the upload queue/state-machine. Both are
        // pure (no SDK/HTTP) and drive injected backend protocols the app implements.
        .library(name: "AlbumCore", targets: ["AlbumCore"]),
        .library(name: "AlbumsFeature", targets: ["AlbumsFeature"]),
        .library(name: "AlbumSyncCore", targets: ["AlbumSyncCore"]),
        .library(name: "UploadCore", targets: ["UploadCore"]),
        .library(name: "UploadFeature", targets: ["UploadFeature"]),
        .library(name: "PhotoLibraryBackupAdapter", targets: ["PhotoLibraryBackupAdapter"]),
        // Library map: MapKit (native Apple Maps) view over the shared encrypted location index.
        // MapCore: platform-neutral annotation type shared by macOS MapFeature and iOS MapUIKitAdapter
        // (MKAnnotation/CLLocationCoordinate2D are identical on both platforms — no duplication).
        .library(name: "MapCore", targets: ["MapCore"]),
        .library(name: "MapUIKitAdapter", targets: ["MapUIKitAdapter"]),
        .library(name: "MapFeature", targets: ["MapFeature"]),
    ],
    dependencies: [
        .package(name: "ProtonDriveSDK", path: "../../Vendor/sdk-swift"),
        .package(url: "https://github.com/ProtonMail/protoncore_ios.git", exact: "37.3.0"),
    ],
    targets: [
        // PhotosCore owns the package-wide localization catalog (Resources/Localizable.xcstrings),
        // resolved via `L10n` / `Bundle.module`. Every package module depends on PhotosCore, so this is
        // the single source of truth for package strings.
        .target(name: "PhotosCore", resources: [.process("Resources")], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "PhotosCoreTests", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        // DesignSystemCore owns the shared branding assets (Resources/Branding.xcassets) - the
        // loading mark is one SwiftUI view used verbatim by macOS (launch veil) and iOS (library
        // loading screen).
        .target(name: "DesignSystemCore", resources: [.process("Resources")], swiftSettings: disableDynamicActorIsolation),
        .target(name: "DesignSystemAppKitAdapter", dependencies: ["DesignSystemCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "DesignSystem", dependencies: ["DesignSystemCore", "DesignSystemAppKitAdapter"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "ProtonAuth", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "ProtonAuthTests", dependencies: ["ProtonAuth"], swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "ProtonDriveBackend",
            dependencies: [
                "PhotosCore",
                "ProtonAuth",
                "AlbumCore",
                "AlbumsFeature",
                "AlbumSyncCore",
                "UploadCore",
                .product(name: "ProtonDriveSDK", package: "ProtonDriveSDK"),
                .product(name: "ProtonCoreDataModel", package: "protoncore_ios"),
                .product(name: "ProtonCoreCrypto", package: "protoncore_ios"),
                .product(name: "ProtonCoreCryptoGoInterface", package: "protoncore_ios"),
            ],
            swiftSettings: sdkBackendSwiftSettings
        ),
        .testTarget(
            name: "ProtonDriveBackendTests",
            dependencies: [
                "ProtonDriveBackend", "ProtonAuth", "PhotosCore", "AlbumSyncCore",
                .product(name: "ProtonCoreCryptoGoInterface", package: "protoncore_ios"),
                // The gopenpgp implementation the app injects at startup - the crypto round-trip
                // tests need a live implementation behind the CryptoGo interface.
                .product(name: "ProtonCoreCryptoPatchedGoImplementation", package: "protoncore_ios"),
            ],
            swiftSettings: sdkBackendSwiftSettings
        ),
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
        .testTarget(name: "MetalGridTextureCoreTests", dependencies: ["MetalGridTextureCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MetalGridTextureAppKitAdapter", dependencies: ["MetalGridTextureCore", "GridCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MetalGridTextureUIKitAdapter", dependencies: ["MetalGridTextureCore", "GridCore"], swiftSettings: disableDynamicActorIsolation),
        // Universal frame-composition core: the single source of truth for the settled-grid streaming +
        // render-group sequence shared by the macOS (TimelineFeature) and iOS (TimelineUIKitFeature) hosts.
        // Metal-tier Core: no platform view framework, no photo-domain IDs (generic over the item ID).
        .target(name: "MetalGridComposeCore", dependencies: ["GridCore", "MetalGridTextureCore", "MetalRenderingCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaCacheAppKitAdapter", dependencies: ["PhotosCore", "MediaByteCache", "MediaDecodingCore", "MediaFeedCore", "MediaCacheCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaCacheUIKitAdapter", dependencies: ["PhotosCore", "MediaByteCache", "MediaDecodingCore", "MediaFeedCore", "MediaCacheCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "MediaCacheUIKitAdapterTests", dependencies: ["MediaCacheUIKitAdapter", "MediaCacheCore", "MediaByteCache", "MediaFeedCore", "PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "MediaCacheCoreTests", dependencies: ["MediaCacheCore", "PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MediaCache", dependencies: ["MediaByteCache", "MediaLocationCore", "MediaCacheCore", "MediaCacheAppKitAdapter"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "TimelineCore", dependencies: ["PhotosCore", "GridCore"], resources: [.process("Resources")], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "TimelineCoreTests", dependencies: ["TimelineCore", "PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "TimelineUIKitAdapter", dependencies: ["GridCore", "TimelineCore", "MetalRenderingCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "TimelineUIKitFeature", dependencies: ["PhotosCore", "GridCore", "TimelineCore", "TimelineUIKitAdapter", "MetalRenderingCore", "MetalGridTextureCore", "MetalGridTextureUIKitAdapter", "MetalGridComposeCore", "MediaCacheUIKitAdapter"], swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "TimelineFeature",
            dependencies: ["PhotosCore", "DesignSystem", "MediaCache", "GridCore", "TimelineCore", "MetalRenderingCore", "MetalGridTextureCore", "MetalGridTextureAppKitAdapter", "MetalGridComposeCore"],
            swiftSettings: disableDynamicActorIsolation
        ),
        .target(name: "PhotoViewerCore", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "PhotoViewerUIKitAdapter", dependencies: ["PhotoViewerCore", "PhotosCore", "MediaCacheCore"], swiftSettings: disableDynamicActorIsolation),
        .target(
            name: "PhotoViewerFeature",
            dependencies: ["PhotosCore", "DesignSystem", "MediaCache", "PhotoViewerCore"],
            swiftSettings: disableDynamicActorIsolation
        ),
        .testTarget(name: "PhotoViewerFeatureTests", dependencies: ["PhotoViewerFeature", "PhotoViewerCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(
            name: "TimelineFeatureTests",
            dependencies: ["TimelineFeature", "TimelineCore", "GridCore", "MetalRenderingCore", "MetalGridTextureCore", "MetalGridTextureAppKitAdapter", "MetalGridTextureUIKitAdapter", "MetalGridComposeCore", "MediaCache", "PhotosCore"],
            swiftSettings: disableDynamicActorIsolation
        ),
        // Albums: universal management protocols + repository over an injected backend. The app's
        // current backend routes reads via direct HTTP; album writes go through the backend's
        // album-write service (direct HTTP + clean-room node crypto) until the SDK exposes them.
        .target(name: "AlbumCore", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        // Backward-compatible feature product for app targets already importing AlbumsFeature.
        .target(name: "AlbumsFeature", dependencies: ["AlbumCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "AlbumsFeatureTests", dependencies: ["AlbumCore", "AlbumsFeature", "PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        // AlbumSyncCore: universal local-album → Proton-album sync engine (planner, runner, mapping
        // store). Pure Swift: no PhotoKit/UIKit/AppKit/SwiftUI/SDK imports - platform adapters
        // provide the local album source; the backend provides remote album operations.
        .target(name: "AlbumSyncCore", dependencies: ["AlbumCore", "UploadCore", "PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "AlbumSyncCoreTests", dependencies: ["AlbumSyncCore", "AlbumCore", "UploadCore", "PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        // UploadCore: pure queue + state machine + folder enumeration over an injected upload backend.
        .target(name: "UploadCore", dependencies: ["PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        // UploadFeature: SwiftUI adapter over UploadCore. No DesignSystem dependency; the native
        // presentation chrome stays owned by the host platform.
        .target(name: "UploadFeature", dependencies: ["UploadCore", "PhotosCore"], swiftSettings: disableDynamicActorIsolation),
        // PhotoLibraryBackupAdapter: the ONE PhotoKit boundary (contract platform-adapter layer),
        // shared verbatim by iOS/iPadOS/macOS. May import Photos; never UIKit/AppKit/SwiftUI or
        // the SDK. Emits platform-neutral UploadCore values; makes no dedupe/upload decisions.
        .target(name: "PhotoLibraryBackupAdapter", dependencies: ["UploadCore", "PhotosCore", "AlbumSyncCore"], swiftSettings: disableDynamicActorIsolation),
        .testTarget(name: "UploadFeatureTests", dependencies: ["UploadCore", "PhotosCore", "PhotoLibraryBackupAdapter"], swiftSettings: disableDynamicActorIsolation),
        // Map: UIKit/AppKit MapKit views + clustering over PhotoLocationIndex (MediaLocationCore).
        // MapCore: platform-neutral MKAnnotation conformer + the shared annotation-loading engine
        // (framing, off-main aggregation, diff, generation guard) used by both map adapters.
        .target(name: "MapCore", dependencies: ["PhotosCore", "MediaLocationCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MapUIKitAdapter", dependencies: ["PhotosCore", "MediaLocationCore", "MapCore"], swiftSettings: disableDynamicActorIsolation),
        .target(name: "MapFeature", dependencies: ["PhotosCore", "MediaLocationCore", "MapCore", "DesignSystem"], swiftSettings: disableDynamicActorIsolation),
    ]
)
