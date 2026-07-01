#if canImport(UIKit)
import CoreGraphics
import Metal
import MetalGridTextureCore

@MainActor
package enum UIKitMetalGridTextureCacheFactory {
    package static func makeCache<ID: Hashable & Sendable>(
        device: MTLDevice,
        policy: UIKitMetalGridTexturePolicy,
        glyphRasterizer: any MetalGridGlyphRasterizing = UIKitMetalGridGlyphRasterizer()
    ) -> MetalGridTextureCache<ID>? {
        MetalGridTextureCache(
            device: device,
            budget: policy.budget,
            maxTexturePixels: policy.maxTexturePixels,
            glyphRasterizer: glyphRasterizer
        )
    }

    package static func makeCache<ID: Hashable & Sendable>(
        device: MTLDevice,
        viewportSize: CGSize,
        glyphRasterizer: any MetalGridGlyphRasterizing = UIKitMetalGridGlyphRasterizer()
    ) -> MetalGridTextureCache<ID>? {
        makeCache(
            device: device,
            policy: UIKitMetalGridTexturePolicies.policy(forViewportSize: viewportSize),
            glyphRasterizer: glyphRasterizer
        )
    }
}
#endif
