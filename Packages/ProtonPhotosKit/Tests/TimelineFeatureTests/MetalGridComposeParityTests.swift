import Testing
import CoreGraphics
import Metal
import GridCore
import MetalRenderingCore
import MetalGridTextureCore
import MetalGridTextureAppKitAdapter
import MetalGridComposeCore
import PhotosCore

/// Contract for the universal `MetalGridFrameComposer` that macOS (`MetalGridCoordinator`) and iOS
/// (`UIKitTimelineGridHost`) both delegate to. Locks the settled-frame sequence that was previously
/// duplicated per host: visible/overscan classification, viewport draw filtering, the streaming window +
/// pin + upload + warm selection, and the resident/placeholder + decoration render-group assembly.
@Suite @MainActor struct MetalGridComposeParityTests {
    private func uid(_ s: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: s) }

    private func slot(_ index: Int, y: CGFloat, side: CGFloat = 100) -> GridRenderSlot {
        GridRenderSlot(index: index, column: 0, row: index, rect: CGRect(x: 0, y: y, width: side, height: side))
    }

    private func makeImage(side: Int = 64) -> CGImage? {
        let ctx = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        ctx?.setFillColor(CGColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1))
        ctx?.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return ctx?.makeImage()
    }

    private func makeCache() -> MetalGridTextureCache<PhotoUID>? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }   // no GPU (CI) → skip
        return MetalGridTextureCache(
            device: device,
            budget: GridTextureBudget(
                maxUploadsPerFrame: 64, maxUploadBytesPerFrame: 64_000_000,
                maxCachedTextures: 4096, maxResidentBytes: 256_000_000, overscanFraction: 1.0
            ),
            maxTexturePixels: 64,
            glyphRasterizer: AppKitMetalGridGlyphRasterizer()
        )
    }

    // MARK: - Visible / overscan classification (pure, no GPU)

    @Test func classifyVisibilitySplitsVisibleAndOverscanInSourceOrder() {
        let flat = [uid("0"), uid("1"), uid("2"), uid("3")]
        let slots = [
            slot(0, y: -220),   // fully above the 480-tall viewport → overscan
            slot(1, y: 20),     // inside → visible
            slot(2, y: 300),    // inside → visible
            slot(3, y: 520),    // fully below → overscan
        ]
        let out = MetalGridFrameComposer.classifyVisibility(
            slots: slots, flatUIDs: flat, viewportSize: CGSize(width: 320, height: 480))
        #expect(out.visible == [uid("1"), uid("2")])
        #expect(out.overscan == [uid("0"), uid("3")])
    }

    @Test func classifyVisibilityIgnoresOutOfRangeSlotIndices() {
        let flat = [uid("0")]
        let slots = [slot(0, y: 10), slot(5, y: 10)]   // index 5 has no UID
        let out = MetalGridFrameComposer.classifyVisibility(
            slots: slots, flatUIDs: flat, viewportSize: CGSize(width: 320, height: 480))
        #expect(out.visible == [uid("0")])
        #expect(out.overscan.isEmpty)
    }

    @Test func viewportDrawSlotsKeepsOnlyViewportIntersectingSlots() {
        let slots = [slot(0, y: -220), slot(1, y: 20), slot(2, y: 520)]
        let drawn = MetalGridFrameComposer.viewportDrawSlots(slots, viewportSize: CGSize(width: 320, height: 480))
        #expect(drawn.map(\.index) == [1])
    }

    // MARK: - Streaming window / upload / warm selection parity (GPU-backed)

    @Test func streamUploadsRamReadyVisibleTilesAndWarmsMissingRetryable() {
        guard let cache = makeCache(), let image = makeImage() else { return }
        let a = uid("a"), b = uid("b"), c = uid("c")
        // a,b are RAM-ready; c is missing but retryable → c must be warmed, not uploaded.
        let ram: [PhotoUID: CGImage] = [a: image, b: image]
        let result = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: [a, b, c], overscanIDs: [],
            pinOverscan: true, effectiveUploadPixels: 64, allowUpgrade: false,
            hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] }
        )
        #expect(cache.isResident(a))
        #expect(cache.isResident(b))
        #expect(!cache.isResident(c))
        #expect(result.warm == [c])
        #expect(!result.pendingVisibleQualityUpgrade)
        #expect(cache.pinnedCount == 3)   // window pinned all three visible under the ample budget
        #expect(cache.effectiveMaxTexturePixels == 64)
    }

    // MARK: - Soft→sharp upgrade parity (the iOS regression: it must NOT keep low-res textures after a zoom)

    @Test func streamUpgradesUndersizedResidentOnlyWhenAllowUpgrade() {
        guard let cache = makeCache(), let image = makeImage(side: 64) else { return }
        let a = uid("a")
        let ram: [PhotoUID: CGImage] = [a: image]
        func run(effective: Int, allowUpgrade: Bool) -> MetalGridFrameComposer.StreamResult<PhotoUID> {
            MetalGridFrameComposer.stream(
                cache: cache, visibleIDs: [a], overscanIDs: [],
                pinOverscan: true, effectiveUploadPixels: effective, allowUpgrade: allowUpgrade,
                hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] })
        }

        // Dense level: uploaded small.
        _ = run(effective: 32, allowUpgrade: false)
        #expect(cache.texture(for: a).width == 32)

        // Zoom to a larger layout but STILL interacting (allowUpgrade:false) → no upgrade, no churn.
        let interacting = run(effective: 64, allowUpgrade: false)
        #expect(cache.texture(for: a).width == 32)
        #expect(cache.upgradesThisFrame == 0)
        #expect(!interacting.pendingVisibleQualityUpgrade)

        // Settled (allowUpgrade:true) with the RAM source present → sharpen IN PLACE to the larger cap.
        _ = run(effective: 64, allowUpgrade: true)
        #expect(cache.texture(for: a).width == 64)
        #expect(cache.upgradesThisFrame == 1)
        #expect(cache.residentCount == 1)   // upgraded in place, no extra resident
    }

    @Test func streamRequestsWarmAndSignalsPendingWhenUpgradeSourceEvicted() {
        guard let cache = makeCache(), let image = makeImage(side: 64) else { return }
        let a = uid("a")

        // Upload small with the source present.
        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: [a], overscanIDs: [],
            pinOverscan: true, effectiveUploadPixels: 32, allowUpgrade: false,
            hasImage: { _ in true }, canRetry: { _ in true }, provideImage: { _ in image })
        #expect(cache.texture(for: a).width == 32)

        // Settled at a larger cap but the RAM source was EVICTED (hasImage:false): the composer cannot upgrade in
        // place, so it must request the source in `warm` and signal a pending upgrade - the host then re-warms and
        // keeps ticking until it sharpens, never a permanent low-res and never a silent forever-spin.
        let settled = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: [a], overscanIDs: [],
            pinOverscan: true, effectiveUploadPixels: 64, allowUpgrade: true,
            hasImage: { _ in false }, canRetry: { _ in true }, provideImage: { _ in nil })
        #expect(cache.texture(for: a).width == 32)          // old soft texture still on screen (no placeholder gap)
        #expect(settled.warm.contains(a))                   // source requested for re-decode
        #expect(settled.pendingVisibleQualityUpgrade)       // host keeps ticking until it sharpens
    }

    @Test func streamPinOverscanFalseClampsPinnedToVisibleCount() {
        guard let cache = makeCache() else { return }
        let vis = [uid("v0"), uid("v1")]
        let over = [uid("o0"), uid("o1"), uid("o2")]
        // Nothing is RAM-ready, so nothing uploads; assert only the pin-window shape.
        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: vis, overscanIDs: over,
            pinOverscan: false, effectiveUploadPixels: 64, allowUpgrade: false,
            hasImage: { _ in false }, canRetry: { _ in true }, provideImage: { _ in nil }
        )
        // pinOverscan:false ⇒ pinned clamps to the visible count (2), never the overscan band.
        #expect(cache.pinnedCount == 2)
    }

    @Test func streamDoesNotUploadOrWarmOverscanWhileVisibleTilesAreMissing() {
        guard let cache = makeCache(), let image = makeImage() else { return }
        let visible = [uid("v0"), uid("v1")]
        let overscan = [uid("o0"), uid("o1")]
        let ram: [PhotoUID: CGImage] = Dictionary(uniqueKeysWithValues: overscan.map { ($0, image) })

        let result = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: visible, overscanIDs: overscan,
            pinOverscan: false, effectiveUploadPixels: 64, allowUpgrade: false,
            hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] }
        )

        #expect(result.warm == visible)
        #expect(!cache.isResident(overscan[0]))
        #expect(!cache.isResident(overscan[1]))
        #expect(cache.uploadsThisFrame == 0)
    }

    @Test func streamUploadsOverscanAfterVisibleTilesAreResident() {
        guard let cache = makeCache(), let image = makeImage() else { return }
        let visible = [uid("v0"), uid("v1")]
        let overscan = [uid("o0"), uid("o1")]
        let ram: [PhotoUID: CGImage] = Dictionary(uniqueKeysWithValues: (visible + overscan).map { ($0, image) })

        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: visible, overscanIDs: overscan,
            pinOverscan: false, effectiveUploadPixels: 64, allowUpgrade: false,
            hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] }
        )
        #expect(visible.allSatisfy { cache.isResident($0) })

        _ = MetalGridFrameComposer.stream(
            cache: cache, visibleIDs: visible, overscanIDs: overscan,
            pinOverscan: true, effectiveUploadPixels: 64, allowUpgrade: false,
            hasImage: { ram[$0] != nil }, canRetry: { _ in true }, provideImage: { ram[$0] }
        )

        #expect(overscan.allSatisfy { cache.isResident($0) })
    }

    // MARK: - Render-group assembly parity (GPU-backed)

    @Test func buildGroupsEmitsImageGroupThenDecorationGroupsInFixedOrder() {
        guard let cache = makeCache(), let image = makeImage() else { return }
        let a = uid("a"), b = uid("b"), c = uid("c")
        let flat = [a, b, c]
        cache.beginFrame(pinned: Set(flat))
        cache.uploadVisible(wanted: flat) { _ in image }
        #expect(cache.isResident(a) && cache.isResident(b) && cache.isResident(c))

        let slots = [slot(0, y: 0), slot(1, y: 100), slot(2, y: 200)]
        let accent = SIMD4<Float>(0, 0, 1, 1)
        let decorations = MetalGridDecorations<PhotoUID>(
            accent: accent, accentGlyphColor: .white, selectionMode: false,
            selected: [a], favorites: [b], isVideo: { $0 == c }
        )
        let out = MetalGridFrameComposer.buildGroups(
            slots: slots, flatUIDs: flat, cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: decorations
        )

        #expect(out.realCount == 3)
        // Group 0 is always the (possibly empty) image group: one textured quad per resident tile.
        guard case .perQuadTexture(let textures) = out.groups[0].source else {
            Issue.record("group 0 must be the per-quad image group"); return
        }
        #expect(textures.count == 3)
        #expect(out.groups[0].quads.count == 3)
        // Quad geometry parity: image quad matches the fitter's own contentRect/UV for a square tile.
        let expectedFit = TileContentFitter.fit(
            slotRect: slots[0].rect, mediaPixelSize: CGSize(width: 64, height: 64), displayMode: .squareFillCrop)
        #expect(out.groups[0].quads[0].rect == expectedFit.contentRect)
        #expect(out.groups[0].quads[0].uvMin == expectedFit.uvMin)
        #expect(out.groups[0].quads[0].uvMax == expectedFit.uvMax)
        #expect(out.groups[0].quads[0].mode == .textured)

        // Group 1 is the selection outline (a is selected): shared placeholder texture, border mode, accent.
        #expect(out.groups[1].quads.count == 1)
        #expect(out.groups[1].quads[0].mode == .border)
        #expect(out.groups[1].quads[0].rect == slots[0].rect)
        #expect(out.groups[1].quads[0].color == accent)

        // Then the video badge (c, since selectionMode is off) and the favorite heart (b) - in that order.
        let modes = out.groups.map { group -> String in
            if case .perQuadTexture = group.source { return "image" }
            if group.quads.first?.mode == .border { return "outline" }
            return "badge"
        }
        #expect(modes == ["image", "outline", "badge", "badge"])
    }

    @Test func buildGroupsWithoutDecorationsEmitsOnlyTheImageGroup() {
        guard let cache = makeCache(), let image = makeImage() else { return }
        let a = uid("a")
        cache.beginFrame(pinned: [a])
        cache.uploadVisible(wanted: [a]) { _ in image }

        let out = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0)], flatUIDs: [a], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil
        )
        #expect(out.groups.count == 1)
        #expect(out.realCount == 1)
    }

    // MARK: - Slot-size-derived corner radius (shared GridCornerRadiusPolicy through the composer)

    @Test func buildGroupsGivesDenseTinySlotsSharpCornersAndLargeSlotsTheFullRadius() {
        guard let cache = makeCache(), let image = makeImage() else { return }
        let a = uid("a"), b = uid("b")
        cache.beginFrame(pinned: [a, b])
        cache.uploadVisible(wanted: [a, b]) { _ in image }

        // Dense tiny square slot (48 pt) → radius 0: sharp 90° corners on the image quad AND its decorations.
        let dense = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0, side: 48)], flatUIDs: [a], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11,
            decorations: MetalGridDecorations<PhotoUID>(
                accent: SIMD4<Float>(0, 0, 1, 1), accentGlyphColor: .white, selectionMode: false,
                selected: [a], favorites: [], isVideo: { _ in false }
            )
        )
        #expect(dense.groups[0].quads[0].radius == 0)
        #expect(dense.groups[1].quads[0].mode == .border)
        #expect(dense.groups[1].quads[0].radius == 0)   // selection outline follows the same policy

        // Large settled slot (200 pt) → the untouched polished base radius.
        let large = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0, side: 200)], flatUIDs: [b], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil
        )
        #expect(large.groups[0].quads[0].radius == 11)

        // Medium slot (96 pt) → reduced radius, strictly between sharp and base.
        let medium = MetalGridFrameComposer.buildGroups(
            slots: [slot(0, y: 0, side: 96)], flatUIDs: [b], cache: cache,
            displayMode: .squareFillCrop, cornerRadius: 11, decorations: nil
        )
        #expect(medium.groups[0].quads[0].radius > 0)
        #expect(medium.groups[0].quads[0].radius < 11)
    }
}
