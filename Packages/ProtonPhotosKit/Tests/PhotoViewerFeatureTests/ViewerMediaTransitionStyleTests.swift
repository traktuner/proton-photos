import XCTest
@testable import PhotoViewerFeature

final class ViewerMediaTransitionStyleTests: XCTestCase {
    func testStandardStylePreservesLivePhotoTiming() {
        let style = ViewerMediaTransitionStyle.standard
        XCTAssertEqual(style.opacityDuration, 0.18, accuracy: 0.000_001)
        XCTAssertEqual(style.scaleDuration, 0.30, accuracy: 0.000_001)
        XCTAssertEqual(style.liveMotionScale, 1.04, accuracy: 0.000_001)
    }

    func testViewerReusesSharedTransitionStyleForMotionAndOriginalReveal() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PhotoViewerFeatureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ProtonPhotosKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // repo

        let view = try String(
            contentsOf: repo.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotoViewerFeature/PhotoViewerView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(view.contains("private let mediaTransition = ViewerMediaTransitionStyle.standard"))
        XCTAssertTrue(view.contains(".animation(mediaTransition.opacityAnimation, value: model.isMotionPlaying)"))
        XCTAssertTrue(view.contains("mediaTransition.liveMotionScale"))
        XCTAssertFalse(view.contains(".easeInOut(duration: 0.18)"), "Live Photo fade duration must not be hardcoded in the view")
        XCTAssertFalse(view.contains(".easeInOut(duration: 0.3)"), "Live Photo scale duration must not be hardcoded in the view")

        let zoomable = try String(
            contentsOf: repo.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotoViewerFeature/ZoomableImageView.swift"),
            encoding: .utf8
        )
        XCTAssertTrue(zoomable.contains("sameItem && !context.coordinator.isSharp && isSharp && !isDismissing"))
        XCTAssertTrue(zoomable.contains("imageView.crossfadeToImage(image, style: transitionStyle)"))
        XCTAssertTrue(zoomable.contains("context.duration = style.opacityDuration"))
    }
}
