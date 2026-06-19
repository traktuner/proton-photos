import CoreGraphics
import PhotosCore

/// Pure, value-type replica of `JustifiedCollectionLayout`'s SQUARE grid geometry — the layout the
/// production grid actually uses (all six levels are `square: true`). It is mathematically identical to
/// `JustifiedCollectionLayout.projectedFramesForElements(in:level:width:)` (verified by
/// `MetalGridLayoutParityTests`): per-section uniform square cells, fixed column count, anchored
/// bottom-right (newest in the corner; the partial/empty row is the OLDEST, at the top of each section).
///
/// Phase-1 scope: it places item rects exactly like production. It does NOT reserve space for, or draw,
/// day/month section header labels — the production square layout doesn't reserve header height either
/// (`geometrySquare` stacks sections directly), so the item geometry matches; the header *labels* are a
/// documented Phase-1 omission, not a geometry mismatch.
///
/// The per-level size/gap/cropMode are stored explicitly; `forLevel(_:sectionCounts:width:)` fills them
/// from `JustifiedCollectionLayout.levels` (the single source of truth for density), so the lab never
/// drifts from production while the geometry math itself stays a pure, nonisolated value type.
struct MetalGridLayout: Equatable {
    /// Item counts per section, in timeline order (section 0 first/top).
    let sectionCounts: [Int]
    let level: Int
    /// Target cell side / gap / crop mode for this level — mirrors a `JustifiedCollectionLayout.Level`.
    /// Stored explicitly (not read from the @MainActor production table) so the geometry is a pure,
    /// nonisolated value type that's trivially unit-testable; `forLevel(_:…)` fills these from production.
    let size: CGFloat
    let gap: CGFloat
    let cropMode: GridCropMode
    let width: CGFloat

    /// Flat index of the first item of each section (prefix sum of `sectionCounts`).
    private let sectionFlatStart: [Int]
    let totalItems: Int

    init(sectionCounts: [Int], level: Int, size: CGFloat, gap: CGFloat, cropMode: GridCropMode, width: CGFloat) {
        self.sectionCounts = sectionCounts
        self.level = level
        self.size = size
        self.gap = gap
        self.cropMode = cropMode
        self.width = max(width, 1)
        var starts: [Int] = []
        starts.reserveCapacity(sectionCounts.count)
        var running = 0
        for c in sectionCounts { starts.append(running); running += c }
        self.sectionFlatStart = starts
        self.totalItems = running
    }

    /// Column count + cell side at this width/level — identical to `JustifiedCollectionLayout.squareMetrics`.
    var metrics: (cols: Int, side: CGFloat) {
        let cols = max(1, Int((width + gap) / (size + gap)))
        let side = (width - gap * CGFloat(cols - 1)) / CGFloat(cols)
        return (cols, side)
    }

    /// Total content height (matches `projectedContentSize(level:width:)`).
    var contentHeight: CGFloat {
        let (cols, side) = metrics
        let step = side + gap
        var h: CGFloat = 0
        for count in sectionCounts {
            let rows = (count + cols - 1) / cols
            h += CGFloat(rows) * step
        }
        return max(h, 1)
    }

    var contentSize: CGSize { CGSize(width: width, height: contentHeight) }

    // MARK: - Per-item frame

    /// Frame of a single item (section/item), or nil if out of range. Mirrors
    /// `projectedFrameForItem(at:level:width:)`.
    func frame(section: Int, item: Int) -> CGRect? {
        guard section >= 0, section < sectionCounts.count else { return nil }
        let count = sectionCounts[section]
        guard item >= 0, item < count else { return nil }
        let (cols, side) = metrics
        let step = side + gap
        var sectionY: CGFloat = 0
        for s in 0 ..< section {
            let rows = (sectionCounts[s] + cols - 1) / cols
            sectionY += CGFloat(rows) * step
        }
        let rows = (count + cols - 1) / cols
        let emptyTopLeft = rows * cols - count
        let slot = emptyTopLeft + item
        let row = slot / cols, col = slot % cols
        return CGRect(x: CGFloat(col) * step, y: sectionY + CGFloat(row) * step, width: side, height: side)
    }

    /// Frame for a flat (library-order) index.
    func frame(flatIndex: Int) -> CGRect? {
        guard let (section, item) = sectionItem(forFlatIndex: flatIndex) else { return nil }
        return frame(section: section, item: item)
    }

    func flatIndex(section: Int, item: Int) -> Int? {
        guard section >= 0, section < sectionCounts.count, item >= 0, item < sectionCounts[section] else { return nil }
        return sectionFlatStart[section] + item
    }

    func sectionItem(forFlatIndex flat: Int) -> (section: Int, item: Int)? {
        guard flat >= 0, flat < totalItems else { return nil }
        // Binary search the prefix-sum boundaries.
        var lo = 0, hi = sectionFlatStart.count - 1, section = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if sectionFlatStart[mid] <= flat { section = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return (section, flat - sectionFlatStart[section])
    }

    // MARK: - Visible range query (proportional to visible rows, never the whole library)

    struct VisibleCell: Equatable {
        let flatIndex: Int
        let section: Int
        let item: Int
        let rect: CGRect
    }

    /// Items intersecting `rect` (content coordinates). Runtime ∝ visible rows. Mirrors
    /// `projectedFramesForElements(in:level:width:)`.
    func visibleCells(in rect: CGRect) -> [VisibleCell] {
        let (cols, side) = metrics
        let step = side + gap
        guard step > 0 else { return [] }
        var result: [VisibleCell] = []
        var sectionY: CGFloat = 0
        for (section, count) in sectionCounts.enumerated() {
            let rows = (count + cols - 1) / cols
            let sectionHeight = CGFloat(rows) * step
            let sectionRect = CGRect(x: 0, y: sectionY, width: width, height: sectionHeight)
            defer { sectionY += sectionHeight }
            guard count > 0, sectionRect.intersects(rect) else { continue }

            let firstRow = max(0, Int(floor((rect.minY - sectionY) / step)) - 1)
            let lastRow = min(rows - 1, Int(floor((rect.maxY - sectionY) / step)) + 1)
            guard firstRow <= lastRow else { continue }
            let emptyTopLeft = rows * cols - count
            let base = sectionFlatStart[section]
            for row in firstRow ... lastRow {
                for col in 0 ..< cols {
                    let slot = row * cols + col
                    let item = slot - emptyTopLeft
                    guard item >= 0, item < count else { continue }
                    let frame = CGRect(x: CGFloat(col) * step, y: sectionY + CGFloat(row) * step, width: side, height: side)
                    guard frame.intersects(rect) else { continue }
                    result.append(VisibleCell(flatIndex: base + item, section: section, item: item, rect: frame))
                }
            }
        }
        return result
    }

    // MARK: - Hit testing (debug only — point → item)

    /// The item whose cell contains `point` (content coordinates), or nil for a gap/empty slot.
    func hitTest(_ point: CGPoint) -> VisibleCell? {
        let probe = CGRect(x: point.x, y: point.y, width: 0.001, height: 0.001)
        for cell in visibleCells(in: probe) where cell.rect.contains(point) {
            return cell
        }
        return nil
    }
}

@MainActor
extension MetalGridLayout {
    /// Build a layout for a production zoom `level`, pulling size/gap/cropMode from
    /// `JustifiedCollectionLayout.levels` so the lab matches the real grid's density exactly.
    static func forLevel(_ level: Int, sectionCounts: [Int], width: CGFloat) -> MetalGridLayout {
        let clamped = min(max(level, 0), JustifiedCollectionLayout.levels.count - 1)
        let cfg = JustifiedCollectionLayout.levels[clamped]
        return MetalGridLayout(
            sectionCounts: sectionCounts, level: clamped,
            size: cfg.size, gap: cfg.gap, cropMode: cfg.cropMode, width: width
        )
    }
}
