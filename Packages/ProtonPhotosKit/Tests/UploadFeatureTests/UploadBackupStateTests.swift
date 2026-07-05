import Foundation
import SQLite3
import XCTest
@testable import UploadCore

final class UploadBackupStateTests: XCTestCase {
    private final class MemoryStore: UploadBackupStateStore, @unchecked Sendable {
        private let lock = NSLock()
        private var rows: [UploadSourceIdentity: [UploadBackupRevision: UploadBackupAssetRecord]] = [:]

        func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
            lock.withLock { rows[source]?[revision] }
        }

        func hasAnyRecord(for source: UploadSourceIdentity) -> Bool {
            lock.withLock { !(rows[source]?.isEmpty ?? true) }
        }

        func upsert(_ record: UploadBackupAssetRecord) {
            lock.withLock { rows[record.source, default: [:]][record.revision] = record }
        }

        func count() -> Int {
            lock.withLock { rows.values.reduce(0) { $0 + $1.count } }
        }
    }

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-backup-state-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func source(_ id: String = "cloud-asset-1") -> UploadSourceIdentity {
        UploadSourceIdentity(kind: .photoLibraryAsset, identifier: id)
    }

    private func revision(_ seconds: TimeInterval) -> UploadBackupRevision {
        UploadBackupRevision(date: Date(timeIntervalSinceReferenceDate: seconds))
    }

    private func snapshot(
        id: String = "cloud-asset-1",
        revision seconds: TimeInterval,
        editRevision: UploadBackupEditRevision = .none,
        resources: Int = 1
    ) -> UploadBackupAssetSnapshot {
        UploadBackupAssetSnapshot(
            source: source(id),
            revision: revision(seconds),
            editRevision: editRevision,
            resourceCount: resources
        )
    }

    func testNewAssetWhenSourceWasNeverSeen() async {
        let index = UploadBackupPreflightIndex(store: MemoryStore())

        let result = await index.classify(snapshot(revision: 10, resources: 2))

        XCTAssertEqual(result, .newAsset)
    }

    func testCompletedRevisionSkipsDirectly() async {
        let store = MemoryStore()
        let index = UploadBackupPreflightIndex(store: store, now: { Date(timeIntervalSince1970: 100) })
        let asset = snapshot(revision: 10, resources: 2)
        await index.markBackedUp(asset)

        let result = await index.classify(asset)

        XCTAssertEqual(result, .alreadyBackedUp)
        XCTAssertEqual(store.count(), 1)
    }

    func testPendingRevisionReportsRemainingResources() async {
        let store = MemoryStore()
        let index = UploadBackupPreflightIndex(store: store)
        let asset = snapshot(revision: 10, resources: 2)
        await index.markPending(asset, pendingResourceCount: 1)

        let result = await index.classify(asset)

        XCTAssertEqual(result, .pendingUpload(remainingResources: 1))
    }

    func testMetadataRevisionDriftWithoutEditEvidenceSeedsCurrentRevisionAsBackedUp() async {
        let store = MemoryStore()
        let index = UploadBackupPreflightIndex(store: store)
        await index.markBackedUp(snapshot(revision: 10))

        let changed = snapshot(revision: 20, editRevision: .none)
        let result = await index.classify(changed)

        XCTAssertEqual(result, .alreadyBackedUp)
        XCTAssertNotNil(store.record(for: changed.source, revision: changed.revision))
        XCTAssertEqual(store.count(), 2)
    }

    func testKnownEditRevisionSkipsAndSeedsCurrentRevision() async {
        let store = MemoryStore()
        let index = UploadBackupPreflightIndex(store: store)
        let edit = revision(15)
        await index.markBackedUp(snapshot(revision: 10))
        await index.markBackedUp(snapshot(revision: 15))

        let changed = snapshot(revision: 20, editRevision: .revision(edit))
        let result = await index.classify(changed)

        XCTAssertEqual(result, .alreadyBackedUp)
        XCTAssertNotNil(store.record(for: changed.source, revision: changed.revision))
    }

    func testUnknownEditRevisionRequiresBackendCheck() async {
        let store = MemoryStore()
        let index = UploadBackupPreflightIndex(store: store)
        await index.markBackedUp(snapshot(revision: 10))

        let changed = snapshot(revision: 20, editRevision: .revision(revision(18)))
        let result = await index.classify(changed)

        XCTAssertEqual(result, .needsBackendCheck(.unseenEditRevision))
    }

    func testUnavailableEditRevisionRequiresBackendCheck() async {
        let store = MemoryStore()
        let index = UploadBackupPreflightIndex(store: store)
        await index.markBackedUp(snapshot(revision: 10))

        let changed = snapshot(revision: 20, editRevision: .unavailable)
        let result = await index.classify(changed)

        XCTAssertEqual(result, .needsBackendCheck(.unreliableEditRevision))
    }

    func testSQLiteStoreRoundTripsAndIndexesBySource() throws {
        let url = tempDir.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)
        let store = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
        let record = UploadBackupAssetRecord(
            source: source(),
            revision: revision(10),
            resourceCount: 2,
            pendingResourceCount: 0,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
        store.upsert(record)

        XCTAssertEqual(store.record(for: source(), revision: revision(10)), record)
        XCTAssertTrue(store.hasAnyRecord(for: source()))
        XCTAssertFalse(store.hasAnyRecord(for: source("other")))
        XCTAssertEqual(store.count(), 1)
    }

    func testSQLiteStoreResetsFutureSchema() throws {
        let url = tempDir.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName)
        do {
            let store = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
            store.upsert(UploadBackupAssetRecord(
                source: source(),
                revision: revision(10),
                resourceCount: 1,
                pendingResourceCount: 0,
                updatedAt: Date()
            ))
            store.close()
        }

        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE backup_state_info SET value=99 WHERE key='schema';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let reopened = try XCTUnwrap(UploadBackupStateManifestStore(url: url))
        XCTAssertEqual(reopened.count(), 0)
    }
}
