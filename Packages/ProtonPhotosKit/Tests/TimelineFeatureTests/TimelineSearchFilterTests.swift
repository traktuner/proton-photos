import Foundation
import Testing
import PhotosCore
import TimelineCore
@testable import TimelineFeature

@Suite struct TimelineSearchFilterTests {
    private let baseDate = Self.date(2026, 2, 15, 10, 30)

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

    @Test func searchMatchesGermanDateTokens() {
        let sections = makeSections()
        let result = TimelineView.filteredSections(sections, query: "15. Februar 2026")
        #expect(result.flatMap(\.items).map(\.uid.nodeID) == ["portrait-node", "video-node"])
    }

    @Test func searchMatchesIsoDateTokens() {
        let sections = makeSections()
        let result = TimelineView.filteredSections(sections, query: "2026-03-01")
        #expect(result.flatMap(\.items).map(\.uid.nodeID) == ["scan-node", "raw-node", "selfie-node"])
    }

    @Test func smartSearchMatchesFavoritesFromContext() {
        let sections = makeSections()
        let favorite = PhotoUID(volumeID: "v", nodeID: "scan-node")
        let result = TimelineView.filteredSections(
            sections,
            query: "Favoriten",
            context: TimelineSearchContext(favoriteUIDs: [favorite])
        )
        #expect(result.flatMap(\.items).map(\.uid.nodeID) == ["scan-node"])
    }

    @Test func smartSearchMatchesServerSideTags() {
        let sections = makeSections()
        let raw = TimelineView.filteredSections(sections, query: "raw")
        let selfie = TimelineView.filteredSections(sections, query: "selfies")
        #expect(raw.flatMap(\.items).map(\.uid.nodeID) == ["raw-node"])
        #expect(selfie.flatMap(\.items).map(\.uid.nodeID) == ["selfie-node"])
    }

    @Test func smartSearchRespectsActiveServerFilterWhenTagsAreMissingLocally() {
        let sections = [
            TimelineSection(id: "filtered", date: baseDate, title: "", items: [
                PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "server-filtered-a"),
                          captureTime: baseDate,
                          mediaType: "image/jpeg")
            ])
        ]

        let result = TimelineView.filteredSections(
            sections,
            query: "screenshots",
            context: TimelineSearchContext(activeFilter: .tag(.screenshots))
        )
        #expect(result.flatMap(\.items).map(\.uid.nodeID) == ["server-filtered-a"])
    }

    @Test func smartSearchCanCombineKindAndDate() {
        let sections = makeSections()
        let result = TimelineView.filteredSections(sections, query: "video 2026 februar")
        #expect(result.flatMap(\.items).map(\.uid.nodeID) == ["video-node"])
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
                              mediaType: "image/png"),
                    PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "raw-node"),
                              captureTime: baseDate.addingTimeInterval(14 * 86_400 + 60),
                              mediaType: "image/x-adobe-dng",
                              tags: [.raw]),
                    PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "selfie-node"),
                              captureTime: baseDate.addingTimeInterval(14 * 86_400 + 120),
                              mediaType: "image/jpeg",
                              tags: [.selfies])
                ]
            )
        ]
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }
}
