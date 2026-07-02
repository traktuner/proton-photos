import Testing
import Foundation
import CoreGraphics
import Metal
import MetalRenderingCore
import MetalGridTextureCore
import MetalGridTextureAppKitAdapter
import MetalGridTextureUIKitAdapter
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
        var lru = GridTextureResidencyPolicy<PhotoUID>(capacity: 2, costCapacity: .max, uploadBudgetPerFrame: 10)
        let (a, b, c) = (uid("a"), uid("b"), uid("c"))
        // Make a the OLDEST, then b, then c (one per frame).
        for u in [a, b, c] {
            lru.beginFrame(pinned: [])
            _ = lru.selectUploads(wanted: [u])
            lru.completeUpload(u, cost: 1)
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
        var lru = GridTextureResidencyPolicy<PhotoUID>(capacity: 10, costCapacity: .max, uploadBudgetPerFrame: 10)
        let a = uid("a")
        #expect(lru.drawState(a) == .placeholder)   // never a hole — always a placeholder
        lru.beginFrame(pinned: [])
        _ = lru.selectUploads(wanted: [a])
        lru.completeUpload(a, cost: 1)
        #expect(lru.drawState(a) == .real)
    }
}

// MARK: 4 — No duplicate concurrent uploads

@Suite struct MetalGridUploadDedupTests {
    @Test func sameUIDNotUploadedTwiceConcurrently() {
        var lru = GridTextureResidencyPolicy<PhotoUID>(capacity: 10, costCapacity: .max, uploadBudgetPerFrame: 10)
        let (a, b, c) = (uid("a"), uid("b"), uid("c"))
        lru.beginFrame(pinned: [])
        #expect(lru.selectUploads(wanted: [a, b]) == [a, b])     // a,b now in flight
        #expect(lru.selectUploads(wanted: [a, b, c]) == [c])     // a,b deduped → only c
        lru.completeUpload(a, cost: 1)
        #expect(lru.selectUploads(wanted: [a, b, c]) == [])      // a resident, b & c in flight → none
    }
}

// MARK: 5 — Per-frame upload budget

@Suite struct MetalGridUploadBudgetTests {
    @Test func perFrameUploadBudgetIsEnforced() {
        var lru = GridTextureResidencyPolicy<PhotoUID>(capacity: 100, costCapacity: .max, uploadBudgetPerFrame: 3)
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
        let window = GridTextureStreamingPolicy.window(visibleIDs: visible, overscanIDs: overscan, maxPinned: 100)

        #expect(window.priority == visible + overscan)
        #expect(window.pinned == Set(visible + overscan))
    }

    @Test func deduplicatesWhilePreservingVisibleFirstOrder() {
        let a = uid("a"), b = uid("b"), c = uid("c")
        let window = GridTextureStreamingPolicy.window(visibleIDs: [a, b], overscanIDs: [b, c, a], maxPinned: 100)

        #expect(window.priority == [a, b, c])
        #expect(window.pinned == [a, b, c])
    }

    @Test func macOSDefaultBudgetKeepsDenseScrollNeighborhoodResidentButByteBounded() {
        let budget = MetalGridBudget.default
        // Scroll-reversal reuse still wants a deep count cache + generous overscan…
        #expect(budget.maxCachedTextures >= 2048)
        #expect(budget.overscanFraction >= 1.0)
        // …but residency must be byte-bounded well below the ~1.15 GB the count-only budget reached,
        // while keeping several visible+overscan bands resident (≥ 256 MiB).
        #expect(budget.maxResidentBytes >= 256 * 1_048_576)
        #expect(budget.maxResidentBytes <= 768 * 1_048_576)
        // Per-frame upload copy work must fit a 60 Hz frame (measured ~0.6 ms per 400 KiB upload).
        #expect(budget.maxUploadBytesPerFrame <= 8 * 1_048_576)
        #expect(budget.maxUploadsPerFrame >= 16)
    }

    @Test func iOSTierBudgetsStayMoreConservativeThanMacOS() {
        let macBudget = MetalGridBudget.default
        for policy in [UIKitMetalGridTexturePolicies.compact,
                       UIKitMetalGridTexturePolicies.regular,
                       UIKitMetalGridTexturePolicies.expanded] {
            #expect(policy.budget.maxResidentBytes < macBudget.maxResidentBytes / 2)
            #expect(policy.budget.maxUploadBytesPerFrame < macBudget.maxUploadBytesPerFrame)
            #expect(policy.budget.maxUploadsPerFrame < macBudget.maxUploadsPerFrame)
            #expect(policy.budget.maxCachedTextures < macBudget.maxCachedTextures)
            #expect(policy.maxTexturePixels < 320)
        }
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

// MARK: 5b — Cache-level byte budgets (real Metal textures; skipped on hosts with no GPU)

@Suite @MainActor struct MetalGridTextureCacheByteBudgetTests {
    /// A decoded-image stand-in: a solid 64×64 CGImage → 64·64·4 = 16,384 texture bytes.
    private static func makeImage(side: Int = 64) -> CGImage? {
        let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx?.makeImage()
    }

    private static func makeCache(budget: GridTextureBudget) -> MetalGridTextureCache<PhotoUID>? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }   // no GPU (CI) → skip
        return MetalGridTextureCache(
            device: device, budget: budget, maxTexturePixels: 64,
            glyphRasterizer: AppKitMetalGridGlyphRasterizer()
        )
    }

    @Test func perFrameUploadByteBudgetDefersRemainderAccurately() throws {
        guard let cache = Self.makeCache(budget: GridTextureBudget(
            maxUploadsPerFrame: 10, maxUploadBytesPerFrame: 32_768,       // room for exactly two 16 KiB textures
            maxCachedTextures: 100, maxResidentBytes: 1_048_576, overscanFraction: 1.0
        )), let image = Self.makeImage() else { return }

        let wanted = (0 ..< 5).map { uid("\($0)") }
        cache.beginFrame(pinned: Set(wanted))
        cache.uploadVisible(wanted: wanted) { _ in image }

        #expect(cache.uploadsThisFrame == 2)
        #expect(cache.uploadBytesThisFrame == 32_768)
        #expect(cache.deferredUploadsThisFrame == 3)                      // byte-deferred, retried next frame
        #expect(!cache.residencySaturatedThisFrame)                       // transient, not a residency refusal

        // Next frame the deferred items are selected and uploaded — deferral is not permanent.
        cache.beginFrame(pinned: Set(wanted))
        cache.uploadVisible(wanted: wanted.filter { !cache.isResident($0) }) { _ in image }
        #expect(cache.uploadsThisFrame == 2)
        #expect(cache.residentCount == 4)
    }

    @Test func residentByteBudgetRefusesUploadsInsteadOfOverflowing() throws {
        guard let cache = Self.makeCache(budget: GridTextureBudget(
            maxUploadsPerFrame: 10, maxUploadBytesPerFrame: 1_048_576,
            maxCachedTextures: 100, maxResidentBytes: 40_960,             // 2.5 × 16 KiB textures
            overscanFraction: 1.0
        )), let image = Self.makeImage() else { return }

        let wanted = (0 ..< 4).map { uid("\($0)") }
        cache.beginFrame(pinned: Set(wanted))
        cache.uploadVisible(wanted: wanted) { _ in image }
        cache.evictToBudget()

        // Visible-first prefix uploads; the rest is refused BEFORE any texture is created.
        #expect(cache.uploadsThisFrame == 2)
        #expect(cache.residentBytes == 32_768)
        #expect(cache.residentBytes <= cache.residentByteBudget)
        #expect(cache.residencySaturatedThisFrame)
        #expect(cache.deferredUploadsThisFrame == 2)
        #expect(!cache.byteBudgetOverflow)
        #expect(cache.isResident(uid("0")) && cache.isResident(uid("1")))
    }

    @Test func maxSafePinnedCountDerivesFromByteBudgetAndWorstCaseTexture() throws {
        guard let cache = Self.makeCache(budget: GridTextureBudget(
            maxUploadsPerFrame: 10, maxUploadBytesPerFrame: 1_048_576,
            maxCachedTextures: 100, maxResidentBytes: 163_840,            // 10 worst-case 64px textures
            overscanFraction: 1.0
        )) else { return }

        #expect(cache.maxSafePinnedCount == 10)                           // 163,840 / (64·64·4)
    }

    @Test func scrolledAwayTexturesEvictSoNewWindowStaysWithinByteBudget() throws {
        guard let cache = Self.makeCache(budget: GridTextureBudget(
            maxUploadsPerFrame: 10, maxUploadBytesPerFrame: 1_048_576,
            maxCachedTextures: 100, maxResidentBytes: 49_152,             // three 16 KiB textures
            overscanFraction: 1.0
        )), let image = Self.makeImage() else { return }

        let first = (0 ..< 3).map { uid("first-\($0)") }
        cache.beginFrame(pinned: Set(first))
        cache.uploadVisible(wanted: first) { _ in image }
        cache.evictToBudget()
        #expect(cache.residentCount == 3)

        // Scroll on: a new window pins new items; the old ones become evictable and the budget holds.
        let second = (0 ..< 3).map { uid("second-\($0)") }
        cache.beginFrame(pinned: Set(second))
        cache.uploadVisible(wanted: second) { _ in image }
        cache.evictToBudget()

        #expect(second.allSatisfy { cache.isResident($0) })
        #expect(cache.residentBytes <= cache.residentByteBudget)
        #expect(!cache.byteBudgetOverflow)
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
