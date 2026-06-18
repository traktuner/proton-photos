import AppKit

/// The photo-grid layout with Apple-Photos' **6 discrete zoom levels**. NOTE: ALL six levels are
/// `square: true` (a uniform SQUARE grid) — this is NOT aspect-preserving justified layout. What
/// changes with depth is only how a photo fills its square cell (`Level.cropMode`):
///  • Levels 0–3 (`aspectFit`):  the whole photo, letterboxed inside the square cell, generous gaps.
///  • Levels 4–5 (`squareFill`): center-cropped to fill the square, packed nearly gapless — the dense
///    overview. (True aspect-preserving `square: false` justified rows exist as DEAD code below but are
///    not enabled; don't claim them as active.)
/// Every level is anchored bottom-right (newest photo in the corner; any partial/empty row is the
/// oldest, at the top). Frames are pooled + queried by binary search for 20k+ photos.
///
/// **Smoothness:** row COMPOSITION (which photos share a row / how many columns) is computed only on a
/// semantic change — zoom level, dataset, or learned aspect ratios — and cached. A pure WIDTH change
/// (sidebar sliding, window resize) does NOT recompute the breaks: it keeps the composition and just
/// rescales each row to the new width. So nothing ever pops between rows — the thumbnails scale
/// seamlessly, exactly like Apple's grid. Composition is only rebuilt on a drastic width jump (so
/// thumbnails never grow/shrink absurdly), never during an animation.
final class JustifiedCollectionLayout: NSCollectionViewLayout {

    struct Level {
        let square: Bool
        let size: CGFloat     // justified: row height · square: target side
        let gap: CGFloat
        let monthLabels: Bool
        let cropMode: GridCropMode
    }
    /// Index 0 = most zoomed IN (biggest thumbnails) … 5 = most zoomed OUT.
    // Every level is a UNIFORM SQUARE grid (equal cells aligned in rows AND columns). What changes with
    // depth is how the photo fills the cell:
    //  • levels 0–3 (`aspectFit`)  — letterbox the whole photo (portrait → space left/right). Generous
    //    gaps; the photo is never cropped.
    //  • levels 4–5 (`squareFill`) — center-CROP to fill a square, packed nearly gapless (gap 1), the
    //    dense Apple-style overview. `cropMode` is a RENDER tag only — geometry stays square-uniform, so
    //    projection/commit math is unchanged; only the cell's contents-gravity and the overlay's UV crop
    //    differ. The transition into square-fill is hidden by the source→preview overlay, never a live
    //    reflow of visible cells.
    static let levels: [Level] = [
        Level(square: true, size: 330, gap: 12, monthLabels: false, cropMode: .aspectFit),
        Level(square: true, size: 185, gap: 8,  monthLabels: false, cropMode: .aspectFit),
        Level(square: true, size: 130, gap: 6,  monthLabels: false, cropMode: .aspectFit),
        Level(square: true, size:  95, gap: 4,  monthLabels: false, cropMode: .aspectFit),
        Level(square: true, size:  70, gap: 1,  monthLabels: true,  cropMode: .squareFill),
        Level(square: true, size:  44, gap: 1,  monthLabels: true,  cropMode: .squareFill),
    ]
    static let defaultLevel = 2

    var level: Int = defaultLevel {
        didSet { if oldValue != level { compositionDirty = true; invalidateLayout() } }
    }
    private var cfg: Level { Self.levels[min(max(level, 0), Self.levels.count - 1)] }

    /// Aspect ratio (w/h) per item, per section. Set by the coordinator. Changing it (learned ratios)
    /// marks the composition dirty so the rows re-break once the real ratios are known.
    var sectionAspects: [[CGFloat]] = [] {
        didSet { compositionDirty = true }
    }

    // Pooled attributes (reused across invalidations when the structure is identical).
    private var itemAttrs: [NSCollectionViewLayoutAttributes] = []
    private var itemMinY: [CGFloat] = []
    private var itemMaxY: [CGFloat] = []
    private var sectionFlatStart: [Int] = []
    private var signature: [Int] = []

    // Cached COMPOSITION (recomputed only on semantic change / drastic width jump).
    private var rowRangesPerSection: [[(Int, Int)]] = []   // justified: item-index ranges per row
    private var colsPerSection: [Int] = []                 // square: column count per section
    private var committedWidth: CGFloat = 0
    private var compositionDirty = true

    private var contentHeight: CGFloat = 0
    private var width: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let newWidth = collectionView.bounds.width
        guard newWidth > 1 else { return }

        // Rebuild the pooled attributes when the item structure changes.
        let sig = sectionAspects.map(\.count)
        if sig != signature {
            signature = sig
            compositionDirty = true
            itemAttrs.removeAll(keepingCapacity: true)
            sectionFlatStart.removeAll(keepingCapacity: true)
            var start = 0
            for (section, aspects) in sectionAspects.enumerated() {
                sectionFlatStart.append(start)
                for item in aspects.indices {
                    itemAttrs.append(NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: item, section: section)))
                }
                start += aspects.count
            }
            itemMinY = Array(repeating: 0, count: itemAttrs.count)
            itemMaxY = Array(repeating: 0, count: itemAttrs.count)
        }

        // Recompose ONLY on a semantic change (zoom level / dataset / learned aspect ratios). A pure
        // WIDTH change — window resize OR sidebar slide — keeps the row composition and just rescales,
        // so all photos grow/shrink together smoothly (Apple's behaviour) instead of popping between
        // rows. New rows/cols appear naturally as the viewport reveals more of the rescaled content.
        let needCompose = compositionDirty || rowRangesPerSection.count != sectionAspects.count
        width = newWidth

        if needCompose {
            composeAll()
            committedWidth = newWidth
            compositionDirty = false
        }

        // Geometry pass: place every item using the cached composition at the current width.
        var y: CGFloat = 0
        var flat = 0
        for (section, aspects) in sectionAspects.enumerated() {
            if cfg.square {
                geometrySquare(aspects, base: flat, cols: colsPerSection[section], y: &y)
            } else {
                geometryJustified(aspects, base: flat, ranges: rowRangesPerSection[section], y: &y)
            }
            flat += aspects.count
        }
        contentHeight = y
    }

    // MARK: - Composition (recomputed rarely)

    // NOTE: all 6 `levels` are currently `square: true`, so the `cfg.square == false` branches below —
    // `composeJustified` / `geometryJustified` / `rowRangesPerSection` — are DEAD (unreachable). They're
    // kept as the aspect-preserving "justified rows" fallback in case a non-square level is reintroduced;
    // don't tweak them expecting a visible effect.
    private func composeAll() {
        rowRangesPerSection.removeAll(keepingCapacity: true)
        colsPerSection.removeAll(keepingCapacity: true)
        for aspects in sectionAspects {
            rowRangesPerSection.append(cfg.square ? [] : composeJustified(aspects))
            colsPerSection.append(cfg.square ? composeSquareCols() : 0)
        }
    }

    /// Breaks the section into justified rows from the END backwards, so the bottom row is full and
    /// the newest photo lands bottom-right. Returns item-index ranges (forward order).
    private func composeJustified(_ aspects: [CGFloat]) -> [(Int, Int)] {
        let rowH = cfg.size, gap = cfg.gap
        let n = aspects.count
        var rowRanges: [(Int, Int)] = []
        var end = n
        while end > 0 {
            var sum: CGFloat = 0
            var start = max(end - 1, 0)
            var i = end - 1
            while i >= 0 {
                sum += aspects[i]
                let cnt = end - i
                if sum * rowH + gap * CGFloat(cnt - 1) >= width { start = i; break }
                start = i; i -= 1
            }
            rowRanges.append((start, end))
            end = start
        }
        rowRanges.reverse()
        return rowRanges
    }

    private func composeSquareCols() -> Int {
        max(1, Int((width + cfg.gap) / (cfg.size + cfg.gap)))
    }

    // MARK: - Geometry (recomputed every width change — cheap, no break decisions)

    private func geometryJustified(_ aspects: [CGFloat], base: Int, ranges: [(Int, Int)], y: inout CGFloat) {
        let rowH = cfg.size, gap = cfg.gap
        // Width the composition was broken at — used to tell a FULL row from the loose partial (top)
        // row. A full row must keep filling the width (grow taller when the window is wider, so there's
        // no black bar); only the partial row is capped at rowH so its few photos don't stretch huge.
        let refW = committedWidth > 1 ? committedWidth : width
        for (rowStart, rowEnd) in ranges {
            var sum: CGFloat = 0
            for k in rowStart ..< rowEnd { sum += aspects[k] }
            let gaps = gap * CGFloat(rowEnd - rowStart - 1)
            let justifiedH = (width - gaps) / max(sum, 0.001)
            let isPartial = (refW - gaps) / max(sum, 0.001) > rowH + 0.5
            let h = isPartial ? max(1, min(justifiedH, rowH)) : max(1, justifiedH)
            var x: CGFloat = 0
            for k in rowStart ..< rowEnd {
                let fi = base + k
                let w = aspects[k] * h
                itemAttrs[fi].frame = NSRect(x: x, y: y, width: w, height: h)
                itemMinY[fi] = y; itemMaxY[fi] = y + h
                x += w + gap
            }
            y += h + gap
        }
    }

    /// Uniform square grid (aspect-fill cells) with a fixed column count; the top-left slots are left
    /// empty so the bottom row is full and the newest photo lands bottom-right.
    private func geometrySquare(_ aspects: [CGFloat], base: Int, cols: Int, y: inout CGFloat) {
        let gap = cfg.gap
        let cols = max(1, cols)
        let side = (width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        let n = aspects.count
        guard n > 0 else { return }
        let rows = (n + cols - 1) / cols
        let emptyTopLeft = rows * cols - n
        for k in 0 ..< n {
            let slot = emptyTopLeft + k
            let row = slot / cols, col = slot % cols
            let fi = base + k
            let x = CGFloat(col) * (side + gap)
            let yy = y + CGFloat(row) * (side + gap)
            itemAttrs[fi].frame = NSRect(x: x, y: yy, width: side, height: side)
            itemMinY[fi] = yy; itemMaxY[fi] = yy + side
        }
        y += CGFloat(rows) * (side + gap)
    }

    override var collectionViewContentSize: NSSize { NSSize(width: width, height: max(contentHeight, 1)) }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        guard !itemAttrs.isEmpty else { return [] }
        var result: [NSCollectionViewLayoutAttributes] = []
        var lo = 0, hi = itemMaxY.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if itemMaxY[mid] < rect.minY { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < itemAttrs.count, itemMinY[i] <= rect.maxY {
            result.append(itemAttrs[i])
            i += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section < sectionFlatStart.count else { return nil }
        let flat = sectionFlatStart[indexPath.section] + indexPath.item
        guard flat >= 0, flat < itemAttrs.count else { return nil }
        return itemAttrs[flat]
    }

    // MARK: - Projection for GPU-backed zoom transitions

    /// Computes the square-grid content size for an arbitrary zoom level without mutating the live
    /// collection-view layout. This keeps the pinch preview independent from AppKit relayout work.
    func projectedContentSize(level projectedLevel: Int, width projectedWidth: CGFloat) -> NSSize {
        let config = Self.levels[min(max(projectedLevel, 0), Self.levels.count - 1)]
        guard config.square, projectedWidth > 1 else { return collectionViewContentSize }
        let metrics = squareMetrics(config: config, width: projectedWidth)
        var height: CGFloat = 0
        for aspects in sectionAspects {
            let rows = (aspects.count + metrics.cols - 1) / metrics.cols
            height += CGFloat(rows) * (metrics.side + config.gap)
        }
        return NSSize(width: projectedWidth, height: max(height, 1))
    }

    /// Computes one item's frame for an arbitrary square-grid zoom level without invalidating the
    /// live layout.
    func projectedFrameForItem(at indexPath: IndexPath, level projectedLevel: Int, width projectedWidth: CGFloat) -> NSRect? {
        let config = Self.levels[min(max(projectedLevel, 0), Self.levels.count - 1)]
        guard config.square, projectedWidth > 1, indexPath.section < sectionAspects.count else {
            return level == projectedLevel ? layoutAttributesForItem(at: indexPath)?.frame : nil
        }
        let metrics = squareMetrics(config: config, width: projectedWidth)
        var sectionY: CGFloat = 0
        for section in 0 ..< indexPath.section {
            let rows = (sectionAspects[section].count + metrics.cols - 1) / metrics.cols
            sectionY += CGFloat(rows) * (metrics.side + config.gap)
        }
        let count = sectionAspects[indexPath.section].count
        guard indexPath.item >= 0, indexPath.item < count else { return nil }
        let rows = (count + metrics.cols - 1) / metrics.cols
        let emptyTopLeft = rows * metrics.cols - count
        let slot = emptyTopLeft + indexPath.item
        let row = slot / metrics.cols
        let col = slot % metrics.cols
        return NSRect(
            x: CGFloat(col) * (metrics.side + config.gap),
            y: sectionY + CGFloat(row) * (metrics.side + config.gap),
            width: metrics.side,
            height: metrics.side
        )
    }

    /// Computes visible item frames for an arbitrary square-grid zoom level without touching
    /// `itemAttrs`. Runtime is proportional to visible rows, not total library size.
    func projectedFramesForElements(in rect: NSRect, level projectedLevel: Int, width projectedWidth: CGFloat) -> [(IndexPath, NSRect)] {
        let config = Self.levels[min(max(projectedLevel, 0), Self.levels.count - 1)]
        guard config.square, projectedWidth > 1 else {
            return level == projectedLevel
                ? layoutAttributesForElements(in: rect).compactMap { attr in attr.indexPath.map { ($0, attr.frame) } }
                : []
        }
        let metrics = squareMetrics(config: config, width: projectedWidth)
        var result: [(IndexPath, NSRect)] = []
        var sectionY: CGFloat = 0
        for (section, aspects) in sectionAspects.enumerated() {
            let count = aspects.count
            let rows = (count + metrics.cols - 1) / metrics.cols
            let sectionHeight = CGFloat(rows) * (metrics.side + config.gap)
            let sectionRect = NSRect(x: 0, y: sectionY, width: projectedWidth, height: sectionHeight)
            defer { sectionY += sectionHeight }
            guard count > 0, sectionRect.intersects(rect) else { continue }

            let firstRow = max(0, Int(floor((rect.minY - sectionY) / max(metrics.side + config.gap, 1))) - 1)
            let lastRow = min(rows - 1, Int(floor((rect.maxY - sectionY) / max(metrics.side + config.gap, 1))) + 1)
            guard firstRow <= lastRow else { continue }

            let emptyTopLeft = rows * metrics.cols - count
            for row in firstRow ... lastRow {
                for col in 0 ..< metrics.cols {
                    let slot = row * metrics.cols + col
                    let item = slot - emptyTopLeft
                    guard item >= 0, item < count else { continue }
                    let frame = NSRect(
                        x: CGFloat(col) * (metrics.side + config.gap),
                        y: sectionY + CGFloat(row) * (metrics.side + config.gap),
                        width: metrics.side,
                        height: metrics.side
                    )
                    if frame.intersects(rect) {
                        result.append((IndexPath(item: item, section: section), frame))
                    }
                }
            }
        }
        return result
    }

    private func squareMetrics(config: Level, width projectedWidth: CGFloat) -> (cols: Int, side: CGFloat) {
        let cols = max(1, Int((projectedWidth + config.gap) / (config.size + config.gap)))
        let side = (projectedWidth - config.gap * CGFloat(cols - 1)) / CGFloat(cols)
        return (cols, side)
    }

    // MARK: - Grid Zoom V2: day-sectioned projection for an ARBITRARY column count (commit == renderer)

    /// The SAME day-sectioned square geometry as `projectedFramesForElements(in:level:)`, but for an
    /// explicit `cols`/`gap` (a continuous-zoom topology) rather than a discrete level. V2 renders the live
    /// overlay from THIS and commits the real grid at the same column count → the two are identical by
    /// construction, so there is no reveal pop. Runtime ∝ visible rows, not library size.
    func projectedFramesForElements(in rect: NSRect, cols: Int, gap: CGFloat, width: CGFloat) -> [(IndexPath, NSRect)] {
        let c = max(1, cols)
        let side = (width - gap * CGFloat(c - 1)) / CGFloat(c)
        var result: [(IndexPath, NSRect)] = []
        var sectionY: CGFloat = 0
        for (section, aspects) in sectionAspects.enumerated() {
            let count = aspects.count
            let rows = (count + c - 1) / c
            let sectionHeight = CGFloat(rows) * (side + gap)
            let sectionRect = NSRect(x: 0, y: sectionY, width: width, height: sectionHeight)
            defer { sectionY += sectionHeight }
            guard count > 0, sectionRect.intersects(rect) else { continue }
            let firstRow = max(0, Int(floor((rect.minY - sectionY) / max(side + gap, 1))) - 1)
            let lastRow = min(rows - 1, Int(floor((rect.maxY - sectionY) / max(side + gap, 1))) + 1)
            guard firstRow <= lastRow else { continue }
            let emptyTopLeft = rows * c - count
            for row in firstRow ... lastRow {
                for col in 0 ..< c {
                    let item = row * c + col - emptyTopLeft
                    guard item >= 0, item < count else { continue }
                    let frame = NSRect(x: CGFloat(col) * (side + gap), y: sectionY + CGFloat(row) * (side + gap), width: side, height: side)
                    if frame.intersects(rect) { result.append((IndexPath(item: item, section: section), frame)) }
                }
            }
        }
        return result
    }

    /// One item's day-sectioned frame for an explicit column count (V2). Matches the committed grid exactly.
    func projectedFrameForItem(at indexPath: IndexPath, cols: Int, gap: CGFloat, width: CGFloat) -> NSRect? {
        let c = max(1, cols)
        guard indexPath.section < sectionAspects.count else { return nil }
        let side = (width - gap * CGFloat(c - 1)) / CGFloat(c)
        var sectionY: CGFloat = 0
        for s in 0 ..< indexPath.section {
            sectionY += CGFloat((sectionAspects[s].count + c - 1) / c) * (side + gap)
        }
        let count = sectionAspects[indexPath.section].count
        guard indexPath.item >= 0, indexPath.item < count else { return nil }
        let rows = (count + c - 1) / c
        let slot = (rows * c - count) + indexPath.item
        return NSRect(x: CGFloat(slot % c) * (side + gap), y: sectionY + CGFloat(slot / c) * (side + gap), width: side, height: side)
    }

    /// Total day-sectioned content height for an explicit column count (V2).
    func projectedContentSize(cols: Int, gap: CGFloat, width: CGFloat) -> NSSize {
        let c = max(1, cols)
        let side = (width - gap * CGFloat(c - 1)) / CGFloat(c)
        var height: CGFloat = 0
        for aspects in sectionAspects {
            height += CGFloat((aspects.count + c - 1) / c) * (side + gap)
        }
        return NSSize(width: width, height: max(height, 1))
    }

    /// The day-sectioned column count for a discrete level at the given width (the V2 detents are these).
    func columnCount(forLevel level: Int, width: CGFloat) -> Int {
        squareMetrics(config: Self.levels[min(max(level, 0), Self.levels.count - 1)], width: width).cols
    }

    /// Only re-justify when the WIDTH changes — never on vertical scroll. (A width change rescales the
    /// cached composition; it does not re-break rows unless something semantic changed.)
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != width
    }
}
