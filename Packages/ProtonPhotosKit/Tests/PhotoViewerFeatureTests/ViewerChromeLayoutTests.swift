import XCTest
import CoreGraphics
@testable import PhotoViewerCore
@testable import PhotoViewerFeature

final class ViewerChromeLayoutTests: XCTestCase {
    func testInfoPanelDoesNotCoverToolbar() {
        let container = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertFalse(ViewerChromeLayout.inspectorOverlapsToolbar(container: container))
        XCTAssertEqual(ViewerChromeLayout.inspectorFrame(in: container).minY, ViewerChromeLayout.toolbarHeight)
    }

    func testInspectorWidthIsStableAndClamped() {
        let wide = CGRect(x: 0, y: 0, width: 1200, height: 800)
        XCTAssertEqual(ViewerChromeLayout.inspectorFrame(in: wide).width, ViewerChromeLayout.inspectorWidth)

        let narrow = CGRect(x: 0, y: 0, width: 330, height: 800)
        XCTAssertEqual(ViewerChromeLayout.inspectorFrame(in: narrow).width, 330)
    }
}
