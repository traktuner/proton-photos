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
        dateMarkers(items: sections.flatMap { $0.items }, granularity: granularity, calendar: calendar, locale: locale)
    }

    /// Same markers over an ALREADY-flattened item list, so callers that have flattened the sections (e.g.
    /// `visibleContent`) don't pay the flatten twice.
    ///
    /// One pass, emitting a marker at every calendar-bucket boundary. It replaces the old per-item
    /// `Calendar.dateComponents` (one calendar computation per photo - the dominant main-actor cost at library
    /// scale) with a `dateInterval` half-open membership test: a calendar computation runs only when an item
    /// falls outside the current bucket (≈ once per month/day/year present), and every other item is a cheap
    /// `Date` comparison. The emitted markers are identical to the components-per-item version - a marker still
    /// appears whenever an item's bucket differs from the previously emitted marker's bucket (verified by the
    /// equivalence test) - because months/days/years partition the timeline and `[start, end)` membership is the
    /// same partition `dateComponents` equality expresses.
    static func dateMarkers(items: [PhotoItem], granularity: TimelineDateMarker.Granularity,
                            calendar: Calendar = .autoupdatingCurrent,
                            locale: Locale = .autoupdatingCurrent) -> [TimelineDateMarker] {
        guard !items.isEmpty else { return [] }
        let component = calendarComponent(for: granularity)
        let formatter = makeFormatter(granularity: granularity, locale: locale)   // built ONCE, reused per boundary
        var markers: [TimelineDateMarker] = []
        var bucketStart: Date?
        var bucketEnd: Date?
        for (i, item) in items.enumerated() {
            let time = item.captureTime
            if let start = bucketStart, let end = bucketEnd, time >= start, time < end {
                continue   // same bucket as the last emitted marker → no boundary
            }
            if let interval = calendar.dateInterval(of: component, for: time) {
                bucketStart = interval.start
                bucketEnd = interval.end
            } else {
                bucketStart = nil   // no interval (pathological date) → emit for every such item, as before
                bucketEnd = nil
            }
            markers.append(TimelineDateMarker(index: i,
                                              date: time,
                                              text: formatter.string(from: time),
                                              granularity: granularity))
        }
        return markers
    }

    private static func calendarComponent(for granularity: TimelineDateMarker.Granularity) -> Calendar.Component {
        switch granularity {
        case .day: .day
        case .month: .month
        case .year: .year
        }
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

    /// One configured formatter per (granularity, locale), built ONCE per `dateMarkers` call and reused for every
    /// boundary - DateFormatter construction is expensive, so do not allocate one per marker.
    private static func makeFormatter(granularity: TimelineDateMarker.Granularity, locale: Locale) -> DateFormatter {
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
        return formatter
    }
}
