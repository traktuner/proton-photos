import Testing
import Foundation
import CoreGraphics
import Metal
import MetalRenderingCore
import MetalGridTextureCore
import MetalGridTextureAppKitAdapter
import PhotosCore
import GridCore
@testable import TimelineFeature

/// Pure-piece tests for the Metal grid's supporting machinery. They run headlessly (no window) so
/// "build succeeded" is never the only evidence — coordinate transforms, LRU policy, placeholder
/// handling, upload dedup/budget, the renderer shader smoke test, and diagnostics counting are all
/// proven in isolation.
///
/// (The legacy `MetalGridLayout` ↔ `JustifiedCollectionLayout` parity / visible-range / hit-test /
/// late-arrival suites were removed with those layouts; the canonical geometry is covered by
/// `SquareTileGridEngineTests`.)

private func uid(_ s: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: s) }

// MARK: 1 — Coordinate transform

@Suite struct MetalGridCoordinateTransformTests {
    @Test func contentRectConvertsToViewportRect() {
        let content = CGRect(x: 100, y: 5000, width: 130, height: 130)
        let origin = CGPoint(x: 0, y: 4800)
        let vp = MetalGridGeometry.viewportRect(contentRect: content, visibleOrigin: origin)
        #expect(vp == CGRect(x: 100, y: 200, width: 130, height: 130))
    }
}

// MARK: 2 — Texture LRU eviction / pinning

@Suite struct GridTextureResidencyPolicyPhotoUIDTests {
    @Test func pinnedVisibleSurvivesEviction_offscreenEvicts() {
        var lru = GridTextureResidencyPolicy<PhotoUID>(capacity: 2, uploadBudgetPerFrame: 10)
        let (a, b, c) = (uid("a"), uid("b"), uid("c"))
        // Make a the OLDEST, then b, then c (one per frame).
        for u in [a, b, c] {
            lru.beginFrame(pinned: [])
            _ = lru.selectUploads(wanted: [u])
            lru.completeUpload(u)
        }
        #expect(lru.residentCount == 3)
        // New frame: a is visible (pinned) but NOT freshly used, so it's the LRU — pinning must save it.
        lru.beginFrame(pinned: [a])
        let evicted = lru.evictToBudget()
        #expect(lru.isResident(a))         // pinned visible survives despite being least-recently-used
        #expect(!lru.isResident(b))        // oldest non-pinned evicted
        #expect(lru.isResident(c))
        #expect(evicted == [b])
        #expect(lru.residentCount == 2)
    }
}

// MARK: 3 — Placeholder always available

@Suite struct MetalGridPlaceholderTests {
    @Test func missingImageDrawsPlaceholderUntilResident() {
        var lru = GridTextureResidencyPolicy<PhotoUID>(capacity: 10, uploadBudgetPerFrame: 10)
        let a = uid("a")
        #expect(lru.drawState(a) == .placeholder)   // never a hole — always a placeholder
        lru.beginFrame(pinned: [])
        _ = lru.selectUploads(wanted: [a])
        lru.completeUpload(a)
        #expect(lru.drawState(a) == .real)
    }
}

// MARK: 4 — No duplicate concurrent uploads

@Suite struct MetalGridUploadDedupTests {
    @Test func sameUIDNotUploadedTwiceConcurrently() {
        var lru = GridTextureResidencyPolicy<PhotoUID>(capacity: 10, uploadBudgetPerFrame: 10)
        let (a, b, c) = (uid("a"), uid("b"), uid("c"))
        lru.beginFrame(pinned: [])
        #expect(lru.selectUploads(wanted: [a, b]) == [a, b])     // a,b now in flight
        #expect(lru.selectUploads(wanted: [a, b, c]) == [c])     // a,b deduped → only c
        lru.completeUpload(a)
        #expect(lru.selectUploads(wanted: [a, b, c]) == [])      // a resident, b & c in flight → none
    }
}

// MARK: 5 — Per-frame upload budget

@Suite struct MetalGridUploadBudgetTests {
    @Test func perFrameUploadBudgetIsEnforced() {
        var lru = GridTextureResidencyPolicy<PhotoUID>(capacity: 100, uploadBudgetPerFrame: 3)
        let wanted = (0 ..< 10).map { uid("\($0)") }
        let chosen = lru.selectUploads(wanted: wanted)
        #expect(chosen.count == 3)                  // capped at the budget
        #expect(chosen == Array(wanted.prefix(3)))  // visible-first priority order preserved
    }
}

@Suite struct MetalGridStreamingPolicyTests {
    @Test func pinsVisibleAndOverscanForScrollReversalReuse() {
        let visible = [uid("visible-a"), uid("visible-b")]
        let overscan = [uid("above-a"), uid("below-a")]
        let window = GridTextureStreamingPolicy.window(visibleIDs: visible, overscanIDs: overscan)

        #expect(window.priority == visible + overscan)
        #expect(window.pinned == Set(visible + overscan))
    }

    @Test func deduplicatesWhilePreservingVisibleFirstOrder() {
        let a = uid("a"), b = uid("b"), c = uid("c")
        let window = GridTextureStreamingPolicy.window(visibleIDs: [a, b], overscanIDs: [b, c, a])

        #expect(window.priority == [a, b, c])
        #expect(window.pinned == [a, b, c])
    }

    @Test func macOSDefaultBudgetKeepsDenseScrollNeighborhoodResident() {
        #expect(MetalGridBudget.default.maxCachedTextures >= 4096)
        #expect(MetalGridBudget.default.maxUploadsPerFrame >= 96)
        #expect(MetalGridBudget.default.overscanFraction >= 1.0)
    }
}

@Suite struct MetalGridGlyphRasterizerTests {
    @Test func glyphRequestCacheKeyIncludesSymbolWeightSizeAndColor() {
        let white = MetalGridGlyphColor.white
        let accent = MetalGridGlyphColor(red: 0.1, green: 0.2, blue: 0.9, alpha: 1)
        let base = MetalGridGlyphRequest(symbol: "heart.fill", pixelSize: 44, weight: .bold, color: white)

        #expect(base == MetalGridGlyphRequest(symbol: "heart.fill", pixelSize: 44, weight: .bold, color: white))
        #expect(base != MetalGridGlyphRequest(symbol: "video.fill", pixelSize: 44, weight: .bold, color: white))
        #expect(base != MetalGridGlyphRequest(symbol: "heart.fill", pixelSize: 30, weight: .bold, color: white))
        #expect(base != MetalGridGlyphRequest(symbol: "heart.fill", pixelSize: 44, weight: .regular, color: white))
        #expect(base != MetalGridGlyphRequest(symbol: "heart.fill", pixelSize: 44, weight: .bold, color: accent))
    }
}

// MARK: Metal smoke — the renderer's runtime shader actually compiles

@Suite struct MetalGridRendererSmokeTests {
    /// Catches MSL compile failures (e.g. reserved-keyword collisions) that otherwise only surface as the
    /// "Metal unavailable" fallback at runtime. Skipped on hosts with no Metal device.
    @Test func rendererBuildsAndShaderCompiles() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { return }   // no GPU (CI) → skip
        #expect(MetalGridRenderer(device: device) != nil)
    }
}

// MARK: 6 — Diagnostics counters

@Suite struct MetalGridDiagnosticsTests {
    @Test func statsReflectRealVsPlaceholderCounts() {
        let drawn = [uid("a"), uid("b"), uid("c"), uid("d")]
        let resident: Set<PhotoUID> = [uid("a"), uid("c")]
        let counts = MetalGridStats.counts(visibleCount: 4, overscanCount: 0, drawnUIDs: drawn) { resident.contains($0) }
        #expect(counts.real == 2)
        #expect(counts.placeholder == 2)
    }
}
