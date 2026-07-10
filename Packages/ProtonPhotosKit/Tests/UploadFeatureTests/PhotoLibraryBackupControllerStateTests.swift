import Foundation
import XCTest
import PhotosCore
import UploadCore
@testable import PhotoLibraryBackupAdapter

@MainActor
final class PhotoLibraryBackupControllerStateTests: XCTestCase {
    func testDisablingBackupClearsPersistedUserPause() throws {
        let suite = "photo-backup-controller-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "photoBackup.userPaused.v1")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }

        let controller = PhotoLibraryBackupController(
            configuration: .init(
                accountDataDirectory: directory,
                databasePolicy: .conservative,
                defaults: defaults
            ),
            identityResolver: nil,
            uploader: MockUploader()
        )
        XCTAssertTrue(controller.isUserPaused)

        controller.disableBackup()

        XCTAssertFalse(controller.isUserPaused)
        XCTAssertFalse(defaults.bool(forKey: "photoBackup.userPaused.v1"))
    }
}
