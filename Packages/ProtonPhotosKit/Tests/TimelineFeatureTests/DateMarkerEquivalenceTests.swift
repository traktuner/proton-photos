import Testing
import Foundation
import PhotosCore
@testable import TimelineFeature

/// Pins the one-pass `dateMarkers` (interval-membership) to the original per-item `Calendar.dateComponents`
/// behavior it replaced. The optimization must be a pure speedup: byte-identical markers for every input.
@Suite struct DateMarkerEquivalenceTests {

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private static let locale = Locale(identifier: "en_US_POSIX")

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        Self.calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private func item(_ i: Int, _ date: Date) -> PhotoItem {
        PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "n\(i)"), captureTime: date, mediaType: "image/jpeg")
    }

    /// Reference: the ORIGINAL implementation (a fresh `dateComponents` per item, emit on change vs the
    /// previous item's components). The production code must match this exactly.
    private func referenceMarkers(_ items: [PhotoItem],
                                  _ granularity: TimelineDateMarker.Granularity) -> [(index: Int, text: String)] {
        guard !items.isEmpty else { return [] }
        let calendar = Self.calendar
        let formatter = DateFormatter()
        formatter.locale = Self.locale
        switch granularity {
        case .day: formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        case .month: formatter.setLocalizedDateFormatFromTemplate("MMM yyyy")
        case .year: formatter.setLocalizedDateFormatFromTemplate("yyyy")
        }
        func comps(_ date: Date) -> DateComponents {
            switch granularity {
            case .day: calendar.dateComponents([.year, .month, .day], from: date)
            case .month: calendar.dateComponents([.year, .month], from: date)
            case .year: calendar.dateComponents([.year], from: date)
            }
        }
        var out: [(Int, String)] = []
        var lastKey: DateComponents?
        for (i, it) in items.enumerated() {
            let key = comps(it.captureTime)
            if key != lastKey {
                lastKey = key
                out.append((i, formatter.string(from: it.captureTime)))
            }
        }
        return out
    }

    private func assertMatchesReference(_ items: [PhotoItem],
                                        _ granularity: TimelineDateMarker.Granularity,
                                        _ label: String) {
        let produced = MetalGridProductionAdapter.dateMarkers(
            items: items, granularity: granularity, calendar: Self.calendar, locale: Self.locale)
        let reference = referenceMarkers(items, granularity)
        #expect(produced.map(\.index) == reference.map(\.index), "\(label): indices [\(granularity)]")
        #expect(produced.map(\.text) == reference.map(\.text), "\(label): labels [\(granularity)]")
    }

    @Test func matchesReferenceAcrossFixturesAndGranularities() {
        // Ascending, spanning months and a year boundary, with same-day runs.
        let ascending = [
            date(2025, 11, 30), date(2025, 12, 1), date(2025, 12, 1), date(2025, 12, 31),
            date(2026, 1, 1), date(2026, 1, 15), date(2026, 1, 15), date(2026, 3, 2),
        ].enumerated().map { item($0.offset, $0.element) }

        // Descending (grid shows newest-first): the run detection must work either direction.
        let descending = Array(ascending.reversed().enumerated().map { item($0.offset, $0.element.captureTime) })

        // Non-monotonic: a month recurs non-adjacently → a fresh marker must reappear.
        let nonMonotonic = [
            date(2026, 1, 5), date(2026, 1, 9), date(2026, 2, 3), date(2026, 1, 20), date(2026, 1, 22),
        ].enumerated().map { item($0.offset, $0.element) }

        // Single item and a same-instant run.
        let single = [item(0, date(2026, 6, 1))]
        let sameInstant = (0 ..< 5).map { item($0, date(2026, 6, 1)) }

        // Large synthetic library: ~4 years, a few photos per day, to exercise many buckets in one pass.
        var big: [PhotoItem] = []
        var idx = 0
        for y in 2022 ... 2025 {
            for m in 1 ... 12 {
                for d in stride(from: 1, through: 27, by: 9) {
                    for _ in 0 ..< 3 { big.append(item(idx, date(y, m, d))); idx += 1 }
                }
            }
        }

        for (label, items) in [("ascending", ascending), ("descending", descending),
                               ("nonMonotonic", nonMonotonic), ("single", single),
                               ("sameInstant", sameInstant), ("big", big)] {
            for granularity in [TimelineDateMarker.Granularity.day, .month, .year] {
                assertMatchesReference(items, granularity, label)
            }
        }
    }

    @Test func itemsAndSectionsOverloadsAgree() {
        let items = [date(2026, 1, 1), date(2026, 1, 2), date(2026, 2, 1), date(2026, 2, 2)]
            .enumerated().map { item($0.offset, $0.element) }
        let section = TimelineSection(id: "s", date: items[0].captureTime, title: "s", items: items)
        let viaItems = MetalGridProductionAdapter.dateMarkers(items: items, granularity: .month,
                                                              calendar: Self.calendar, locale: Self.locale)
        let viaSections = MetalGridProductionAdapter.dateMarkers(sections: [section], granularity: .month,
                                                                calendar: Self.calendar, locale: Self.locale)
        #expect(viaItems == viaSections)
    }

    @Test func emptyItemsProduceNoMarkers() {
        #expect(MetalGridProductionAdapter.dateMarkers(items: [], granularity: .month,
                                                       calendar: Self.calendar, locale: Self.locale).isEmpty)
    }
}
