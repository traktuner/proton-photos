import Testing
import CoreGraphics
import Metal
import GridCore
import MetalGridTextureCore
import MetalGridTextureAppKitAdapter
import PhotosCore

/// Governor-driven GPU residency pressure: `setResidencyPressureScale` must shed OFFSCREEN residency down
/// to the scaled ceiling immediately, never evict the visible pinned set (the grid stays drawable), and
/// restore the full ceiling when the scale returns to 1.0. This is the exact hook the iOS grid host and the
/// macOS coordinator both register with the shared `MemoryPressureGovernor`.
@Suite @MainActor struct MetalGridTexturePressureTests {
    private func uid(_ s: String) -> PhotoUID { PhotoUID(volumeID: "v", nodeID: s) }

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

    @Test func pressureScaleShedsOffscreenResidencyButNeverTheVisiblePinnedSet() {
        guard let cache = makeCache(), let image = makeImage() else { return }
        let visible = [uid("vis-0"), uid("vis-1")]
        let offscreen = (0 ..< 6).map { uid("off-\($0)") }

        // Frame 1: everything resident (pinned so admission is unconditional).
        cache.beginFrame(pinned: Set(visible + offscreen))
        cache.uploadVisible(wanted: visible + offscreen) { _ in image }
        #expect((visible + offscreen).allSatisfy { cache.isResident($0) })

        // Frame 2: only the viewport set stays pinned; the rest is offscreen residency.
        cache.beginFrame(pinned: Set(visible))

        // Critical tier (scale 0): keep ONLY what is currently essential - the visible pinned set.
        cache.setResidencyPressureScale(0.0)
        #expect(visible.allSatisfy { cache.isResident($0) })
        #expect(offscreen.allSatisfy { !cache.isResident($0) })

        // Recovery: full ceiling restored → future frames may re-admit offscreen residency again.
        cache.setResidencyPressureScale(1.0)
        cache.beginFrame(pinned: Set(visible + offscreen))
        cache.uploadVisible(wanted: offscreen) { _ in image }
        #expect(offscreen.allSatisfy { cache.isResident($0) })
    }

    @Test func reducedPressureScaleKeepsResidencyWithinTheScaledByteCeiling() {
        // Small byte ceiling (≈10 × 16 KiB textures) so the 0.5 scale genuinely forces evictions.
        guard let device = MTLCreateSystemDefaultDevice(), let image = makeImage(),
              let cache = MetalGridTextureCache<PhotoUID>(
                  device: device,
                  budget: GridTextureBudget(
                      maxUploadsPerFrame: 64, maxUploadBytesPerFrame: 64_000_000,
                      maxCachedTextures: 4096, maxResidentBytes: 10 * 16_384, overscanFraction: 1.0
                  ),
                  maxTexturePixels: 64,
                  glyphRasterizer: AppKitMetalGridGlyphRasterizer()
              )
        else { return }
        let pinned = [uid("pin-0")]
        let offscreen = (0 ..< 9).map { uid("half-\($0)") }
        cache.beginFrame(pinned: Set(pinned + offscreen))   // pinned admission → everything resident
        cache.uploadVisible(wanted: pinned + offscreen) { _ in image }
        cache.beginFrame(pinned: Set(pinned))               // now only one tile is truly visible
        let fullResident = cache.residentBytes
        #expect(fullResident > cache.residentByteBudget / 2)   // precondition: the 0.5 ceiling must bite

        cache.setResidencyPressureScale(0.5)
        #expect(cache.residentBytes <= Int(Double(cache.residentByteBudget) * 0.5))
        #expect(cache.residentBytes < fullResident)
        #expect(pinned.allSatisfy { cache.isResident($0) })    // visible pinned survives the shed
    }
}
