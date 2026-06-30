import Metal
import CoreGraphics
import AppKit
import PhotosCore

/// One-`MTLTexture`-per-image GPU cache (Pixe-style, Option A) sitting on top of the pure
/// `MetalGridTextureLRU` policy. Persistent across frames; visible items are pinned and never evicted;
/// offscreen items are evicted LRU once the budget is exceeded. A neutral placeholder texture is always
/// resident so a missing thumbnail draws a stable card, never a transparent hole or black rectangle.
///
/// All texture uploads happen on the render (main) thread from already-decoded RAM images — there is no
/// disk/network decode in here (that is `ThumbnailFeed`'s job, off-main). Uploads are bounded per frame.
@MainActor
final class MetalGridTextureCache {
    private let device: MTLDevice
    private var lru: MetalGridTextureLRU
    private var textures: [PhotoUID: MTLTexture] = [:]
    private(set) var placeholderTexture: MTLTexture

    /// Rolling per-frame accounting (reset each `beginFrame`).
    private(set) var uploadsThisFrame = 0
    private(set) var uploadBytesThisFrame = 0
    private(set) var uploadMsThisFrame: Double = 0
    private(set) var evictionsThisFrame = 0
    private(set) var residentBytes = 0

    /// Max pixel side a thumbnail is uploaded at (Retina-aware crispness without wasting VRAM).
    let maxTexturePixels: Int

    init?(device: MTLDevice, budget: MetalGridBudget, maxTexturePixels: Int = 320) {
        self.device = device
        self.maxTexturePixels = maxTexturePixels
        self.lru = MetalGridTextureLRU(
            capacity: budget.maxCachedTextures,
            uploadBudgetPerFrame: budget.maxUploadsPerFrame
        )
        guard let placeholder = Self.makePlaceholder(device: device) else { return nil }
        self.placeholderTexture = placeholder
    }

    // MARK: - Per-frame lifecycle

    func beginFrame(pinned: Set<PhotoUID>) {
        lru.beginFrame(pinned: pinned)
        uploadsThisFrame = 0
        uploadBytesThisFrame = 0
        uploadMsThisFrame = 0
        evictionsThisFrame = 0
    }

    func noteUsed(_ uid: PhotoUID) { lru.noteUsed(uid) }

    func isResident(_ uid: PhotoUID) -> Bool { lru.isResident(uid) }
    func isInFlight(_ uid: PhotoUID) -> Bool { lru.isInFlight(uid) }

    /// The texture to draw for `uid` — real if resident, else the shared placeholder.
    func texture(for uid: PhotoUID) -> MTLTexture {
        textures[uid] ?? placeholderTexture
    }

    /// Upload the chosen subset of `wanted` (visible-first priority order) from the supplied RAM images.
    /// Honours the per-frame budget + in-flight dedup via the LRU policy: `provideImage` is only called
    /// for the UIDs actually selected this frame, and never for an already-resident/in-flight UID.
    func uploadVisible(wanted: [PhotoUID], provideImage: (PhotoUID) -> CGImage?) {
        let chosen = lru.selectUploads(wanted: wanted)
        for uid in chosen {
            guard let image = provideImage(uid) else {
                lru.abandonUpload(uid)   // image vanished between selection and upload — retry later
                continue
            }
            let start = CFAbsoluteTimeGetCurrent()
            guard let texture = makeTexture(from: image) else {
                lru.abandonUpload(uid)
                continue
            }
            uploadMsThisFrame += (CFAbsoluteTimeGetCurrent() - start) * 1000
            let bytes = texture.width * texture.height * 4
            textures[uid] = texture
            residentBytes += bytes
            uploadBytesThisFrame += bytes
            uploadsThisFrame += 1
            lru.completeUpload(uid)
        }
    }

    /// Evict offscreen LRU textures down to the budget and release their GPU memory.
    func evictToBudget() {
        let evicted = lru.evictToBudget()
        for uid in evicted {
            if let tex = textures.removeValue(forKey: uid) {
                residentBytes -= tex.width * tex.height * 4
            }
        }
        evictionsThisFrame = evicted.count
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

    private var glyphs: [String: MTLTexture] = [:]

    /// A cached, tinted SF-Symbol texture for a badge glyph (favorite/checked/video). Resident for the
    /// session (a handful of small textures), so badge rendering is a cheap textured quad.
    func glyphTexture(symbol: String, pixelSize: Int = 44, weight: NSFont.Weight = .bold, color: NSColor) -> MTLTexture? {
        let rgba = color.usingColorSpace(.sRGB) ?? color
        let key = "\(symbol)|\(pixelSize)|\(weight.rawValue)|\(rgba.redComponent),\(rgba.greenComponent),\(rgba.blueComponent),\(rgba.alphaComponent)"
        if let cached = glyphs[key] { return cached }
        guard let cg = Self.renderGlyph(symbol: symbol, pixelSize: pixelSize, weight: weight, color: color),
              let texture = makeTexture(from: cg) else { return nil }
        glyphs[key] = texture
        return texture
    }

    /// Renders a tinted SF Symbol centered into a transparent `pixelSize`² bitmap (template + sourceAtop
    /// tint), returned via `nsImage.cgImage(...)` so it matches the orientation convention of thumbnails.
    private static func renderGlyph(symbol: String, pixelSize: Int, weight: NSFont.Weight, color: NSColor) -> CGImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: CGFloat(pixelSize) * 0.72, weight: weight)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        let canvas = NSImage(size: NSSize(width: pixelSize, height: pixelSize))
        canvas.lockFocus()
        let s = base.size
        let rect = NSRect(x: (CGFloat(pixelSize) - s.width) / 2, y: (CGFloat(pixelSize) - s.height) / 2, width: s.width, height: s.height)
        base.draw(in: rect)
        color.set()
        NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize).fill(using: .sourceAtop)
        canvas.unlockFocus()
        return canvas.cgImage(forProposedRect: nil, context: nil, hints: nil)
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
