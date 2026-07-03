import XCTest
import Foundation
import PhotosCore
@testable import PhotoViewerCore

/// Locks the shared Live Photo motion policy + controller both platforms drive, so the "when do we prepare a
/// motion clip" rule and the safe idle behavior can never drift between macOS and iOS.
final class LivePhotoMotionTests: XCTestCase {

    private func item(isLivePhoto: Bool, relatedVideoID: String?) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: "v", nodeID: "n"),
            captureTime: Date(timeIntervalSince1970: 0),
            mediaType: "image/heic",
            isLivePhoto: isLivePhoto,
            relatedVideoID: relatedVideoID
        )
    }

    func testShouldPrepareOnlyForLivePhotoWithPairedVideoAndStreamer() {
        let live = item(isLivePhoto: true, relatedVideoID: "motion")
        XCTAssertTrue(LivePhotoMotionPolicy.shouldPrepare(item: live, hasStreamer: true))
    }

    func testShouldNotPrepareWithoutStreamer() {
        let live = item(isLivePhoto: true, relatedVideoID: "motion")
        XCTAssertFalse(LivePhotoMotionPolicy.shouldPrepare(item: live, hasStreamer: false))
    }

    func testShouldNotPrepareForNonLiveItem() {
        let still = item(isLivePhoto: false, relatedVideoID: "motion")
        XCTAssertFalse(LivePhotoMotionPolicy.shouldPrepare(item: still, hasStreamer: true))
    }

    func testShouldNotPrepareWhenNoPairedVideo() {
        // A Live Photo whose backend path has not enriched the paired video id yet cannot be prepared.
        let live = item(isLivePhoto: true, relatedVideoID: nil)
        XCTAssertFalse(LivePhotoMotionPolicy.shouldPrepare(item: live, hasStreamer: true))
    }

    @MainActor
    func testControllerIdleOperationsAreSafeNoOps() {
        // With no prepared player, play/stop/teardown must not crash and must leave the state clean.
        let controller = LivePhotoMotionController()
        XCTAssertNil(controller.player)
        XCTAssertFalse(controller.isPlaying)
        controller.play()
        XCTAssertFalse(controller.isPlaying, "play() with no player must stay stopped")
        controller.stop()
        controller.teardown()
        XCTAssertNil(controller.player)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testPrepareForNonLiveItemLeavesNoPlayer() {
        // No streamer + non-Live item → shouldPrepare is false, so the controller stays idle.
        let controller = LivePhotoMotionController()
        controller.prepare(for: item(isLivePhoto: false, relatedVideoID: nil), streamer: nil) { true }
        XCTAssertNil(controller.player)
        XCTAssertFalse(controller.isPlaying)
    }
}
