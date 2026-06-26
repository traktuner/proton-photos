import Foundation
import PhotosCore
import MediaCache

struct TimelineDateMarker: Equatable, Sendable {
    enum Granularity: Equatable, Sendable {
        case day
        case month
        case year
    }

    let index: Int
    let date: Date
    let text: String
    let granularity: Granularity
}

/// Bridges the production timeline (`TimelineSection`/`PhotoItem` + the shared `ThumbnailFeed`) to the
/// Metal grid's `MetalGridDataSource`, and derives the month/year header markers. The production
/// timeline is delivered as a single ordered section, so a flat scan over its items is exact.
enum MetalGridProductionAdapter {
    @MainActor static func makeDataSource(sections: [TimelineSection], feed: ThumbnailFeed) -> MetalGridDataSource {
        RealMetalGridDataSource(sections: sections, feed: feed)
    }

    /// Date markers over the single flattened production timeline. This is the pure foundation for Apple-like
    /// day/month/year navigation; the current grid UI renders only month markers on L4/L5.
    static func dateMarkers(sections: [TimelineSection], granularity: TimelineDateMarker.Granularity,
                            calendar: Calendar = .autoupdatingCurrent,
                            locale: Locale = .autoupdatingCurrent) -> [TimelineDateMarker] {
        let items = sections.flatMap { $0.items }
        guard !items.isEmpty else { return [] }
        var markers: [TimelineDateMarker] = []
        var lastKey: DateComponents?
        for (i, item) in items.enumerated() {
            let key = components(for: item.captureTime, granularity: granularity, calendar: calendar)
            if key != lastKey {
                lastKey = key
                markers.append(TimelineDateMarker(index: i,
                                                  date: item.captureTime,
                                                  text: label(for: item.captureTime, granularity: granularity, locale: locale),
                                                  granularity: granularity))
            }
        }
        return markers
    }

    /// Month/year markers (flat item index → localized "MMM yyyy"), one per month boundary in library order.
    static func monthMarkers(sections: [TimelineSection]) -> [(index: Int, text: String)] {
        dateMarkers(sections: sections, granularity: .month).map { ($0.index, $0.text) }
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

    private static func components(for date: Date, granularity: TimelineDateMarker.Granularity,
                                   calendar: Calendar) -> DateComponents {
        switch granularity {
        case .day:
            calendar.dateComponents([.year, .month, .day], from: date)
        case .month:
            calendar.dateComponents([.year, .month], from: date)
        case .year:
            calendar.dateComponents([.year], from: date)
        }
    }

    private static func label(for date: Date, granularity: TimelineDateMarker.Granularity, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        switch granularity {
        case .day:
            formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        case .month:
            formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        case .year:
            formatter.setLocalizedDateFormatFromTemplate("yyyy")
        }
        return formatter.string(from: date)
    }
}
