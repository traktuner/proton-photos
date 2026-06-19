import CoreGraphics

// MARK: - Per-detent layout (square mosaic OR justified aspect rows)
//
// A pure, Sendable value type that turns one `GridZoomDetent` + width + per-item aspect ratios into item
// frames. It is the "real detent geometry" the zoom transition composites between — NOT a square-aspectFit
// approximation. Two backends, one interface:
//   • squareGrid           → delegates to the proven `MetalGridLayout` square math (parity-tested).
//   • justifiedAspectRows  → `JustifiedDetentLayout` below: a value-type replica of the production
//                            `JustifiedCollectionLayout` justified-rows algorithm (compose from the end so
//                            the newest photo lands bottom-right; full rows fill the width; the oldest
//                            partial row is capped at the row height).
//
// Built once per (detent, width, aspect-version) and reused across frames — never rebuilt per draw.

/// One laid-out cell, family-agnostic. `aspect` is the cell's content aspect ratio (w/h): the photo's
/// aspect for justified rows, 1 for the square mosaic (the image is center-cropped to the square).
public struct GridDetentCell: Equatable, Sendable {
    public let flatIndex: Int
    public let section: Int
    public let item: Int
    public let rect: CGRect
    public let aspect: CGFloat
}

/// Justified-aspect-rows layout (Apple's near/large levels): uniform row height, variable cell widths =
/// photo aspect, uniform gap, no crop, no letterbox bars. A value-type replica of
/// `JustifiedCollectionLayout`'s `composeJustified`/`geometryJustified`, so it is unit-testable and matches
/// the production justified algorithm (verified by GridDetentLayoutTests parity cases).
public struct JustifiedDetentLayout: Equatable, Sendable {
    public let width: CGFloat
    public let rowHeight: CGFloat
    public let gap: CGFloat
    public let sectionCounts: [Int]

    // Precomputed geometry (O(total items) at init; O(log n + visible) per query).
    private let frames: [CGRect]
    private let aspectsFlat: [CGFloat]
    private let minY: [CGFloat]
    private let maxY: [CGFloat]
    private let sectionFlatStart: [Int]
    public let contentHeight: CGFloat
    public let totalItems: Int

    /// `sectionAspects[s][i]` = aspect ratio (w/h) of item i in section s. Missing/short sections are
    /// padded with 1.0 so a not-yet-measured photo still composes (then re-composes when its ratio lands).
    public init(width: CGFloat, rowHeight: CGFloat, gap: CGFloat, sectionCounts: [Int], sectionAspects: [[CGFloat]]) {
        let w = max(width, 1)
        let rh = max(rowHeight, 1)
        self.width = w
        self.rowHeight = rh
        self.gap = gap
        self.sectionCounts = sectionCounts

        var starts: [Int] = []
        starts.reserveCapacity(sectionCounts.count)
        var running = 0
        for c in sectionCounts { starts.append(running); running += c }
        self.sectionFlatStart = starts
        self.totalItems = running

        var frames = [CGRect](repeating: .zero, count: running)
        var aspectsFlat = [CGFloat](repeating: 1, count: running)
        var minY = [CGFloat](repeating: 0, count: running)
        var maxY = [CGFloat](repeating: 0, count: running)

        var y: CGFloat = 0
        for (section, count) in sectionCounts.enumerated() {
            guard count > 0 else { continue }
            let base = starts[section]
            // Aspect ratios for this section, padded/clamped.
            var aspects = [CGFloat](repeating: 1, count: count)
            if section < sectionAspects.count {
                let src = sectionAspects[section]
                for i in 0 ..< count where i < src.count {
                    aspects[i] = min(max(src[i], 0.2), 5.0)
                }
            }
            for i in 0 ..< count { aspectsFlat[base + i] = aspects[i] }

            // Compose rows from the END backward so the bottom row is full and the newest is bottom-right.
            let rowRanges = Self.composeRows(aspects: aspects, rowHeight: rh, gap: gap, width: w)
            // Geometry: full rows justified to the width; the oldest partial (top) row capped at rowHeight.
            for (rowStart, rowEnd) in rowRanges {
                var sum: CGFloat = 0
                for k in rowStart ..< rowEnd { sum += aspects[k] }
                let gaps = gap * CGFloat(max(rowEnd - rowStart - 1, 0))
                let justifiedH = (w - gaps) / max(sum, 0.001)
                let h = max(1, min(justifiedH, rh))
                var x: CGFloat = 0
                for k in rowStart ..< rowEnd {
                    let fi = base + k
                    let cw = aspects[k] * h
                    frames[fi] = CGRect(x: x, y: y, width: cw, height: h)
                    minY[fi] = y
                    maxY[fi] = y + h
                    x += cw + gap
                }
                y += h + gap
            }
        }
        self.frames = frames
        self.aspectsFlat = aspectsFlat
        self.minY = minY
        self.maxY = maxY
        self.contentHeight = max(y, 1)
    }

    /// Break a section into justified rows from the END backwards (returns forward-ordered item ranges).
    static func composeRows(aspects: [CGFloat], rowHeight: CGFloat, gap: CGFloat, width: CGFloat) -> [(Int, Int)] {
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
                if sum * rowHeight + gap * CGFloat(cnt - 1) >= width { start = i; break }
                start = i
                i -= 1
            }
            rowRanges.append((start, end))
            end = start
        }
        rowRanges.reverse()
        return rowRanges
    }

    public var contentSize: CGSize { CGSize(width: width, height: contentHeight) }

    public func flatIndex(section: Int, item: Int) -> Int? {
        guard section >= 0, section < sectionCounts.count, item >= 0, item < sectionCounts[section] else { return nil }
        return sectionFlatStart[section] + item
    }

    public func sectionItem(forFlatIndex flat: Int) -> (section: Int, item: Int)? {
        guard flat >= 0, flat < totalItems else { return nil }
        var lo = 0, hi = sectionFlatStart.count - 1, section = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if sectionFlatStart[mid] <= flat { section = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return (section, flat - sectionFlatStart[section])
    }

    public func frame(flatIndex: Int) -> CGRect? {
        guard flatIndex >= 0, flatIndex < frames.count else { return nil }
        return frames[flatIndex]
    }

    /// Items intersecting `rect` (content coords). Runtime ∝ visible rows (binary search on the monotonic
    /// per-item minY, exactly like the production layout).
    public func visibleCells(in rect: CGRect) -> [GridDetentCell] {
        guard !frames.isEmpty else { return [] }
        var result: [GridDetentCell] = []
        var lo = 0, hi = maxY.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if maxY[mid] < rect.minY { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < frames.count, minY[i] <= rect.maxY {
            if frames[i].intersects(rect), let si = sectionItem(forFlatIndex: i) {
                result.append(GridDetentCell(flatIndex: i, section: si.section, item: si.item, rect: frames[i], aspect: aspectsFlat[i]))
            }
            i += 1
        }
        return result
    }

    public func hitTest(_ point: CGPoint) -> GridDetentCell? {
        let probe = CGRect(x: point.x, y: point.y, width: 0.001, height: 0.001)
        for cell in visibleCells(in: probe) where cell.rect.contains(point) { return cell }
        return nil
    }
}

/// Family-agnostic detent layout. Branches to the square mosaic (`MetalGridLayout`) or justified rows
/// (`JustifiedDetentLayout`) but exposes one interface for the renderer + transition planner.
public struct GridDetentLayout: Equatable, Sendable {
    public let detent: GridZoomDetent
    public let width: CGFloat

    private enum Backend: Equatable, Sendable {
        case square(MetalGridLayout)
        case justified(JustifiedDetentLayout)
    }
    private let backend: Backend

    /// `sectionAspects` is only consulted for justified detents (the square mosaic ignores aspect, using
    /// center-crop). Pass `[]` for square if you don't have ratios.
    public init(detent: GridZoomDetent, width: CGFloat, sectionCounts: [Int], sectionAspects: [[CGFloat]]) {
        self.detent = detent
        self.width = max(width, 1)
        switch detent.family {
        case .squareGrid:
            backend = .square(MetalGridLayout(
                sectionCounts: sectionCounts, level: detent.id,
                size: detent.size, gap: detent.gap, cropMode: .squareFill, width: width
            ))
        case .justifiedAspectRows:
            backend = .justified(JustifiedDetentLayout(
                width: width, rowHeight: detent.size, gap: detent.gap,
                sectionCounts: sectionCounts, sectionAspects: sectionAspects
            ))
        }
    }

    public var contentSize: CGSize {
        switch backend {
        case .square(let l): return l.contentSize
        case .justified(let l): return l.contentSize
        }
    }

    public func frame(flatIndex: Int) -> CGRect? {
        switch backend {
        case .square(let l): return l.frame(flatIndex: flatIndex)
        case .justified(let l): return l.frame(flatIndex: flatIndex)
        }
    }

    public func visibleCells(in rect: CGRect) -> [GridDetentCell] {
        switch backend {
        case .square(let l):
            return l.visibleCells(in: rect).map {
                GridDetentCell(flatIndex: $0.flatIndex, section: $0.section, item: $0.item, rect: $0.rect, aspect: 1)
            }
        case .justified(let l):
            return l.visibleCells(in: rect)
        }
    }

    public func hitTest(_ point: CGPoint) -> GridDetentCell? {
        switch backend {
        case .square(let l):
            guard let c = l.hitTest(point) else { return nil }
            return GridDetentCell(flatIndex: c.flatIndex, section: c.section, item: c.item, rect: c.rect, aspect: 1)
        case .justified(let l):
            return l.hitTest(point)
        }
    }
}
