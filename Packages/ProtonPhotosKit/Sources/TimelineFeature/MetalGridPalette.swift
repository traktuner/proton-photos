import AppKit
import Metal

// MARK: - MetalGridPalette — the single source of truth for the production grid surface color
//
// The production grid must read as ONE continuous Apple-like dark-gray surface behind the thumbnails: gaps
// between tiles, aspectFit letterbox/pillarbox, and the clear color are all THIS color. No per-cell card
// backgrounds (except a placeholder while an image is genuinely missing), no grid lines, no debug tile colors.
// Do not scatter hardcoded colors — use these constants everywhere.
enum MetalGridPalette {
    /// Neutral dark surface, ~#1f1f1f. Dark-appearance friendly (sampled near Apple Photos' dark grid surface).
    static let backgroundRGBA: (r: Double, g: Double, b: Double, a: Double) = (0.122, 0.122, 0.122, 1.0)

    static var background: NSColor {
        NSColor(srgbRed: backgroundRGBA.r, green: backgroundRGBA.g, blue: backgroundRGBA.b, alpha: backgroundRGBA.a)
    }
    static var clearColor: MTLClearColor {
        MTLClearColor(red: backgroundRGBA.r, green: backgroundRGBA.g, blue: backgroundRGBA.b, alpha: backgroundRGBA.a)
    }
    /// The same color as a premultiplied float vector (for any quad that needs to paint the surface explicitly).
    static var backgroundVector: SIMD4<Float> {
        SIMD4(Float(backgroundRGBA.r), Float(backgroundRGBA.g), Float(backgroundRGBA.b), Float(backgroundRGBA.a))
    }
}
