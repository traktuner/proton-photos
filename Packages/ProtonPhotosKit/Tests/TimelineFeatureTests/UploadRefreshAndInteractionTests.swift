import XCTest
import PhotosCore
import MediaCache
import TimelineCore
@testable import TimelineFeature

final class UploadRefreshAndInteractionTests: XCTestCase {
    @MainActor
    func testManualRefreshReloadsAndDeduplicatesTimeline() async {
        let old = photo("old", seconds: 1)
        let new = photo("new", seconds: 2)
        let repository = RefreshRepository(timelines: [
            [section([old])],
            [section([old, new, new])],
        ])
        let model = TimelineViewModel(repository: repository, feed: makeFeed())

        await model.load()
        XCTAssertEqual(model.allItems.map(\.uid), [old.uid])

        let result = await model.refreshLibrary()
        XCTAssertEqual(result.timelineCountBefore, 1)
        XCTAssertEqual(result.timelineCountAfter, 2)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(model.allItems.map(\.uid), [old.uid, new.uid])
        XCTAssertEqual(repository.loadCount, 2)
    }

    @MainActor
    func testRefreshAfterUploadFindsUploadedUID() async {
        let uploaded = photo("uploaded", seconds: 2)
        let repository = RefreshRepository(timelines: [
            [section([])],
            [section([uploaded])],
        ])
        let model = TimelineViewModel(repository: repository, feed: makeFeed())

        await model.load()
        let result = await model.refreshAfterUpload(uploadedUID: uploaded.uid)

        XCTAssertTrue(result.found)
        XCTAssertEqual(result.foundItem?.uid, uploaded.uid)
        XCTAssertEqual(result.filterDescription, "all")
    }

    // MARK: - Main-actor refresh: no-op unchanged refresh + `.all` session snapshot

    func testTimelineContentUnchangedHelper() {
        let a = photo("a", seconds: 1)
        let b = photo("b", seconds: 2)
        let sections = [section([a, b])]
        // Identical flattened content → unchanged.
        XCTAssertTrue(TimelineViewModel.timelineContentUnchanged(sections, vs: [a, b]))
        // A different count, a reorder, a removed item, or an appended item → changed.
        XCTAssertFalse(TimelineViewModel.timelineContentUnchanged(sections, vs: [a]))
        XCTAssertFalse(TimelineViewModel.timelineContentUnchanged(sections, vs: [b, a]))
        XCTAssertFalse(TimelineViewModel.timelineContentUnchanged(sections, vs: [a, b, photo("c", seconds: 3)]))
        // Same items but re-grouped into two sections still flattens equal → unchanged.
        XCTAssertTrue(TimelineViewModel.timelineContentUnchanged([section([a]), section([b])], vs: [a, b]))
    }

    @MainActor
    func testUnchangedAllRefreshDoesNotReassignOrRestartPrefetch() async {
        let a = photo("a", seconds: 1)
        let b = photo("b", seconds: 2)
        let repository = RefreshRepository(timelines: [[section([a, b])], [section([a, b])]])
        let model = TimelineViewModel(repository: repository, feed: makeFeed())
        await model.load()

        PhotoDiagnostics.shared.resetForTests()
        let result = await model.refreshLibrary()   // fresh content identical to what's shown

        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.refresh.unchangedSkip"), 1)
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.refresh.applied"), 0)   // no reassignment, no prefetch restart
        XCTAssertEqual(result.timelineCountBefore, 2)
        XCTAssertEqual(result.timelineCountAfter, 2)
        XCTAssertNil(result.errorMessage)
        XCTAssertEqual(model.allItems.map(\.uid), [a.uid, b.uid])
    }

    @MainActor
    func testChangedAllRefreshAppliesExactlyOnce() async {
        let a = photo("a", seconds: 1)
        let b = photo("b", seconds: 2)
        let repository = RefreshRepository(timelines: [[section([a])], [section([a, b])]])
        let model = TimelineViewModel(repository: repository, feed: makeFeed())
        await model.load()

        PhotoDiagnostics.shared.resetForTests()
        _ = await model.refreshLibrary()   // content changed (b appeared)

        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.refresh.applied"), 1)
        XCTAssertEqual(PhotoDiagnostics.shared.counter("timeline.refresh.unchangedSkip"), 0)
        XCTAssertEqual(model.allItems.map(\.uid), [a.uid, b.uid])
    }

    @MainActor
    func testAllRevisitUsesSessionSnapshotNotDiskReload() async {
        let a = photo("a", seconds: 1)
        let repository = RefreshRepository(timelines: [[section([a])]])
        let library = FakeLibrary(sections: [section([photo("raw", seconds: 5)])])
        let model = TimelineViewModel(repository: repository, feed: makeFeed(), library: library)
        await model.load()
        XCTAssertEqual(repository.cachedCount, 1)   // first visit consulted the on-disk cache once

        await model.select(.tag(.raw))   // leave All Photos
        PhotoDiagnostics.shared.resetForTests()
        await model.select(.all)                                                   // return to All Photos

        // The revisit shows the in-memory snapshot instantly - it must NOT re-read the on-disk cache.
        XCTAssertEqual(repository.cachedCount, 1)
        XCTAssertGreaterThanOrEqual(PhotoDiagnostics.shared.counter("timeline.refresh.snapshotHit"), 1)
        XCTAssertEqual(model.allItems.map(\.uid), [a.uid])
    }

    @MainActor
    func testSlowAllRefreshDoesNotClobberSelectedFilteredRoute() async {
        let a = photo("a", seconds: 1)
        let rawItem = photo("raw", seconds: 5)
        let repository = RefreshRepository(timelines: [[section([a])], [section([a])]])
        let library = FakeLibrary(sections: [section([rawItem])])
        let model = TimelineViewModel(repository: repository, feed: makeFeed(), library: library)
        await model.load()

        // Kick a slow `.all` refresh, then switch to a filtered route before it finishes; the stale `.all`
        // result must not overwrite the newly-selected route.
        repository.loadDelayMs = 120
        async let refresh: Void = { _ = await model.refreshLibrary() }()
        await model.select(.tag(.raw))
        _ = await refresh

        XCTAssertEqual(model.filter, .tag(.raw))
        XCTAssertEqual(model.allItems.map(\.uid), [rawItem.uid])   // filtered route intact, not clobbered by All
    }

    func testUploadRefreshRetryScheduleIsBounded() {
        let schedule = TimelineRefreshRetrySchedule.uploadDefault
        XCTAssertEqual(schedule.delays, [.zero, .seconds(1), .seconds(3), .seconds(8), .seconds(18)])
    }

    func testSingleClickSelectsAndDoesNotOpenViewer() {
        let decision = GridInteractionPolicy.decision(click: .single, selectionMode: false)
        XCTAssertFalse(decision.opensViewer)
        XCTAssertEqual(decision.selection, .replace)
    }

    func testDoubleClickOpensViewer() {
        let decision = GridInteractionPolicy.decision(click: .double, selectionMode: false)
        XCTAssertTrue(decision.opensViewer)
        XCTAssertEqual(decision.selection, .none)
    }

    func testCmdClickTogglesSelection() {
        let decision = GridInteractionPolicy.decision(click: .single, modifiers: .command, selectionMode: false)
        XCTAssertFalse(decision.opensViewer)
        XCTAssertEqual(decision.selection, .toggle)
    }

    func testShiftClickRangeSelects() {
        let decision = GridInteractionPolicy.decision(click: .single, modifiers: .shift, selectionMode: false)
        XCTAssertFalse(decision.opensViewer)
        XCTAssertEqual(decision.selection, .range)
    }

    func testSelectionModeSingleClickTogglesSelection() {
        let decision = GridInteractionPolicy.decision(click: .single, selectionMode: true)
        XCTAssertFalse(decision.opensViewer)
        XCTAssertEqual(decision.selection, .toggle)
    }

    func testDoubleClickOpensViewerEvenInSelectionMode() {
        let decision = GridInteractionPolicy.decision(click: .double, selectionMode: true)
        XCTAssertTrue(decision.opensViewer)
    }
}

@MainActor private func makeFeed() -> ThumbnailFeed {
    let namespace = "tests-refresh-\(UUID().uuidString)"
    let root = timelineFeatureTestCacheRoot("upload-refresh")
    return ThumbnailFeed(cache: ThumbnailCache(namespace: namespace, rootDirectory: root), loader: EmptyThumbnailLoader())
}

private func photo(_ id: String, seconds: TimeInterval) -> PhotoItem {
    PhotoItem(uid: PhotoUID(volumeID: "vol", nodeID: id),
              captureTime: Date(timeIntervalSince1970: seconds),
              mediaType: "image/jpeg")
}

private func section(_ items: [PhotoItem]) -> TimelineSection {
    TimelineSection(id: "all", date: items.first?.captureTime ?? .distantPast, title: "", items: items)
}

private final class RefreshRepository: PhotosRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var timelines: [[TimelineSection]]
    private var _loadCount = 0
    private var _cachedCount = 0
    private var _loadDelayMs = 0

    init(timelines: [[TimelineSection]]) {
        self.timelines = timelines
    }

    func loadTimeline() async throws -> [TimelineSection] {
        let delay = lock.withLock { _loadDelayMs }
        if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
        return lock.withLock {
            _loadCount += 1
            if timelines.count > 1 {
                return timelines.removeFirst()
            }
            return timelines.first ?? []
        }
    }

    func cachedTimeline() async -> [TimelineSection]? {
        lock.withLock { _cachedCount += 1 }
        return nil
    }

    var loadCount: Int { lock.withLock { _loadCount } }
    var cachedCount: Int { lock.withLock { _cachedCount } }
    var loadDelayMs: Int {
        get { lock.withLock { _loadDelayMs } }
        set { lock.withLock { _loadDelayMs = newValue } }
    }
}

private final class FakeLibrary: PhotoLibraryProvider, @unchecked Sendable {
    private let sections: [TimelineSection]
    init(sections: [TimelineSection]) { self.sections = sections }
    func albums() async throws -> [PhotoAlbum] { [] }
    func timeline(filter: PhotoFilter) async throws -> [TimelineSection] { sections }
}

private actor EmptyThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void) async -> ThumbnailBatchLoadResult { .delivered }
}
