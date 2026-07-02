import XCTest
@testable import PhotosCore

/// Security follow-up #2: a FULL sign-out must erase the SDK metadata SQLite stores so no
/// account-tied data survives, while the Settings "Delete Offline Cache" action must stay narrower
/// (cached media only, KEEPS the account key, stays signed in). `SDKMetadataStore` is the testable
/// single source of truth for *which* files the sign-out purge removes; these tests pin that the
/// purge (a) deletes the entity + per-account timeline stores and their WAL/SHM sidecars, and
/// (b) leaves everything else in the same directory - other accounts' data, the encrypted caches,
/// and the account-data cache - untouched, so the two erase actions stay distinct.
final class SDKMetadataStoreTests: XCTestCase {

    private let uid = "user-ABC123"

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SDKMetadataStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func write(_ name: String, in dir: URL) throws {
        try Data("x".utf8).write(to: dir.appendingPathComponent(name))
    }

    private func exists(_ name: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    // MARK: - File-name contract

    func testMetadataFileNamesCoverBothStoresAndSidecars() {
        let names = Set(SDKMetadataStore.metadataFileNames(uid: uid))
        // The account-shared entity store + its WAL/SHM sidecars.
        XCTAssertTrue(names.isSuperset(of: ["entities.sqlite", "entities.sqlite-wal", "entities.sqlite-shm"]))
        // The per-account timeline store + sidecars, keyed by uid.
        XCTAssertTrue(names.isSuperset(of: [
            "timeline-v3-\(uid).sqlite",
            "timeline-v3-\(uid).sqlite-wal",
            "timeline-v3-\(uid).sqlite-shm",
        ]))
        XCTAssertEqual(names.count, 6, "exactly the two stores × {main, -wal, -shm}")
    }

    func testTimelineFileNameIsScopedToTheGivenUID() {
        let names = SDKMetadataStore.metadataFileNames(uid: "OTHER")
        XCTAssertTrue(names.contains("timeline-v3-OTHER.sqlite"))
        XCTAssertFalse(names.contains("timeline-v3-\(uid).sqlite"))
    }

    // MARK: - Purge

    func testPurgeDeletesAllMetadataFilesAndReportsCount() throws {
        let dir = try makeTempDir()
        for name in SDKMetadataStore.metadataFileNames(uid: uid) { try write(name, in: dir) }

        let removed = SDKMetadataStore.purgeMetadata(in: dir, uid: uid)

        XCTAssertEqual(removed, 6, "all present metadata files removed")
        for name in SDKMetadataStore.metadataFileNames(uid: uid) {
            XCTAssertFalse(exists(name, in: dir), "\(name) should be gone after sign-out purge")
        }
    }

    func testPurgeIsBestEffortWhenSidecarsAbsent() throws {
        let dir = try makeTempDir()
        // Only the two main SQLite files exist (no WAL/SHM, e.g. clean shutdown).
        try write("entities.sqlite", in: dir)
        try write("timeline-v3-\(uid).sqlite", in: dir)

        let removed = SDKMetadataStore.purgeMetadata(in: dir, uid: uid)

        XCTAssertEqual(removed, 2, "only the present files count as removed")
        XCTAssertFalse(exists("entities.sqlite", in: dir))
        XCTAssertFalse(exists("timeline-v3-\(uid).sqlite", in: dir))
    }

    func testPurgeLeavesUnrelatedFilesIntact() throws {
        let dir = try makeTempDir()
        for name in SDKMetadataStore.metadataFileNames(uid: uid) { try write(name, in: dir) }

        // Co-located artifacts that the metadata purge must NOT touch - they're erased (or kept) by
        // their own paths. This is what keeps sign-out's full purge distinct from cache-clear and
        // scoped per account.
        let bystanders = [
            "account-users-\(uid).enc",        // AccountDataCache - cleared separately on sign-out
            "account-addresses-\(uid).enc",
            "timeline-v3-OTHER-UID.sqlite",    // a different account's timeline store
            "secrets.sqlite",                   // legacy secret cache (purged on bridge init, not here)
        ]
        for name in bystanders { try write(name, in: dir) }

        SDKMetadataStore.purgeMetadata(in: dir, uid: uid)

        for name in bystanders {
            XCTAssertTrue(exists(name, in: dir), "\(name) must survive the scoped metadata purge")
        }
    }

    func testPurgeOnEmptyDirectoryRemovesNothing() throws {
        let dir = try makeTempDir()
        XCTAssertEqual(SDKMetadataStore.purgeMetadata(in: dir, uid: uid), 0)
    }
}
