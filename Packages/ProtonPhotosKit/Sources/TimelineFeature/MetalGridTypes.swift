import CoreGraphics
import PhotosCore

// MARK: - Metal grid — shared value types (diagnostics + HUD)
//
// Per-frame render accounting and HUD mirroring for the Metal-backed photo grid.
//
// Architecture (Option A): NSScrollView owns scroll physics; a viewport-sized MTKView draws only the
// visible items each frame, with one texture per image behind an LRU cache (Pixe-style).

/// Per-frame render accounting for the `[MetalGrid]` diagnostics block + the in-lab HUD overlay.
struct MetalGridStats: Equatable, Sendable {
    var visibleItems = 0
    var overscanItems = 0
    var realTextureItems = 0
    var placeholderItems = 0
    var textureUploads = 0
    var textureUploadBytes = 0
    var cacheHits = 0
    var cacheMisses = 0
    var evictions = 0
    var drawCalls = 0
    var instanceCount = 0
    var cpuLayoutMs: Double = 0
    var cpuInstanceMs: Double = 0
    var textureUploadMs: Double = 0
    var gpuDrawMs: Double = 0
    var fpsEstimate: Double = 0
    var memoryEstimateBytes = 0

    var summary: String {
        "visibleItems=\(visibleItems) overscanItems=\(overscanItems) realTextureItems=\(realTextureItems) "
        + "placeholderItems=\(placeholderItems) textureUploads=\(textureUploads) textureUploadBytes=\(textureUploadBytes) "
        + "cacheHits=\(cacheHits) cacheMisses=\(cacheMisses) evictions=\(evictions) drawCalls=\(drawCalls) "
        + "instanceCount=\(instanceCount) cpuLayoutMs=\(fmt(cpuLayoutMs)) cpuInstanceMs=\(fmt(cpuInstanceMs)) "
        + "textureUploadMs=\(fmt(textureUploadMs)) gpuDrawMs=\(fmt(gpuDrawMs)) fpsEstimate=\(fmt(fpsEstimate)) "
        + "memoryEstimateMB=\(fmt(Double(memoryEstimateBytes) / 1_048_576))"
    }

    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    /// Pure derivation of the visible/real/placeholder counts from a frame's draw list — unit-testable
    /// without Metal (DiagnosticsCounterTest). `realResident(uid)` reports whether a real GPU texture is
    /// resident for that photo (placeholder otherwise).
    static func counts(
        visibleCount: Int,
        overscanCount: Int,
        drawnUIDs: [PhotoUID],
        realResident: (PhotoUID) -> Bool
    ) -> (real: Int, placeholder: Int) {
        var real = 0
        for uid in drawnUIDs where realResident(uid) { real += 1 }
        return (real, drawnUIDs.count - real)
    }
}

/// Texture-cache diagnostics (the `[MetalGridCache]` block).
struct MetalGridCacheStats: Equatable, Sendable {
    var textureCount = 0
    var pinnedVisible = 0
    var lruSize = 0
    var uploadQueueDepth = 0

    var summary: String {
        "textureCount=\(textureCount) pinnedVisible=\(pinnedVisible) lruSize=\(lruSize) uploadQueueDepth=\(uploadQueueDepth)"
    }
}

/// Everything the SwiftUI HUD overlay mirrors each (throttled) update.
struct MetalGridHUD: Equatable, Sendable {
    var stats = MetalGridStats()
    var cache = MetalGridCacheStats()
    var level = 2
    var totalItems = 0
    var dataSource = "—"   // "real" / "synthetic"
}

/// Tunable streaming/overscan budgets (kept liberal; tune against real-device profiling if needed).
struct MetalGridBudget: Sendable {
    /// Max texture uploads pushed to the GPU per frame (visible-first). macOS can afford a larger burst here:
    /// the decoded CGImages are already in RAM, and this prevents dense-grid direction changes from repainting
    /// visible thumbnails over many frames.
    var maxUploadsPerFrame = 96
    /// Max resident textures before LRU eviction kicks in. This is a macOS adapter budget, not a Core rule;
    /// future iOS/iPadOS adapters should inject their own lower memory policy.
    var maxCachedTextures = 4096
    /// Vertical overscan (fraction of viewport height) queried above & below the visible rect.
    var overscanFraction: CGFloat = 1.2

    static let `default` = MetalGridBudget()
}
