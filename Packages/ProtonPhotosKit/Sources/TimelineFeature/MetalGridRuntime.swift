import Foundation
import Metal
import MetalRenderingCore
import PhotosCore

/// Runtime probe for the Metal-backed library grid. The production timeline is MetalGrid-ONLY (the canonical
/// `SquareTileGridEngine` owns all geometry - there is no legacy-grid fallback and no feature flag). This
/// only answers "can Metal actually initialise on this machine" so callers never crash if a GPU/shader is
/// missing, and logs the resolved path once for diagnostics.
enum MetalGridRuntime {
    /// One-time probe: a Metal device exists AND the production renderer/shader builds. Cached.
    static let isMetalRenderable: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return MetalGridRenderer(device: device, clearColor: MetalGridPalette.clearColor) != nil
    }()

    @MainActor private static var didLogResolution = false

    /// Logs the resolved render path exactly once (idempotent across the many TimelineView re-renders).
    @MainActor static func logResolutionOnce() {
        guard !didLogResolution else { return }
        didLogResolution = true
        PhotoDiagnostics.shared.emit("MetalGrid", [
            "activePath": isMetalRenderable ? "metal" : "unavailable",
            "metalRenderable": "\(isMetalRenderable)",
        ])
    }
}
