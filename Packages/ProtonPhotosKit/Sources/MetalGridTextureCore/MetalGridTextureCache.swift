import Metal
import CoreGraphics
import GridCore

/// One-`MTLTexture`-per-image GPU cache (Pixe-style, Option A) sitting on top of the pure
/// `GridTextureResidencyPolicy`. Persistent across frames; visible items are pinned and never evicted;
/// offscreen items are evicted LRU once the budget is exceeded. A neutral placeholder texture is always
/// resident so a missing thumbnail draws a stable card, never a transparent hole or black rectangle.
///
/// All texture uploads happen on the render (main) thread from already-decoded RAM images. Disk/network decode
/// belongs to the caller's feed layer, off-main. Uploads are bounded per frame by count AND bytes, and
/// residency is bounded by count AND bytes: the generic policy owns the bookkeeping, this cache supplies
/// the real texture byte cost (the policy cannot know Metal texture sizes) and refuses to create a texture
/// that could not stay resident within budget.
@MainActor
package final class MetalGridTextureCache<ID: Hashable & Sendable> {
    private let device: MTLDevice
    private let glyphRasterizer: any MetalGridGlyphRasterizing
    private let budget: GridTextureBudget
    private var lru: GridTextureResidencyPolicy<ID>
    private var textures: [ID: MTLTexture] = [:]
    package private(set) var placeholderTexture: MTLTexture

    /// Rolling per-frame accounting (reset each `beginFrame`).
    package private(set) var uploadsThisFrame = 0
    package private(set) var uploadBytesThisFrame = 0
    package private(set) var uploadMsThisFrame: Double = 0
    package private(set) var evictionsThisFrame = 0
    package private(set) var evictMsThisFrame: Double = 0
    package private(set) var deferredUploadsThisFrame = 0
    /// In-place re-uploads this frame that grew an already-resident texture to the current effective cap
    /// (`upgradeUndersizedResident`) — a subset of `uploadsThisFrame`, surfaced separately for diagnostics.
    package private(set) var upgradesThisFrame = 0
    /// True once an upload was refused this frame because the resident byte/count budget cannot admit it
    /// even after evicting every non-pinned texture. That state only changes when the streaming window
    /// changes (scroll/zoom) or images arrive — both trigger their own redraw — so callers may stop
    /// display-link pumping on it instead of spinning on placeholders that can never fill.
    package private(set) var residencySaturatedThisFrame = false
    /// True when at least one visible resident texture is still below the current effective cap because the
    /// per-frame upload budget ran out (not because residency refused it — that never changes without a
    /// window change). Callers keep the display link ticking on this so a soft carried-over texture finishes
    /// upgrading to full resolution over the next frames instead of freezing mid-upgrade on an idle grid.
    package private(set) var pendingUpgradesThisFrame = false

    /// Absolute pixel side ceiling a thumbnail is uploaded at (platform adapter policy — Retina crispness
    /// without wasting VRAM). The per-frame *effective* cap (`effectiveMaxTexturePixels`) is derived from the
    /// on-screen slot size and can only ever be smaller, never larger, than this.
    package let maxTexturePixels: Int

    /// The cap actually applied to thumbnail uploads this frame: the coordinator lowers it for dense zoom
    /// levels (tiny slots) via `setEffectiveMaxTexturePixels` so those upload smaller textures. Defaults to
    /// `maxTexturePixels`, so a caller that never sets it behaves exactly as before. Glyph textures ignore
    /// this and always size against `maxTexturePixels` (their size must stay stable across zoom).
    package private(set) var effectiveMaxTexturePixels: Int

    package var residentCount: Int { lru.residentCount }
    package var pinnedCount: Int { lru.pinnedCount }
    package var inFlightCount: Int { lru.inFlightCount }
    package var residencyCapacity: Int { lru.capacity }
    package var pinnedOverflow: Bool { lru.pinnedCount > lru.capacity }
    /// Exact resident GPU texture bytes (single source of truth: the policy's cost ledger).
    package var residentBytes: Int { lru.residentCost }
    package var residentByteBudget: Int { budget.maxResidentBytes }
    package var uploadByteBudgetPerFrame: Int { budget.maxUploadBytesPerFrame }
    package var uploadTimeBudgetPerFrame: Double { budget.maxUploadMillisecondsPerFrame }
    /// True when resident bytes exceed the budget — transiently possible inside a frame (uploads land
    /// before `evictToBudget`), never after eviction ran. Persistent `true` in logs signals a bug.
    package var byteBudgetOverflow: Bool { lru.residentCost > budget.maxResidentBytes }
    /// Largest pin set the byte budget can guarantee residency for, assuming worst-case (square,
    /// `effectiveMaxTexturePixels`-sided) uploads. The streaming window clamps pinning to this so visible-first
    /// pinning degrades to placeholders instead of overflowing the budget.
    ///
    /// Using the *effective* cap (not the absolute `maxTexturePixels`) makes this accurate per zoom level: at
    /// the dense overview levels — where the pin count explodes (viewport + 2× overscan can exceed the count
    /// cap entirely) — the effective cap is small, so each texture is cheap and far more of the visible tiles
    /// can be pinned within the same byte budget instead of degrading to placeholders. Structural admission in
    /// the residency policy still enforces the byte ceiling regardless, so an over-optimistic estimate can only
    /// cost a transient placeholder, never a budget overflow.
    package var maxSafePinnedCount: Int {
        let worstCaseBytesPerTexture = max(1, effectiveMaxTexturePixels * effectiveMaxTexturePixels * 4)
        return min(budget.maxCachedTextures, budget.maxResidentBytes / worstCaseBytesPerTexture)
    }

    package init?(
        device: MTLDevice,
        budget: GridTextureBudget,
        maxTexturePixels: Int = 320,
        glyphRasterizer: any MetalGridGlyphRasterizing
    ) {
        self.device = device
        self.glyphRasterizer = glyphRasterizer
        self.budget = budget
        self.maxTexturePixels = maxTexturePixels
        self.effectiveMaxTexturePixels = maxTexturePixels
        self.lru = GridTextureResidencyPolicy(
            capacity: budget.maxCachedTextures,
            costCapacity: budget.maxResidentBytes,
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
        upgradesThisFrame = 0
        residencySaturatedThisFrame = false
        pendingUpgradesThisFrame = false
    }

    /// Set the per-frame effective upload cap (derived by the coordinator from the on-screen slot size at the
    /// current zoom level; see `GridTextureUploadSizing`). Clamped to `1...maxTexturePixels`, so it can only
    /// shrink uploads relative to the platform ceiling, never enlarge them beyond it.
    package func setEffectiveMaxTexturePixels(_ pixels: Int) {
        effectiveMaxTexturePixels = min(maxTexturePixels, max(1, pixels))
    }

    package func noteUsed(_ id: ID) { lru.noteUsed(id) }

    package func isResident(_ id: ID) -> Bool { lru.isResident(id) }
    package func isInFlight(_ id: ID) -> Bool { lru.isInFlight(id) }

    /// The texture to draw for `id` — real if resident, else the shared placeholder.
    package func texture(for id: ID) -> MTLTexture {
        textures[id] ?? placeholderTexture
    }

    /// True when a resident texture is materially below the current effective cap and should be considered
    /// for a soft→sharp replacement. Uses the same 1.25× hysteresis as `upgradeUndersizedResident` so small
    /// cap fluctuations do not keep the display link awake or churn uploads.
    package func residentTextureNeedsMeaningfulUpgrade(_ id: ID) -> Bool {
        guard let current = textures[id] else { return false }
        let currentLongest = max(current.width, current.height)
        guard currentLongest < effectiveMaxTexturePixels else { return false }
        return effectiveMaxTexturePixels * 4 >= currentLongest * 5
    }

    private var uploadTimeBudgetExhausted: Bool {
        uploadsThisFrame > 0 && uploadMsThisFrame >= budget.maxUploadMillisecondsPerFrame
    }

    /// Upload the chosen subset of `wanted` (visible-first priority order) from the supplied RAM images.
    /// Honours the per-frame count budget + in-flight dedup via the LRU policy (`provideImage` is only
    /// called for the IDs actually selected this frame, never for an already-resident/in-flight ID), the
    /// per-frame byte and measured-time budgets (bounding the main-thread copy cost), and residency admission
    /// (a texture that could not stay within the resident budget is never created). Everything refused for
    /// budget reasons is reported in `deferredUploadsThisFrame` and retried on later frames.
    package func uploadVisible(wanted: [ID], provideImage: (ID) -> CGImage?) {
        let chosen = lru.selectUploads(wanted: wanted)
        var budgetDeferred = 0
        var frameByteBudgetExhausted = false
        var frameTimeBudgetExhausted = false
        for id in chosen {
            if frameByteBudgetExhausted || frameTimeBudgetExhausted {
                lru.abandonUpload(id)
                budgetDeferred += 1
                continue
            }
            guard let image = provideImage(id) else {
                lru.abandonUpload(id)   // image vanished between selection and upload — retry later
                continue
            }
            let size = uploadPixelSize(for: image, cap: effectiveMaxTexturePixels)
            let bytes = size.width * size.height * 4
            // The first upload of a frame always proceeds so one oversized image can never starve forever.
            if uploadsThisFrame > 0, uploadBytesThisFrame + bytes > budget.maxUploadBytesPerFrame {
                frameByteBudgetExhausted = true
                lru.abandonUpload(id)
                budgetDeferred += 1
                continue
            }
            guard lru.canAdmitUpload(id, cost: bytes) else {
                residencySaturatedThisFrame = true
                lru.abandonUpload(id)
                budgetDeferred += 1
                continue
            }
            let start = CFAbsoluteTimeGetCurrent()
            guard let texture = makeTexture(from: image, width: size.width, height: size.height) else {
                lru.abandonUpload(id)
                continue
            }
            uploadMsThisFrame += (CFAbsoluteTimeGetCurrent() - start) * 1000
            textures[id] = texture
            uploadBytesThisFrame += bytes
            uploadsThisFrame += 1
            frameTimeBudgetExhausted = uploadTimeBudgetExhausted
            lru.completeUpload(id, cost: bytes)
        }
        deferredUploadsThisFrame = max(0, wanted.count - chosen.count) + budgetDeferred
    }

    /// Re-upload, in place, visible resident textures that sit BELOW the current effective cap — carried over
    /// from a denser zoom level where they were uploaded smaller — so zooming back out to a sparse level
    /// restores full crispness instead of magnifying a small texture. The old texture stays on screen until
    /// the larger one is ready (a soft→sharp upgrade, never a placeholder gap).
    ///
    /// Bounded by the SAME per-frame upload count + byte budget as `uploadVisible`, and run AFTER it, so it
    /// only spends what fresh content left unused (new placeholders always win). Only meaningful growth is
    /// re-uploaded (a hysteresis margin avoids churn at size boundaries), and the replacement is refused if the
    /// larger texture would push resident bytes over budget — the count is unchanged, so only the byte delta
    /// matters. A budget-deferred upgrade sets `pendingUpgradesThisFrame` (retrying makes progress); a
    /// residency-refused or image-missing one does not (retrying would not).
    package func upgradeUndersizedResident(_ ids: [ID], provideImage: (ID) -> CGImage?) {
        let cap = effectiveMaxTexturePixels
        for id in ids {
            guard uploadsThisFrame < budget.maxUploadsPerFrame else { pendingUpgradesThisFrame = true; break }
            guard !uploadTimeBudgetExhausted else { pendingUpgradesThisFrame = true; break }
            guard let current = textures[id] else { continue }        // non-resident → normal upload path handles it
            let currentLongest = max(current.width, current.height)
            guard currentLongest < cap else { continue }              // already at/above the cap → crisp, skip
            guard let image = provideImage(id) else { continue }      // decoded image gone from RAM → keep the soft one
            let size = uploadPixelSize(for: image, cap: cap)
            let targetLongest = max(size.width, size.height)
            // Only on meaningful growth (≥ 1.25×) AND strictly larger — never re-upload a source-limited texture
            // to the same size (that would churn every frame).
            guard targetLongest > currentLongest, targetLongest * 4 >= currentLongest * 5 else { continue }
            let newBytes = size.width * size.height * 4
            let oldBytes = current.width * current.height * 4
            if uploadsThisFrame > 0, uploadBytesThisFrame + newBytes > budget.maxUploadBytesPerFrame {
                pendingUpgradesThisFrame = true
                break
            }
            // Replacement admission: residency count is unchanged. For visible/pinned replacements, the
            // policy checks the pinned byte floor instead of the current total so evictable offscreen
            // residents do not permanently block a visible low-res→full-res upgrade at a full cache.
            guard lru.canReplaceResident(id, oldCost: oldBytes, newCost: newBytes) else { continue }
            let start = CFAbsoluteTimeGetCurrent()
            guard let texture = makeTexture(from: image, width: size.width, height: size.height) else { continue }
            uploadMsThisFrame += (CFAbsoluteTimeGetCurrent() - start) * 1000
            textures[id] = texture
            uploadBytesThisFrame += newBytes
            uploadsThisFrame += 1
            upgradesThisFrame += 1
            lru.completeUpload(id, cost: newBytes)   // resident-replace branch: swaps the byte cost in place
        }
    }

    /// Evict offscreen LRU textures down to the count + byte budget and release their GPU memory.
    package func evictToBudget() {
        let start = CFAbsoluteTimeGetCurrent()
        let evicted = lru.evictToBudget()
        for id in evicted {
            textures.removeValue(forKey: id)
        }
        evictionsThisFrame = evicted.count
        evictMsThisFrame += (CFAbsoluteTimeGetCurrent() - start) * 1000
    }

    // MARK: - Texture creation

    /// Pixel size a decoded image will be uploaded at (longest side clamped to `cap`) — the texture byte cost
    /// (w·h·4) is derived from this BEFORE any normalization/upload work is spent, so budget refusals cost
    /// nothing. `cap` is the effective per-frame cap for thumbnails and the absolute `maxTexturePixels` for
    /// glyphs; either way the aspect ratio is preserved and an image never upscales past its source.
    private func uploadPixelSize(for image: CGImage, cap: Int) -> (width: Int, height: Int) {
        let srcW = max(image.width, 1), srcH = max(image.height, 1)
        let longest = max(srcW, srcH)
        let cap = max(1, cap)
        let scale = longest > cap ? CGFloat(cap) / CGFloat(longest) : 1
        return (max(1, Int((CGFloat(srcW) * scale).rounded())), max(1, Int((CGFloat(srcH) * scale).rounded())))
    }

    /// Builds an upright RGBA8 texture from a decoded image at the pre-computed `uploadPixelSize`. A decoded
    /// CGImage is already row-0-top, and `CGContext.draw` preserves that into the bitmap buffer, so texel
    /// row 0 is the visual TOP — no context flip — and the renderer samples with straightforward UVs
    /// (uv.y 0 = top), keeping thumbnails upright. (Synthetic tiles are generated `flipped: true` to match
    /// this row-0-top convention.)
    private func makeTexture(from image: CGImage, width w: Int, height h: Int) -> MTLTexture? {
        let isDownsampling = w < image.width || h < image.height
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
        ctx.interpolationQuality = isDownsampling ? .medium : .high
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
        guard let cg = glyphRasterizer.image(for: request) else { return nil }
        // Glyphs size against the ABSOLUTE cap, never the per-frame effective cap: badge sizing must stay
        // stable across zoom levels (a badge is not a zoom-scaled thumbnail).
        let size = uploadPixelSize(for: cg, cap: maxTexturePixels)
        guard let texture = makeTexture(from: cg, width: size.width, height: size.height) else { return nil }
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
