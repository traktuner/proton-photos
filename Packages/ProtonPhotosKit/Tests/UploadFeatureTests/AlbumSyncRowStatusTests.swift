import XCTest
@testable import PhotoLibraryBackupAdapter

final class AlbumSyncRowStatusTests: XCTestCase {

    func testAttentionOverridesRecentSyncedStateInAlbumRows() {
        let album = AlbumSyncController.SelectedAlbum(
            id: "album-1",
            title: "FaceApp",
            assetCount: 2,
            state: .synced(Date(timeIntervalSince1970: 1_720_000_000)),
            needsAttentionCount: 1
        )

        XCTAssertTrue(album.hasNeedsAttention)
        XCTAssertNotEqual(
            album.localizedRowStatusDescription,
            album.localizedStateDescription,
            "a row with failed photos must not present itself as cleanly synced"
        )
    }
}
