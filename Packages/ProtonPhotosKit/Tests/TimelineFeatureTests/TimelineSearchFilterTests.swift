import Foundation
import Testing
import PhotosCore
@testable import TimelineFeature

@Suite struct TimelineSearchFilterTests {
    private let baseDate = Date(timeIntervalSince1970: 1_771_200_000) // 2026-02-15

    @Test func searchMatchesSectionTitleAndKeepsWholeSection() {
        let sections = makeSections()
        let result = TimelineView.filteredSections(sections, query: "Feb")
        #expect(result.count == 1)
        #expect(result.first?.title == "15. Februar 2026")
        #expect(result.first?.items.count == 2)
    }

    @Test func searchMatchesItemMediaTypeAndFiltersWithinSection() {
        let sections = makeSections()
        let result = TimelineView.filteredSections(sections, query: "video")
        #expect(result.count == 1)
        #expect(result.first?.items.map(\.uid.nodeID) == ["video-node"])
    }

    @Test func searchMatchesNodeIDCaseInsensitively() {
        let sections = makeSections()
        let result = TimelineView.filteredSections(sections, query: "PORTRAIT")
        #expect(result.flatMap(\.items).map(\.uid.nodeID) == ["portrait-node"])
    }

    private func makeSections() -> [TimelineSection] {
        [
            TimelineSection(
                id: "2026-02-15",
                date: baseDate,
                title: "15. Februar 2026",
                items: [
                    PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "portrait-node"),
                              captureTime: baseDate,
                              mediaType: "image/jpeg"),
                    PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "video-node"),
                              captureTime: baseDate.addingTimeInterval(60),
                              mediaType: "video/quicktime")
                ]
            ),
            TimelineSection(
                id: "2026-03-01",
                date: baseDate.addingTimeInterval(14 * 86_400),
                title: "1. Marz 2026",
                items: [
                    PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "scan-node"),
                              captureTime: baseDate.addingTimeInterval(14 * 86_400),
                              mediaType: "image/png")
                ]
            )
        ]
    }
}
