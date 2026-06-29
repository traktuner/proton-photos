import Foundation
import Testing
import PhotosCore
import MediaCache
@testable import TimelineFeature

@MainActor
@Suite struct TimelineVisibleContentTests {
    @Test func favoriteContextInvalidatesCachedSearchResult() async {
        let item = photo("favorite-candidate", month: 1)
        let model = TimelineViewModel(
            repository: VisibleContentRepository(timelines: [[section([item])]]),
            feed: makeVisibleContentFeed()
        )
        await model.load()

        let withoutFavorite = model.visibleContent(
            searchText: "favorites",
            favoriteUIDs: [],
            includeMonthMarkers: false
        )
        #expect(withoutFavorite.isEmptySearchResult)

        let withFavorite = model.visibleContent(
            searchText: "favorites",
            favoriteUIDs: [item.uid],
            includeMonthMarkers: false
        )
        #expect(withFavorite.items.map(\.uid) == [item.uid])
        #expect(!withFavorite.isEmptySearchResult)
    }

    @Test func stateReloadInvalidatesCachedSearchResult() async {
        let old = photo("old-item", month: 1)
        let new = photo("new-item", month: 1)
        let model = TimelineViewModel(
            repository: VisibleContentRepository(timelines: [
                [section([old])],
                [section([new])]
            ]),
            feed: makeVisibleContentFeed()
        )
        await model.load()

        let beforeReload = model.visibleContent(searchText: "new-item", favoriteUIDs: [], includeMonthMarkers: false)
        #expect(beforeReload.isEmptySearchResult)

        _ = await model.refreshLibrary()
        let afterReload = model.visibleContent(searchText: "new-item", favoriteUIDs: [], includeMonthMarkers: false)
        #expect(afterReload.items.map(\.uid) == [new.uid])
    }

    @Test func monthMarkersAreOnlyDerivedWhenRequested() async {
        let january = photo("jan", month: 1)
        let february = photo("feb", month: 2)
        let model = TimelineViewModel(
            repository: VisibleContentRepository(timelines: [[section([january, february])]]),
            feed: makeVisibleContentFeed()
        )
        await model.load()

        let normalLevel = model.visibleContent(searchText: "", favoriteUIDs: [], includeMonthMarkers: false)
        #expect(normalLevel.monthMarkers.isEmpty)

        let overviewLevel = model.visibleContent(searchText: "", favoriteUIDs: [], includeMonthMarkers: true)
        #expect(overviewLevel.monthMarkers.map(\.index) == [0, 1])
        #expect(overviewLevel.items.map(\.uid) == [january.uid, february.uid])
    }

    private func photo(_ id: String, month: Int) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: id),
            captureTime: Self.date(2026, month, 1),
            mediaType: "image/jpeg"
        )
    }

    private func section(_ items: [PhotoItem]) -> TimelineSection {
        TimelineSection(id: "visible-content", date: items.first?.captureTime ?? .distantPast, title: "", items: items)
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
}

@MainActor private func makeVisibleContentFeed() -> ThumbnailFeed {
    let namespace = "tests-visible-content-\(UUID().uuidString)"
    let aspects = AspectRegistry(namespace: namespace)
    return ThumbnailFeed(cache: ThumbnailCache(namespace: namespace), loader: VisibleContentThumbnailLoader(), aspects: aspects)
}

private final class VisibleContentRepository: PhotosRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var timelines: [[TimelineSection]]

    init(timelines: [[TimelineSection]]) {
        self.timelines = timelines
    }

    func loadTimeline() async throws -> [TimelineSection] {
        lock.withLock {
            if timelines.count > 1 {
                return timelines.removeFirst()
            }
            return timelines.first ?? []
        }
    }

    func cachedTimeline() async -> [TimelineSection]? { nil }
}

private actor VisibleContentThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void) async {}
}
