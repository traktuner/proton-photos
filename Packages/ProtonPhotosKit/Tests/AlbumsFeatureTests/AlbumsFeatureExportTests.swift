import XCTest
import AlbumsFeature

final class AlbumsFeatureExportTests: XCTestCase {
    func testAlbumsFeatureReExportsUniversalAlbumCore() {
        XCTAssertEqual(AlbumCapabilities.readOnly.canList, true)
        XCTAssertEqual(AlbumCapabilities.readOnly.canCreate, false)
    }
}
