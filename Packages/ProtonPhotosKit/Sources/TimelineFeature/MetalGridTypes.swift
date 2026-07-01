import Foundation
import CoreGraphics
import GridCore

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
    /// without Metal (DiagnosticsCounterTest). `realResident(id)` reports whether a real GPU texture is
    /// resident for that item (placeholder otherwise).
    static func counts<ID>(
        visibleCount: Int,
        overscanCount: Int,
        drawnUIDs: [ID],
        realResident: (ID) -> Bool
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

typealias MetalGridBudget = GridTextureBudget

extension GridTextureBudget {
    /// macOS adapter default. Other adapters must inject their own measured policy.
    static let `default` = GridTextureBudget(
        maxUploadsPerFrame: 96,
        maxCachedTextures: 4096,
        overscanFraction: 1.2
    )
}
