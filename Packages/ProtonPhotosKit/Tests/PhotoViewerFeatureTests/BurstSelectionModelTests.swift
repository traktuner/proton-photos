import XCTest
import PhotosCore
@testable import PhotoViewerCore

final class BurstSelectionModelTests: XCTestCase {
    func testSeedsKnownTimelineGroupInPresentationOrder() {
        var selection = BurstSelectionModel()
        let items = [
            item("a", members: ["a", "b", "c"]),
            item("b", members: ["a", "b", "c"]),
            item("c", members: ["a", "b", "c"]),
        ]

        selection.seedKnownGroup(for: items[1], libraryItems: items)

        XCTAssertTrue(selection.hasFilmstrip)
        XCTAssertEqual(selection.items.map(\.uid.nodeID), ["a", "b", "c"])
        XCTAssertEqual(selection.selectedIndex, 1)
    }

    func testEmptyProviderResultDoesNotClearSeededTimelineGroup() {
        var selection = BurstSelectionModel()
        let items = [
            item("a", members: ["a", "b", "c"]),
            item("b", members: ["a", "b", "c"]),
            item("c", members: ["a", "b", "c"]),
        ]
        selection.seedKnownGroup(for: items[1], libraryItems: items)
        XCTAssertTrue(selection.beginLoadingIfCandidate(items[1]))

        selection.applyLoadedGroup([], containing: items[1])

        XCTAssertFalse(selection.isLoading)
        XCTAssertTrue(selection.hasFilmstrip)
        XCTAssertEqual(selection.current(fallback: items[1]).uid.nodeID, "b")
    }

    func testSelectionNavigationStaysInsideSeriesUntilEdge() {
        var selection = BurstSelectionModel(
            items: [item("a"), item("b"), item("c")],
            selectedIndex: 1
        )

        XCTAssertEqual(selection.selectNext()?.uid.nodeID, "c")
        XCTAssertNil(selection.selectNext())
        XCTAssertEqual(selection.selectPrevious()?.uid.nodeID, "b")
        XCTAssertEqual(selection.selectPrevious()?.uid.nodeID, "a")
        XCTAssertNil(selection.selectPrevious())
    }

    func testExportAndReturnCandidatesPreferSeriesWhenActive() {
        let base = item("b")
        let selected = item("c")
        let group = [item("a"), base, selected]
        let selection = BurstSelectionModel(items: group, selectedIndex: 2)

        XCTAssertEqual(selection.exportItems(current: selected).map(\.uid.nodeID), ["a", "b", "c"])
        XCTAssertEqual(selection.gridReturnCandidates(current: selected, base: base).map(\.uid.nodeID), ["c", "b"])
    }

    private func item(_ id: String, members: [String] = []) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: id),
            captureTime: Date(timeIntervalSince1970: Double(id.unicodeScalars.first?.value ?? 0)),
            mediaType: "image/jpeg",
            tags: members.isEmpty ? [] : [.bursts],
            burstMemberIDs: members
        )
    }
}
