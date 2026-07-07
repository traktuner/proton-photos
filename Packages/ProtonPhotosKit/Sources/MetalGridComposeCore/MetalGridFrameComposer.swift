import CoreGraphics
import GridCore
import Metal
import MetalGridTextureCore
import MetalRenderingCore
import simd

/// Universal, platform-neutral composition of ONE settled grid frame.
///
/// This is the single source of truth for the settled-frame sequence that macOS (`MetalGridCoordinator`)
/// and iOS/iPadOS (`UIKitTimelineGridHost`) previously each re-implemented: visible/overscan classification,
/// the streaming window + pin clamp + effective-pixel sizing, `beginFrame` + visible upload selection +
/// soft→sharp upgrade + warm selection, viewport-only draw filtering, and the resident/placeholder +
/// decoration render-group assembly. Platform hosts own scheduling and OS view plumbing (the drawable, the
/// display link, gestures, resize) and feed neutral data/closures in; the algorithm lives here so a
/// grid/streaming/rendering bug is fixed once, for every platform.
///
/// It is data-in / data-out. It never retains AppKit/UIKit objects, imports no platform view framework, and
/// mutates only the injected texture cache (which is itself platform-neutral).
package enum MetalGridFrameComposer {

    // MARK: - Visible / overscan classification

    /// Split render slots into the viewport-visible and overscan-only UID lists (visible first, source order).
    /// A slot is *visible* when its viewport rect intersects the pure viewport; otherwise it is overscan
    /// (streamed/pinned but not drawn). Out-of-range slot indices are ignored.
    package static func classifyVisibility<ID>(
        slots: [GridRenderSlot], flatUIDs: [ID], viewportSize: CGSize
    ) -> (visible: [ID], overscan: [ID]) {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        var visible: [ID] = []
        var overscan: [ID] = []
        visible.reserveCapacity(slots.count)
        overscan.reserveCapacity(slots.count)
        for s in slots where s.index < flatUIDs.count {
            if s.rect.intersects(viewport) { visible.append(flatUIDs[s.index]) }
            else { overscan.append(flatUIDs[s.index]) }
        }
        return (visible, overscan)
    }

    /// Keep only the slots that actually intersect the viewport - the draw set (overscan feeds streaming/pinning
    /// only, never a draw). Missing thumbnails draw nothing, so the bottom-most clear surface stays continuous.
    package static func viewportDrawSlots(_ slots: [GridRenderSlot], viewportSize: CGSize) -> [GridRenderSlot] {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        return slots.filter { $0.rect.intersects(viewport) }
    }

    // MARK: - Texture streaming (visible-first upload + upgrade + off-main warm selection)

    /// Result of one streaming pass: the UIDs the host should warm off-main this frame, and whether a visible
    /// resident texture is still mid-upgrade (a budget-deferred soft→sharp grow) so the host keeps ticking.
    package struct StreamResult<ID> {
        package var warm: [ID]
        package var pendingVisibleQualityUpgrade: Bool
    }

    /// Run the settled streaming sequence against the injected cache:
    /// 1. set the per-frame effective upload cap (host supplies the level-aware pixel side),
    /// 2. build the visible-first duplicate-free streaming window, clamped to the byte budget's safe pin count,
    /// 3. `beginFrame` on the pinned set,
    /// 4. upload the still-missing, RAM-ready visible-first tiles within the frame budget,
    /// 5. (settled only) grow carried-over undersized visible textures to the current cap in place,
    /// 6. select the still-missing, retryable, not-yet-in-RAM tiles for an off-main warm.
    ///
    /// The order is load-bearing: the effective cap is set BEFORE `maxSafePinnedCount` is read (so dense levels
    /// pin more cheap textures), and the upgrade runs AFTER fresh uploads spend their budget share (new
    /// placeholders always win). `signposts` lets the host wrap the upload/upgrade work in its own Instruments
    /// intervals without this module importing the host's diagnostics.
    /// `needsSharperSource` reports a RAM image that EXISTS but was decoded materially below the current
    /// effective pixels, so the warm pass can re-decode it sharper for the in-place texture upgrade. The
    /// default (never) matches a feed whose decodes always land at the platform cap - macOS today.
    @MainActor
    package static func stream<ID: Hashable & Sendable>(
        cache: MetalGridTextureCache<ID>,
        visibleIDs: [ID],
        overscanIDs: [ID],
        pinOverscan: Bool,
        effectiveUploadPixels: Int,
        allowUpgrade: Bool,
        hasImage: (ID) -> Bool,
        canRetry: (ID) -> Bool,
        needsSharperSource: (ID) -> Bool = { _ in false },
        provideImage: (ID) -> CGImage?,
        signposts: MetalGridComposeSignposts = MetalGridComposeSignposts()
    ) -> StreamResult<ID> {
        // Level-aware upload size FIRST: `maxSafePinnedCount` reads the effective cap, so setting it here lets
        // dense zoom levels pin far more (cheap) visible tiles within the same byte budget.
        cache.setEffectiveMaxTexturePixels(effectiveUploadPixels)
        // Pinning is clamped to what the byte budget can guarantee (visible first, then nearest overscan).
        let window = GridTextureStreamingPolicy.window(
            visibleIDs: visibleIDs, overscanIDs: overscanIDs,
            maxPinned: cache.maxSafePinnedCount, pinOverscan: pinOverscan
        )
        cache.beginFrame(pinned: window.pinned)
        let visibleMissing = visibleIDs.contains { !cache.isResident($0) && canRetry($0) }
        let priority = visibleMissing ? visibleIDs : window.priority
        var wanted: [ID] = []
        for uid in priority where !cache.isResident(uid) && hasImage(uid) { wanted.append(uid) }
        let upgradeCandidates = allowUpgrade ? visibleIDs.filter { cache.residentTextureNeedsMeaningfulUpgrade($0) } : []
        signposts.uploadInterval {
            cache.uploadVisible(wanted: wanted) { provideImage($0) }
        }
        // Settled only: after fresh uploads spend their share of the budget, grow any visible texture still
        // below the current cap (carried over from a denser level) to full crispness, in place.
        if allowUpgrade {
            signposts.upgradeInterval {
                cache.upgradeUndersizedResident(upgradeCandidates) { provideImage($0) }
            }
        }
        var warm: [ID] = []
        var queuedWarm = Set<ID>()
        func appendWarm(_ uid: ID) {
            guard queuedWarm.insert(uid).inserted else { return }
            warm.append(uid)
        }
        for uid in priority where !cache.isResident(uid) && !cache.isInFlight(uid) && !hasImage(uid) && canRetry(uid) {
            appendWarm(uid)
        }
        var pendingVisibleQualityUpgrade = cache.pendingUpgradesThisFrame
        if allowUpgrade {
            for uid in upgradeCandidates where cache.residentTextureNeedsMeaningfulUpgrade(uid) {
                // A low-res resident keeps drawing while its RAM decode is missing OR materially below the
                // effective cap; request the source so a settled sparse frame can replace it with a sharp
                // texture. If the source is present at its adequate cap (source-limited included), or the
                // pinned floor cannot fit the replacement, there is no retryable work.
                guard !hasImage(uid) || needsSharperSource(uid), canRetry(uid) else { continue }
                appendWarm(uid)
                pendingVisibleQualityUpgrade = true
            }
        }
        return StreamResult(warm: warm, pendingVisibleQualityUpgrade: pendingVisibleQualityUpgrade)
    }

    // MARK: - Render group assembly (resident/placeholder draw + production decorations)

    /// Build the settled-grid render groups for a set of slots at an EXPLICIT display mode (the canonical
    /// settled appearance: rounded thumbnail cover-fit on the uniform bg + optional production decorations).
    /// Pure builder - no eviction, no draw. Returns (groups, resident-texture count).
    ///
    /// The image group is always the first (back-most) group even when empty (the renderer skips empty groups),
    /// then, if `decorations` are supplied, the selection outline + badge groups in a fixed order. Missing
    /// thumbnails draw nothing, so gaps + aspectFit letterbox reveal the same uniform surface.
    @MainActor
    package static func buildGroups<ID: Hashable & Sendable>(
        slots: [GridRenderSlot],
        flatUIDs: [ID],
        cache: MetalGridTextureCache<ID>,
        displayMode: TileContentDisplayMode,
        cornerRadius: CGFloat,
        decorations: MetalGridDecorations<ID>?
    ) -> (groups: [MetalGridRenderGroup], realCount: Int) {
        var images: [MetalGridQuad] = []
        var imageTextures: [MTLTexture] = []
        var outlineQuads: [MetalGridQuad] = []
        var favoriteQuads: [MetalGridQuad] = []
        var checkFilledQuads: [MetalGridQuad] = []
        var checkEmptyQuads: [MetalGridQuad] = []
        var videoQuads: [MetalGridQuad] = []
        var realCount = 0
        for s in slots where s.index < flatUIDs.count {
            let uid = flatUIDs[s.index]
            let cell = s.rect                               // viewport-space, ALWAYS square (engine guarantee)
            let r = Self.cellRadius(base: cornerRadius, cell: cell)
            if cache.isResident(uid) {
                cache.noteUsed(uid)
                let texture = cache.texture(for: uid)
                // The fitter is the ONLY thing that sees media aspect; the slot is square regardless. The rounded
                // thumbnail sits directly on the uniform background (no per-cell card), so gaps + aspectFit
                // letterbox show the same surface.
                let fit = TileContentFitter.fit(slotRect: cell,
                                                mediaPixelSize: CGSize(width: texture.width, height: texture.height),
                                                displayMode: displayMode)
                images.append(MetalGridQuad(rect: fit.contentRect, uvMin: fit.uvMin, uvMax: fit.uvMax, radius: r))
                imageTextures.append(texture)
                realCount += 1
            }
            if let decorations {
                appendDecorations(uid: uid, cell: cell, displayed: cell, cardRadius: r, decorations: decorations,
                                  outline: &outlineQuads, favorite: &favoriteQuads,
                                  checkFilled: &checkFilledQuads, checkEmpty: &checkEmptyQuads, video: &videoQuads)
            }
        }
        var groups: [MetalGridRenderGroup] = [
            MetalGridRenderGroup(source: .perQuadTexture(imageTextures), quads: images),
        ]
        if !outlineQuads.isEmpty {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(cache.placeholderTexture), quads: outlineQuads))
        }
        if !videoQuads.isEmpty, let texture = cache.glyphTexture(symbol: "video.fill", color: .white) {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(texture), quads: videoQuads))
        }
        if !favoriteQuads.isEmpty, let texture = cache.glyphTexture(symbol: "heart.fill", color: .white) {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(texture), quads: favoriteQuads))
        }
        if !checkEmptyQuads.isEmpty, let texture = cache.glyphTexture(symbol: "circle", color: .white) {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(texture), quads: checkEmptyQuads))
        }
        if !checkFilledQuads.isEmpty, let decorations,
           let texture = cache.glyphTexture(symbol: "checkmark.circle.fill", color: decorations.accentGlyphColor) {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(texture), quads: checkFilledQuads))
        }
        return (groups, realCount)
    }

    /// The slot-size-derived card corner radius (shared `GridCornerRadiusPolicy`): tiny dense cells draw
    /// SHARP 90° corners (radius 0, renderer fast path), medium cells a reduced radius, large cells `base`.
    package static func cellRadius(base: CGFloat, cell: CGRect) -> Float {
        Float(GridCornerRadiusPolicy.radius(forSlotSidePoints: min(cell.width, cell.height), base: base))
    }

    @MainActor
    private static func appendDecorations<ID: Hashable>(
        uid: ID, cell: CGRect, displayed: CGRect, cardRadius: Float, decorations: MetalGridDecorations<ID>,
        outline: inout [MetalGridQuad], favorite: inout [MetalGridQuad],
        checkFilled: inout [MetalGridQuad], checkEmpty: inout [MetalGridQuad], video: inout [MetalGridQuad]
    ) {
        let side = cell.height
        let badge = min(22, max(11, side * 0.3))
        let pad = max(3, side * 0.06)
        let isSelected = decorations.selected.contains(uid)
        // Blue selection outline hugging the displayed image (border mode → no layout impact).
        if isSelected {
            let radius = min(cardRadius, Float(min(displayed.width, displayed.height) * 0.5))
            outline.append(MetalGridQuad(rect: displayed, radius: radius, color: decorations.accent, mode: .border, borderWidth: 3.5))
        }
        // Favorite heart, bottom-left.
        if decorations.favorites.contains(uid) {
            favorite.append(MetalGridQuad(rect: CGRect(x: cell.minX + pad, y: cell.maxY - badge - pad, width: badge, height: badge), radius: 0))
        }
        let brCorner = CGRect(x: cell.maxX - badge - pad, y: cell.maxY - badge - pad, width: badge, height: badge)
        if decorations.selectionMode {
            // Checkmark badge, bottom-right (filled+accent when selected, empty circle otherwise).
            if isSelected { checkFilled.append(MetalGridQuad(rect: brCorner, radius: 0)) }
            else { checkEmpty.append(MetalGridQuad(rect: brCorner, radius: 0)) }
        } else if decorations.isVideo(uid) {
            // Video marker, bottom-right (no duration text yet).
            video.append(MetalGridQuad(rect: brCorner, radius: 0))
        }
    }
}

/// Production decoration descriptors for `buildGroups`, injected as neutral data. Platform hosts convert their
/// native accent colour (AppKit/UIKit) into the SIMD/glyph values at their adapter edge; this stays neutral.
/// Selection/favorite membership is passed as value-type sets; video membership is a main-actor query into the
/// host's data source (which owns that classification).
package struct MetalGridDecorations<ID: Hashable> {
    package var accent: SIMD4<Float>
    package var accentGlyphColor: MetalGridGlyphColor
    package var selectionMode: Bool
    package var selected: Set<ID>
    package var favorites: Set<ID>
    package var isVideo: @MainActor (ID) -> Bool

    package init(
        accent: SIMD4<Float>,
        accentGlyphColor: MetalGridGlyphColor,
        selectionMode: Bool,
        selected: Set<ID>,
        favorites: Set<ID>,
        isVideo: @escaping @MainActor (ID) -> Bool
    ) {
        self.accent = accent
        self.accentGlyphColor = accentGlyphColor
        self.selectionMode = selectionMode
        self.selected = selected
        self.favorites = favorites
        self.isVideo = isVideo
    }
}

/// Minimal signpost seam so a host can keep its Instruments intervals around the upload/upgrade work the
/// composer now owns, WITHOUT the composer importing the host's diagnostics module. Default = no-op, so a
/// host that does not instrument simply omits it (iOS today).
package struct MetalGridComposeSignposts {
    package var uploadInterval: (() -> Void) -> Void
    package var upgradeInterval: (() -> Void) -> Void

    package init(
        uploadInterval: @escaping (() -> Void) -> Void = { $0() },
        upgradeInterval: @escaping (() -> Void) -> Void = { $0() }
    ) {
        self.uploadInterval = uploadInterval
        self.upgradeInterval = upgradeInterval
    }
}
