import XCTest
@testable import PhotosCore

/// The sign-out purge is destructive (it erases a highly sensitive photo backup's local state), so
/// its safety gate is pinned here: it fires ONLY when an explicit sign-out armed it, and a sign-in
/// disarms it so a stale flag can never wipe a now-active account on a transient session re-check.
final class BackupLocalDataPurgeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        suiteName = "purge-test-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeTempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("purge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: url.appendingPathComponent("queue.sqlite"))
        return url
    }

    func testPurgeRunsOnlyWhenArmedThenDisarms() throws {
        let root = try makeTempRoot()

        // Not armed → must NEVER touch data (this is the transient-teardown safety).
        XCTAssertFalse(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: [root]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), "an un-armed purge must not delete anything")

        // Explicit sign-out arms it → purges and disarms.
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        XCTAssertTrue(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: [root]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path), "an armed purge removes the account root")

        // Disarmed after running → a second teardown is a no-op.
        let root2 = try makeTempRoot()
        XCTAssertFalse(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: [root2]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root2.path))
    }

    func testSignInCancelsAPendingPurgeSoLiveDataSurvives() throws {
        let root = try makeTempRoot()
        BackupLocalDataPurge.requestPurgeOnSignOut(defaults: defaults)
        BackupLocalDataPurge.cancelPurgeRequest(defaults: defaults)   // a sign-in happened before teardown

        XCTAssertFalse(BackupLocalDataPurge.purgeIfSignOutRequested(defaults: defaults, roots: [root]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path),
                      "a cancelled request must never purge a now-active account")
    }

    func testPurgeAllIsIdempotentOverMissingRoots() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertEqual(BackupLocalDataPurge.purgeAllLocalAccountData(roots: [missing]), 0, "missing roots are ignored, not errors")
    }
}
