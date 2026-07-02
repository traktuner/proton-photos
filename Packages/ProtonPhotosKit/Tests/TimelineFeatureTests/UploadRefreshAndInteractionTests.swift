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

    init(timelines: [[TimelineSection]]) {
        self.timelines = timelines
    }

    func loadTimeline() async throws -> [TimelineSection] {
        lock.withLock {
            _loadCount += 1
            if timelines.count > 1 {
                return timelines.removeFirst()
            }
            return timelines.first ?? []
        }
    }

    func cachedTimeline() async -> [TimelineSection]? { nil }

    var loadCount: Int {
        lock.withLock { _loadCount }
    }
}

private actor EmptyThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void) async -> ThumbnailBatchLoadResult { .delivered }
}
