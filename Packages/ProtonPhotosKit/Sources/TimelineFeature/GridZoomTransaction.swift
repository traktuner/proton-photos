import CoreGraphics

// MARK: - GridZoomTransaction — engine-owned LIVE zoom (focus-row stable)
//
// A settled `GridFramePlan` answers "where do items live at level N". It CANNOT be the live-zoom model:
// re-resolving it per frame changes `columnCount`, and the placement `row = slot/cols, col = slot%cols`
// rewraps every flat index — the row under the cursor becomes an unrelated row (the observed jump).
//
// A live zoom is instead a TRANSACTION captured once at gesture start. The anchor item (the photo under the
// cursor) is pinned under the cursor, and the whole grid is laid out RELATIVE TO THE ANCHOR — the anchor is
// placed at the cursor's column, and indices fan out from it. Therefore the FOCUS ROW (the row under the
// cursor) is always a CONTIGUOUS run of global indices centred on the anchor by the cursor column:
//   • zoom IN  → fewer columns → the run shrinks, dropping edge neighbours (the focus photos stay);
//   • zoom OUT → more columns  → the run grows, adding neighbours left/right around the anchor.
// It never snaps to a row-major boundary and never jumps to an unrelated row.
//
// The settled target grid is still normal row-major; the transaction only governs the LIVE drag until
// commit. (No crossfade / opacity work here — identity + position continuity only.)
//
// SINGLE-SECTION ONLY. The transaction treats the library as ONE contiguous run (`anchorGlobalIndex + delta`),
// which matches the engine's geometry only when there is exactly one section. Production uses ONE physical
// layout section by design — `RealMetalGridDataSource` flattens all `TimelineSection`s into a single
// continuous photo wall — so the transaction drives the production live pinch. A genuinely multi-section
// engine wraps each section independently (its own partial row + header offset), so the flat fan-out would be
// wrong across section boundaries; `beginZoomTransaction` therefore returns nil for one (a safety guard, not a
// production path).

/// A renderable square slot in VIEWPORT coordinates — exactly what the Metal renderer draws. Produced both
/// by the settled `GridFramePlan` (mapped from `GridSlot.viewportRect`) and by the live `GridZoomTransaction`.
/// Deliberately distinct from the engine's `GridSlot`, whose `slotRect` is CONTENT-space: keeping a separate
/// type means viewport-space and content-space rects are never conflated under one name.
public struct GridRenderSlot: Equatable, Sendable {
    public let index: Int      // global (flat) item index → UID lookup
    public let column: Int
    public let row: Int
    public let rect: CGRect    // viewport-space, ALWAYS square

    public init(index: Int, column: Int, row: Int, rect: CGRect) {
        self.index = index
        self.column = column
        self.row = row
        self.rect = rect
    }
}

/// One live-zoom frame: the resolved metrics + the focus row (ordered global indices under the cursor) +
/// every visible render slot, placed in VIEWPORT coordinates relative to the anchor.
public struct GridZoomTransactionFrame: Equatable, Sendable {
    public let columns: Int
    public let slotSide: CGFloat
    public let gap: CGFloat
    public let pitch: CGFloat
    /// The anchor's column within the focus row.
    public let anchorColumn: Int
    /// Ordered global indices in the row under the cursor — contiguous, always contains the anchor.
    public let focusRow: [Int]
    /// Every visible render slot (focus row + the rows above/below), viewport coords. `row` is RELATIVE to
    /// the anchor row (0 = focus row, negative = above).
    public let visibleSlots: [GridRenderSlot]
}

public struct GridZoomTransaction: Equatable, Sendable {
    public let totalItems: Int
    /// The anchor's identity — the item under the cursor at gesture start (section/global index). NEVER a
    /// raw y; this is what is pinned under the cursor through the whole gesture.
    public let anchorGlobalIndex: Int
    /// Where the anchor's local point is held fixed (the cursor, viewport coords).
    public let anchorViewportPoint: CGPoint
    /// The cursor's unit position inside the anchor slot (kept invariant so the cursor stays pinned).
    public let anchorLocalFraction: CGPoint
    /// The density ladder (for apparent-metric interpolation across the gesture).
    public let levels: [GridLevelMetrics]
    /// The level the gesture started on (the snap-back / commit reference).
    public let sourceLevel: Int

    public init(totalItems: Int, anchorGlobalIndex: Int, anchorViewportPoint: CGPoint,
                anchorLocalFraction: CGPoint, levels: [GridLevelMetrics], sourceLevel: Int) {
        self.totalItems = totalItems
        self.anchorGlobalIndex = anchorGlobalIndex
        self.anchorViewportPoint = anchorViewportPoint
        self.anchorLocalFraction = anchorLocalFraction
        self.levels = levels.isEmpty ? SquareTileGridEngine.defaultLevels : levels
        self.sourceLevel = sourceLevel
    }

    /// The anchor-relative lattice at a continuous level: apparent metrics + the origin/anchor-column that pin
    /// the anchor cell under the cursor. Shared by `frame()` and `rect(forGlobalIndex:)` so they never drift.
    struct Lattice {
        let columns: Int, side: CGFloat, gap: CGFloat, pitch: CGFloat, anchorColumn: Int
        let gridOriginX: CGFloat, gridOriginY: CGFloat
    }

    func lattice(continuousLevel x: CGFloat, width rawWidth: CGFloat) -> Lattice {
        let width = max(rawWidth, 1)
        // RUBBER-BAND over-zoom past the largest detent (x < 0): the level-0 grid is GEOMETRICALLY SCALED
        // around the cursor (fixed columns, NO reflow) — "zooming the image", restoring the original working
        // rubber band. Cell, gap and pitch all scale by the same factor `f`, so the whole grid grows uniformly
        // about the anchor; the column reflow happens only on release (commit at level 0). For x ≥ 0 the
        // in-band / densest behaviour below is unchanged.
        if x < 0 {
            // Over-zoom past the largest level: geometrically SCALE the level-0 grid about the cursor. FIXED-COLUMNS,
            // WIDTH-FILLING: L0 HOLDS its `nominalColumns` and the base side is the settled (width-FILLED) L0 side —
            // so at x == 0 the scale factor is exactly 1 and this branch is continuous with the in-band branch, and
            // the over-zoom anchors on the same grid the settled L0 shows.
            let columns = levels[0].nominalColumns                       // FIXED-COLUMNS: L0 holds its count
            let baseSide = apparentSlotSide(at: 0, width: width)
            let f = apparentSlotSide(at: x, width: width) / max(baseSide, 0.001)   // > 1 past level 0 (grows)
            let side = baseSide * f
            let gap = levels[0].gap * f
            let pitch = side + gap
            let anchorCellX = anchorViewportPoint.x - anchorLocalFraction.x * side
            let anchorCellY = anchorViewportPoint.y - anchorLocalFraction.y * side
            let cA = min(max(Int((anchorViewportPoint.x / pitch).rounded(.down)), 0), columns - 1)
            return Lattice(columns: columns, side: side, gap: gap, pitch: pitch, anchorColumn: cA,
                           gridOriginX: anchorCellX - CGFloat(cA) * pitch, gridOriginY: anchorCellY)
        }
        let gap = apparentGap(at: x)
        let target = apparentSlotSide(at: x, width: width)
        // FIXED-COLUMNS, WIDTH-FILLING: `apparentSlotSide` already returns the per-level FILLED side. At an integer
        // detent the column count is that level's `nominalColumns` — the SAME fixed count the settled
        // `resolvedForLevel` holds — so the transaction and the settled plan agree on (size, columns) at every
        // detent (the commit seam closes; no vertical OR size jump). BETWEEN detents (the continuous over-zoom)
        // the count comes from `columnsForFixedSide` on the apparent side; only this off-detent path is adaptive.
        let columns: Int
        let nearestLevel = x.rounded()
        if abs(x - nearestLevel) < 1e-6, nearestLevel >= 0, Int(nearestLevel) < levels.count {
            let lv = Int(nearestLevel)
            columns = levels[lv].nominalColumns                          // FIXED-COLUMNS: the detent holds its count
        } else {
            columns = SquareTileGridEngine.columnsForFixedSide(side: target, gap: gap, width: width)
        }
        let side = target            // the apparent FILLED side — equals the settled side at every detent
        let pitch = side + gap
        // Pin the anchor under the cursor: its cell's local point sits at `anchorViewportPoint`.
        let anchorCellX = anchorViewportPoint.x - anchorLocalFraction.x * side
        let anchorCellY = anchorViewportPoint.y - anchorLocalFraction.y * side
        // The anchor's column = the column the cursor is over; the lattice is shifted so the anchor cell
        // aligns there (so the focus row is centred on the anchor BY THE CURSOR, not by slot%cols).
        let cA = min(max(Int((anchorViewportPoint.x / pitch).rounded(.down)), 0), columns - 1)
        return Lattice(columns: columns, side: side, gap: gap, pitch: pitch, anchorColumn: cA,
                       gridOriginX: anchorCellX - CGFloat(cA) * pitch, gridOriginY: anchorCellY)
    }

    /// The VIEWPORT rect of an arbitrary global index in the transaction lattice at `x` (nil if out of range).
    /// The lattice is infinite, so this is valid even for items currently off-screen — used by the commit
    /// bridge + the commit-delta measurement.
    func rect(forGlobalIndex g: Int, continuousLevel x: CGFloat, viewportSize: CGSize) -> CGRect? {
        guard g >= 0, g < totalItems else { return nil }
        let l = lattice(continuousLevel: x, width: viewportSize.width)
        let m = (g - anchorGlobalIndex) + l.anchorColumn          // anchor sits at (row 0, col anchorColumn)
        let row = Int(floor(Double(m) / Double(l.columns)))
        let col = m - row * l.columns
        return CGRect(x: l.gridOriginX + CGFloat(col) * l.pitch,
                      y: l.gridOriginY + CGFloat(row) * l.pitch, width: l.side, height: l.side)
    }

    /// The live frame at a continuous level position (fractional = mid-pinch). Focus row preserved.
    public func frame(continuousLevel x: CGFloat, viewportSize: CGSize, overscan: CGFloat) -> GridZoomTransactionFrame {
        let l = lattice(continuousLevel: x, width: viewportSize.width)
        let columns = l.columns, side = l.side, gap = l.gap, pitch = l.pitch
        let cA = l.anchorColumn, gridOriginX = l.gridOriginX, gridOriginY = l.gridOriginY

        let firstRow = Int(((-overscan - gridOriginY) / pitch).rounded(.down))
        let lastRow = Int(((viewportSize.height + overscan - gridOriginY) / pitch).rounded(.up))

        var slots: [GridRenderSlot] = []
        var focusRow: [Int] = []
        guard firstRow <= lastRow else {
            return GridZoomTransactionFrame(columns: columns, slotSide: side, gap: gap, pitch: pitch,
                                            anchorColumn: cA, focusRow: [], visibleSlots: [])
        }
        for row in firstRow ... lastRow {
            for col in 0 ..< columns {
                let delta = row * columns + col - cA          // offset from the anchor (anchor at row 0, col cA)
                let g = anchorGlobalIndex + delta
                guard g >= 0, g < totalItems else { continue }
                let cell = CGRect(x: gridOriginX + CGFloat(col) * pitch,
                                  y: gridOriginY + CGFloat(row) * pitch, width: side, height: side)
                guard cell.maxY > -overscan, cell.minY < viewportSize.height + overscan,
                      cell.maxX > 0, cell.minX < viewportSize.width else { continue }
                slots.append(GridRenderSlot(index: g, column: col, row: row, rect: cell))
                if row == 0 { focusRow.append(g) }
            }
        }
        focusRow.sort()
        return GridZoomTransactionFrame(columns: columns, slotSide: side, gap: gap, pitch: pitch,
                                        anchorColumn: cA, focusRow: focusRow, visibleSlots: slots)
    }

    // Apparent-metric interpolation (mirrors SquareTileGridEngine, with the soft rubber-band past the ends).
    public func apparentSlotSide(at x: CGFloat, width: CGFloat) -> CGFloat {
        let maxIndex = levels.count - 1
        // The per-level WIDTH-FILLED side at this width — identical to the engine's settled `resolvedForLevel`,
        // so an integer detent's apparent size equals the settled size and the commit seam closes at any width.
        func side(_ i: Int) -> CGFloat {
            SquareTileGridEngine.nominalSlotSide(columns: levels[i].nominalColumns, gap: levels[i].gap, width: width)
        }
        if x <= 0 { return side(0) * (1 - x * 0.6) }
        if x >= CGFloat(maxIndex) { return side(maxIndex) }
        let lo = Int(x)
        return lerp(side(lo), side(lo + 1), smoothstep(x - CGFloat(lo)))
    }
    public func apparentGap(at x: CGFloat) -> CGFloat {
        let maxIndex = levels.count - 1
        if x <= 0 { return levels[0].gap }
        if x >= CGFloat(maxIndex) { return levels[maxIndex].gap }
        let lo = Int(x)
        return lerp(levels[lo].gap, levels[lo + 1].gap, smoothstep(x - CGFloat(lo)))
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }
    private func smoothstep(_ x: CGFloat) -> CGFloat { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }
}

public extension SquareTileGridEngine {
    /// Capture a live-zoom transaction anchored at the item under (or nearest to) the cursor. `cursorContentPoint`
    /// is the cursor in CONTENT space at the current `level`; `viewportPoint` is where to hold it (the cursor in
    /// viewport space). Returns nil for an empty library OR a multi-section engine (the transaction's flat
    /// single-run model is only valid for one section — see the file header; production uses one physical
    /// section by design, so it drives the transaction).
    func beginZoomTransaction(cursorContentPoint: CGPoint, viewportPoint: CGPoint, level: Int, width: CGFloat, columnPhase: Int? = nil) -> GridZoomTransaction? {
        guard sectionCounts.count <= 1 else { return nil }
        // Resolve the anchor in the CURRENTLY-DISPLAYED grid — i.e. with the committed column phase. Without it
        // the anchor would be read from the canonical layout, which (after a prior phased zoom) holds a DIFFERENT
        // item at the cursor's content point → the gesture would anchor the wrong item (the 24→18 swap).
        guard let a = anchorItem(nearContentPoint: cursorContentPoint, level: level, width: width, columnPhase: columnPhase) else { return nil }
        return GridZoomTransaction(totalItems: totalItems, anchorGlobalIndex: a.flatIndex,
                                   anchorViewportPoint: viewportPoint, anchorLocalFraction: a.localFraction,
                                   levels: levels, sourceLevel: clampLevel(level))
    }
}
