import CoreGraphics

/// Platform-injected texture streaming and residency limits.
///
/// This is only the portable budget shape. Concrete defaults belong to platform adapters because macOS,
/// iPhone, and iPad may choose different RAM/GPU tradeoffs.
///
/// The budget is hybrid: texture *count* limits bound bookkeeping and small-texture floods, byte limits
/// bound the real GPU memory footprint (count alone is unbounded in bytes once pixel sizes vary) and the
/// per-frame upload copy cost on the render thread.
package struct GridTextureBudget: Equatable, Sendable {
    /// Max texture uploads started in one frame (count backstop for many tiny textures).
    package var maxUploadsPerFrame: Int
    /// Max texture bytes uploaded in one frame — bounds the main-thread copy cost per frame.
    package var maxUploadBytesPerFrame: Int
    /// Max measured upload/normalization milliseconds spent in one frame. The first upload of a frame is
    /// still allowed so one expensive image cannot starve forever; remaining work is deferred.
    package var maxUploadMillisecondsPerFrame: Double
    /// Max resident textures by count.
    package var maxCachedTextures: Int
    /// Max resident texture bytes — the real GPU memory ceiling the cache must enforce.
    package var maxResidentBytes: Int
    package var overscanFraction: CGFloat

    package init(
        maxUploadsPerFrame: Int,
        maxUploadBytesPerFrame: Int,
        maxCachedTextures: Int,
        maxResidentBytes: Int,
        overscanFraction: CGFloat,
        maxUploadMillisecondsPerFrame: Double = .infinity
    ) {
        self.maxUploadsPerFrame = maxUploadsPerFrame
        self.maxUploadBytesPerFrame = maxUploadBytesPerFrame
        self.maxUploadMillisecondsPerFrame = max(0, maxUploadMillisecondsPerFrame)
        self.maxCachedTextures = maxCachedTextures
        self.maxResidentBytes = maxResidentBytes
        self.overscanFraction = overscanFraction
    }
}
