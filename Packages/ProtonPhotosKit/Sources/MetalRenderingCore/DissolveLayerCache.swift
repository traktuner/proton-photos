/// Pure, GPU-free decision for the OVERVIEW LAYER DISSOLVE: which of the two frozen layers (source, target)
/// must be re-rasterized this frame, and which can be reused from the previous frame's offscreen texture.
///
/// The dissolve composites two settled grids as `mix(A, B, t)`. During a held pinch/scrub only `t` moves,
/// so both layers are pixel-identical frame to frame - yet the old renderer re-rasterized BOTH every frame
/// (two full offscreen passes + two `buildRealGroups`, the dissolve's dominant cost). A layer only actually
/// changes when: the drawable resizes, the dissolve plan is replaced (a new begin), or a thumbnail that layer
/// wants finishes streaming in. This state machine records which layers have been rasterized and returns, per
/// frame, exactly the ones that must be (re)drawn - so a steady frame becomes composite-only.
///
/// It is intentionally Metal-free (tracks only `Bool` flags + an `Int` size) so the invalidation logic is
/// unit-testable without a GPU. The renderer keys its actual `MTLTexture` (re)allocation on the SAME
/// width/height passed here, so "resize invalidates both layers" stays consistent between the two.
package struct DissolveLayerCache: Equatable {
    private var renderedSource = false
    private var renderedTarget = false
    private var size: SIMDSizeless?

    // A tiny value type so we don't pull SIMD/CoreGraphics in just for an (Int, Int) pair.
    private struct SIMDSizeless: Equatable { var width: Int; var height: Int }

    package init() {}

    /// Decide which layers to (re)raster this frame and record that they will be. `redrawSource`/`redrawTarget`
    /// are the caller's content-arrival requests (a wanted thumbnail for that layer became resident/upgraded).
    /// A drawable-size change forces BOTH (the offscreen textures are reallocated, so their contents are gone),
    /// and a layer that has never been rasterized for the current plan is always drawn.
    package mutating func plan(redrawSource: Bool, redrawTarget: Bool, width: Int, height: Int) -> (source: Bool, target: Bool) {
        let incoming = SIMDSizeless(width: width, height: height)
        if size != incoming {
            renderedSource = false
            renderedTarget = false
            size = incoming
        }
        let drawSource = redrawSource || !renderedSource
        let drawTarget = redrawTarget || !renderedTarget
        if drawSource { renderedSource = true }
        if drawTarget { renderedTarget = true }
        return (drawSource, drawTarget)
    }

    /// A new dissolve plan replaced the old one (a fresh begin): forget both rasters so the next frame redraws
    /// the new plan's geometry. Keeps the size (same drawable), so only content, not the surface, is invalidated.
    package mutating func invalidate() {
        renderedSource = false
        renderedTarget = false
    }

    /// The dissolve ended (commit/finish): forget everything, so the next dissolve starts from a clean slate
    /// and the renderer can free the offscreen textures.
    package mutating func release() {
        renderedSource = false
        renderedTarget = false
        size = nil
    }

    // Test/inspection surface.
    package var hasRenderedSource: Bool { renderedSource }
    package var hasRenderedTarget: Bool { renderedTarget }
}
