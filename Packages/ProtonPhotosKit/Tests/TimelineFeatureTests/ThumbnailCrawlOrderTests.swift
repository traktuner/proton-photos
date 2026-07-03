import Foundation
import Testing
import PhotosCore
@testable import MediaCache

/// Proves the background crawl order is newest to oldest.
@Suite("Thumbnail crawl order")
struct ThumbnailCrawlOrderTests {
    private func item(_ id: String, _ t: TimeInterval) -> PhotoItem {
        PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: id), captureTime: Date(timeIntervalSince1970: t), mediaType: "image/jpeg")
    }

    @Test func newestFirstRegardlessOfInputOrder() {
        // Input is oldest-first, like the SQLite store (ORDER BY t ASC).
        let oldestFirst = [item("a", 100), item("b", 200), item("c", 300)]
        let order = ThumbnailCrawlOrder.newestToOldest(oldestFirst)
        #expect(order.map(\.nodeID) == ["c", "b", "a"])   // newest (c) crawled first
        #expect(order.first?.nodeID == "c")
        #expect(order.last?.nodeID == "a")
    }

    @Test func robustToShuffledInput() {
        let shuffled = [item("b", 200), item("a", 100), item("c", 300)]
        #expect(ThumbnailCrawlOrder.newestToOldest(shuffled).map(\.nodeID) == ["c", "b", "a"])
    }

    @Test func stableTieBreakOnEqualTimestamps() {
        // Many photos can share a capture time; the crawl must stay deterministic (resumable checkpoint).
        let sameTime = [item("x", 500), item("y", 500), item("z", 500)]
        // All equal → preserve original order, newest-first sort leaves them as given.
        #expect(ThumbnailCrawlOrder.newestToOldest(sameTime).map(\.nodeID) == ["x", "y", "z"])
    }

    @Test func emptyIsEmpty() {
        #expect(ThumbnailCrawlOrder.newestToOldest([]).isEmpty)
    }
}
