// swift-tools-version: 6.0
import PackageDescription

// Pure-Swift feature modules. Deliberately has NO dependency on ProtonDriveSDK,
// so it stays free of the SDK's `unsafeFlags` linker constraints. SDK-coupled glue
// (HttpClient/AccountClient/Bridge) lives in the app target instead.
let package = Package(
    name: "ProtonPhotosKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "PhotosCore", targets: ["PhotosCore"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "ProtonAuth", targets: ["ProtonAuth"]),
        .library(name: "MediaCache", targets: ["MediaCache"]),
        .library(name: "TimelineFeature", targets: ["TimelineFeature"]),
        .library(name: "PhotoViewerFeature", targets: ["PhotoViewerFeature"]),
        // Isolated Grid-Zoom V3 prototype (synthetic tiles, no Proton data). See GridZoomV3Lab.
        .library(name: "GridZoomV3", targets: ["GridZoomV3"]),
    ],
    targets: [
        .target(name: "PhotosCore"),
        .target(name: "DesignSystem", dependencies: ["PhotosCore"]),
        .target(name: "ProtonAuth", dependencies: ["PhotosCore"]),
        .target(name: "MediaCache", dependencies: ["PhotosCore"]),
        .target(
            name: "TimelineFeature",
            dependencies: ["PhotosCore", "DesignSystem", "MediaCache"]
        ),
        .target(
            name: "PhotoViewerFeature",
            dependencies: ["PhotosCore", "DesignSystem", "MediaCache"]
        ),
        .testTarget(
            name: "TimelineFeatureTests",
            dependencies: ["TimelineFeature", "MediaCache", "PhotosCore"]
        ),
        // Pure prototype: AppKit renderer + SwiftUI shell + pure layout engine. No Proton deps.
        .target(name: "GridZoomV3"),
        .testTarget(name: "GridZoomV3Tests", dependencies: ["GridZoomV3"]),
    ]
)
