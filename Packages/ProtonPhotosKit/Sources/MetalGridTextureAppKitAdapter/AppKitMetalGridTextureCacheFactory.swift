#if canImport(AppKit)
import Metal
import MetalGridTextureCore

@MainActor
package enum AppKitMetalGridTextureCacheFactory {
    package static func makeCache<ID: Hashable & Sendable>(
        device: MTLDevice,
        policy: AppKitMetalGridTexturePolicy,
        glyphRasterizer: any MetalGridGlyphRasterizing = AppKitMetalGridGlyphRasterizer()
    ) -> MetalGridTextureCache<ID>? {
        MetalGridTextureCache(
            device: device,
            budget: policy.budget,
            maxTexturePixels: policy.maxTexturePixels,
            glyphRasterizer: glyphRasterizer
        )
    }
}
#endif
