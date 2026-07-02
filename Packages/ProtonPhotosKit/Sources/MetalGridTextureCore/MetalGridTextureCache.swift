import Metal
import CoreGraphics
import GridCore

/// One-`MTLTexture`-per-image GPU cache (Pixe-style, Option A) sitting on top of the pure
/// `GridTextureResidencyPolicy`. Persistent across frames; visible items are pinned and never evicted;
/// offscreen items are evicted LRU once the budget is exceeded. A neutral placeholder texture is always
/// resident so a missing thumbnail draws a stable card, never a transparent hole or black rectangle.
///
/// All texture uploads happen on the render (main) thread from already-decoded RAM images. Disk/network decode
/// belongs to the caller's feed layer, off-main. Uploads are bounded per frame.
@MainActor
package final class MetalGridTextureCache<ID: Hashable & Sendable> {
    private let device: MTLDevice
    private let glyphRasterizer: any MetalGridGlyphRasterizing
    private var lru: GridTextureResidencyPolicy<ID>
    private var textures: [ID: MTLTexture] = [:]
    package private(set) var placeholderTexture: MTLTexture

    /// Rolling per-frame accounting (reset each `beginFrame`).
    package private(set) var uploadsThisFrame = 0
    package private(set) var uploadBytesThisFrame = 0
    package private(set) var uploadMsThisFrame: Double = 0
    package private(set) var evictionsThisFrame = 0
    package private(set) var evictMsThisFrame: Double = 0
    package private(set) var residentBytes = 0
    package private(set) var deferredUploadsThisFrame = 0

    /// Max pixel side a thumbnail is uploaded at (Retina-aware crispness without wasting VRAM).
    package let maxTexturePixels: Int

    package var residentCount: Int { lru.residentCount }
    package var pinnedCount: Int { lru.pinnedCount }
    package var inFlightCount: Int { lru.inFlightCount }
    package var residencyCapacity: Int { lru.capacity }
    package var pinnedOverflow: Bool { lru.pinnedCount > lru.capacity }

    package init?(
        device: MTLDevice,
        budget: GridTextureBudget,
        maxTexturePixels: Int = 320,
        glyphRasterizer: any MetalGridGlyphRasterizing
    ) {
        self.device = device
        self.glyphRasterizer = glyphRasterizer
        self.maxTexturePixels = maxTexturePixels
        self.lru = GridTextureResidencyPolicy(
            capacity: budget.maxCachedTextures,
            uploadBudgetPerFrame: budget.maxUploadsPerFrame
        )
        guard let placeholder = Self.makePlaceholder(device: device) else { return nil }
        self.placeholderTexture = placeholder
    }

    // MARK: - Per-frame lifecycle

    package func beginFrame(pinned: Set<ID>) {
        lru.beginFrame(pinned: pinned)
        uploadsThisFrame = 0
        uploadBytesThisFrame = 0
        uploadMsThisFrame = 0
        evictionsThisFrame = 0
        evictMsThisFrame = 0
        deferredUploadsThisFrame = 0
    }

    package func noteUsed(_ id: ID) { lru.noteUsed(id) }

    package func isResident(_ id: ID) -> Bool { lru.isResident(id) }
    package func isInFlight(_ id: ID) -> Bool { lru.isInFlight(id) }

    /// The texture to draw for `id` — real if resident, else the shared placeholder.
    package func texture(for id: ID) -> MTLTexture {
        textures[id] ?? placeholderTexture
    }

    /// Upload the chosen subset of `wanted` (visible-first priority order) from the supplied RAM images.
    /// Honours the per-frame budget + in-flight dedup via the LRU policy: `provideImage` is only called
    /// for the IDs actually selected this frame, and never for an already-resident/in-flight ID.
    package func uploadVisible(wanted: [ID], provideImage: (ID) -> CGImage?) {
        let chosen = lru.selectUploads(wanted: wanted)
        deferredUploadsThisFrame = max(0, wanted.count - chosen.count)
        for id in chosen {
            guard let image = provideImage(id) else {
                lru.abandonUpload(id)   // image vanished between selection and upload — retry later
                continue
            }
            let start = CFAbsoluteTimeGetCurrent()
            guard let texture = makeTexture(from: image) else {
                lru.abandonUpload(id)
                continue
            }
            uploadMsThisFrame += (CFAbsoluteTimeGetCurrent() - start) * 1000
            let bytes = texture.width * texture.height * 4
            textures[id] = texture
            residentBytes += bytes
            uploadBytesThisFrame += bytes
            uploadsThisFrame += 1
            lru.completeUpload(id)
        }
    }

    /// Evict offscreen LRU textures down to the budget and release their GPU memory.
    package func evictToBudget() {
        let start = CFAbsoluteTimeGetCurrent()
        let evicted = lru.evictToBudget()
        for id in evicted {
            if let tex = textures.removeValue(forKey: id) {
                residentBytes -= tex.width * tex.height * 4
            }
        }
        evictionsThisFrame = evicted.count
        evictMsThisFrame += (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    // MARK: - Texture creation

    /// Builds an upright RGBA8 texture from a decoded image, downsampled to `maxTexturePixels`. A decoded
    /// CGImage is already row-0-top, and `CGContext.draw` preserves that into the bitmap buffer, so texel
    /// row 0 is the visual TOP — no context flip — and the renderer samples with straightforward UVs
    /// (uv.y 0 = top), keeping thumbnails upright. (Synthetic tiles are generated `flipped: true` to match
    /// this row-0-top convention.)
    private func makeTexture(from image: CGImage) -> MTLTexture? {
        let srcW = max(image.width, 1), srcH = max(image.height, 1)
        let longest = max(srcW, srcH)
        let scale = longest > maxTexturePixels ? CGFloat(maxTexturePixels) / CGFloat(longest) : 1
        let w = max(1, Int((CGFloat(srcW) * scale).rounded()))
        let h = max(1, Int((CGFloat(srcH) * scale).rounded()))
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let ctx = CGContext(
            data: &pixels, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        // Interpolation quality only matters when actually downsampling (a 1:1 draw ignores it).
        // `.medium` (bilinear) is materially cheaper on the render thread than `.high` (Lanczos) and
        // visually indistinguishable for grid thumbnails at these sizes; the full-res viewer decode
        // is a separate path that keeps high quality.
        ctx.interpolationQuality = scale < 1 ? .medium : .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: pixels, bytesPerRow: bytesPerRow)
        return texture
    }

    // MARK: - Glyph textures (badges) — resident, not LRU-managed

    private var glyphs: [MetalGridGlyphRequest: MTLTexture] = [:]

    /// A cached, tinted SF-Symbol texture for a badge glyph (favorite/checked/video). Resident for the
    /// session (a handful of small textures), so badge rendering is a cheap textured quad.
    package func glyphTexture(
        symbol: String,
        pixelSize: Int = 44,
        weight: MetalGridGlyphWeight = .bold,
        color: MetalGridGlyphColor
    ) -> MTLTexture? {
        let request = MetalGridGlyphRequest(symbol: symbol, pixelSize: pixelSize, weight: weight, color: color)
        if let cached = glyphs[request] { return cached }
        guard let cg = glyphRasterizer.image(for: request),
              let texture = makeTexture(from: cg) else { return nil }
        glyphs[request] = texture
        return texture
    }

    /// A small neutral warm-gray texture used as the resting placeholder + letterbox background.
    private static func makePlaceholder(device: MTLDevice) -> MTLTexture? {
        let side = 8
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 40; pixels[i + 1] = 38; pixels[i + 2] = 36; pixels[i + 3] = 255   // warm dark gray
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: side, height: side, mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0, withBytes: pixels, bytesPerRow: side * 4)
        return texture
    }
}
