#if canImport(UIKit)
import Metal
import MetalRenderingCore
import QuartzCore

package extension MetalGridDrawableTarget {
    @MainActor
    init?(layer: CAMetalLayer, clearColor: MTLClearColor = MetalGridRenderPalette.clearColor) {
        guard let drawable = layer.nextDrawable() else { return nil }

        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.texture
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clearColor

        self.init(
            drawable: drawable,
            renderPassDescriptor: descriptor,
            presentsWithTransaction: layer.presentsWithTransaction
        )
    }
}
#endif
