// swift-tools-version: 6.0
import PackageDescription

// Pure-Swift feature modules. Deliberately has NO dependency on ProtonDriveSDK,
// so it stays free of the SDK's `unsafeFlags` linker constraints. SDK-coupled glue
// (HttpClient/AccountClient/Bridge) lives in the app target instead.
let package = Package(
    name: "ProtonPhotosKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PhotosCore", targets: ["PhotosCore"]),
        .library(name: "DesignSystem", targets: ["DesignSystem"]),
        .library(name: "ProtonAuth", targets: ["ProtonAuth"]),
        .library(name: "MediaCache", targets: ["MediaCache"]),
        .library(name: "TimelineFeature", targets: ["TimelineFeature"]),
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
    ]
)
