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

    @Test func cachedFilterRouteIsShownImmediatelyWhileRefreshing() async {
        let oldFavorite = photo("old-favorite", month: 1)
        let newFavorite = photo("new-favorite", month: 1)
        let all = photo("all", month: 1)
        let favoriteFilter = PhotoFilter.tag(.favorites)
        let library = VisibleContentLibrary(
            timelines: [
                favoriteFilter: [
                    [section([oldFavorite])],
                    [section([newFavorite])]
                ]
            ],
            delayAfterFirstRequest: [favoriteFilter: .milliseconds(120)]
        )
        let model = TimelineViewModel(
            repository: VisibleContentRepository(timelines: [[section([all])]]),
            feed: makeVisibleContentFeed(),
            library: library
        )

        await model.select(favoriteFilter)
        #expect(model.allItems.map(\.uid) == [oldFavorite.uid])

        await model.select(.all)
        #expect(model.allItems.map(\.uid) == [all.uid])

        let refresh = Task { await model.select(favoriteFilter) }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(model.allItems.map(\.uid) == [oldFavorite.uid])

        await refresh.value
        #expect(model.allItems.map(\.uid) == [newFavorite.uid])
    }

    @Test func slowAllLoadDoesNotClobberSelectedFilter() async {
        let all = photo("all-after-delay", month: 1)
        let favorite = photo("favorite-selected", month: 1)
        let favoriteFilter = PhotoFilter.tag(.favorites)
        let model = TimelineViewModel(
            repository: VisibleContentRepository(
                timelines: [[section([all])]],
                cachedDelay: .milliseconds(120)
            ),
            feed: makeVisibleContentFeed(),
            library: VisibleContentLibrary(timelines: [favoriteFilter: [[section([favorite])]]])
        )

        let initialAllLoad = Task { await model.load() }
        try? await Task.sleep(for: .milliseconds(20))

        await model.select(favoriteFilter)
        await initialAllLoad.value

        #expect(model.allItems.map(\.uid) == [favorite.uid])
        let visible = model.visibleContent(searchText: "", favoriteUIDs: [], includeMonthMarkers: false)
        #expect(visible.items.map(\.uid) == [favorite.uid])
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
    private let cachedDelay: Duration?

    init(timelines: [[TimelineSection]], cachedDelay: Duration? = nil) {
        self.timelines = timelines
        self.cachedDelay = cachedDelay
    }

    func loadTimeline() async throws -> [TimelineSection] {
        lock.withLock {
            if timelines.count > 1 {
                return timelines.removeFirst()
            }
            return timelines.first ?? []
        }
    }

    func cachedTimeline() async -> [TimelineSection]? {
        if let cachedDelay {
            try? await Task.sleep(for: cachedDelay)
        }
        return nil
    }
}

private actor VisibleContentLibrary: PhotoLibraryProvider {
    private var timelines: [PhotoFilter: [[TimelineSection]]]
    private let delayAfterFirstRequest: [PhotoFilter: Duration]
    private var requestCounts: [PhotoFilter: Int] = [:]

    init(
        timelines: [PhotoFilter: [[TimelineSection]]],
        delayAfterFirstRequest: [PhotoFilter: Duration] = [:]
    ) {
        self.timelines = timelines
        self.delayAfterFirstRequest = delayAfterFirstRequest
    }

    func albums() async throws -> [PhotoAlbum] { [] }

    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] {
        let count = requestCounts[filter, default: 0]
        requestCounts[filter] = count + 1
        if count > 0, let delay = delayAfterFirstRequest[filter] {
            try? await Task.sleep(for: delay)
        }
        var sequence = timelines[filter] ?? []
        if sequence.count > 1 {
            let next = sequence.removeFirst()
            timelines[filter] = sequence
            return next
        }
        return sequence.first ?? []
    }
}

private actor VisibleContentThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void) async {}
}
