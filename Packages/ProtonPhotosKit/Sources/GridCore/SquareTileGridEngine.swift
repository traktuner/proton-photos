import CoreGraphics

// MARK: - SquareTileGridEngine - the single canonical owner of ALL timeline grid geometry
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
//   • resize behaviour (FIXED-COLUMNS + WIDTH-FILL: each level HOLDS its `nominalColumns`; the square tile is
//     sized to FILL the viewport width exactly (no trailing gutter), so a width change SCALES the tile - a wider
//     window shows the SAME columns at a LARGER tile. The column count changes ONLY on a zoom, NEVER on resize.
//     A live resize/sidebar drag presents this as a uniform snapshot scale in the platform presentation layer.)
//
// No coordinator, renderer, thumbnail loader, or transition code may compute independent grid positions,
// gaps, pitch, columns, or section offsets. If a visible cell, header, or gap is wrong, the fix is HERE or
// in the level metrics - never in the renderer. The renderer only converts the returned `GridFramePlan`
// into quads.
//
// The thumbnail DISPLAY mode (how a photo fills its square) is explicitly NOT here - that is `TileContentFitter`.
// The engine never sees media aspect; a slot's geometry is identical regardless of payload.
//
// Geometry is self-contained (pure value-type math), so the whole grid is unit-testable without a GPU.

/// One zoom level's nominal metrics. `slotSide` is the TARGET square side; the actually-rendered side is
/// recomputed per width so the grid fills the viewport exactly. `gap` is the inter-slot spacing and may
/// differ per level (dynamic gap). `headerHeight`/`interSectionSpacing` let the engine reserve section
/// header space + spacing (0 = labels float over the grid, the production default). `pitch == slotSide + gap`.
/// How two adjacent levels transition. STORED CLASSIFICATION ONLY - the engine stays pure geometry; the visual
/// transition EFFECTS that consume this classification live OUTSIDE the engine (the continuous-pinch transition
/// layer + the overview dissolve). The engine itself animates nothing.
public enum GridTransitionKind: String, Equatable, Sendable {
    /// Normal photo↔photo levels: the focus row re-lays-out (the cursor-anchored zoom we already ship).
    case focusRowRelayout
    /// Last normal photo level → first dense square overview (a larger re-layout / "warp").
    case overviewWarp
    /// Within the dense square overview: zoom between the two overview densities.
    case denseOverviewZoom
}

public enum GridLevelSemanticRole: String, Equatable, Sendable {
    /// Regular photo/video thumbnails. They may be shown aspect-fit or square-cropped inside the square slot.
    case aspectThumbnail
    /// Dense overview levels. They are square-fill-only and typically carry date labels.
    case squareOverview
}

public extension GridTransitionKind {
    static func semantic(from lower: GridLevelSemanticRole, to upper: GridLevelSemanticRole) -> GridTransitionKind? {
        switch (lower, upper) {
        case (.aspectThumbnail, .aspectThumbnail):
            return .focusRowRelayout
        case (.aspectThumbnail, .squareOverview):
            return .overviewWarp
        case (.squareOverview, .squareOverview):
            return .denseOverviewZoom
        case (.squareOverview, .aspectThumbnail):
            return nil
        }
    }
}

/// One Apple-like zoom level. FIXED-COLUMNS MODEL: each level HOLDS its `nominalColumns` as the runtime column
/// count; the square slot is sized to FILL the width, so a wider viewport shows the SAME columns at a LARGER
/// tile (a uniform width-scale, not a column reflow). `nominalColumns` is the runtime column source AND the
/// density seed. (A size-based / adaptive-columns variant was explored - see `GridSizePolicy` /
/// `referenceSlotSide` - but is NOT the adopted runtime rule; the settled resolve forces `nominalColumns`.)
public struct AppleGridLevelSpec: Equatable, Sendable {
    public let id: Int
    public let nominalColumns: Int
    public let gap: CGFloat
    public let supportedContentModes: Set<TileContentDisplayMode>
    public let defaultContentMode: TileContentDisplayMode
    public let transitionKindToNext: GridTransitionKind?   // nil = last level (no next)
    public let monthLabels: Bool

    public init(id: Int, nominalColumns: Int, gap: CGFloat, supportedContentModes: Set<TileContentDisplayMode>,
                defaultContentMode: TileContentDisplayMode, transitionKindToNext: GridTransitionKind?, monthLabels: Bool) {
        self.id = id; self.nominalColumns = nominalColumns; self.gap = gap
        self.supportedContentModes = supportedContentModes; self.defaultContentMode = defaultContentMode
        self.transitionKindToNext = transitionKindToNext; self.monthLabels = monthLabels
    }
}

public struct GridLevelMetrics: Equatable, Sendable {
    public let levelID: Int
    /// The runtime column count for this level (FIXED per level) AND the density seed for `referenceSlotSide`.
    /// FIXED-COLUMNS: the settled resolve holds this count and fills the width, so the column count changes only
    /// on a zoom, never on a resize.
    public let nominalColumns: Int
    public let gap: CGFloat
    public let headerHeight: CGFloat
    public let interSectionSpacing: CGFloat
    public let monthLabels: Bool
    public let supportedContentModes: Set<TileContentDisplayMode>
    public let defaultContentMode: TileContentDisplayMode
    public let transitionKindToNext: GridTransitionKind?

    /// SIZE-BASED SCAFFOLDING (NOT the adopted model): a per-level reference photo side for an adaptive-columns
    /// model that was explored but NOT adopted. The shipping settled resolve is FIXED-COLUMNS - `resolvedForLevel`
    /// passes `fixedColumns: nominalColumns`, which OVERRIDES this `targetSide` - so this value is computed and
    /// passed but does NOT drive the settled column count. Retained as calibration + the seam for a possible
    /// future responsive size-class pass; `GridSizePolicy` documents the same.
    public var referenceSlotSide: CGFloat {
        GridSizePolicy.slotSide(nominalColumns: nominalColumns, gap: gap, sizeClass: .regular)
    }

    public var semanticRole: GridLevelSemanticRole {
        supportedContentModes.contains(.aspectFitInsideSquare) ? .aspectThumbnail : .squareOverview
    }

    public init(levelID: Int, nominalColumns: Int, gap: CGFloat, monthLabels: Bool,
                supportedContentModes: Set<TileContentDisplayMode> = [.squareFillCrop],
                defaultContentMode: TileContentDisplayMode = .squareFillCrop,
                transitionKindToNext: GridTransitionKind? = nil,
                headerHeight: CGFloat = 0, interSectionSpacing: CGFloat = 0) {
        self.levelID = levelID
        self.nominalColumns = nominalColumns
        self.gap = gap
        self.monthLabels = monthLabels
        self.supportedContentModes = supportedContentModes
        self.defaultContentMode = defaultContentMode
        self.transitionKindToNext = transitionKindToNext
        self.headerHeight = headerHeight
        self.interSectionSpacing = interSectionSpacing
    }
}

/// A named density ladder for a class of available viewport, not for a device family. Platform adapters may map
/// UIKit/AppKit/SwiftUI traits to one of these profiles, but the core grid stays scene-size driven and does not
/// know about a concrete operating system, orientation, or device idiom.
public struct GridLevelProfile: Equatable, Sendable {
    public let id: String
    public let levels: [GridLevelMetrics]
    public let defaultLevel: Int

    public init(id: String, levels: [GridLevelMetrics], defaultLevel: Int) {
        precondition(!levels.isEmpty, "GridLevelProfile requires at least one level")
        precondition(defaultLevel >= 0 && defaultLevel < levels.count, "GridLevelProfile defaultLevel is out of range")
        self.id = id
        self.levels = levels
        self.defaultLevel = defaultLevel
    }

    public func clampLevel(_ level: Int) -> Int { min(max(level, 0), levels.count - 1) }
    public func metrics(level: Int) -> GridLevelMetrics { levels[clampLevel(level)] }
    public func showsMonthLabels(level: Int) -> Bool { metrics(level: level).monthLabels }
}

/// One square slot in the resolved grid. The OUTER rect (`slotRect` / `viewportRect`) is ALWAYS square and
/// is the single authority for layout, outer-tile rendering, hit testing, selection, visible queries,
/// scroll/content size and zoom geometry. `row` is the slot's row WITHIN its section; `column` is the grid
/// column (shared across sections). Media aspect must never change any of this - the thumbnail fits INSIDE
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
/// concern supplied by the app - the engine owns only the rect.
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

    public var pitch: CGFloat { slotSide + gap }
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
    /// The SINGLE source of truth for grid density - one square ladder, one place to retune.
    public let levels: [GridLevelMetrics]
    private let configuredDefaultLevel: Int

    /// Flat index of the first item of each section (prefix sum), and the library total.
    private let sectionFlatStart: [Int]
    public let totalItems: Int

    /// A top layout margin (points) added ABOVE the first section so the first row rests below the window's
    /// translucent toolbar instead of being tucked under it. Baked into the layout ORIGIN (every section / slot /
    /// header Y shifts down by it) AND into `contentHeight`, so the scroll coordinate stays natural - the host's
    /// existing `max(0, …)` pin/clamp math is untouched; the first row simply lands at viewport-y `topInset` when
    /// scrolled to the top. Default 0 (engine geometry tests + standalone callers are unaffected); production
    /// adapters set it to the toolbar/safe-area height plumbed from their host view.
    public var topInset: CGFloat = 0

    public init(sectionCounts: [Int], levels: [GridLevelMetrics], defaultLevel: Int) {
        precondition(!levels.isEmpty, "SquareTileGridEngine requires at least one grid level")
        precondition(defaultLevel >= 0 && defaultLevel < levels.count, "SquareTileGridEngine defaultLevel is out of range")
        self.sectionCounts = sectionCounts
        self.levels = levels
        self.configuredDefaultLevel = defaultLevel
        var starts: [Int] = []
        starts.reserveCapacity(sectionCounts.count)
        var running = 0
        for c in sectionCounts { starts.append(running); running += max(c, 0) }
        self.sectionFlatStart = starts
        self.totalItems = running
    }

    public init(sectionCounts: [Int], profile: GridLevelProfile) {
        self.init(sectionCounts: sectionCounts, levels: profile.levels, defaultLevel: profile.defaultLevel)
    }

    public var levelCount: Int { levels.count }
    /// Opens at the comfortable medium density (level 3 = 9 columns; the width-filled side is ~135pt at the
    /// 1280 reference width). Clamped for custom ladders.
    public var defaultLevel: Int { configuredDefaultLevel }
    public var sectionCount: Int { sectionCounts.count }

    public func clampLevel(_ l: Int) -> Int { min(max(l, 0), levels.count - 1) }
    public func metrics(level: Int) -> GridLevelMetrics { levels[clampLevel(level)] }

    /// The transition kind for the ADJACENT step between `a` and `b` (keyed off the lower level's
    /// `transitionKindToNext`). nil if the two levels are not adjacent (`|a-b| != 1`). Pure.
    public func adjacentTransitionKind(_ a: Int, _ b: Int) -> GridTransitionKind? {
        guard abs(a - b) == 1 else { return nil }
        return metrics(level: min(a, b)).transitionKindToNext
    }

    public func derivedTransitionKindToNext(level: Int) -> GridTransitionKind? {
        let lower = clampLevel(level)
        guard lower < levelCount - 1 else { return nil }
        return GridTransitionKind.semantic(
            from: metrics(level: lower).semanticRole,
            to: metrics(level: lower + 1).semanticRole
        )
    }

    /// Whether the adjacent step `a↔b` crosses an OVERVIEW boundary (`.overviewWarp` = last normal → first
    /// dense overview, or `.denseOverviewZoom` = between the two dense overviews). These are the boundaries the
    /// V3.10 overview WARP owns; the normal-level `.focusRowRelayout` steps stay on the accepted V3.9 pinch.
    public func isOverviewBoundary(_ a: Int, _ b: Int) -> Bool {
        switch adjacentTransitionKind(a, b) {
        case .overviewWarp, .denseOverviewZoom: return true
        default: return false
        }
    }

    /// THE content-mode policy (single source of truth, used by the coordinator AND tests): the user's
    /// preferred mode where the level supports it, else the forced `squareFillCrop` (the only mode the dense
    /// overview levels L4–L5 offer). Pure - it reads only the level's `supportedContentModes`.
    public func effectiveContentMode(preferred: TileContentDisplayMode, level: Int) -> TileContentDisplayMode {
        metrics(level: level).supportedContentModes.contains(preferred) ? preferred : .squareFillCrop
    }

    /// Whether the aspect/square toggle is meaningful at a level (both modes supported → the normal levels L0–L3).
    public func contentModeToggleAvailable(level: Int) -> Bool { metrics(level: level).supportedContentModes.count > 1 }

    /// The SIX Apple-like zoom levels, keyed by density (nominalColumns) - the canonical spec (video + the
    /// user-confirmed macOS-Photos ladder ~3/5/7/9/20+/30+). L0–L3 are normal photo levels (both content modes
    /// supported; default `aspectFitInsideSquare` = media preserves aspect INSIDE the square slot, the observed
    /// Apple "All Photos" look - toggleable to squareFillCrop); L4–L5 are dense square overviews (squareFillCrop
    /// only, month/year labels). The SLOTS are always square. FIXED-COLUMNS, WIDTH-FILLING: each level HOLDS its
    /// `nominalColumns` and the square slot is sized to FILL the width - so a width change SCALES the tile (same
    /// columns, larger tile when wider), never a gutter and never a column reflow. Transition kinds are a stored
    /// classification consumed by the transition-effect layer outside the engine; the engine animates nothing.
    public static let appleLevelSpecs: [AppleGridLevelSpec] = [
        AppleGridLevelSpec(id: 0, nominalColumns: 3,  gap: 16, supportedContentModes: [.aspectFitInsideSquare, .squareFillCrop], defaultContentMode: .aspectFitInsideSquare, transitionKindToNext: .focusRowRelayout,  monthLabels: false),
        AppleGridLevelSpec(id: 1, nominalColumns: 5,  gap: 12, supportedContentModes: [.aspectFitInsideSquare, .squareFillCrop], defaultContentMode: .aspectFitInsideSquare, transitionKindToNext: .focusRowRelayout,  monthLabels: false),
        AppleGridLevelSpec(id: 2, nominalColumns: 7,  gap: 10, supportedContentModes: [.aspectFitInsideSquare, .squareFillCrop], defaultContentMode: .aspectFitInsideSquare, transitionKindToNext: .focusRowRelayout,  monthLabels: false),
        AppleGridLevelSpec(id: 3, nominalColumns: 9,  gap: 8,  supportedContentModes: [.aspectFitInsideSquare, .squareFillCrop], defaultContentMode: .aspectFitInsideSquare, transitionKindToNext: .overviewWarp,      monthLabels: false), // default density
        AppleGridLevelSpec(id: 4, nominalColumns: 20, gap: 2,  supportedContentModes: [.squareFillCrop],                         defaultContentMode: .squareFillCrop,        transitionKindToNext: .denseOverviewZoom, monthLabels: true),
        AppleGridLevelSpec(id: 5, nominalColumns: 30, gap: 1,  supportedContentModes: [.squareFillCrop],                         defaultContentMode: .squareFillCrop,        transitionKindToNext: nil,                 monthLabels: true),
    ]

    /// The width-filling square side for a column count + gap - the resolution-independent slot size. Levels
    /// are defined by columns; this derives the pixel side at the CURRENT width: `(width − gap·(cols−1))/cols`.
    /// Feeding this back into the column-from-side resolve returns exactly `columns`, so the live-zoom lattice
    /// is unchanged while levels become resolution-independent.
    public static func nominalSlotSide(columns: Int, gap: CGFloat, width: CGFloat) -> CGFloat {
        let c = CGFloat(max(1, columns)); let g = max(0, gap); let w = max(1, width)
        return max(1, (w - g * (c - 1)) / c)
    }

    /// Pick the column count whose width-FILLING tile size is CLOSEST to the target `side` (round to nearest),
    /// with an optional hard cap. NOTE: this is NOT the settled production rule - the settled resolve AND the live
    /// lattice's integer DETENTS both HOLD each level's `nominalColumns` (fixed-columns). This round rule runs
    /// ONLY for the live pinch OVER-ZOOM (the between-detent / past-the-end extrapolation), where the column count
    /// is genuinely derived from the apparent size.
    ///
    /// ROUND (nearest), not floor: where this rule IS used the grid FILLS the width - the sub-column remainder is
    /// re-distributed INTO the tiles (a small size change), never left as a trailing gutter. Floor would keep the
    /// tile at exactly `side` and leak the remainder as blank up to one whole pitch (≈ a full empty tile at the
    /// largest levels - the rejected "huge gutter" state). See `nominalSlotSide`, which `resolved()` pairs with
    /// this to size the tile. Min 1 column. When `maxColumns` binds, the surplus width is margin, never a stretch.
    public static func columnsForFixedSide(side: CGFloat, gap: CGFloat, width: CGFloat, maxColumns: Int? = nil) -> Int {
        let s = max(1, side), g = max(0, gap), w = max(1, width)
        let fit = max(1, Int(((w + g) / (s + g)).rounded()))
        return min(maxColumns ?? Int.max, fit)
    }

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

    // MARK: - Resolved section layout (the geometry kernel - pure)

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

        /// Square frame + placement of a global index. The wrap phase is `sectionEmptyTopLeft`: bottom-right
        /// anchoring, so the partial/empty row is the OLDEST, at the section's top-left.
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
            let estimatedRows = max(1, Int(ceil(rect.height / pitch)) + 3)
            result.reserveCapacity(estimatedRows * columns)
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
            result.reserveCapacity(sectionCounts.count)
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
    ///
    /// `columnPhase` is the engine-owned COLUMN PHASE (single continuous section only): the count of leading
    /// empty slots before item 0, i.e. `column(globalIndex) = (columnPhase + globalIndex) % columns`. It lets
    /// a zoom commit land the anchor item in the cursor's column so the photo under the cursor does NOT fly
    /// across the grid on release (`SquareTileGridEngine.columnPhase(forItem:targetColumn:…)` derives it).
    /// `nil` = the default BOTTOM-RIGHT anchoring: newest item in the corner, the only partial row is the
    /// OLDEST at the top-left, no black on the right of the last row. With a cursor-aligned phase the partial
    /// row instead splits between the oldest (top-left) and newest (bottom-right) ends - see the report.
    func resolved(targetSide: CGFloat, gap: CGFloat, headerHeight: CGFloat, interSectionSpacing: CGFloat,
                  width: CGFloat, columnPhase: Int? = nil, fixedColumns: Int? = nil, maxColumns: Int? = nil) -> ResolvedGrid {
        let w = max(width, 1)
        let g = max(gap, 0)
        let target = max(targetSide, 1)
        // WIDTH-FILLING resolve with two column-source branches:
        //  • `fixedColumns` given (the SETTLED + live-detent path): hold that column count and size the square slot
        //    to FILL the width (`nominalSlotSide` = `(w − gap·(cols−1))/cols`). This is the PRODUCTION model -
        //    `resolvedForLevel` passes `fixedColumns: nominalColumns`, so a width change SCALES the tile (same
        //    columns), never a column reflow.
        //  • `fixedColumns == nil` (the live pinch OVER-ZOOM only): the count is `columnsForFixedSide` (round to
        //    the nearest count whose width-filling tile is closest to `target`). NO settled caller takes this
        //    branch - it exists for the lattice's past-the-end extrapolation.
        // Either branch fills the width exactly (no trailing gutter).
        let columns: Int
        let side: CGFloat
        if let fc = fixedColumns {
            columns = max(1, fc)
            side = Self.nominalSlotSide(columns: columns, gap: g, width: w)
        } else {
            columns = Self.columnsForFixedSide(side: target, gap: g, width: w, maxColumns: maxColumns)
            side = Self.nominalSlotSide(columns: columns, gap: g, width: w)
        }
        let pitch = side + g
        let singleSection = sectionCounts.count == 1
        var headerTop = [CGFloat](repeating: 0, count: sectionCounts.count)
        var contentTop = [CGFloat](repeating: 0, count: sectionCounts.count)
        var rowsArr = [Int](repeating: 0, count: sectionCounts.count)
        var emptyArr = [Int](repeating: 0, count: sectionCounts.count)
        var heightArr = [CGFloat](repeating: 0, count: sectionCounts.count)
        var y: CGFloat = topInset                              // top margin so row 0 clears the translucent toolbar
        for (s, count) in sectionCounts.enumerated() {
            headerTop[s] = y
            contentTop[s] = y + headerHeight
            let rows: Int, emptyTopLeft: Int
            if singleSection, let phase = columnPhase, count > 0 {
                emptyTopLeft = ((phase % columns) + columns) % columns       // cursor-aligned wrap (0…cols-1)
                rows = (count + emptyTopLeft + columns - 1) / columns
            } else {
                rows = count > 0 ? (count + columns - 1) / columns : 0
                emptyTopLeft = rows * columns - count                        // bottom-right anchoring (default)
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
        // FIXED-COLUMNS model: each level HOLDS its `nominalColumns` and the tile FILLS the width. So a width
        // change (window resize / sidebar) SCALES the tiles and NEVER reflows - the column count changes ONLY on
        // a zoom (level change). The pinch lattice (`apparentSlotSide`) routes through the same `nominalColumns`,
        // so the live + settled grids stay in lock-step at every detent (the commit seam closes, no size pop).
        return resolved(targetSide: m.referenceSlotSide, gap: m.gap, headerHeight: m.headerHeight,
                        interSectionSpacing: m.interSectionSpacing, width: width, columnPhase: columnPhase,
                        fixedColumns: m.nominalColumns)
    }

    // MARK: Frame plans

    /// The renderable plan for a settled level at the given viewport + scroll offset.
    public func framePlan(level: Int, viewportSize: CGSize, scrollOffset: CGPoint, overscan: CGFloat, columnPhase: Int? = nil) -> GridFramePlan {
        let lv = clampLevel(level)
        let grid = resolvedForLevel(lv, width: viewportSize.width, columnPhase: columnPhase)
        return plan(grid: grid, levelID: lv, continuousLevel: CGFloat(lv),
                    viewportSize: viewportSize, scrollOffset: scrollOffset, overscan: overscan)
    }

    /// Apparent-metrics plan for a fractional level. NOTE: this RE-RESOLVES columns from the apparent slot
    /// size every call, so a continuous sweep rewraps flat indices at every column-count threshold - visually
    /// discontinuous. It is therefore NOT used by the production pinch. The engine-owned live zoom
    /// (`GridZoomTransaction`) already exists and computes its own anchor-relative layout WITHOUT calling this;
    /// this method is now exercised only by engine unit tests.
    public func zoomFramePlan(continuousLevel x: CGFloat, viewportSize: CGSize, anchor: GridZoomAnchor, overscan: CGFloat) -> GridFramePlan {
        let baseLevel = clampLevel(Int(x.rounded()))
        let side = apparentSlotSide(at: x, width: viewportSize.width)
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
        return GridFramePlan(levelID: levelID, columns: grid.columns, slotSide: grid.slotSide, gap: grid.gap,
                             contentSize: grid.contentSize, viewportRect: viewportRect,
                             visibleSlots: slots, visibleHeaders: headers)
    }

    // MARK: Single-item / section queries (settled level)

    public func contentSize(level: Int, width: CGFloat, columnPhase: Int? = nil) -> CGSize {
        resolvedForLevel(level, width: width, columnPhase: columnPhase).contentSize
    }

    /// Clamp a vertical scroll offset into the real content bounds for a settled level/phase. Transition builders
    /// must use this before constructing an endpoint frame: the rendered endpoint and the post-release committed
    /// grid must share the exact same scroll Y, including at library edges where cursor anchoring is impossible.
    public func clampScrollOffsetY(_ y: CGFloat, level: Int, width: CGFloat,
                                   viewportHeight: CGFloat, columnPhase: Int? = nil) -> CGFloat {
        let maxY = max(0, contentSize(level: level, width: width, columnPhase: columnPhase).height - viewportHeight)
        return min(max(0, y), maxY)
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

    /// Every slot whose SQUARE cell INTERSECTS a CONTENT-space rect - drives marquee (drag-rectangle) selection.
    public func slots(intersecting contentRect: CGRect, level: Int, width: CGFloat, columnPhase: Int? = nil) -> [GridSlot] {
        resolvedForLevel(level, width: width, columnPhase: columnPhase)
            .visibleSlots(in: contentRect, viewportOrigin: .zero)
            .filter { $0.slotRect.intersects(contentRect) }
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

    // MARK: Apparent metrics (continuous zoom - engine-owned)

    /// The apparent square slot size for a continuous level position `x`, including the soft rubber-band:
    /// within the ladder it interpolates the bracketing detents; past the largest end it grows with
    /// diminishing return; past the densest end it clamps (never over-shrink below fill).
    public func apparentSlotSide(at x: CGFloat, width: CGFloat) -> CGFloat {
        let maxIndex = levels.count - 1
        // The per-level WIDTH-FILLED side at this width - the EXACT side the settled grid resolves to for that
        // level (`resolvedForLevel`, FIXED-COLUMNS). Interpolating these makes an integer detent's apparent size
        // equal the settled size, so the pinch commit lands with no size pop (the seam closes at every width).
        func side(_ i: Int) -> CGFloat {
            Self.nominalSlotSide(columns: levels[i].nominalColumns, gap: levels[i].gap, width: width)
        }
        if x <= 0 { return side(0) * (1 - x * 0.6) }
        if x >= CGFloat(maxIndex) { return side(maxIndex) }
        let lo = Int(x)
        return lerp(side(lo), side(lo + 1), smoothstep(x - CGFloat(lo)))
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
                                      viewportPointY: CGFloat, level: Int, width: CGFloat, columnPhase: Int? = nil) -> CGFloat {
        let grid = resolvedForLevel(level, width: width, columnPhase: columnPhase)
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
    /// The anchor IDENTITY is the ITEM (section + item / global index), never a raw y - so it survives
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
    /// given metrics - the explicit "rebase from the item, never from raw scrollOffset" used by the
    /// coordinator + tests. Vertical grid: x scroll is always 0 (the grid fills the width).
    public func anchoredScrollOffset(flatIndex: Int, localFraction: CGPoint, viewportPoint: CGPoint, level: Int, width: CGFloat, columnPhase: Int? = nil) -> CGPoint {
        let grid = resolvedForLevel(level, width: width, columnPhase: columnPhase)
        guard let p = grid.placement(globalIndex: flatIndex) else { return .zero }
        let y = p.rect.minY + localFraction.y * p.rect.height - viewportPoint.y
        return CGPoint(x: 0, y: y)
    }

    // MARK: Column phase (cursor-anchor-preserving commit)

    /// The COLUMN PHASE (leading-empty-slot count) that lands global index `item` in `targetColumn` at the
    /// given level/width - single continuous run only. Feed the result as `columnPhase:` to the settled
    /// queries so the committed grid keeps the anchor in the cursor's column (no horizontal fly on release).
    public func columnPhase(forItem item: Int, targetColumn: Int, level: Int, width: CGFloat) -> Int {
        let cols = resolvedMetrics(level: level, width: width).columns
        return ((targetColumn - item) % cols + cols) % cols
    }

    /// The column the cursor's viewport x falls in at a settled level (clamped to the grid). The phase a zoom
    /// commits to is `columnPhase(forItem: anchor, targetColumn: cursorColumn(...))` - so the anchor settles
    /// exactly where the live transaction held it.
    public func cursorColumn(viewportX: CGFloat, level: Int, width: CGFloat) -> Int {
        let m = resolvedMetrics(level: level, width: width)
        guard m.pitch > 0 else { return 0 }
        return min(max(Int(viewportX / m.pitch), 0), m.columns - 1)
    }

    /// THE engine-owned anchor-capture + rebase for a DISCRETE level change: resolve the item under the
    /// cursor at `sourceLevel`, then return the scroll Y at `targetLevel` that keeps that SAME item under the
    /// SAME viewport point (zoom directed toward the cursor - the Apple rule). This is NOT a top-viewport
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
