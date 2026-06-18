import CoreGraphics
import Foundation

/// Pure, GPU-free math for the grid-zoom frozen-source overlay.
///
/// Extracted as free functions (no AppKit, no `@MainActor`) so they can be unit-tested headlessly
/// (`GridZoomMathTests`) and so the Metal vertex shader's transform has a single Swift mirror to
/// assert against. Two concerns live here:
///  • **coverage** — given the live pinch scale, what source-space rect must the frozen surface cover
///    to fill the viewport, and how much of it the already-captured surface actually covers; and
///  • **ghosts** — the experimental far-band / edge target-ghost alpha curve (Phase 4, off by default).
///
/// All rects are in *source/base space*: the viewport-at-pinch-begin coordinates the frozen sprites
/// were captured in (top-left origin, y down — same space the snapshots' `imageFrame` lives in).
enum GridZoomMath {

    // MARK: - Frozen transform (mirror of the Metal vertex shader)

    /// The frozen-source vertex transform, mirrored verbatim from `gridSpriteVertex` in
    /// `GridSpriteTransitionView`'s shader: a base-geometry point scaled around the pinch anchor.
    /// Shader: `float2 scaled = anchor + (position - anchor) * scale;`
    /// If you change one, change both — `frozenTransformMatchesShaderSpec` guards the formula.
    static func frozenTransform(base: CGPoint, anchor: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: anchor.x + (base.x - anchor.x) * scale,
                y: anchor.y + (base.y - anchor.y) * scale)
    }

    /// Rect version of the frozen-source transform. Used for the opaque source plate and diagnostics.
    static func scaledRect(_ rect: CGRect, anchor: CGPoint, scale: CGFloat) -> CGRect {
        CGRect(
            x: anchor.x + (rect.minX - anchor.x) * scale,
            y: anchor.y + (rect.minY - anchor.y) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        )
    }

    // MARK: - Coverage

    /// The source-space rect that must be covered to fill `viewport` at the given live `scale`,
    /// inverting the frozen transform around `anchor`. `scale < 1` (zoom OUT) ⇒ a rect LARGER than the
    /// viewport (the surface shrinks, so more source area is exposed); `scale > 1` ⇒ smaller. `margin`
    /// pads the result for edge overscan.
    static func sourceRectNeededForFrozenScale(viewport: CGRect, anchor: CGPoint, scale: CGFloat, margin: CGSize) -> CGRect {
        let s = max(scale, 0.001)
        let minX = anchor.x + (viewport.minX - anchor.x) / s
        let maxX = anchor.x + (viewport.maxX - anchor.x) / s
        let minY = anchor.y + (viewport.minY - anchor.y) / s
        let maxY = anchor.y + (viewport.maxY - anchor.y) / s
        return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                      width: abs(maxX - minX), height: abs(maxY - minY))
            .insetBy(dx: -margin.width, dy: -margin.height)
    }

    struct Coverage {
        var ratio: CGFloat
        var missingTop: CGRect      // strip of `needed` above (smaller y than) `captured`
        var missingBottom: CGRect   // strip below (larger y)
        var missingLeft: CGRect
        var missingRight: CGRect
        /// Treat ≥97% as covered: page 0 captures viewport±~10%/25%, so a small overscan margin at
        /// scale 1 should NOT count as a miss and trigger spurious top-ups.
        var isCovered: Bool { ratio >= 0.97 }
        var hasMissingRegion: Bool {
            !(missingTop.isNull && missingBottom.isNull && missingLeft.isNull && missingRight.isNull)
        }
    }

    /// How much of `needed` the already-`captured` source rect covers (area ratio), plus the four band
    /// rects of `needed` that fall outside `captured`. Corners may overlap between adjacent bands —
    /// callers dedupe gathered items by uid, so overlap is harmless. `top` = the visual top (smaller y).
    static func coverage(captured: CGRect, needed: CGRect) -> Coverage {
        let neededArea = max(needed.width, 0) * max(needed.height, 0)
        guard neededArea > 0, !needed.isNull else {
            return Coverage(ratio: 1, missingTop: .null, missingBottom: .null, missingLeft: .null, missingRight: .null)
        }
        guard !captured.isNull else {
            return Coverage(ratio: 0, missingTop: needed, missingBottom: .null, missingLeft: .null, missingRight: .null)
        }
        let inter = captured.intersection(needed)
        let interArea = inter.isNull ? 0 : inter.width * inter.height
        let ratio = max(0, min(1, interArea / neededArea))

        func band(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
            (w <= 0.5 || h <= 0.5) ? .null : CGRect(x: x, y: y, width: w, height: h)
        }
        let topH = min(captured.minY, needed.maxY) - needed.minY
        let bottomH = needed.maxY - max(captured.maxY, needed.minY)
        let leftW = min(captured.minX, needed.maxX) - needed.minX
        let rightW = needed.maxX - max(captured.maxX, needed.minX)
        return Coverage(
            ratio: ratio,
            missingTop: band(needed.minX, needed.minY, needed.width, topH),
            missingBottom: band(needed.minX, max(captured.maxY, needed.minY), needed.width, bottomH),
            missingLeft: band(needed.minX, needed.minY, leftW, needed.height),
            missingRight: band(max(captured.maxX, needed.minX), needed.minY, rightW, needed.height)
        )
    }

    /// Fraction of the viewport not covered by the scaled source plate. This is the gate for live
    /// target edge fill; internal thumbnail gaps do NOT count because the source plate covers them.
    static func viewportUncoveredRatio(viewport: CGRect, sourcePlateRect: CGRect, anchor: CGPoint, scale: CGFloat) -> CGFloat {
        let viewportArea = max(viewport.width, 0) * max(viewport.height, 0)
        guard viewportArea > 0, !viewport.isNull, !sourcePlateRect.isNull else { return 1 }
        let plateScreen = scaledRect(sourcePlateRect, anchor: anchor, scale: scale)
        let covered = plateScreen.intersection(viewport)
        let coveredArea = covered.isNull ? 0 : max(covered.width, 0) * max(covered.height, 0)
        return max(0, min(1, (viewportArea - coveredArea) / viewportArea))
    }

    /// Live target backdrop appears only for real zoom-out exposure, never for zoom-in or tiny rocking.
    static func shouldShowTargetBackdrop(sourceScale: CGFloat, uncoveredRatio: CGFloat) -> Bool {
        sourceScale < 0.92 && uncoveredRatio > 0.08
    }

    /// A target backdrop pixel is visually allowed only outside the scaled source plate. Drawing may be
    /// implemented by putting the opaque source plate over the backdrop, but the visibility rule is this.
    static func targetBackdropVisibleAt(_ point: CGPoint, sourcePlateRect: CGRect, anchor: CGPoint, sourceScale: CGFloat) -> Bool {
        !scaledRect(sourcePlateRect, anchor: anchor, scale: sourceScale).contains(point)
    }

    /// Backdrop pages are frozen during normal small oscillations. Replacing is allowed only for the
    /// first page or a discrete target-level change; origin jitter alone must not swap the UID set.
    static func shouldReplaceFrozenBackdrop(
        frozenLevel: Int?,
        frozenOriginY: CGFloat?,
        candidateLevel: Int,
        candidateOriginY: CGFloat,
        viewportHeight: CGFloat
    ) -> Bool {
        guard let frozenLevel, let frozenOriginY else { return true }
        if candidateLevel != frozenLevel { return true }
        return abs(candidateOriginY - frozenOriginY) > max(viewportHeight, 1) * 0.50
    }

    // MARK: - Discrete snap model (release continues the anchored zoom to a resting level)

    /// On release, choose the discrete resting level: continue the user's anchored zoom to the next
    /// level, NOT a free size and NOT a best-fit neighborhood. Tiny movement (and no flick) returns to
    /// the source level; an intentional pinch advances one level; a big/fast gesture may cross more, but
    /// only as far as the live position actually went. `velocity` is in levels/second (signed: + = zoom
    /// out / higher index). Always clamped to a valid level.
    static func snapLevel(sourceLevel: Int, livePosition: CGFloat, velocity: CGFloat, levelCount: Int) -> Int {
        let maxLevel = max(0, levelCount - 1)
        func clamp(_ l: Int) -> Int { min(max(l, 0), maxLevel) }
        let delta = livePosition - CGFloat(sourceLevel)
        let absDelta = abs(delta)
        let dir = delta >= 0 ? 1 : -1
        let sameWay = velocity == 0 || (velocity > 0) == (delta > 0)
        let flick = sameWay && abs(velocity) > 0.9
        // Tiny movement, no flick → stay on the source level (no snap).
        if absDelta < 0.2, !flick { return clamp(sourceLevel) }
        let full = Int(absDelta)                          // whole levels the position crossed
        let partial = absDelta - CGFloat(full)
        let commitPartial = partial >= 0.5 || (partial >= 0.2 && flick)   // round up near a boundary / on a flick
        let steps = max(1, full + (commitPartial ? 1 : 0))               // an intentional pinch is ≥ 1 level
        return clamp(sourceLevel + dir * steps)
    }

    // MARK: - Source occlusion mask (row bands — NOT one big rectangle)

    /// A masked set of source ROW bands (base/viewport-at-begin coords). Target backdrop is allowed only
    /// where the transformed bands do NOT cover the viewport — so it never shines through internal source
    /// gaps, and is never blocked by a giant rectangle covering areas where no source images exist (the
    /// "black box" bug of a single `sourcePlateRect`).
    struct SourceOcclusionMask: Equatable {
        var rowBands: [CGRect] = []
        var isEmpty: Bool { rowBands.isEmpty }
        var boundingRect: CGRect { rowBands.reduce(.null) { $0.union($1) } }

        /// True if `screenPoint` lies inside any row band transformed by (anchor, scale).
        func covers(_ screenPoint: CGPoint, anchor: CGPoint, scale: CGFloat) -> Bool {
            for band in rowBands {
                let s = CGRect(x: anchor.x + (band.minX - anchor.x) * scale,
                               y: anchor.y + (band.minY - anchor.y) * scale,
                               width: band.width * scale, height: band.height * scale)
                if s.contains(screenPoint) { return true }
            }
            return false
        }

        /// Total area of `screenRect` occluded by the source bands transformed by (anchor, scale). Bands
        /// can overlap each other slightly (gap pad), so this may over-count near band seams — callers
        /// clamp `visibleFraction` to [0,1]. RECT-overlap, not center-point, so a big target cell that
        /// only partly covers an exposed edge is still drawn.
        func overlapArea(withScreenRect rect: CGRect, anchor: CGPoint, scale: CGFloat) -> CGFloat {
            var area: CGFloat = 0
            for band in rowBands {
                let s = CGRect(x: anchor.x + (band.minX - anchor.x) * scale,
                               y: anchor.y + (band.minY - anchor.y) * scale,
                               width: band.width * scale, height: band.height * scale)
                let i = s.intersection(rect)
                if !i.isNull { area += i.width * i.height }
            }
            return area
        }

        /// Fraction of `screenRect` NOT occluded by the source mask (1 = fully exposed, 0 = fully behind
        /// source). Drives target-cell visibility during `.changed`.
        func visibleFraction(ofScreenRect rect: CGRect, anchor: CGPoint, scale: CGFloat) -> CGFloat {
            let a = max(rect.width, 0) * max(rect.height, 0)
            guard a > 0 else { return 0 }
            return max(0, min(1, 1 - overlapArea(withScreenRect: rect, anchor: anchor, scale: scale) / a))
        }
    }

    /// The two scales during a pinch: the frozen SOURCE surface uses `source`, the candidate TARGET
    /// detent surface uses `target` (apparent size over its OWN level size). The target surface must use
    /// `target` — forcing it to the source scale makes it shrink with the old layout and leaves dark gaps.
    static func detentScales(apparentSize: CGFloat, sourceLevelSize: CGFloat, targetLevelSize: CGFloat) -> (source: CGFloat, target: CGFloat) {
        (apparentSize / max(sourceLevelSize, 1), apparentSize / max(targetLevelSize, 1))
    }

    /// Origin IDENTITY between the live target-detent surface and the commit. When the release snaps to
    /// the SAME level the live `TargetDetentPlan` was frozen at, the committed content-origin MUST be the
    /// plan's exact origin — that is the precise content the gesture previewed, so the revealed real grid
    /// lands where the user saw it. Returns nil when there is no matching live plan, signalling the caller
    /// to derive the origin from the TARGET level's projected geometry instead (never the source level's).
    static func commitOrigin(livePlanTargetLevel: Int?, livePlanOrigin: CGPoint?, finalLevel: Int) -> CGPoint? {
        guard let level = livePlanTargetLevel, let origin = livePlanOrigin, level == finalLevel else { return nil }
        return origin
    }

    /// The aspect-FIT rect of an image inside a cell (letterbox): the largest centered rect with the
    /// image's aspect ratio that fits the cell. This is the frame the photo actually OCCUPIES on an
    /// `aspectFit` level (portrait → bars left/right, landscape → bars top/bottom).
    static func aspectFitRect(in cell: CGRect, imageSize: CGSize) -> CGRect {
        let imageAspect = imageSize.width / max(imageSize.height, 1)
        let cellAspect = cell.width / max(cell.height, 1)
        if imageAspect > cellAspect {
            let height = cell.width / max(imageAspect, 0.001)
            return CGRect(x: cell.minX, y: cell.midY - height / 2, width: cell.width, height: height)
        } else {
            let width = cell.height * imageAspect
            return CGRect(x: cell.midX - width / 2, y: cell.minY, width: width, height: cell.height)
        }
    }

    /// The frame the DISPLAYED photo occupies inside its cell. The user points at the visible image, not
    /// the abstract cell, so anchoring must use THIS rect: `aspectFit` levels letterbox (fitted rect),
    /// `squareFill` levels center-crop to fill the whole cell (→ cell frame). Falls back to the cell frame
    /// when the image size is unknown (caller logs the fallback).
    static func displayedImageFrame(cellFrame: CGRect, imageSize: CGSize, cropMode: GridCropMode) -> CGRect {
        guard imageSize.width > 0.5, imageSize.height > 0.5 else { return cellFrame }
        switch cropMode {
        case .squareFill: return cellFrame
        case .aspectFit:  return aspectFitRect(in: cellFrame, imageSize: imageSize)
        }
    }

    /// Where to scroll so a given IMAGE-local unit point of the anchor asset lands at `viewportPoint`,
    /// for a target detent. `targetCellFrame` is the asset's cell frame at the target level (document
    /// space). The displayed-image frame (not the cell) carries the point. Used by the headless test to
    /// prove image-anchor preservation across aspectFit↔squareFill level changes.
    static func anchoredImageOrigin(targetCellFrame: CGRect, imageSize: CGSize, cropMode: GridCropMode,
                                    imageLocalUnitPoint local: CGPoint, viewportPoint: CGPoint) -> CGPoint {
        let imageFrame = displayedImageFrame(cellFrame: targetCellFrame, imageSize: imageSize, cropMode: cropMode)
        let contentPoint = CGPoint(x: imageFrame.minX + local.x * imageFrame.width,
                                   y: imageFrame.minY + local.y * imageFrame.height)
        return CGPoint(x: contentPoint.x - viewportPoint.x, y: contentPoint.y - viewportPoint.y)
    }

    /// EVERY level change is a topology change from the user's view — thumbnail size, gap, column count
    /// and row assignment all change even when `cropMode` is identical (e.g. level 1→2). So a target
    /// preview must be built and crossfaded before reveal for ANY `sourceLevel != finalLevel`; only a
    /// same-level release (return to source) may settle source-only. cropMode equality is NOT proof that
    /// topology is unchanged.
    static func requiresTargetPreview(sourceLevel: Int, finalLevel: Int) -> Bool {
        sourceLevel != finalLevel
    }

    /// The resting level on release. The SNAP is the only source of truth — a target surface shown during
    /// `.changed` may not influence it. Note this takes no live-plan argument BY DESIGN: it is structurally
    /// impossible for the live backdrop to override the snapped level here. Cancelled → return to source.
    static func resolveFinalLevel(cancelled: Bool, sourceLevel: Int, snapLevel: Int) -> Int {
        cancelled ? sourceLevel : snapLevel
    }

    /// Per-cell target-PREVIEW alpha during the settle crossfade. The preview never appears as a full
    /// wall from the first frame: cells in the focus band around the pointer dissolve in LATEST (so the
    /// focus image is the last thing replaced), cells far from the focus dissolve in a little earlier —
    /// the user sees a replacement/crossfade, never a sudden reveal. `settleProgress` is the eased 0→1
    /// settle position. Focus band half-height = 0.18·viewportHeight (matches `focusBandHalfHeight`).
    static func previewCellAlpha(settleProgress: CGFloat, cellCenterY: CGFloat, anchorY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        let distance = abs(cellCenterY - anchorY)
        if distance < focusBandHalfHeight(viewportHeight: viewportHeight) {
            return smoothstep(0.92, 1.0, settleProgress)   // focus band: replaced LAST (anchor stays source-dominant)
        }
        return smoothstep(0.62, 0.95, settleProgress)       // far band: a little earlier
    }

    // MARK: - One global zoom world (per-photo visual nodes; no plate / backdrop / wall)

    /// The topmost PHOTO covering a point in the global zoom world. A SOURCE rect always occludes a
    /// TARGET rect (source draws over target by depth), and within a layer the first covering node wins.
    /// Returns nil if no node covers the point. The focus-anchor invariant requires this to equal the
    /// anchor photo throughout `.changed` — that is what keeps the focused photo under the pointer.
    /// Generic over the id type so it is pure and headlessly testable.
    static func topNodeAtAnchor<ID>(sourceRects: [(id: ID, rect: CGRect)], targetRects: [(id: ID, rect: CGRect)], at point: CGPoint) -> ID? {
        if let s = sourceRects.first(where: { $0.rect.contains(point) }) { return s.id }
        if let t = targetRects.first(where: { $0.rect.contains(point) }) { return t.id }
        return nil
    }

    /// The photos sharing the pointer's ROW: cells whose vertical centre lies within the anchor cell's
    /// row band (the anchor cell's Y-extent padded by `gapPad`). These are the PROTECTED focus row — no
    /// target node is drawn for them during `.changed`, and they are the last thing replaced on settle.
    static func focusRowIDs<ID>(cells: [(id: ID, frame: CGRect)], anchorFrame: CGRect, gapPad: CGFloat) -> [ID] {
        let lo = anchorFrame.minY - gapPad, hi = anchorFrame.maxY + gapPad
        return cells.filter { $0.frame.midY >= lo && $0.frame.midY <= hi }.map(\.id)
    }

    /// How far the live gesture has travelled toward the target detent, 0→1. 0 at the source thumbnail
    /// size, 1 once the apparent size reaches the target thumbnail size. Drives the per-cell crossfade.
    static func liveProgressTowardDetent(apparentSize: CGFloat, sourceLevelSize: CGFloat, targetLevelSize: CGFloat) -> CGFloat {
        let denom = sourceLevelSize - targetLevelSize
        guard abs(denom) > 0.001 else { return 0 }
        return max(0, min(1, (sourceLevelSize - apparentSize) / denom))
    }

    /// Per-cell REPLACEMENT alpha: how much a photo OUTSIDE the focus band has crossfaded from source to
    /// target. Rows far from the focus replace EARLIER (start nearer 0.28); the focus row replaces LATEST
    /// (start 0.78). Edge / target-only cells fade in early (start 0.05) so a zoom-out fills the viewport.
    /// This is what dissolves the source per-cell instead of keeping it an opaque rectangle.
    static func replacementAlpha(progress: CGFloat, distanceFromFocus: CGFloat, viewportHeight: CGFloat, isEdgeOrTargetOnly: Bool) -> CGFloat {
        let d = min(distanceFromFocus / max(viewportHeight * 0.55, 1), 1)
        let start = isEdgeOrTargetOnly ? 0.05 : lerp(0.78, 0.28, d)
        let end = min(start + 0.22, 1.0)
        return smoothstep(start, end, progress)
    }

    /// SOURCE node alpha during `.changed`: the focus band stays fully opaque (1) — the row under the
    /// pointer never dissolves; OUTSIDE the band the source photo fades per-cell (1 − replacementAlpha),
    /// so there is no opaque source rectangle. (Target-only cells have no source; the caller uses 0.)
    static func sourceNodeAlpha(progress: CGFloat, distanceFromFocus: CGFloat, viewportHeight: CGFloat, inFocusBand: Bool) -> CGFloat {
        if inFocusBand { return 1 }
        return 1 - replacementAlpha(progress: progress, distanceFromFocus: distanceFromFocus, viewportHeight: viewportHeight, isEdgeOrTargetOnly: false)
    }

    /// TARGET node alpha during `.changed`: 0 inside the focus band (the focus stays source); OUTSIDE the
    /// band the target photo fades IN (replacementAlpha), earlier for edge / target-only cells.
    static func targetNodeAlpha(progress: CGFloat, distanceFromFocus: CGFloat, viewportHeight: CGFloat, inFocusBand: Bool, isEdgeOrTargetOnly: Bool) -> CGFloat {
        if inFocusBand { return 0 }
        return replacementAlpha(progress: progress, distanceFromFocus: distanceFromFocus, viewportHeight: viewportHeight, isEdgeOrTargetOnly: isEdgeOrTargetOnly)
    }

    /// Whether a target node's screen position falls in the PROTECTED focus BAND around the pointer
    /// (screen-space). Unlike the source-identity `focusRowUIDs` set, this catches ANY photo that reflows
    /// into the pointer band at the target level — so no target content ever appears next to the pointer
    /// during `.changed`, even photos that were not in the source focus row.
    static func inFocusBand(screenY: CGFloat, anchorY: CGFloat, viewportHeight: CGFloat) -> Bool {
        abs(screenY - anchorY) < focusBandHalfHeight(viewportHeight: viewportHeight)
    }


    /// Group source cell frames into row bands. A band spans the row's full horizontal extent (first
    /// cell minX → last cell maxX) and the row's cell height padded by `gapPad` top+bottom (so adjacent
    /// bands meet and target can't shine through the row gap). Data only — never a drawn rectangle.
    static func sourceRowBands(cellFrames: [CGRect], gapPad: CGFloat) -> [CGRect] {
        let frames = cellFrames.filter { $0.width > 0.5 && $0.height > 0.5 }.sorted { $0.midY < $1.midY }
        guard !frames.isEmpty else { return [] }
        var bands: [CGRect] = []
        var minX = CGFloat.greatestFiniteMagnitude, maxX = -CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        var refMidY = frames[0].midY
        var rowH = frames[0].height
        func flush() {
            guard minX <= maxX else { return }
            bands.append(CGRect(x: minX, y: minY - gapPad, width: maxX - minX, height: (maxY - minY) + 2 * gapPad))
        }
        for f in frames {
            if f.midY - refMidY > rowH * 0.5 {            // a new row started
                flush()
                minX = .greatestFiniteMagnitude; maxX = -.greatestFiniteMagnitude
                minY = .greatestFiniteMagnitude; maxY = -.greatestFiniteMagnitude
            }
            minX = min(minX, f.minX); maxX = max(maxX, f.maxX)
            minY = min(minY, f.minY); maxY = max(maxY, f.maxY)
            refMidY = f.midY; rowH = f.height
        }
        flush()
        return bands
    }

    // MARK: - Ghost alpha (Phase 4 — experimental, off by default)

    // MARK: - Square-fill crop + live target-fill scale

    /// Center-crop inset (fractions of width/height, 0…0.5 per side) to fit `imageSize` into a SQUARE
    /// cell (aspectFill): landscape crops the sides, portrait crops top/bottom.
    static func squareFillCropInset(imageSize: CGSize) -> (x: CGFloat, y: CGFloat) {
        let aspect = imageSize.width / max(imageSize.height, 1)
        return aspect >= 1 ? ((1 - 1 / aspect) * 0.5, 0) : (0, (1 - aspect) * 0.5)
    }

    /// Live scale for the target-fill surface — render the target-level fill cells at the current
    /// apparent thumbnail size so they breathe with the pinch (instead of looking screen-static),
    /// clamped to avoid over-zoom. Returns 1 when the apparent size equals the fill level's cell size.
    static func targetFillScale(apparentSize: CGFloat, fillSize: CGFloat) -> CGFloat {
        max(0.5, min(2.5, apparentSize / max(fillSize, 1)))
    }

    /// Target-BACKDROP alpha for the FULL target surface that sits over the source during a topology
    /// zoom. Unlike a sparse ghost, this is computed for EVERY cell — alpha (not omission) decides
    /// visibility, so missing/low cells never become holes:
    ///  • a cell with no source behind it (outside the on-screen shrunk source block) is OPAQUE (1.0) —
    ///    a real target image is always better than a black edge;
    ///  • a focus-band cell stays ~0 until late `progress` (source stays dominant around the pointer);
    ///  • far bands fade in earlier as `progress` grows.
    static func targetBackdropAlpha(progress: CGFloat, cellCenterY: CGFloat, anchorY: CGFloat, viewportHeight: CGFloat, isOutsideSourceBlock: Bool) -> CGFloat {
        if isOutsideSourceBlock { return 1 }
        let focusBand = focusBandHalfHeight(viewportHeight: viewportHeight)
        let focusDistance = abs(cellCenterY - anchorY)
        if focusDistance < focusBand {
            return progress < 0.72 ? 0 : smoothstep(0.72, 0.95, progress) * 0.35
        }
        let normalized = min(focusDistance / max(viewportHeight * 0.55, 1), 1)
        let start = lerp(0.72, 0.24, normalized)
        return smoothstep(start, start + 0.24, progress)
    }

    static func smoothstep(_ edge0: CGFloat, _ edge1: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - edge0) / max(edge1 - edge0, 0.0001)))
        return t * t * (3 - 2 * t)
    }

    static func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    /// Half-height of the source-stable focus band around the gesture anchor.
    static func focusBandHalfHeight(viewportHeight: CGFloat) -> CGFloat { viewportHeight * 0.18 }

    /// Far-band / edge target-ghost alpha. Rows inside the focus band stay source-only until late
    /// `progress` (≥0.72), then fade a faint ghost; rows farther from the anchor fade their ghost in
    /// earlier, and newly-exposed edge cells (which source cannot cover — e.g. the left/right zoom-out
    /// margins beyond the finite source content width) get an extra boost and may become strong early.
    static func ghostAlpha(progress: CGFloat, rowCenterY: CGFloat, anchorY: CGFloat, viewportHeight: CGFloat, isNewlyExposedEdge: Bool) -> CGFloat {
        let focusBand = focusBandHalfHeight(viewportHeight: viewportHeight)
        let distance = abs(rowCenterY - anchorY)
        // A newly-exposed edge cell has no source behind it at all → fill it regardless of focus band.
        if isNewlyExposedEdge {
            let base = smoothstep(0.0, 0.5, progress)
            return min(1, 0.35 + base * 0.65)
        }
        if distance < focusBand {
            return progress < 0.72 ? 0 : smoothstep(0.72, 0.95, progress) * 0.35
        }
        let normalized = min(distance / max(viewportHeight * 0.55, 1), 1)
        let start = lerp(0.72, 0.24, normalized)
        let end = min(start + 0.24, 1)
        return smoothstep(start, end, progress)
    }

    // MARK: - Visual commit plan (preserve the visible neighborhood, not just the anchor point)

    /// One visible source proxy's "vote" for the committed content-origin Y, weighted by importance
    /// (anchor item ≫ focus band > far). The vote is the originY that would place this proxy's TARGET
    /// frame at the proxy's current on-screen position: `targetDocMidY - sourceScreenMidY`.
    struct OriginVote: Equatable { let value: CGFloat; let weight: CGFloat }

    static func originVote(sourceScreenMidY: CGFloat, targetDocMidY: CGFloat, weight: CGFloat) -> OriginVote {
        OriginVote(value: targetDocMidY - sourceScreenMidY, weight: weight)
    }

    /// Weighted median of origin-Y votes — robust against a few mis-decoded/outlier proxies the way a
    /// weighted mean is not. With the anchor weighted ≫ others, the anchor's vote wins ties, keeping the
    /// committed anchor error bounded while the surrounding votes still pull the neighborhood into place.
    /// Returns nil when there are no positive-weight, finite votes.
    static func weightedMedian(_ votes: [OriginVote]) -> CGFloat? {
        let valid = votes.filter { $0.weight > 0 && $0.value.isFinite }
        guard !valid.isEmpty else { return nil }
        let sorted = valid.sorted { $0.value < $1.value }
        let total = sorted.reduce(CGFloat(0)) { $0 + $1.weight }
        let half = total / 2
        var acc: CGFloat = 0
        for v in sorted {
            acc += v.weight
            if acc >= half { return v.value }
        }
        return sorted.last?.value
    }
}
