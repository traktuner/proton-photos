import Testing
import MetalRenderingCore

/// The pure state machine behind overview-dissolve layer caching: decides which of the two frozen layers must
/// be re-rasterized each frame so a steady scrub becomes composite-only, while newly streamed thumbnails,
/// resizes, and new plans still force the right re-raster. GPU-free by design.
@Suite struct DissolveLayerCacheTests {
    private let w = 1280, h = 800

    @Test func firstFrameDrawsBothLayers() {
        var cache = DissolveLayerCache()
        let d = cache.plan(redrawSource: false, redrawTarget: false, width: w, height: h)
        #expect(d.source && d.target, "a never-rasterized plan must draw both layers on the first frame")
    }

    @Test func steadyScrubDrawsNeitherLayer() {
        var cache = DissolveLayerCache()
        _ = cache.plan(redrawSource: false, redrawTarget: false, width: w, height: h)   // first frame
        // Subsequent frames with no content arrival, same size, same plan → composite-only.
        for _ in 0 ..< 5 {
            let d = cache.plan(redrawSource: false, redrawTarget: false, width: w, height: h)
            #expect(!d.source && !d.target, "a steady scrub must not re-raster either layer")
        }
    }

    @Test func newlyResidentTileRedrawsOnlyThatLayer() {
        var cache = DissolveLayerCache()
        _ = cache.plan(redrawSource: false, redrawTarget: false, width: w, height: h)   // settle both

        // A target-layer thumbnail arrived: redraw target only.
        let t = cache.plan(redrawSource: false, redrawTarget: true, width: w, height: h)
        #expect(!t.source && t.target)

        // Back to steady → neither.
        let steady = cache.plan(redrawSource: false, redrawTarget: false, width: w, height: h)
        #expect(!steady.source && !steady.target)

        // A source-layer thumbnail arrived: redraw source only.
        let s = cache.plan(redrawSource: true, redrawTarget: false, width: w, height: h)
        #expect(s.source && !s.target)
    }

    @Test func drawableResizeRedrawsBothLayers() {
        var cache = DissolveLayerCache()
        _ = cache.plan(redrawSource: false, redrawTarget: false, width: w, height: h)   // settle both
        _ = cache.plan(redrawSource: false, redrawTarget: false, width: w, height: h)   // steady

        let resized = cache.plan(redrawSource: false, redrawTarget: false, width: w + 200, height: h)
        #expect(resized.source && resized.target, "a resize reallocates the offscreen textures → both must redraw")

        // After the resize frame, steady again at the new size.
        let steady = cache.plan(redrawSource: false, redrawTarget: false, width: w + 200, height: h)
        #expect(!steady.source && !steady.target)
    }

    @Test func invalidateForcesBothOnNextFrameKeepingSize() {
        var cache = DissolveLayerCache()
        _ = cache.plan(redrawSource: false, redrawTarget: false, width: w, height: h)
        _ = cache.plan(redrawSource: false, redrawTarget: false, width: w, height: h)   // steady

        cache.invalidate()   // a new dissolve plan replaced the old one
        let d = cache.plan(redrawSource: false, redrawTarget: false, width: w, height: h)
        #expect(d.source && d.target, "a new plan must re-raster both layers (same drawable size)")
    }

    @Test func releaseResetsToCleanSlate() {
        var cache = DissolveLayerCache()
        _ = cache.plan(redrawSource: false, redrawTarget: false, width: w, height: h)
        _ = cache.plan(redrawSource: false, redrawTarget: false, width: w, height: h)

        cache.release()   // dissolve committed/finished
        #expect(!cache.hasRenderedSource && !cache.hasRenderedTarget)
        // The next dissolve starts fresh → both drawn even at the same size (size was cleared).
        let d = cache.plan(redrawSource: false, redrawTarget: false, width: w, height: h)
        #expect(d.source && d.target)
    }
}
