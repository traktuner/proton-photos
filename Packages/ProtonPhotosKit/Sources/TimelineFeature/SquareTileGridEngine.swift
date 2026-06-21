import CoreGraphics

// MARK: - SquareTileGridEngine — the single canonical owner of ALL timeline grid geometry
//
// THE GRID IS THE PRODUCT. Photos/videos are payload inside grid slots.
//
// This engine is the ONE place grid geometry is resolved. It owns the FULL timeline grid geometry:
//   • section order + per-section item counts
//   • section top offsets, optional section header rects, inter-section spacing
//   • column count, square slot side, gap, pitch (per level, dynamic gap)
//   • row/column mapping inside each section
//   • globalIndex ⇄ (section, item) mapping
//   • content size
//   • visible slot query + visible header (supplementary) query
//   • hit testing
//   • zoom metrics (continuous apparent slot size / gap) + anchor preservation
//   • resize behaviour (columns recompute from width so the grid always fills the viewport)
//
// No coordinator, renderer, thumbnail loader, or transition code may compute independent grid positions,
// gaps, pitch, columns, or section offsets. If a visible cell, header, or gap is wrong, the fix is HERE or
// in the level metrics — never in the renderer. The renderer only converts the returned `GridFramePlan`
// into quads.
//
// The thumbnail DISPLAY mode (how a photo fills its square) is explicitly NOT here — that is `TileContentFitter`.
// The engine never sees media aspect; a slot's geometry is identical regardless of payload.
//
// Geometry is self-contained (pure value-type math), so the whole grid is unit-testable without a GPU.

/// One zoom level's nominal metrics. `slotSide` is the TARGET square side; the actually-rendered side is
/// recomputed per width so the grid fills the viewport exactly. `gap` is the inter-slot spacing and may
/// differ per level (dynamic gap). `headerHeight`/`interSectionSpacing` let the engine reserve section
/// header space + spacing (0 = labels float over the grid, the production default). `pitch == slotSide + gap`.
public struct GridLevelMetrics: Equatable, Sendable {
    public let levelID: Int
    public let slotSide: CGFloat
    public let gap: CGFloat
    public let headerHeight: CGFloat
    public let interSectionSpacing: CGFloat
    public let monthLabels: Bool

    public var pitch: CGFloat { slotSide + gap }

    public init(levelID: Int, slotSide: CGFloat, gap: CGFloat, monthLabels: Bool,
                headerHeight: CGFloat = 0, interSectionSpacing: CGFloat = 0) {
        self.levelID = levelID
        self.slotSide = slotSide
        self.gap = gap
        self.monthLabels = monthLabels
        self.headerHeight = headerHeight
        self.interSectionSpacing = interSectionSpacing
    }
}

/// One square slot in the resolved grid. The OUTER rect (`slotRect` / `viewportRect`) is ALWAYS square and
/// is the single authority for layout, outer-tile rendering, hit testing, selection, visible queries,
/// scroll/content size and zoom geometry. `row` is the slot's row WITHIN its section; `column` is the grid
/// column (shared across sections). Media aspect must never change any of this — the thumbnail fits INSIDE
/// `slotRect` via `TileContentFitter`.
public struct GridSlot: Equatable, Sendable {
    public let index: Int          // flat / global (library-order) index
    public let section: Int
    public let item: Int           // item index within the section
    public let column: Int         // grid column (0-based)
    public let row: Int            // row within the section (0-based)
    public let slotRect: CGRect    // square, content space (y down, origin at top of library)
    public let viewportRect: CGRect

    public init(index: Int, section: Int, item: Int, column: Int, row: Int, slotRect: CGRect, viewportRect: CGRect) {
        self.index = index
        self.section = section
        self.item = item
        self.column = column
        self.row = row
        self.slotRect = slotRect
        self.viewportRect = viewportRect
    }
}

/// A section's header (supplementary) geometry. `headerRect` spans the full width at the section's top; its
/// height is the level's `headerHeight` (0 when labels float over the grid). The label TEXT is a data
/// concern supplied by the app — the engine owns only the rect.
public struct GridSectionHeader: Equatable, Sendable {
    public let section: Int
    public let headerRect: CGRect     // content space
    public let viewportRect: CGRect

    public init(section: Int, headerRect: CGRect, viewportRect: CGRect) {
        self.section = section
        self.headerRect = headerRect
        self.viewportRect = viewportRect
    }
}

/// Per-frame diagnostics — what the engine resolved this frame. Pure data; never an input to layout.
public struct GridDebugInfo: Equatable, Sendable {
    public let levelID: Int
    public let continuousLevel: CGFloat
    public let columns: Int
    public let slotSide: CGFloat
    public let gap: CGFloat
    public let pitch: CGFloat
    public let contentSize: CGSize
    public let visibleSlotCount: Int
    public let sectionCount: Int
}

/// The complete renderable plan for ONE frame. The renderer converts `visibleSlots`/`visibleHeaders` to
/// quads; it invents nothing. `slotSide`/`gap`/`pitch`/`columns` describe the RESOLVED grid (the grid that
/// actually fills the width at this frame's metrics).
public struct GridFramePlan: Equatable, Sendable {
    public let levelID: Int
    public let columns: Int
    public let slotSide: CGFloat
    public let gap: CGFloat
    public let contentSize: CGSize
    public let viewportRect: CGRect
    public let visibleSlots: [GridSlot]
    public let visibleHeaders: [GridSectionHeader]
    public let debug: GridDebugInfo

    public var pitch: CGFloat { slotSide + gap }
}

/// What the app/coordinator sends the engine each frame. `continuousLevel == nil` → a settled integer
/// `level` with free user scroll (`scrollOffset`). `continuousLevel != nil` → a live pinch: the engine
/// resolves apparent metrics for the fractional level and computes the anchored scroll offset itself.
public struct GridEngineInput: Equatable, Sendable {
    public let viewportSize: CGSize
    public let scrollOffset: CGPoint
    public let overscan: CGFloat
    public let level: Int
    public let continuousLevel: CGFloat?
    public let anchor: GridZoomAnchor?

    public init(viewportSize: CGSize, scrollOffset: CGPoint, overscan: CGFloat,
                level: Int, continuousLevel: CGFloat? = nil, anchor: GridZoomAnchor? = nil) {
        self.viewportSize = viewportSize
        self.scrollOffset = scrollOffset
        self.overscan = overscan
        self.level = level
        self.continuousLevel = continuousLevel
        self.anchor = anchor
    }
}

/// The fixed point a live zoom holds: the item under the cursor (or a content fraction over a gap) is kept
/// under `viewportPoint` as the grid metrics change.
public struct GridZoomAnchor: Equatable, Sendable {
    public let flatIndex: Int?
    public let viewportPoint: CGPoint
    public let contentFractionY: CGFloat
    public let relInCell: CGPoint

    public init(flatIndex: Int?, viewportPoint: CGPoint, contentFractionY: CGFloat, relInCell: CGPoint) {
        self.flatIndex = flatIndex
        self.viewportPoint = viewportPoint
        self.contentFractionY = contentFractionY
        self.relInCell = relInCell
    }
}

// MARK: - The engine

public struct SquareTileGridEngine: Equatable, Sendable {
    /// Section order is the array order; element = that section's item count (section 0 first/top).
    public let sectionCounts: [Int]
    /// The SINGLE source of truth for grid density — one square ladder, one place to retune.
    public let levels: [GridLevelMetrics]

    /// Flat index of the first item of each section (prefix sum), and the library total.
    private let sectionFlatStart: [Int]
    public let totalItems: Int

    public init(sectionCounts: [Int], levels: [GridLevelMetrics] = SquareTileGridEngine.defaultLevels) {
        self.sectionCounts = sectionCounts
        self.levels = levels.isEmpty ? SquareTileGridEngine.defaultLevels : levels
        var starts: [Int] = []
        starts.reserveCapacity(sectionCounts.count)
        var running = 0
        for c in sectionCounts { starts.append(running); running += max(c, 0) }
        self.sectionFlatStart = starts
        self.totalItems = running
    }

    public var levelCount: Int { levels.count }
    /// Opens at the comfortable medium density (slotSide 140), which is index 3 in the default ladder
    /// (after the larger level 0 was prepended). Clamped for custom ladders.
    public var defaultLevel: Int { min(3, levels.count - 1) }
    public var sectionCount: Int { sectionCounts.count }

    public func clampLevel(_ l: Int) -> Int { min(max(l, 0), levels.count - 1) }
    public func metrics(level: Int) -> GridLevelMetrics { levels[clampLevel(level)] }

    /// The canonical square ladder: square `slotSide` (target) + first-class per-level `gap` (14 → 2,
    /// clearly dynamic), `monthLabels` on the dense overview. Headers float (headerHeight 0), as production
    /// shows them today. This is the ONE table; retuning the grid is a one-place edit.
    public static let defaultLevels: [GridLevelMetrics] = [
        GridLevelMetrics(levelID: 0, slotSide: 380, gap: 16, monthLabels: false), // NEW largest — fewer, bigger tiles
        GridLevelMetrics(levelID: 1, slotSide: 260, gap: 14, monthLabels: false),
        GridLevelMetrics(levelID: 2, slotSide: 190, gap: 12, monthLabels: false),
        GridLevelMetrics(levelID: 3, slotSide: 140, gap: 10, monthLabels: false), // default density
        GridLevelMetrics(levelID: 4, slotSide: 100, gap: 7,  monthLabels: false),
        GridLevelMetrics(levelID: 5, slotSide: 72,  gap: 4,  monthLabels: true),
        GridLevelMetrics(levelID: 6, slotSide: 48,  gap: 2,  monthLabels: true),
    ]

    // MARK: globalIndex ⇄ (section, item)

    public func globalIndex(section: Int, item: Int) -> Int? {
        guard section >= 0, section < sectionCounts.count, item >= 0, item < sectionCounts[section] else { return nil }
        return sectionFlatStart[section] + item
    }

    public func sectionItem(globalIndex flat: Int) -> (section: Int, item: Int)? {
        guard flat >= 0, flat < totalItems else { return nil }
        var lo = 0, hi = sectionFlatStart.count - 1, section = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if sectionFlatStart[mid] <= flat { section = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return (section, flat - sectionFlatStart[section])
    }

    // MARK: - Resolved section layout (the geometry kernel — pure)

    /// The fully-resolved grid for one set of metrics + width: column count, exact (width-filling) square
    /// side, and per-section top offsets / header rects / rows. Everything else is a query against this.
    struct ResolvedGrid: Equatable {
        let columns: Int
        let slotSide: CGFloat
        let gap: CGFloat
        let headerHeight: CGFloat
        let interSectionSpacing: CGFloat
        let width: CGFloat
        let sectionCounts: [Int]
        let sectionFlatStart: [Int]
        let sectionHeaderTop: [CGFloat]    // y of the section header's top
        let sectionContentTop: [CGFloat]   // y of the section's first grid row
        let sectionRows: [Int]
        let sectionEmptyTopLeft: [Int]      // leading empty slots per section (wrap phase)
        let sectionHeight: [CGFloat]        // header + rows*pitch (matches a uniform step grid)
        let contentHeight: CGFloat

        var pitch: CGFloat { slotSide + gap }
        var contentSize: CGSize { CGSize(width: width, height: contentHeight) }

        /// Square frame + placement of a global index. The wrap phase is `sectionEmptyTopLeft` (default
        /// bottom-right: the partial/empty row is the OLDEST, at the top; a live-zoom commit may instead set
        /// it so the focus item keeps its cursor column — see `SquareTileGridEngine.columnPhase`).
        func placement(globalIndex flat: Int) -> (rect: CGRect, section: Int, item: Int, row: Int, column: Int)? {
            guard let (section, item) = sectionItem(flat) else { return nil }
            let emptyTopLeft = sectionEmptyTopLeft[section]
            let slot = emptyTopLeft + item
            let row = slot / columns, col = slot % columns
            let rect = CGRect(x: CGFloat(col) * pitch, y: sectionContentTop[section] + CGFloat(row) * pitch,
                              width: slotSide, height: slotSide)
            return (rect, section, item, row, col)
        }

        private func sectionItem(_ flat: Int) -> (Int, Int)? {
            guard flat >= 0, !sectionCounts.isEmpty else { return nil }
            let total = sectionFlatStart[sectionFlatStart.count - 1] + sectionCounts[sectionCounts.count - 1]
            guard flat < total else { return nil }
            var lo = 0, hi = sectionFlatStart.count - 1, section = 0
            while lo <= hi {
                let mid = (lo + hi) / 2
                if sectionFlatStart[mid] <= flat { section = mid; lo = mid + 1 } else { hi = mid - 1 }
            }
            return (section, flat - sectionFlatStart[section])
        }

        /// Square slots intersecting `rect` (content coords). Runtime ∝ visible rows.
        func visibleSlots(in rect: CGRect, viewportOrigin: CGPoint) -> [GridSlot] {
            guard pitch > 0 else { return [] }
            var result: [GridSlot] = []
            for (section, count) in sectionCounts.enumerated() where count > 0 {
                let top = sectionHeaderTop[section]
                let h = sectionHeight[section]
                guard top < rect.maxY, top + h > rect.minY else { continue }
                let contentTop = sectionContentTop[section]
                let rows = sectionRows[section]
                let emptyTopLeft = sectionEmptyTopLeft[section]
                let base = sectionFlatStart[section]
                let firstRow = max(0, Int(floor((rect.minY - contentTop) / pitch)) - 1)
                let lastRow = min(rows - 1, Int(floor((rect.maxY - contentTop) / pitch)) + 1)
                guard firstRow <= lastRow else { continue }
                for row in firstRow ... lastRow {
                    for col in 0 ..< columns {
                        let slot = row * columns + col
                        let item = slot - emptyTopLeft
                        guard item >= 0, item < count else { continue }
                        let frame = CGRect(x: CGFloat(col) * pitch, y: contentTop + CGFloat(row) * pitch,
                                           width: slotSide, height: slotSide)
                        guard frame.intersects(rect) else { continue }
                        let vp = CGRect(x: frame.minX - viewportOrigin.x, y: frame.minY - viewportOrigin.y,
                                        width: frame.width, height: frame.height)
                        result.append(GridSlot(index: base + item, section: section, item: item,
                                               column: col, row: row, slotRect: frame, viewportRect: vp))
                    }
                }
            }
            return result
        }

        /// Section headers whose band intersects `rect` (content coords). For floating labels (headerHeight
        /// 0) a header is "visible" when its top sits within the query band.
        func visibleHeaders(in rect: CGRect, viewportOrigin: CGPoint) -> [GridSectionHeader] {
            var result: [GridSectionHeader] = []
            for section in sectionCounts.indices where sectionCounts[section] > 0 {
                let topY = sectionHeaderTop[section]
                let headerRect = CGRect(x: 0, y: topY, width: width, height: headerHeight)
                let visible = headerHeight > 0
                    ? headerRect.intersects(rect)
                    : (topY >= rect.minY - pitch && topY <= rect.maxY)
                guard visible else { continue }
                let vp = CGRect(x: -viewportOrigin.x, y: topY - viewportOrigin.y, width: width, height: headerHeight)
                result.append(GridSectionHeader(section: section, headerRect: headerRect, viewportRect: vp))
            }
            return result
        }

        func hitTest(_ point: CGPoint) -> GridSlot? {
            let probe = CGRect(x: point.x, y: point.y, width: 0.001, height: 0.001)
            for slot in visibleSlots(in: probe, viewportOrigin: .zero) where slot.slotRect.contains(point) {
                return slot
            }
            return nil
        }
    }

    /// Build the resolved grid for a set of metrics + width. Column count + exact width-filling side are
    /// derived here (one rule), so the grid ALWAYS fills the width and the rendered side is uniform & square.
    /// `columnPhase` (single continuous section only): the leading-empty-slot count P so the wrap aligns the
    /// grid to a chosen column (a live-zoom commit sets it so the focus item keeps its cursor column → the
    /// commit is seamless, no rephase jump). nil = the default bottom-right wrap (newest in the corner).
    func resolved(targetSide: CGFloat, gap: CGFloat, headerHeight: CGFloat, interSectionSpacing: CGFloat,
                  width: CGFloat, columnPhase: Int? = nil) -> ResolvedGrid {
        let w = max(width, 1)
        let g = max(gap, 0)
        let target = max(targetSide, 1)
        let columns = max(1, Int((w + g) / (target + g)))
        let side = (w - g * CGFloat(columns - 1)) / CGFloat(columns)
        let pitch = side + g
        let singleSection = sectionCounts.count == 1
        var headerTop = [CGFloat](repeating: 0, count: sectionCounts.count)
        var contentTop = [CGFloat](repeating: 0, count: sectionCounts.count)
        var rowsArr = [Int](repeating: 0, count: sectionCounts.count)
        var emptyArr = [Int](repeating: 0, count: sectionCounts.count)
        var heightArr = [CGFloat](repeating: 0, count: sectionCounts.count)
        var y: CGFloat = 0
        for (s, count) in sectionCounts.enumerated() {
            headerTop[s] = y
            contentTop[s] = y + headerHeight
            let emptyTopLeft: Int
            let rows: Int
            if singleSection, let phase = columnPhase, count > 0 {
                emptyTopLeft = ((phase % columns) + columns) % columns       // wrap phase 0…cols-1
                rows = (count + emptyTopLeft + columns - 1) / columns
            } else {
                rows = count > 0 ? (count + columns - 1) / columns : 0
                emptyTopLeft = rows * columns - count                        // bottom-right (default)
            }
            rowsArr[s] = rows
            emptyArr[s] = emptyTopLeft
            let h = headerHeight + CGFloat(rows) * pitch        // trailing gap separates sections (matches uniform step grid)
            heightArr[s] = h
            y += h + interSectionSpacing
        }
        let contentHeight = max(y - interSectionSpacing, 1)
        return ResolvedGrid(columns: columns, slotSide: side, gap: g, headerHeight: headerHeight,
                            interSectionSpacing: interSectionSpacing, width: w, sectionCounts: sectionCounts,
                            sectionFlatStart: sectionFlatStart, sectionHeaderTop: headerTop,
                            sectionContentTop: contentTop, sectionRows: rowsArr, sectionEmptyTopLeft: emptyArr,
                            sectionHeight: heightArr, contentHeight: contentHeight)
    }

    private func resolvedForLevel(_ level: Int, width: CGFloat, columnPhase: Int? = nil) -> ResolvedGrid {
        let m = metrics(level: level)
        return resolved(targetSide: m.slotSide, gap: m.gap, headerHeight: m.headerHeight,
                        interSectionSpacing: m.interSectionSpacing, width: width, columnPhase: columnPhase)
    }

    // MARK: Frame plans

    /// The renderable plan for a settled level at the given viewport + scroll offset. `columnPhase` (single
    /// continuous run) aligns the wrap so a committed live-zoom focus item keeps its cursor column.
    public func framePlan(level: Int, viewportSize: CGSize, scrollOffset: CGPoint, overscan: CGFloat, columnPhase: Int? = nil) -> GridFramePlan {
        let lv = clampLevel(level)
        let grid = resolvedForLevel(lv, width: viewportSize.width, columnPhase: columnPhase)
        return plan(grid: grid, levelID: lv, continuousLevel: CGFloat(lv),
                    viewportSize: viewportSize, scrollOffset: scrollOffset, overscan: overscan)
    }

    /// Apparent-metrics plan for a fractional level. NOTE: this RE-RESOLVES columns from the apparent slot
    /// size every call, so a continuous sweep rewraps flat indices at every column-count threshold — visually
    /// discontinuous. It is therefore NOT used by the production pinch (Option A is detent-only). It remains
    /// as a building block for the future engine-owned `GridZoomTransaction` (Option B), which must wrap it
    /// in source/target topology continuity rather than calling it per frame.
    public func zoomFramePlan(continuousLevel x: CGFloat, viewportSize: CGSize, anchor: GridZoomAnchor, overscan: CGFloat) -> GridFramePlan {
        let baseLevel = clampLevel(Int(x.rounded()))
        let side = apparentSlotSide(at: x)
        let gap = apparentGap(at: x)
        let m = metrics(level: baseLevel)
        let grid = resolved(targetSide: side, gap: gap, headerHeight: m.headerHeight,
                            interSectionSpacing: m.interSectionSpacing, width: viewportSize.width)
        let offset = anchoredScrollOffset(grid: grid, anchor: anchor)
        return plan(grid: grid, levelID: baseLevel, continuousLevel: x,
                    viewportSize: viewportSize, scrollOffset: offset, overscan: overscan)
    }

    private func plan(grid: ResolvedGrid, levelID: Int, continuousLevel: CGFloat,
                      viewportSize: CGSize, scrollOffset: CGPoint, overscan: CGFloat) -> GridFramePlan {
        let viewportRect = CGRect(origin: scrollOffset, size: viewportSize)
        let minY = max(0, viewportRect.minY - overscan)
        let maxY = min(max(grid.contentHeight, viewportRect.maxY), viewportRect.maxY + overscan)
        let query = CGRect(x: viewportRect.minX, y: minY, width: viewportRect.width, height: max(0, maxY - minY))
        let slots = grid.visibleSlots(in: query, viewportOrigin: scrollOffset)
        let headers = grid.visibleHeaders(in: query, viewportOrigin: scrollOffset)
        let debug = GridDebugInfo(levelID: levelID, continuousLevel: continuousLevel, columns: grid.columns,
                                  slotSide: grid.slotSide, gap: grid.gap, pitch: grid.pitch,
                                  contentSize: grid.contentSize, visibleSlotCount: slots.count,
                                  sectionCount: sectionCounts.count)
        return GridFramePlan(levelID: levelID, columns: grid.columns, slotSide: grid.slotSide, gap: grid.gap,
                             contentSize: grid.contentSize, viewportRect: viewportRect,
                             visibleSlots: slots, visibleHeaders: headers, debug: debug)
    }

    // MARK: Single-item / section queries (settled level)

    public func contentSize(level: Int, width: CGFloat, columnPhase: Int? = nil) -> CGSize {
        resolvedForLevel(level, width: width, columnPhase: columnPhase).contentSize
    }

    /// One item's square content-space frame at a settled level (nil if out of range).
    public func slotRect(flatIndex: Int, level: Int, width: CGFloat, columnPhase: Int? = nil) -> CGRect? {
        resolvedForLevel(level, width: width, columnPhase: columnPhase).placement(globalIndex: flatIndex)?.rect
    }

    /// The section's header rect at a settled level (full width × headerHeight at the section top).
    public func sectionHeaderRect(section: Int, level: Int, width: CGFloat) -> CGRect? {
        let grid = resolvedForLevel(level, width: width)
        guard section >= 0, section < grid.sectionHeaderTop.count else { return nil }
        return CGRect(x: 0, y: grid.sectionHeaderTop[section], width: grid.width, height: grid.headerHeight)
    }

    /// The content-space Y where a section's first grid row begins.
    public func sectionTop(section: Int, level: Int, width: CGFloat) -> CGFloat? {
        let grid = resolvedForLevel(level, width: width)
        guard section >= 0, section < grid.sectionContentTop.count else { return nil }
        return grid.sectionContentTop[section]
    }

    /// Resolved (columns, side, gap, pitch) for a settled level at a width.
    public func resolvedMetrics(level: Int, width: CGFloat) -> (columns: Int, slotSide: CGFloat, gap: CGFloat, pitch: CGFloat) {
        let grid = resolvedForLevel(level, width: width)
        return (grid.columns, grid.slotSide, grid.gap, grid.pitch)
    }

    /// Hit test a CONTENT-space point at a settled level → the slot under it (nil for a gap/empty slot/header).
    /// Uses the SQUARE slotRect, never an inner content rect.
    public func hitTest(contentPoint: CGPoint, level: Int, width: CGFloat, columnPhase: Int? = nil) -> GridSlot? {
        resolvedForLevel(level, width: width, columnPhase: columnPhase).hitTest(contentPoint)
    }

    /// (section, item, row, column) of a global index at a settled level (row is section-local).
    public func locate(flatIndex: Int, level: Int, width: CGFloat) -> (section: Int, item: Int, row: Int, column: Int)? {
        guard let p = resolvedForLevel(level, width: width).placement(globalIndex: flatIndex) else { return nil }
        return (p.section, p.item, p.row, p.column)
    }

    /// The global index at a section-local (row, column) at a settled level, or nil for an empty slot.
    public func flatIndex(section: Int, row: Int, column: Int, level: Int, width: CGFloat) -> Int? {
        let grid = resolvedForLevel(level, width: width)
        guard section >= 0, section < sectionCounts.count, row >= 0, column >= 0, column < grid.columns else { return nil }
        let count = sectionCounts[section]
        let rows = grid.sectionRows[section]
        guard row < rows else { return nil }
        let emptyTopLeft = rows * grid.columns - count
        let slot = row * grid.columns + column
        let item = slot - emptyTopLeft
        guard item >= 0, item < count else { return nil }
        return sectionFlatStart[section] + item
    }

    // MARK: Apparent metrics (continuous zoom — engine-owned)

    /// The apparent square slot size for a continuous level position `x`, including the soft rubber-band:
    /// within the ladder it interpolates the bracketing detents; past the largest end it grows with
    /// diminishing return; past the densest end it clamps (never over-shrink below fill).
    public func apparentSlotSide(at x: CGFloat) -> CGFloat {
        let maxIndex = levels.count - 1
        if x <= 0 { return levels[0].slotSide * (1 - x * 0.6) }
        if x >= CGFloat(maxIndex) { return levels[maxIndex].slotSide }
        let lo = Int(x)
        return lerp(levels[lo].slotSide, levels[lo + 1].slotSide, smoothstep(x - CGFloat(lo)))
    }

    /// The apparent gap for a continuous level position (first-class: scales smoothly through the pinch).
    public func apparentGap(at x: CGFloat) -> CGFloat {
        let maxIndex = levels.count - 1
        if x <= 0 { return levels[0].gap }
        if x >= CGFloat(maxIndex) { return levels[maxIndex].gap }
        let lo = Int(x)
        return lerp(levels[lo].gap, levels[lo + 1].gap, smoothstep(x - CGFloat(lo)))
    }

    // MARK: Anchor preservation

    private func anchoredScrollOffset(grid: ResolvedGrid, anchor: GridZoomAnchor) -> CGPoint {
        let anchorContentY: CGFloat
        if let item = anchor.flatIndex, let p = grid.placement(globalIndex: item) {
            anchorContentY = p.rect.minY + anchor.relInCell.y * p.rect.height
        } else {
            anchorContentY = anchor.contentFractionY * grid.contentHeight
        }
        return CGPoint(x: 0, y: anchorContentY - anchor.viewportPoint.y)
    }

    /// The settled scroll offset Y that keeps an anchor under a viewport point at a final level (used by the
    /// host to re-anchor after a commit). Clamps are applied by the caller.
    public func anchoredScrollOffsetY(flatIndex: Int?, relInCellY: CGFloat, contentFractionY: CGFloat,
                                      viewportPointY: CGFloat, level: Int, width: CGFloat) -> CGFloat {
        let grid = resolvedForLevel(level, width: width)
        let anchorContentY: CGFloat
        if let item = flatIndex, let p = grid.placement(globalIndex: item) {
            anchorContentY = p.rect.minY + relInCellY * p.rect.height
        } else {
            anchorContentY = contentFractionY * grid.contentHeight
        }
        return anchorContentY - viewportPointY
    }

    // MARK: Logical anchor capture (item-based, section-aware)

    /// The logical zoom anchor near a content point: the item UNDER it, or the nearest item if the point is
    /// over a gap/header. Returns the item's global index, its (section, item), its slot rect at the current
    /// metrics, and the point's local fraction within that slot (0…1). nil only for an empty library.
    ///
    /// The anchor IDENTITY is the ITEM (section + item / global index), never a raw y — so it survives
    /// slotSide / gap / column-count / row / section-offset changes during a zoom. The engine rebases the
    /// scroll offset from this item's NEW slot rect at every apparent metric.
    public func anchorItem(nearContentPoint point: CGPoint, level: Int, width: CGFloat, columnPhase: Int? = nil)
        -> (flatIndex: Int, section: Int, item: Int, slotRect: CGRect, localFraction: CGPoint)? {
        let grid = resolvedForLevel(level, width: width, columnPhase: columnPhase)
        if let hit = grid.hitTest(point) {
            return (hit.index, hit.section, hit.item, hit.slotRect, Self.localFraction(of: point, in: hit.slotRect))
        }
        // Over a gap/header → the nearest visible slot in a band around the point's row.
        let band = CGRect(x: 0, y: point.y - grid.pitch * 2, width: max(width, 1), height: grid.pitch * 4)
        let candidates = grid.visibleSlots(in: band, viewportOrigin: .zero)
        if let nearest = candidates.min(by: { Self.distanceSquared(point, $0.slotRect) < Self.distanceSquared(point, $1.slotRect) }) {
            return (nearest.index, nearest.section, nearest.item, nearest.slotRect, Self.localFraction(of: point, in: nearest.slotRect))
        }
        return nil
    }

    /// The scroll offset that places anchor item `flatIndex`'s local point back under `viewportPoint` at the
    /// given metrics — the explicit "rebase from the item, never from raw scrollOffset" used by the
    /// coordinator + tests. Vertical grid: x scroll is always 0 (the grid fills the width).
    public func anchoredScrollOffset(flatIndex: Int, localFraction: CGPoint, viewportPoint: CGPoint, level: Int, width: CGFloat, columnPhase: Int? = nil) -> CGPoint {
        let grid = resolvedForLevel(level, width: width, columnPhase: columnPhase)
        guard let p = grid.placement(globalIndex: flatIndex) else { return .zero }
        let y = p.rect.minY + localFraction.y * p.rect.height - viewportPoint.y
        return CGPoint(x: 0, y: y)
    }

    /// The wrap phase (leading empty slots) that lands global index `forItem` in column `targetColumn` at a
    /// given level/width — used so a settled grid after a live-zoom commit keeps the focus item's cursor
    /// column (seamless commit). Single continuous run only.
    public func columnPhase(forItem item: Int, targetColumn: Int, level: Int, width: CGFloat) -> Int {
        let cols = resolvedForLevel(level, width: width).columns
        return ((targetColumn - item) % cols + cols) % cols
    }

    /// THE engine-owned anchor-capture + rebase for a DISCRETE level change: resolve the item under the
    /// cursor at `sourceLevel`, then return the scroll Y at `targetLevel` that keeps that SAME item under the
    /// SAME viewport point (zoom directed toward the cursor — the Apple rule). This is NOT a top-viewport
    /// anchor; the cursor's item is held, wherever it is in the viewport. nil only for an empty library.
    /// (The coordinator passes view width + the current scroll origin; the engine owns the logic.)
    public func cursorAnchoredScrollOffsetY(levelChangeFrom sourceLevel: Int, to targetLevel: Int, width: CGFloat,
                                            cursorContentPoint: CGPoint, sourceScrollOriginY: CGFloat) -> CGFloat? {
        guard let a = anchorItem(nearContentPoint: cursorContentPoint, level: sourceLevel, width: width) else { return nil }
        let cursorViewportY = cursorContentPoint.y - sourceScrollOriginY
        return anchoredScrollOffset(flatIndex: a.flatIndex, localFraction: a.localFraction,
                                    viewportPoint: CGPoint(x: 0, y: cursorViewportY), level: targetLevel, width: width).y
    }

    private static func localFraction(of point: CGPoint, in rect: CGRect) -> CGPoint {
        guard rect.width > 0, rect.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(max((point.x - rect.minX) / rect.width, 0), 1),
                       y: min(max((point.y - rect.minY) / rect.height, 0), 1))
    }
    private static func distanceSquared(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let cx = min(max(p.x, r.minX), r.maxX), cy = min(max(p.y, r.minY), r.maxY)
        let dx = p.x - cx, dy = p.y - cy
        return dx * dx + dy * dy
    }
}

// MARK: - Pure easing helpers (free functions so the engine stays a pure value type)

private func clamp01(_ x: CGFloat) -> CGFloat { min(max(x, 0), 1) }
private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
private func smoothstep(_ x: CGFloat) -> CGFloat { let t = clamp01(x); return t * t * (3 - 2 * t) }
