import CoreGraphics
import GridCore

package enum UIKitMetalGridTextureSurfaceClass: String, Sendable {
    case compact
    case regular
    case expanded

    package static func resolving(viewportSize: CGSize) -> Self {
        let shortestSide = min(viewportSize.width, viewportSize.height)
        if shortestSide < 430 { return .compact }
        if shortestSide < 768 { return .regular }
        return .expanded
    }
}

package struct UIKitMetalGridTexturePolicy: Equatable, Sendable {
    package let budget: GridTextureBudget
    package let maxTexturePixels: Int

    package init(budget: GridTextureBudget, maxTexturePixels: Int) {
        self.budget = budget
        self.maxTexturePixels = maxTexturePixels
    }
}

/// iOS/iPadOS budgets are far more conservative than macOS: GPU allocations count fully against the app
/// footprint on Apple Silicon and jetsam limits on small devices sit near ~2 GB total, so the resident
/// byte caps (64/96/192 MiB by surface class) leave room for the decoded-image and byte caches. Count caps
/// are still high enough for dense, level-aware thumbnails to bind on bytes first; they only prevent runaway
/// bookkeeping. Per-frame upload bytes are sized for a 120 Hz (8.3 ms) frame budget on A-series parts.
package enum UIKitMetalGridTexturePolicies {
    package static let compact = UIKitMetalGridTexturePolicy(
        budget: GridTextureBudget(maxUploadsPerFrame: 16, maxUploadBytesPerFrame: 2_097_152, maxCachedTextures: 2_048, maxResidentBytes: 67_108_864, overscanFraction: 0.75),
        maxTexturePixels: 224
    )

    package static let regular = UIKitMetalGridTexturePolicy(
        budget: GridTextureBudget(maxUploadsPerFrame: 24, maxUploadBytesPerFrame: 3_145_728, maxCachedTextures: 3_072, maxResidentBytes: 100_663_296, overscanFraction: 0.9),
        maxTexturePixels: 256
    )

    package static let expanded = UIKitMetalGridTexturePolicy(
        budget: GridTextureBudget(maxUploadsPerFrame: 32, maxUploadBytesPerFrame: 4_194_304, maxCachedTextures: 6_144, maxResidentBytes: 201_326_592, overscanFraction: 1.0),
        maxTexturePixels: 288
    )

    package static func policy(for surfaceClass: UIKitMetalGridTextureSurfaceClass) -> UIKitMetalGridTexturePolicy {
        switch surfaceClass {
        case .compact: compact
        case .regular: regular
        case .expanded: expanded
        }
    }

    package static func policy(forViewportSize viewportSize: CGSize) -> UIKitMetalGridTexturePolicy {
        policy(for: UIKitMetalGridTextureSurfaceClass.resolving(viewportSize: viewportSize))
    }
}
