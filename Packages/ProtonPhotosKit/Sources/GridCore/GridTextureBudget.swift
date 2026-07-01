import CoreGraphics

/// Platform-injected texture streaming and residency limits.
///
/// This is only the portable budget shape. Concrete defaults belong to platform adapters because macOS,
/// iPhone, and iPad may choose different RAM/GPU tradeoffs.
package struct GridTextureBudget: Equatable, Sendable {
    package var maxUploadsPerFrame: Int
    package var maxCachedTextures: Int
    package var overscanFraction: CGFloat

    package init(maxUploadsPerFrame: Int, maxCachedTextures: Int, overscanFraction: CGFloat) {
        self.maxUploadsPerFrame = maxUploadsPerFrame
        self.maxCachedTextures = maxCachedTextures
        self.overscanFraction = overscanFraction
    }
}
