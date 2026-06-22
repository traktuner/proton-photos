import Testing
import Foundation
import CoreGraphics
import PhotosCore
import MediaCache
@testable import TimelineFeature

/// Production MetalGrid geometry is ONE continuous square-tile photo wall: `RealMetalGridDataSource` flattens
/// all `TimelineSection`s into a single ordered layout section, so the live `GridZoomTransaction` (single-
/// section only) is available in production. Date/month labels still come from the ORIGINAL
/// `TimelineSection`s via `MetalGridProductionAdapter.monthMarkers`. (Multi-section layout stays supported by
/// `SquareTileGridEngine` and its own tests; production just never uses more than one layout section.)
@MainActor
@Suite struct ProductionGridFlatteningTests {

    private func feed() -> ThumbnailFeed {
        ThumbnailFeed(cache: ThumbnailCache(namespace: "test-\(UUID().uuidString)"),
                      loader: NoopThumbnailLoader(),
                      aspects: AspectRegistry(namespace: "test-\(UUID().uuidString)"))
    }

    private func day(_ year: Int, _ month: Int, _ d: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: d))!
    }

    private func item(_ id: String, _ date: Date, video: Bool = false) -> PhotoItem {
        PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: id), captureTime: date,
                  mediaType: video ? "video/quicktime" : "image/jpeg")
    }

    /// Three date-grouped sections (5 + 7 + 4 items) in timeline order, spanning Jan/Feb/Mar 2026.
    private func sampleSections() -> [TimelineSection] {
        let jan = (0 ..< 5).map { item("jan-\($0)", day(2026, 1, 10 + $0)) }
        let feb = (0 ..< 7).map { item("feb-\($0)", day(2026, 2, 3 + $0)) }
        let mar = (0 ..< 4).map { item("mar-\($0)", day(2026, 3, 1 + $0)) }
        return [
            TimelineSection(id: "2026-01", date: day(2026, 1, 10), title: "January", items: jan),
            TimelineSection(id: "2026-02", date: day(2026, 2, 3),  title: "February", items: feb),
            TimelineSection(id: "2026-03", date: day(2026, 3, 1),  title: "March", items: mar),
        ]
    }

    // ProductionDataSourceUsesSingleContinuousSectionTest
    @Test func productionDataSourceUsesSingleContinuousSection() {
        let ds = MetalGridProductionAdapter.makeDataSource(sections: sampleSections(), feed: feed())
        #expect(ds.sectionCounts == [16], "production must be ONE continuous section of all 16 items, got \(ds.sectionCounts)")
        #expect(ds.flatUIDs.count == 16)
        // Flat order preserves timeline order across the original sections.
        #expect(ds.flatUIDs.first == PhotoUID(volumeID: "v", nodeID: "jan-0"))
        #expect(ds.flatUIDs.last == PhotoUID(volumeID: "v", nodeID: "mar-3"))
        // Empty library → no layout sections at all.
        let empty = MetalGridProductionAdapter.makeDataSource(sections: [], feed: feed())
        #expect(empty.sectionCounts == [])
        #expect(empty.flatUIDs.isEmpty)
    }

    // ProductionMonthMarkersStillUseOriginalTimelineSectionsTest
    @Test func productionMonthMarkersStillUseOriginalTimelineSections() {
        let markers = MetalGridProductionAdapter.monthMarkers(sections: sampleSections())
        // One marker per month boundary in flat order: Jan @0, Feb @5, Mar @12 (5 + 7 = 12). Derived from the
        // items' capture dates (the original sections), NOT from the single physical layout section.
        #expect(markers.map(\.index) == [0, 5, 12], "month markers must come from the items' dates, got \(markers.map(\.index))")
        #expect(markers.count == 3)
        #expect(markers.allSatisfy { !$0.text.isEmpty })
        #expect(Set(markers.map(\.text)).count == 3, "each month label is distinct")
    }

    // ProductionBeginZoomTransactionIsAvailableTest
    @Test func productionBeginZoomTransactionIsAvailable() {
        // An engine built from production-style single-section counts can capture the live transaction.
        let e = SquareTileGridEngine(sectionCounts: [16])
        let tx = e.beginZoomTransaction(cursorContentPoint: CGPoint(x: 200, y: 300),
                                        viewportPoint: CGPoint(x: 200, y: 300), level: 3, width: 1400)
        #expect(tx != nil, "production single-section engine must be able to begin a live zoom transaction")
    }

    // ProductionGridTransactionNotDisabledByTimelineSectionsTest
    @Test func productionGridTransactionNotDisabledByTimelineSections() {
        // Many date-grouped TimelineSections feed the data source, but it flattens them → the engine the
        // coordinator builds (`SquareTileGridEngine(sectionCounts: dataSource.sectionCounts)`) is single-
        // section, so the live transaction is NOT disabled by having multiple timeline sections.
        let manySections = (0 ..< 40).map { s in
            TimelineSection(id: "2026-\(s)", date: day(2026, 1, 1), title: "S\(s)",
                            items: (0 ..< 25).map { item("s\(s)-\($0)", day(2026, 1, 1)) })
        }
        let ds = MetalGridProductionAdapter.makeDataSource(sections: manySections, feed: feed())
        #expect(ds.sectionCounts.count == 1, "40 timeline sections must collapse to ONE layout section")
        #expect(ds.sectionCounts == [40 * 25])

        let engine = SquareTileGridEngine(sectionCounts: ds.sectionCounts)
        let tx = engine.beginZoomTransaction(cursorContentPoint: CGPoint(x: 200, y: 500),
                                             viewportPoint: CGPoint(x: 200, y: 300), level: 3, width: 1400)
        #expect(tx != nil, "timeline sections must NOT disable the production live transaction")
    }
}

private actor NoopThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void) async {}
}
