import CoreGraphics
import PhotosCore

// MARK: - Metal Grid Lab (Phase 1) — shared value types
//
// This is the isolated MetalGridLab prototype (Phase 1 of the Metal-grid rewrite). It proves a Metal-
// backed photo grid can render + scroll the 20k-photo library smoothly. It does NOT replace the
// production NSCollectionView grid (`PhotoGridView`) — see the lab entry `MetalGridLab`.
//
// Architecture (Option A): NSScrollView owns scroll physics; a viewport-sized MTKView draws only the
// visible items. The renderer reuses the proven rounded-corner SDF + premultiplied-alpha shader from
// `GridSpriteTransitionView` (one quad per visible cell) but uses one-texture-per-image with an LRU
// cache (Pixe-style, Option A) rather than the zoom-transition atlas, so the production zoom path is
// left completely untouched.

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

/// Scroll-state diagnostics (the `[MetalGridScroll]` block).
struct MetalGridScrollStats: Equatable, Sendable {
    var visibleRect: CGRect = .zero
    var contentSize: CGSize = .zero
    var scrollVelocity: CGFloat = 0      // points/sec, vertical
    var overscanAhead: CGFloat = 0
    var overscanBehind: CGFloat = 0

    var summary: String {
        "visibleRect=\(rectStr(visibleRect)) contentSize=(\(Int(contentSize.width))x\(Int(contentSize.height))) "
        + "scrollVelocity=\(Int(scrollVelocity)) overscanAhead=\(Int(overscanAhead)) overscanBehind=\(Int(overscanBehind))"
    }

    private func rectStr(_ r: CGRect) -> String {
        "(\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height)))"
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
    var scroll = MetalGridScrollStats()
    var cache = MetalGridCacheStats()
    var level = 2
    var totalItems = 0
    var dataSource = "—"   // "real" / "synthetic"
}

/// Tunable budgets for the prototype (kept liberal — Phase 1 proves the architecture, not final tuning).
struct MetalGridBudget: Sendable {
    /// Max texture uploads pushed to the GPU per frame (visible-first). 8–32 per the spec.
    var maxUploadsPerFrame = 24
    /// Max resident textures before LRU eviction kicks in.
    var maxCachedTextures = 1200
    /// Vertical overscan (fraction of viewport height) queried above & below the visible rect.
    var overscanFraction: CGFloat = 0.6

    static let `default` = MetalGridBudget()
}
