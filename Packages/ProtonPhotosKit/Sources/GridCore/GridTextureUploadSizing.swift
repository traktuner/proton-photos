import CoreGraphics

/// Pure, platform-neutral policy for the pixel side a grid thumbnail should be uploaded at.
///
/// The Metal texture cache is level-blind on its own - it clamps every upload to a single `maxTexturePixels`
/// cap. That over-supplies texels for the dense overview levels (a 30-column tile is physically ~39–94 px yet
/// still uploaded at 320 px = 11–33× the texels it can ever display), wasting GPU memory and upload bandwidth
/// and - with no mipmaps - adding minification shimmer. This helper derives the *effective* cap for the
/// on-screen slot so dense levels upload small textures while sparse levels saturate at the platform cap and
/// keep full quality.
///
/// It is deliberately geometric only: it takes a slot side in points, a display backing scale, and the
/// adapter's absolute cap, and knows nothing about photo domains, zoom-level ladders, Metal, or a concrete OS.
/// The photo-domain caller (the grid coordinator) supplies the slot side for the current level; the platform
/// adapter supplies `cap` (its `maxTexturePixels`). Both stay outside GridCore.
package enum GridTextureUploadSizing {
    /// The upload pixel side for a slot: its native device pixels (`slotSidePoints × backingScale`) times a
    /// small supersampling `headroom`, clamped to `[floor, cap]`.
    ///
    /// - Dense (small-slot) levels resolve well below `cap` - the memory/bandwidth win.
    /// - Sparse (large-slot) levels saturate at `cap`, so they upload exactly as before (no quality change).
    /// - `headroom` (≥ 1) trades a little VRAM for less minification shimmer on the mip-less grid textures.
    /// - `floor` guarantees a minimum crispness for physically tiny dense-overview slots.
    ///
    /// The result is always ≥ 1 and ≤ `cap` (so it can never *raise* the platform ceiling), and never below
    /// `min(floor, cap)`.
    package static func uploadPixels(
        slotSidePoints: CGFloat,
        backingScale: CGFloat,
        headroom: CGFloat,
        floor: Int,
        cap: Int
    ) -> Int {
        let cap = max(1, cap)
        let native = max(0, slotSidePoints) * max(1, backingScale)
        let target = Int((native * max(1, headroom)).rounded())
        let lowerBound = min(max(1, floor), cap)
        return min(cap, max(lowerBound, target))
    }
}
