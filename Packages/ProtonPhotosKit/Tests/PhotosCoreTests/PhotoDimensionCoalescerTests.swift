import XCTest
@testable import PhotosCore

/// Guards the decode→DB dimension pipeline's batching contract: per-decode callbacks are deduped
/// and coalesced into ONE store batch (no per-decode writes), invalid sizes are dropped, and a UID
/// already flushed this session is never re-sent (re-decodes of evicted thumbnails are free).
final class PhotoDimensionCoalescerTests: XCTestCase {

    private actor RecordingStore: PhotoDimensionRecording {
        private(set) var batches: [[PhotoUID: PhotoPixelDimensions]] = []
        func recordDimensions(_ batch: [PhotoUID: PhotoPixelDimensions]) async {
            batches.append(batch)
        }
        func received() -> [[PhotoUID: PhotoPixelDimensions]] { batches }
    }

    private let a = PhotoUID(volumeID: "vol", nodeID: "a")
    private let b = PhotoUID(volumeID: "vol", nodeID: "b")

    func testCoalescesDedupesAndFlushesOneBatch() async throws {
        let store = RecordingStore()
        // Long delay: flushing happens only via flushNow(), so the test is deterministic.
        let coalescer = PhotoDimensionCoalescer(store: store, flushDelay: .seconds(600))

        await coalescer.enqueue(a, try XCTUnwrap(PhotoPixelDimensions(width: 320, height: 240)))
        // Duplicate sighting of the same UID (a re-decode) — first one wins.
        await coalescer.enqueue(a, try XCTUnwrap(PhotoPixelDimensions(width: 999, height: 111)))
        await coalescer.enqueue(b, try XCTUnwrap(PhotoPixelDimensions(width: 100, height: 100)))
        await coalescer.flushNow()

        let batches = await store.received()
        XCTAssertEqual(batches.count, 1, "one batched write, not one per decode")
        XCTAssertEqual(batches.first, [
            a: try XCTUnwrap(PhotoPixelDimensions(width: 320, height: 240)),
            b: try XCTUnwrap(PhotoPixelDimensions(width: 100, height: 100)),
        ])
    }

    func testFlushedUIDsAreNotResentAndEmptyFlushIsSilent() async throws {
        let store = RecordingStore()
        let coalescer = PhotoDimensionCoalescer(store: store, flushDelay: .seconds(600))

        await coalescer.enqueue(a, try XCTUnwrap(PhotoPixelDimensions(width: 320, height: 240)))
        await coalescer.flushNow()
        // The same UID after a flush (thumbnail evicted + re-decoded) must not re-hit the store.
        await coalescer.enqueue(a, try XCTUnwrap(PhotoPixelDimensions(width: 320, height: 240)))
        await coalescer.flushNow()
        // And a flush with nothing pending stays silent.
        await coalescer.flushNow()

        let batches = await store.received()
        XCTAssertEqual(batches.count, 1)
    }

    func testInvalidSizesAreDroppedAtTheDoor() {
        XCTAssertNil(PhotoPixelDimensions(width: 0, height: 240))
        XCTAssertNil(PhotoPixelDimensions(width: 320, height: 0))
        XCTAssertNil(PhotoPixelDimensions(width: -1, height: -1))
        XCTAssertEqual(PhotoPixelDimensions(width: 4032, height: 3024)?.aspectRatio ?? 0, 4.0 / 3.0, accuracy: 1e-9)
    }
}
