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

/// One live-zoom frame: the resolved metrics + the focus row (ordered global indices under the cursor) +
/// every visible slot, placed in VIEWPORT coordinates relative to the anchor.
public struct GridZoomTransactionFrame: Equatable, Sendable {
    public let columns: Int
    public let slotSide: CGFloat
    public let gap: CGFloat
    public let pitch: CGFloat
    /// The anchor's column within the focus row.
    public let anchorColumn: Int
    /// Ordered global indices in the row under the cursor — contiguous, always contains the anchor.
    public let focusRow: [Int]
    /// Every visible slot (focus row + the rows above/below), viewport coords. `row` is RELATIVE to the
    /// anchor row (0 = focus row, negative = above).
    public let visibleSlots: [GridSlot]
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

    /// The live frame at a continuous level position (fractional = mid-pinch). Focus row preserved.
    public func frame(continuousLevel x: CGFloat, viewportSize: CGSize, overscan: CGFloat) -> GridZoomTransactionFrame {
        let width = max(viewportSize.width, 1)
        let gap = apparentGap(at: x)
        let target = apparentSlotSide(at: x)
        // Columns fill the width (same rule as the settled grid); the rendered side is uniform & square.
        let columns = max(1, Int((width + gap) / (target + gap)))
        let side = (width - gap * CGFloat(columns - 1)) / CGFloat(columns)
        let pitch = side + gap

        // Pin the anchor under the cursor: its cell's local point sits at `anchorViewportPoint`.
        let anchorCellX = anchorViewportPoint.x - anchorLocalFraction.x * side
        let anchorCellY = anchorViewportPoint.y - anchorLocalFraction.y * side
        // The anchor's column = the column the cursor is over; the lattice is shifted so the anchor cell
        // aligns there (so the focus row is centred on the anchor BY THE CURSOR, not by slot%cols).
        let cA = min(max(Int((anchorViewportPoint.x / pitch).rounded(.down)), 0), columns - 1)
        let gridOriginX = anchorCellX - CGFloat(cA) * pitch
        let gridOriginY = anchorCellY                                   // anchor is at relative row 0

        let firstRow = Int(((-overscan - gridOriginY) / pitch).rounded(.down))
        let lastRow = Int(((viewportSize.height + overscan - gridOriginY) / pitch).rounded(.up))

        var slots: [GridSlot] = []
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
                      cell.maxX > 0, cell.minX < width else { continue }
                slots.append(GridSlot(index: g, section: 0, item: g, column: col, row: row,
                                      slotRect: cell, viewportRect: cell))
                if row == 0 { focusRow.append(g) }
            }
        }
        focusRow.sort()
        return GridZoomTransactionFrame(columns: columns, slotSide: side, gap: gap, pitch: pitch,
                                        anchorColumn: cA, focusRow: focusRow, visibleSlots: slots)
    }

    // Apparent-metric interpolation (mirrors SquareTileGridEngine, with the soft rubber-band past the ends).
    public func apparentSlotSide(at x: CGFloat) -> CGFloat {
        let maxIndex = levels.count - 1
        if x <= 0 { return levels[0].slotSide * (1 - x * 0.6) }
        if x >= CGFloat(maxIndex) { return levels[maxIndex].slotSide }
        let lo = Int(x)
        return lerp(levels[lo].slotSide, levels[lo + 1].slotSide, smoothstep(x - CGFloat(lo)))
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
    /// viewport space). nil only for an empty library.
    func beginZoomTransaction(cursorContentPoint: CGPoint, viewportPoint: CGPoint, level: Int, width: CGFloat, columnPhase: Int? = nil) -> GridZoomTransaction? {
        guard let a = anchorItem(nearContentPoint: cursorContentPoint, level: level, width: width, columnPhase: columnPhase) else { return nil }
        return GridZoomTransaction(totalItems: totalItems, anchorGlobalIndex: a.flatIndex,
                                   anchorViewportPoint: viewportPoint, anchorLocalFraction: a.localFraction,
                                   levels: levels, sourceLevel: clampLevel(level))
    }
}
