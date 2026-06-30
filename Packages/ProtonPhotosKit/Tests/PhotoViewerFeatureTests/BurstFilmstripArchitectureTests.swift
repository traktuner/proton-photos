import XCTest
import Foundation
import PhotosCore
import MediaCache
@testable import PhotoViewerFeature

final class BurstFilmstripArchitectureTests: XCTestCase {
    func testBurstFilmstripUsesSharedViewerModelAndDoesNotOwnBackendLoading() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotoViewerFeatureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ProtonPhotosKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repo

        let model = try String(
            contentsOf: repo.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotoViewerFeature/PhotoViewerModel.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(model.contains("private let burstProvider: BurstGroupProvider?"))
        XCTAssertTrue(model.contains("public func selectBurstIndex"))
        XCTAssertTrue(model.contains("public func nextInContext"))
        XCTAssertTrue(model.contains("public func previousInContext"))
        XCTAssertTrue(model.contains("private func loadDisplayedItem(_ item: PhotoItem)"))
        XCTAssertTrue(model.contains("public var exportItemsForDownload"))

        let view = try String(
            contentsOf: repo.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotoViewerFeature/PhotoViewerView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(view.contains("BurstFilmstripView("))
        XCTAssertTrue(view.contains("model.selectBurstIndex($0)"))
        XCTAssertTrue(view.contains("model.canNavigatePrevious"))
        XCTAssertTrue(view.contains("model.canNavigateNext"))
        XCTAssertTrue(view.contains("burstFilmstripItemSide(panelWidth: width"))
        XCTAssertTrue(view.contains("burstFilmstripNeedsScroller(panelWidth: width"))
        XCTAssertFalse(view.contains("min(max(contentSize.width - 40, 320), 1240)"),
                       "The series filmstrip must scale with the viewer width, not stay capped to a narrow fixed panel")
        XCTAssertFalse(view.contains("burstGroup(containing:"), "The SwiftUI/AppKit view must not call the backend directly")

        let filmstrip = try String(
            contentsOf: repo.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotoViewerFeature/BurstFilmstripView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(filmstrip.contains("let itemSide: CGFloat"))
        XCTAssertTrue(filmstrip.contains("scrollView.contentView.drawsBackground = false"))
        XCTAssertTrue(filmstrip.contains("scrollView.hasHorizontalScroller = showsHorizontalScroller"))
        XCTAssertTrue(filmstrip.contains("layout.itemSize = NSSize(width: itemSide, height: itemSide)"))

        let mainView = try String(
            contentsOf: repo.appendingPathComponent("App/Views/MainView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(mainView.contains("makeExportRequest(for: items"))
        XCTAssertTrue(mainView.contains("backend.burstGroup(containing: item.uid)"))
        XCTAssertTrue(mainView.contains("export.series_zip_suffix"))
        XCTAssertTrue(mainView.contains("downloadViewerSelection(viewerModel)"))
    }

    @MainActor
    func testViewerSeedsKnownBurstMembersBeforeProviderResponse() async {
        let items = [
            makeItem("a", burstMembers: ["a", "b", "c"]),
            makeItem("b", burstMembers: ["a", "b", "c"]),
            makeItem("c", burstMembers: ["a", "b", "c"]),
        ]
        let model = PhotoViewerModel(
            items: items,
            index: 1,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "burst-filmstrip-\(UUID().uuidString)"),
                loader: EmptyThumbnailLoader(),
                aspects: AspectRegistry()
            ),
            media: FailingMediaProvider(),
            burstProvider: EmptyBurstProvider()
        )
        model.start()
        defer { model.stop() }

        XCTAssertTrue(model.hasBurstFilmstrip)
        XCTAssertEqual(model.burstItems.map(\.uid.nodeID), ["a", "b", "c"])
        XCTAssertEqual(model.burstIndex, 1)

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.hasBurstFilmstrip, "An empty provider response must not clear a known timeline burst group")

        model.selectBurstIndex(2)
        XCTAssertEqual(model.current.uid.nodeID, "c")
        XCTAssertEqual(model.exportItemsForDownload.map(\.uid.nodeID), ["a", "b", "c"])
    }

    @MainActor
    func testContextualNavigationPrefersFilmstripThenFallsThroughToLibrary() async {
        let title = makeItem("b", burstMembers: ["a", "b", "c"])
        let nextLibraryItem = makeItem("d", burstMembers: [])
        let burst = [
            makeItem("a", burstMembers: ["a", "b", "c"]),
            title,
            makeItem("c", burstMembers: ["a", "b", "c"]),
        ]
        let model = PhotoViewerModel(
            items: [title, nextLibraryItem],
            index: 0,
            feed: ThumbnailFeed(
                cache: ThumbnailCache(namespace: "burst-navigation-\(UUID().uuidString)"),
                loader: EmptyThumbnailLoader(),
                aspects: AspectRegistry()
            ),
            media: FailingMediaProvider(),
            burstProvider: StaticBurstProvider(items: burst)
        )
        model.start()
        defer { model.stop() }

        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(model.hasBurstFilmstrip)
        XCTAssertEqual(model.current.uid.nodeID, "b")
        XCTAssertEqual(model.index, 0)

        model.nextInContext()
        XCTAssertEqual(model.current.uid.nodeID, "c")
        XCTAssertEqual(model.index, 0, "Right arrow should stay inside the series before changing library item")

        model.nextInContext()
        XCTAssertEqual(model.current.uid.nodeID, "d")
        XCTAssertEqual(model.index, 1, "At the series edge, right arrow should fall through to the next library item")
    }

    private func makeItem(_ id: String, burstMembers: [String]) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: id),
            captureTime: Date(timeIntervalSince1970: Double(id.unicodeScalars.first?.value ?? 0)),
            mediaType: "image/jpeg",
            tags: [.bursts],
            burstMemberIDs: burstMembers
        )
    }
}

private struct EmptyThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void) async {}
}

private struct FailingMediaProvider: FullMediaProvider {
    func preview(for uid: PhotoUID) async throws -> Data { throw TestError.unavailable }
    func originalData(for uid: PhotoUID, onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        throw TestError.unavailable
    }
}

private struct EmptyBurstProvider: BurstGroupProvider {
    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] { [] }
}

private struct StaticBurstProvider: BurstGroupProvider {
    let items: [PhotoItem]
    func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] { items }
}

private enum TestError: Error {
    case unavailable
}
