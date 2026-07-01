import CoreGraphics
import GridCore
import Metal

/// Package boundary marker for reusable Metal grid texture code.
///
/// The actual texture cache moves here only after the gate proves this target on macOS, iOS, and iPadOS.
/// Keep platform glyph implementations, view hosting, scroll/gesture input, and photo-domain IDs in adapters.
package enum MetalGridTextureCoreBoundary {
    package typealias Budget = GridTextureBudget
    package typealias UploadImage = CGImage
    package typealias Texture = MTLTexture
}
