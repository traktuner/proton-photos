import Foundation
import PhotosCore
import MediaCache

/// Bridges the production timeline (`TimelineSection`/`PhotoItem` + the shared `ThumbnailFeed`) to the
/// Metal grid's `MetalGridDataSource`, and derives the month/year header markers. The production
/// timeline is delivered as a single ordered section, so a flat scan over its items is exact.
enum MetalGridProductionAdapter {
    @MainActor static func makeDataSource(sections: [TimelineSection], feed: ThumbnailFeed) -> MetalGridDataSource {
        RealMetalGridDataSource(sections: sections, feed: feed)
    }

    /// Month/year markers (flat item index → "LLLL yyyy"), one per month boundary in library order —
    /// matches `PhotoGridView`'s month-label computation.
    static func monthMarkers(sections: [TimelineSection]) -> [(index: Int, text: String)] {
        let items = sections.flatMap { $0.items }
        guard !items.isEmpty else { return [] }
        let cal = Calendar.current
        let fmt = DateFormatter(); fmt.dateFormat = "LLLL yyyy"
        var markers: [(Int, String)] = []
        var lastKey = -1
        for (i, item) in items.enumerated() {
            let c = cal.dateComponents([.year, .month], from: item.captureTime)
            let key = (c.year ?? 0) * 100 + (c.month ?? 0)
            if key != lastKey {
                lastKey = key
                markers.append((i, fmt.string(from: item.captureTime)))
            }
        }
        return markers
    }

    /// Cheap structural fingerprint to detect when the data source must be rebuilt (count + first/last uid).
    static func dataToken(sections: [TimelineSection]) -> Int {
        var hasher = Hasher()
        var total = 0
        for s in sections { total += s.items.count }
        hasher.combine(total)
        if let first = sections.first?.items.first { hasher.combine(first.uid) }
        if let last = sections.last?.items.last { hasher.combine(last.uid) }
        return hasher.finalize()
    }
}
