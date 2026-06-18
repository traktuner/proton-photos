// ContinuousPhotoWallLayoutEngine.swift  —  GridZoomV3 Lab (Phase 2)
//
// PURE, deterministic layout engine for the V3 grid-zoom prototype. NO AppKit, NO Metal, NO Proton data.
//
// ─────────────────────────────────────────────────────────────────────────────────────────────────────
// THE MENTAL MODEL (single source of truth — must match the prompt):
//   • There is ONE global photo wall. Tiles are laid out in a uniform grid in a stable order.
//   • The viewport is only a CAMERA looking into that wall (a content offset).
//   • Pinch changes a single continuous scalar `apparentCellSize`. The wall BREATHES because the cell
//     size IS that scalar — between column flips nothing reflows, the cells just grow/shrink smoothly.
//   • `columnCount` is a PURE function of `apparentCellSize` (a `floor` of a monotone expression), so it
//     changes by at most ONE column as `apparentCellSize` crosses a threshold — never a far jump.
//   • The six zoom levels are ONLY resting/snap detents (see WallZoomDirector). This engine NEVER takes
//     a detent / snapLevel as input for live geometry — only `apparentCellSize`.
//   • Pinch-in and pinch-out are the IDENTICAL computation; only the direction `apparentCellSize` moves
//     differs.
//
// A tile's SCREEN rect is its fixed doc rect minus the camera offset — a pure translation of the one
// layout rect. It is NEVER `lerp(oldRect, newRect, progress)`. Identity == one rect in one layout.
// ─────────────────────────────────────────────────────────────────────────────────────────────────────

import CoreGraphics

/// Stable identity of a tile. In the prototype these are synthetic ("T0001") so motion/identity bugs are
/// obvious; in production they would be Proton photo UIDs. The order of `orderedUIDs` is the wall order and
/// never changes during a gesture.
public typealias TileUID = String

/// How a tile's image is fitted inside its (square) cell. The GRID geometry (cell rects) is identical
/// across crop modes at the same column count — only the IMAGE rect inside the cell differs. That is what
/// makes an aspectFit↔squareFill change a pure alpha "crop rebase" with no tile movement (CropModeRebaseTest).
public enum WallCropMode: Equatable, Sendable {
    /// Large/near levels: the whole image is shown, letterboxed to its intrinsic aspect inside the cell,
    /// with a visible inter-cell gap. (`aspectFit` and `aspectPreserve` behave identically on square cells;
    /// both are kept so the production crop vocabulary maps 1:1.)
    case aspectFit
    case aspectPreserve
    /// Dense/far levels: the image fills the square cell (centre-crop), near-gapless mosaic.
    case squareFill

    public var fillsCell: Bool { self == .squareFill }
}

public enum ContinuousPhotoWallLayoutEngine {

    // MARK: - Input

    /// Everything the engine needs to produce one deterministic layout. The engine is a pure function of
    /// this struct — same input ⇒ byte-identical output.
    public struct Config: Sendable {
        public var orderedUIDs: [TileUID]
        /// Intrinsic aspect (width / height) per tile, used ONLY for the letterboxed `imageRect` in
        /// aspect modes. Missing ⇒ 1.0 (square). Never affects the cell grid (uniform).
        public var aspectByUID: [TileUID: CGFloat]
        public var viewportWidth: CGFloat
        /// THE driver. Continuous during a live pinch. The cell side equals this value.
        public var apparentCellSize: CGFloat
        public var gap: CGFloat
        public var cropMode: WallCropMode
        /// Horizontal inset on each side (the wall is centred in the remaining width) and the top inset.
        public var contentInset: CGFloat
        public var topInset: CGFloat
        /// When set, the layout uses EXACTLY this many columns instead of the natural count derived from
        /// `apparentCellSize`. Used by the topology-rebase path (to hold the outgoing topology) and by the
        /// committed/resting grid. `nil` for the normal live wall.
        public var columnsOverride: Int?
        public var minColumns: Int
        public var maxColumns: Int

        public init(orderedUIDs: [TileUID],
                    aspectByUID: [TileUID: CGFloat] = [:],
                    viewportWidth: CGFloat,
                    apparentCellSize: CGFloat,
                    gap: CGFloat,
                    cropMode: WallCropMode,
                    contentInset: CGFloat = 0,
                    topInset: CGFloat = 0,
                    columnsOverride: Int? = nil,
                    minColumns: Int = 1,
                    maxColumns: Int = 64) {
            self.orderedUIDs = orderedUIDs
            self.aspectByUID = aspectByUID
            self.viewportWidth = viewportWidth
            self.apparentCellSize = apparentCellSize
            self.gap = gap
            self.cropMode = cropMode
            self.contentInset = contentInset
            self.topInset = topInset
            self.columnsOverride = columnsOverride
            self.minColumns = minColumns
            self.maxColumns = maxColumns
        }
    }

    // MARK: - Continuous column count (pure function of apparentCellSize — NO detent input)

    /// The natural column count for a cell size. Because it is the `floor` of a continuous, monotonically
    /// DECREASING function of `apparentCellSize`, it changes by at most ONE column as the cell size crosses
    /// a threshold (ColumnLocalityTest) and is the SAME whether the size was reached by zooming in or out
    /// (SamePathInOutTest — no hysteresis, no direction term).
    public static func columnCount(apparentCellSize: CGFloat,
                                   viewportWidth: CGFloat,
                                   gap: CGFloat,
                                   contentInset: CGFloat = 0,
                                   minColumns: Int = 1,
                                   maxColumns: Int = 64) -> Int {
        let usable = max(viewportWidth - 2 * contentInset, 1)
        // n cells of side `s` with `gap` between fit when n*s + (n-1)*gap <= usable
        //   ⇒ n <= (usable + gap) / (s + gap). The +1e-6 absorbs FP so a cell size that EXACTLY fills
        // (ratio == an integer, the resting detent case) floors to that integer rather than one below.
        let n = Int(((usable + gap) / (max(apparentCellSize, 1) + gap) + 1e-6).rounded(.down))
        return min(max(n, minColumns), maxColumns)
    }

    /// The `apparentCellSize` at which exactly `columns` columns EXACTLY fill the usable width (gap fixed).
    /// This is the resting cell size of a detent with that column count — the live wall passes smoothly
    /// through it without snapping.
    public static func fillCellSize(columns: Int,
                                    viewportWidth: CGFloat,
                                    gap: CGFloat,
                                    contentInset: CGFloat = 0) -> CGFloat {
        let cols = max(columns, 1)
        let usable = max(viewportWidth - 2 * contentInset, 1)
        return max((usable - CGFloat(cols - 1) * gap) / CGFloat(cols), 1)
    }

    // MARK: - The layout

    /// A full, deterministic layout for one topology. Holds the cheap scalar parameters and computes rects
    /// on demand (so the live renderer never materialises a 5 000-entry dictionary per frame); the
    /// `…ByUID` dictionaries are computed conveniences for tests and integration.
    public struct Layout: Sendable {
        public let columnCount: Int
        public let cellSize: CGFloat
        public let gap: CGFloat
        public let cropMode: WallCropMode
        public let contentInset: CGFloat
        public let topInset: CGFloat
        public let leftGutter: CGFloat
        public let rowCount: Int
        public let contentSize: CGSize
        public let orderedUIDs: [TileUID]
        public let aspectByUID: [TileUID: CGFloat]

        fileprivate var stride: CGFloat { cellSize + gap }

        // MARK: Index-space geometry (what the renderer uses — O(1), no allocation)

        public func cellRect(forIndex i: Int) -> CGRect {
            let col = i % columnCount
            let row = i / columnCount
            return CGRect(x: leftGutter + CGFloat(col) * stride,
                          y: topInset + CGFloat(row) * stride,
                          width: cellSize, height: cellSize)
        }

        /// The displayed-image rect inside the cell. squareFill ⇒ the whole cell; aspect modes ⇒ the
        /// image's intrinsic aspect letterboxed and centred (this is where the visible inter-image gap of
        /// the large levels comes from). The CELL rect is unaffected by crop mode (so a crop change moves
        /// nothing).
        public func imageRect(forIndex i: Int) -> CGRect {
            let cell = cellRect(forIndex: i)
            guard !cropMode.fillsCell else { return cell }
            let aspect = aspectByUID[orderedUIDs[i]] ?? 1
            return ContinuousPhotoWallLayoutEngine.aspectFitRect(aspect: aspect, in: cell)
        }

        public func row(forIndex i: Int) -> Int { i / columnCount }

        // MARK: UID-space geometry (tests / integration convenience)

        private var indexByUID: [TileUID: Int] {
            var m = [TileUID: Int](minimumCapacity: orderedUIDs.count)
            for (i, u) in orderedUIDs.enumerated() { m[u] = i }
            return m
        }

        public func cellRect(of uid: TileUID) -> CGRect? {
            indexByUID[uid].map { cellRect(forIndex: $0) }
        }

        public var rectByUID: [TileUID: CGRect] {
            var m = [TileUID: CGRect](minimumCapacity: orderedUIDs.count)
            for i in orderedUIDs.indices { m[orderedUIDs[i]] = cellRect(forIndex: i) }
            return m
        }

        public var imageRectByUID: [TileUID: CGRect] {
            var m = [TileUID: CGRect](minimumCapacity: orderedUIDs.count)
            for i in orderedUIDs.indices { m[orderedUIDs[i]] = imageRect(forIndex: i) }
            return m
        }

        public var rowByUID: [TileUID: Int] {
            var m = [TileUID: Int](minimumCapacity: orderedUIDs.count)
            for i in orderedUIDs.indices { m[orderedUIDs[i]] = i / columnCount }
            return m
        }

        /// One band rect per row (full wall width), top→bottom.
        public var rowRects: [CGRect] {
            (0..<rowCount).map { r in
                CGRect(x: leftGutter, y: topInset + CGFloat(r) * stride,
                       width: CGFloat(columnCount) * stride - gap, height: cellSize)
            }
        }

        // MARK: Visibility / hit-testing against the GLOBAL layout (no captured viewport rectangle)

        /// Indices whose cell intersects `viewportRect` (doc space). Computed by arithmetic over the
        /// uniform grid — O(visible), never O(n), and purely from the global layout.
        public func visibleIndices(in viewportRect: CGRect) -> [Int] {
            guard columnCount > 0, !orderedUIDs.isEmpty else { return [] }
            let count = orderedUIDs.count
            let firstRow = max(0, Int(((viewportRect.minY - topInset) / stride).rounded(.down)))
            let lastRow = min(rowCount - 1, Int(((viewportRect.maxY - topInset) / stride).rounded(.down)))
            guard firstRow <= lastRow else { return [] }
            let firstCol = max(0, Int(((viewportRect.minX - leftGutter) / stride).rounded(.down)))
            let lastCol = min(columnCount - 1, Int(((viewportRect.maxX - leftGutter) / stride).rounded(.down)))
            guard firstCol <= lastCol else { return [] }
            var out: [Int] = []
            out.reserveCapacity((lastRow - firstRow + 1) * (lastCol - firstCol + 1))
            for r in firstRow...lastRow {
                let base = r * columnCount
                for c in firstCol...lastCol {
                    let idx = base + c
                    if idx < count { out.append(idx) }
                }
            }
            return out
        }

        public func visibleUIDs(in viewportRect: CGRect) -> [TileUID] {
            visibleIndices(in: viewportRect).map { orderedUIDs[$0] }
        }

        /// The single tile whose CELL contains `point` (doc space). Cells never overlap, so "topmost" is
        /// unambiguous — this is the anchor-identity oracle used by AnchorTopmostTest. Returns nil if the
        /// point is in a gap / gutter.
        public func topMostIndex(atDocPoint point: CGPoint) -> Int? {
            guard columnCount > 0, !orderedUIDs.isEmpty else { return nil }
            let col = Int(((point.x - leftGutter) / stride).rounded(.down))
            let row = Int(((point.y - topInset) / stride).rounded(.down))
            guard col >= 0, col < columnCount, row >= 0, row < rowCount else { return nil }
            let idx = row * columnCount + col
            guard idx < orderedUIDs.count else { return nil }
            return cellRect(forIndex: idx).contains(point) ? idx : nil
        }

        public func topMostUID(atDocPoint point: CGPoint) -> TileUID? {
            topMostIndex(atDocPoint: point).map { orderedUIDs[$0] }
        }
    }

    /// Build the single deterministic layout for `config`. The cell side IS `apparentCellSize` (continuous
    /// breathing); the column count is the natural one (or `columnsOverride` for the rebase/committed path).
    /// The wall is horizontally centred in the usable width.
    public static func layout(_ config: Config) -> Layout {
        let cols = config.columnsOverride.map { max(min($0, config.maxColumns), config.minColumns) }
            ?? columnCount(apparentCellSize: config.apparentCellSize,
                           viewportWidth: config.viewportWidth, gap: config.gap,
                           contentInset: config.contentInset,
                           minColumns: config.minColumns, maxColumns: config.maxColumns)
        let cell = max(config.apparentCellSize, 1)
        let stride = cell + config.gap
        let count = config.orderedUIDs.count
        let rows = cols > 0 ? (count + cols - 1) / cols : 0
        let gridWidth = CGFloat(cols) * stride - config.gap
        let usable = max(config.viewportWidth - 2 * config.contentInset, 1)
        let leftGutter = config.contentInset + max(0, (usable - gridWidth) / 2)
        let contentHeight = config.topInset + CGFloat(rows) * stride - (rows > 0 ? config.gap : 0)
        return Layout(columnCount: cols, cellSize: cell, gap: config.gap, cropMode: config.cropMode,
                      contentInset: config.contentInset, topInset: config.topInset,
                      leftGutter: leftGutter, rowCount: rows,
                      contentSize: CGSize(width: config.viewportWidth, height: max(contentHeight, 0)),
                      orderedUIDs: config.orderedUIDs, aspectByUID: config.aspectByUID)
    }

    // MARK: - Anchor → camera (pure)

    /// The camera offset (content origin) that pins `anchorDocPoint` under `cursorViewportPoint`. A tile's
    /// screen rect is then `cellRect.offsetBy(dx: -offset.x, dy: -offset.y)`. This is the ONLY thing that
    /// moves the wall under the cursor — there is no separate "viewport patch". (AnchorOriginTest)
    public static func cameraOffset(anchorDocPoint: CGPoint, cursorViewportPoint: CGPoint) -> CGPoint {
        CGPoint(x: anchorDocPoint.x - cursorViewportPoint.x,
                y: anchorDocPoint.y - cursorViewportPoint.y)
    }

    /// Aspect-fit (letterbox) `aspect` (= w/h) centred inside `cell`.
    public static func aspectFitRect(aspect: CGFloat, in cell: CGRect) -> CGRect {
        let a = max(aspect, 0.0001)
        var w = cell.width, h = cell.height
        if a >= 1 { h = cell.width / a } else { w = cell.height * a }
        return CGRect(x: cell.midX - w / 2, y: cell.midY - h / 2, width: w, height: h)
    }
}
