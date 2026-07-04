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
/// bookkeeping. Per-frame upload bytes and measured upload time are sized for a 120 Hz (8.3 ms) frame budget
/// on A-series parts.
///
/// `maxTexturePixels` is the ABSOLUTE ceiling reached only by the largest (sparsest) grid levels — dense
/// levels are sized far below it per frame by `GridTextureUploadSizing`, so this ceiling never touches
/// dense-scroll cost. It is calibrated to the largest L0 tile each surface class can produce: compact
/// ≈ 133 pt × 3× scale × 1.15 headroom ≈ 460 px → 480; regular/expanded ≈ 200–250 pt × 2× × 1.15 ≈
/// 460–575 px → 512 (expanded accepts slight undersupply at its very largest tiles to keep one upload
/// ≤ 1 MiB). Residency stays bounded by the UNCHANGED byte caps: at sparse levels few tiles are visible,
/// so the visible set's texture bytes stay ≈ viewport pixels × 4 regardless of this ceiling.
package enum UIKitMetalGridTexturePolicies {
    package static let compact = UIKitMetalGridTexturePolicy(
        budget: GridTextureBudget(maxUploadsPerFrame: 16, maxUploadBytesPerFrame: 2_097_152, maxCachedTextures: 2_048, maxResidentBytes: 67_108_864, overscanFraction: 0.75, maxUploadMillisecondsPerFrame: 2.5),
        maxTexturePixels: 480
    )

    package static let regular = UIKitMetalGridTexturePolicy(
        budget: GridTextureBudget(maxUploadsPerFrame: 24, maxUploadBytesPerFrame: 3_145_728, maxCachedTextures: 3_072, maxResidentBytes: 100_663_296, overscanFraction: 0.9, maxUploadMillisecondsPerFrame: 3.5),
        maxTexturePixels: 512
    )

    package static let expanded = UIKitMetalGridTexturePolicy(
        budget: GridTextureBudget(maxUploadsPerFrame: 32, maxUploadBytesPerFrame: 4_194_304, maxCachedTextures: 6_144, maxResidentBytes: 201_326_592, overscanFraction: 1.0, maxUploadMillisecondsPerFrame: 4.5),
        maxTexturePixels: 512
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
