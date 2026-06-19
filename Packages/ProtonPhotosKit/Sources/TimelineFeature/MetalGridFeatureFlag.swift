import Foundation
import Metal
import PhotosCore

/// Central feature flag controlling whether the library grid uses the Metal-backed renderer
/// (`MetalProductionGridView`) or the legacy `NSCollectionView` grid (`PhotoGridView`).
///
/// Default: **ON**. Override via the Settings ▸ Developer toggle, the `MetalGrid.enabled` UserDefaults
/// key, or a launch argument `-MetalGrid.enabled NO` (NSUserDefaults' argument domain). The legacy grid
/// is kept as a temporary fallback until interaction parity is fully verified.
public enum MetalGridFeatureFlag {
    public static let userDefaultsKey = "MetalGrid.enabled"

    /// True unless explicitly disabled. An unset key defaults to enabled.
    public static var isEnabled: Bool {
        guard UserDefaults.standard.object(forKey: userDefaultsKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: userDefaultsKey)
    }

    public static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: userDefaultsKey)
    }
}

/// Runtime gate: even when the flag is ON, the Metal path is only used if Metal can actually initialise
/// (a GPU exists and the renderer's shader compiles). Otherwise we fall back to NSCollectionView and
/// never crash. The probe runs once and is cached.
enum MetalGridRuntime {
    /// One-time probe: a device exists AND the production renderer/shader builds.
    static let isMetalRenderable: Bool = {
        guard let device = MTLCreateSystemDefaultDevice() else { return false }
        return MetalGridRenderer(device: device) != nil
    }()

    /// Whether the live grid should use Metal: flag ON and Metal actually renderable.
    static var usesMetalGrid: Bool { MetalGridFeatureFlag.isEnabled && isMetalRenderable }

    @MainActor private static var didLogResolution = false

    /// Logs the resolved path exactly once (idempotent across the many TimelineView re-renders).
    @MainActor static func logResolutionOnce() {
        guard !didLogResolution else { return }
        didLogResolution = true
        let metal = usesMetalGrid
        PhotoDiagnostics.shared.emit("MetalGrid", [
            "productionEnabled": "\(MetalGridFeatureFlag.isEnabled)",
            "fallbackAvailable": "true",
            "metalRenderable": "\(isMetalRenderable)",
        ])
        PhotoDiagnostics.shared.emit("MetalGrid", ["activePath": metal ? "metal" : "nscollectionview"])
        if MetalGridFeatureFlag.isEnabled && !isMetalRenderable {
            PhotoDiagnostics.shared.emit("MetalGridFallback", ["reason": "metalUnavailable"])
        }
    }
}
