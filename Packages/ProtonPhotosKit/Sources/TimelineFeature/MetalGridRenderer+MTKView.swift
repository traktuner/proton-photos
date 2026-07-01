import CoreGraphics
import MetalKit
import MetalRenderingCore

extension MetalGridDrawableTarget {
    @MainActor
    init?(view: MTKView) {
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor else { return nil }
        self.init(
            drawable: drawable,
            renderPassDescriptor: pass,
            presentsWithTransaction: view.presentsWithTransaction
        )
    }
}

extension MetalGridRenderer {
    @MainActor
    func render(in view: MTKView, viewportSize: CGSize, groups: [MetalGridRenderGroup]) {
        guard let target = MetalGridDrawableTarget(view: view) else { return }
        render(to: target, viewportSize: viewportSize, groups: groups)
    }

    @MainActor
    func renderLayerDissolve(
        in view: MTKView,
        viewportSize: CGSize,
        sourceGroups: [MetalGridRenderGroup],
        targetGroups: [MetalGridRenderGroup],
        t: Float
    ) {
        guard let target = MetalGridDrawableTarget(view: view) else { return }
        renderLayerDissolve(
            to: target,
            viewportSize: viewportSize,
            sourceGroups: sourceGroups,
            targetGroups: targetGroups,
            t: t
        )
    }
}
