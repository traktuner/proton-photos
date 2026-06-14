import AppKit

/// Justified flow layout for the photo grid (uniform row height, aspect-proportional widths, last
/// row left-aligned), with sticky section headers. Frames are precomputed once per invalidation
/// and queried by binary search, so visible-range lookup stays O(log n) even at 20k+ photos.
final class JustifiedCollectionLayout: NSCollectionViewLayout {
    var rowHeight: CGFloat = 168 { didSet { invalidateLayout() } }
    var spacing: CGFloat = 2
    var headerHeight: CGFloat = 32
    var sectionGap: CGFloat = 10

    /// Aspect ratio (w/h) per item, per section. Set by the coordinator.
    var sectionAspects: [[CGFloat]] = []

    private struct Element { let attrs: NSCollectionViewLayoutAttributes; let minY: CGFloat; let maxY: CGFloat }
    private var items: [Element] = []
    private var headers: [NSCollectionViewLayoutAttributes] = []
    private var contentHeight: CGFloat = 0
    private var width: CGFloat = 0

    override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let newWidth = collectionView.bounds.width
        guard newWidth > 1 else { return }        // ignore transient/zero-width passes
        width = newWidth
        items.removeAll(keepingCapacity: true)
        headers.removeAll(keepingCapacity: true)

        var y: CGFloat = 0
        for (section, aspects) in sectionAspects.enumerated() {
            let header = NSCollectionViewLayoutAttributes(
                forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                with: IndexPath(item: 0, section: section)
            )
            header.frame = NSRect(x: 0, y: y, width: width, height: headerHeight)
            header.zIndex = 1
            headers.append(header)
            y += headerHeight

            var index = 0
            var run: [CGFloat] = []
            var sum: CGFloat = 0

            func flush(justified: Bool) {
                let rawH = justified ? (width - spacing * CGFloat(run.count - 1)) / max(sum, 0.001) : rowHeight
                let h = max(1, min(rawH, 4000))   // never emit zero/NaN/huge frames
                var x: CGFloat = 0
                for a in run {
                    let w = a * h
                    let attrs = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: section))
                    attrs.frame = NSRect(x: x, y: y, width: w, height: h)
                    items.append(Element(attrs: attrs, minY: y, maxY: y + h))
                    x += w + spacing
                    index += 1
                }
                y += h + spacing
                run.removeAll(keepingCapacity: true)
                sum = 0
            }

            for aspect in aspects {
                run.append(aspect); sum += aspect
                if sum * rowHeight + spacing * CGFloat(run.count - 1) >= width { flush(justified: true) }
            }
            if !run.isEmpty { flush(justified: false) }
            y += sectionGap
        }
        contentHeight = y
    }

    override var collectionViewContentSize: NSSize { NSSize(width: width, height: max(contentHeight, 1)) }

    override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        var result: [NSCollectionViewLayoutAttributes] = []

        for header in headers where header.frame.maxY >= rect.minY && header.frame.minY <= rect.maxY {
            result.append(header)
        }

        guard !items.isEmpty else { return result }
        // Binary search the first item whose maxY >= rect.minY, then walk until minY > rect.maxY.
        var lo = 0, hi = items.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if items[mid].maxY < rect.minY { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < items.count, items[i].minY <= rect.maxY {
            result.append(items[i].attrs)
            i += 1
        }
        return result
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        items.first { $0.attrs.indexPath == indexPath }?.attrs
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: NSCollectionView.SupplementaryElementKind,
        at indexPath: IndexPath
    ) -> NSCollectionViewLayoutAttributes? {
        guard indexPath.section < headers.count else { return nil }
        return headers[indexPath.section]
    }

    /// Only re-justify when the WIDTH changes — never on vertical scroll or magnification (which
    /// previously invalidated the layout mid-magnify and crashed with invalid attributes).
    override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != width
    }
}
