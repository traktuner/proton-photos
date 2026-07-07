import Foundation
import SQLite3
import XCTest
import PhotoLibraryBackupAdapter
@testable import UploadCore

/// Persistent local photo-library catalog: round-trips, change classification, removed handling,
/// and the catalog-backed scan source that feeds only new/changed candidates to the backup engine.
/// All pure/off-device - no PhotoKit, so it runs everywhere.
final class PhotoLibraryCatalogStoreTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() throws -> PhotoLibraryCatalogManifestStore {
        let url = tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)
        return try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: url))
    }

    // MARK: - Fixtures

    private func info(
        id: String,
        modified: Date? = Date(timeIntervalSince1970: 1_700_000_100),
        width: Int = 4032,
        height: Int = 3024,
        live: Bool = false,
        video: Bool = false,
        resources: [PhotoBackupAssetInfo.Resource]
    ) -> PhotoBackupAssetInfo {
        PhotoBackupAssetInfo(
            localIdentifier: id,
            creationDate: Date(timeIntervalSince1970: 1_700_000_000),
            modificationDate: modified,
            pixelWidth: width, pixelHeight: height,
            durationSeconds: video ? 12 : 0,
            isLivePhoto: live, isVideo: video,
            resources: resources
        )
    }

    private func photoInfo(id: String, modified: Date? = Date(timeIntervalSince1970: 1_700_000_100)) -> PhotoBackupAssetInfo {
        info(id: id, modified: modified, resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_\(id).HEIC", mimeType: "image/heic"),
        ])
    }

    private func entry(from info: PhotoBackupAssetInfo, at seconds: TimeInterval) -> PhotoLibraryCatalogEntry {
        PhotoLibraryCatalogMapper.entry(for: info, observedAt: Date(timeIntervalSince1970: seconds))
    }

    // MARK: - Round trips

    func testInsertUpdateRoundTripPreservesFirstSeenAndClassifies() throws {
        let store = try makeStore()
        let inserted = entry(from: photoInfo(id: "A"), at: 100)

        XCTAssertEqual(store.upsert(inserted), .inserted)
        let readBack = try XCTUnwrap(store.entry(for: "A"))
        XCTAssertEqual(readBack, inserted, "the full row must round-trip byte-for-byte")

        // Same content observed later: unchanged, firstSeenAt kept, lastSeenAt advanced.
        let later = entry(from: photoInfo(id: "A"), at: 200)
        XCTAssertEqual(store.upsert(later), .unchanged)
        let afterUnchanged = try XCTUnwrap(store.entry(for: "A"))
        XCTAssertEqual(afterUnchanged.firstSeenAt, Date(timeIntervalSince1970: 100))
        XCTAssertEqual(afterUnchanged.lastSeenAt, Date(timeIntervalSince1970: 200))

        // A metadata-only change (new modificationDate) moves the metadata revision → changed.
        let touched = entry(from: photoInfo(id: "A", modified: Date(timeIntervalSince1970: 1_700_009_999)), at: 300)
        XCTAssertEqual(store.upsert(touched), .changed)
        XCTAssertEqual(store.entry(for: "A")?.firstSeenAt, Date(timeIntervalSince1970: 100))
    }

    func testResourceRolesOrderAndOrdinalsRoundTrip() throws {
        let store = try makeStore()
        let asset = info(id: "R", resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_1.HEIC", mimeType: "image/heic"),
            .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: "image/jpeg"),
            .init(role: .adjustmentData, originalFilename: "Adjustments.plist", mimeType: nil),
        ])
        let e = entry(from: asset, at: 10)
        XCTAssertEqual(store.upsert(e), .inserted)

        let read = try XCTUnwrap(store.entry(for: "R"))
        XCTAssertEqual(read.resources, e.resources, "resource role/name/mime/ordinal must survive the JSON round trip")
        XCTAssertEqual(read.resources.map(\.role), ["originalPhoto", "fullSizePhoto", "adjustmentData"])
        XCTAssertNil(read.resources[2].mimeType)
    }

    // MARK: - Fingerprint stability / change detection

    func testUnchangedResourcesAreStableAndEditsChangeTheFingerprint() throws {
        let base = photoInfo(id: "F")
        let same = PhotoLibraryCatalogMapper.entry(for: base, observedAt: Date(timeIntervalSince1970: 1))
        let sameAgain = PhotoLibraryCatalogMapper.entry(for: photoInfo(id: "F"), observedAt: Date(timeIntervalSince1970: 999))
        XCTAssertEqual(same.contentFingerprint, sameAgain.contentFingerprint,
                       "identical resources must fingerprint identically regardless of observation time")

        // Adding an edit render is a real structural change → different fingerprint.
        let edited = info(id: "F", resources: [
            .init(role: .originalPhoto, originalFilename: "IMG_F.HEIC", mimeType: "image/heic"),
            .init(role: .fullSizePhoto, originalFilename: "FullSizeRender.jpg", mimeType: "image/jpeg"),
        ])
        let editedEntry = PhotoLibraryCatalogMapper.entry(for: edited, observedAt: Date(timeIntervalSince1970: 2))
        XCTAssertNotEqual(same.contentFingerprint, editedEntry.contentFingerprint)
    }

    // MARK: - Removed / missing handling

    func testFullSweepMarksUnseenRemovedAndResurrectionIsAChange() throws {
        let store = try makeStore()
        for id in ["A", "B", "C"] { XCTAssertEqual(store.upsert(entry(from: photoInfo(id: id), at: 100)), .inserted) }

        // Second pass at t=200 only re-observes A and B; C is now missing.
        for id in ["A", "B"] { store.upsert(entry(from: photoInfo(id: id), at: 200)) }
        XCTAssertEqual(store.sweepRemoved(notSeenAfter: Date(timeIntervalSince1970: 200), removedAt: Date(timeIntervalSince1970: 200)), 1)
        XCTAssertEqual(store.entry(for: "C")?.isRemoved, true)
        XCTAssertEqual(store.entry(for: "A")?.isRemoved, false)
        XCTAssertEqual(store.snapshot(), PhotoLibraryCatalogSnapshot(total: 3, present: 2, removed: 1))

        // C comes back → a removed row reappearing is a change (re-checked by backup).
        XCTAssertEqual(store.upsert(entry(from: photoInfo(id: "C"), at: 300)), .changed)
        XCTAssertEqual(store.entry(for: "C")?.isRemoved, false)
        XCTAssertNil(store.entry(for: "C")?.removedAt)
    }

    func testMarkRemovedOnlyTouchesPresentRequestedIdentifiers() throws {
        let store = try makeStore()
        store.upsert(entry(from: photoInfo(id: "keep"), at: 100))
        store.upsert(entry(from: photoInfo(id: "gone"), at: 100))

        // "unknown" is not catalogued and must be a no-op; "keep" is not in the list, stays present.
        XCTAssertEqual(store.markRemoved(["gone", "unknown"], removedAt: Date(timeIntervalSince1970: 150)), 1)
        XCTAssertEqual(store.entry(for: "gone")?.isRemoved, true)
        XCTAssertEqual(store.entry(for: "keep")?.isRemoved, false)
        XCTAssertNil(store.entry(for: "unknown"))
    }

    func testFutureSchemaResetsToEmpty() throws {
        let url = tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)
        do {
            let store = try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: url))
            store.upsert(entry(from: photoInfo(id: "A"), at: 1))
            store.close()
        }
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE photo_catalog_info SET value=99 WHERE key='schema';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let reopened = try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: url))
        XCTAssertEqual(reopened.count(), 0)
    }

    func testCompletedFullScanMarkerPersistsAcrossReopen() throws {
        let url = tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)
        do {
            let store = try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: url))
            XCTAssertFalse(store.hasCompletedFullScan())
            store.completeFullScan()
            XCTAssertTrue(store.hasCompletedFullScan())
            store.close()
        }

        let reopened = try XCTUnwrap(PhotoLibraryCatalogManifestStore(url: url))
        XCTAssertTrue(reopened.hasCompletedFullScan())
    }

    // MARK: - Catalog sync driver (integration with the engine's enqueue contract)

    func testDriverEnqueuesOnlyNewAndChangedAssets() async throws {
        let store = try makeStore()
        let enumerator = StubEnumerator(infos: [photoInfo(id: "A"), photoInfo(id: "B")])

        // First full pass: both new → both enqueued.
        let e1 = RecordingEnqueuer()
        let p1 = try await runDriver(store: store, enumerator: enumerator, engine: e1, at: 100)
        XCTAssertEqual(Set(e1.enqueued), ["A", "B"])
        XCTAssertEqual(p1.discovered, 2)
        XCTAssertEqual(p1.changed, 0)

        // Second pass, nothing changed → nothing re-checked (the big repeat-scan win).
        let e2 = RecordingEnqueuer()
        let p2 = try await runDriver(store: store, enumerator: enumerator, engine: e2, at: 200)
        XCTAssertTrue(e2.enqueued.isEmpty, "unchanged assets must not be re-handed to the backup engine")
        XCTAssertEqual(p2.discovered + p2.changed, 0)

        // Change B only → only B is re-checked.
        enumerator.infos = [photoInfo(id: "A"), photoInfo(id: "B", modified: Date(timeIntervalSince1970: 1_700_050_000))]
        let e3 = RecordingEnqueuer()
        let p3 = try await runDriver(store: store, enumerator: enumerator, engine: e3, at: 300)
        XCTAssertEqual(e3.enqueued, ["B"])
        XCTAssertEqual(p3.changed, 1)
        XCTAssertEqual(p3.discovered, 0)
    }

    func testDriverWritesQueueRowBeforeAdvancingCatalog() async throws {
        // The durability contract: if the process died between the queue write and the catalog
        // advance, the asset must re-yield next pass - so the catalog must NOT yet reflect the asset
        // at the moment its candidate is enqueued.
        let store = try makeStore()
        let enumerator = StubEnumerator(infos: [photoInfo(id: "A"), photoInfo(id: "B")])
        let enqueuer = OrderingEnqueuer(store: store)

        _ = try await runDriver(store: store, enumerator: enumerator, engine: enqueuer, at: 100)

        XCTAssertEqual(enqueuer.catalogAbsentAtEnqueue, ["A": true, "B": true],
                       "the durable queue row must be written before the catalog marks the asset seen")
        // After the pass the catalog is advanced for both.
        XCTAssertNotNil(store.entry(for: "A"))
        XCTAssertNotNil(store.entry(for: "B"))
    }

    func testDriverFullSweepMarksRemovedAndReportsProgress() async throws {
        let store = try makeStore()
        let enumerator = StubEnumerator(infos: [photoInfo(id: "A"), photoInfo(id: "B"), photoInfo(id: "C")])
        _ = try await runDriver(store: store, enumerator: enumerator, engine: RecordingEnqueuer(), at: 100)

        // C disappears from the library on the next full scan.
        enumerator.infos = [photoInfo(id: "A"), photoInfo(id: "B")]
        let progressBox = ProgressBox()
        let e2 = RecordingEnqueuer()
        _ = try await runDriver(store: store, enumerator: enumerator, engine: e2, at: 200, progress: progressBox)

        XCTAssertTrue(e2.enqueued.isEmpty)
        XCTAssertEqual(store.entry(for: "C")?.isRemoved, true)
        XCTAssertEqual(progressBox.last?.scanned, 2)
        XCTAssertEqual(progressBox.last?.removed, 1)
    }

    func testDriverTargetedScanUpdatesOnlyRequestedIDsAndMarksMissing() async throws {
        let store = try makeStore()
        let enumerator = StubEnumerator(infos: [photoInfo(id: "A"), photoInfo(id: "B")])
        _ = try await runDriver(store: store, enumerator: enumerator, engine: RecordingEnqueuer(), at: 100)
        let aLastSeen = store.entry(for: "A")?.lastSeenAt

        // Targeted pass for B (changed) and D (requested but not in the library → removed).
        enumerator.infos = [photoInfo(id: "B", modified: Date(timeIntervalSince1970: 1_700_060_000))]
        let e2 = RecordingEnqueuer()
        _ = try await runDriver(store: store, enumerator: enumerator, engine: e2, identifiers: ["B", "D"], at: 200)

        XCTAssertEqual(e2.enqueued, ["B"])
        XCTAssertEqual(store.entry(for: "A")?.lastSeenAt, aLastSeen, "a targeted scan must not touch unrelated rows")
        XCTAssertEqual(store.entry(for: "A")?.isRemoved, false)
        XCTAssertNil(store.entry(for: "D"), "a requested id that was never catalogued stays absent, not invented")
    }

    /// End-to-end through the REAL engine + queue store: proves the driver feeds durable queue rows,
    /// exactly the seam the controller composes.
    func testDriverWithRealEngineWritesDurableQueueRows() async throws {
        let store = try makeStore()
        let queueURL = tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        let queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(url: queueURL))
        let engine = UploadBackupSyncEngine(
            preflight: UploadBackupPreflightIndex(store: MemoryBackupStateStore()),
            queue: queue,
            now: { Date(timeIntervalSince1970: 100) }
        )
        let enumerator = StubEnumerator(infos: [photoInfo(id: "A"), photoInfo(id: "B")])

        _ = try await PhotoLibraryCatalogSync(
            store: store, enumerator: enumerator, chunkSize: 2, now: { Date(timeIntervalSince1970: 100) }
        ).run(engine: engine)

        XCTAssertEqual(queue.count(), 2, "both new assets must land as durable queue rows")
        XCTAssertEqual(queue.summary().waiting, 2, "first-seen assets enter as discovered/waiting work")
        queue.close()
    }

    /// Abort mid-scan (cancellation reaching the enumerator, or an enumeration failure) must not
    /// advance the catalog for assets it never delivered - they re-yield cleanly on the next pass.
    /// Combined with the queue-row-before-catalog-advance ordering, this closes the data-loss window.
    func testAbortedScanDoesNotStrandUndeliveredAssets() async throws {
        let store = try makeStore()

        // Pass 1 delivers only A, then aborts (the real PhotoKit enumerator finishes with a
        // CancellationError the same way when its detached fetch is cancelled).
        let aborting = AbortingEnumerator(chunks: [[photoInfo(id: "A")]], thenThrow: CancellationError())
        let e1 = RecordingEnqueuer()
        do {
            _ = try await PhotoLibraryCatalogSync(
                store: store, enumerator: aborting, chunkSize: 1, now: { Date(timeIntervalSince1970: 100) }
            ).run(engine: e1)
            XCTFail("an aborted scan must rethrow, not silently succeed")
        } catch is CancellationError {
            // expected
        }

        XCTAssertEqual(e1.enqueued, ["A"], "the delivered asset was enqueued before the abort")
        XCTAssertNotNil(store.entry(for: "A"), "the delivered asset's catalog row is committed")
        XCTAssertEqual(store.count(), 1, "the abort must not catalog anything beyond what it delivered")

        // Pass 2 is a clean full scan that now also sees B. A is unchanged (not re-enqueued); B was
        // never stranded by the aborted pass, so it re-yields as new.
        let clean = StubEnumerator(infos: [photoInfo(id: "A"), photoInfo(id: "B")])
        let e2 = RecordingEnqueuer()
        _ = try await PhotoLibraryCatalogSync(
            store: store, enumerator: clean, chunkSize: 2, now: { Date(timeIntervalSince1970: 200) }
        ).run(engine: e2)

        XCTAssertEqual(e2.enqueued, ["B"], "the previously-undelivered asset re-yields; the delivered one does not")
    }

    // MARK: - Helpers

    private func runDriver(
        store: any PhotoLibraryCatalogStore,
        enumerator: any PhotoLibraryAssetEnumerator,
        engine: any UploadBackupCandidateEnqueueing,
        identifiers: [String]? = nil,
        at seconds: TimeInterval,
        progress: ProgressBox? = nil
    ) async throws -> PhotoLibraryCatalogProgress {
        let onProgress: (@Sendable (PhotoLibraryCatalogProgress) -> Void)?
        if let progress {
            onProgress = { report in progress.record(report) }
        } else {
            onProgress = nil
        }
        let sync = PhotoLibraryCatalogSync(
            store: store,
            enumerator: enumerator,
            chunkSize: 2,
            now: { Date(timeIntervalSince1970: seconds) },
            onProgress: onProgress
        )
        return try await sync.run(engine: engine, identifiers: identifiers)
    }

    /// Records which candidates the driver enqueued.
    private final class RecordingEnqueuer: UploadBackupCandidateEnqueueing, @unchecked Sendable {
        private let lock = NSLock()
        private var _enqueued: [String] = []
        var enqueued: [String] { lock.withLock { _enqueued } }

        func enqueue(_ candidate: UploadBackupAssetCandidate) async -> UploadBackupSyncScanResult {
            lock.withLock { _enqueued.append(candidate.snapshot.source.identifier) }
            return UploadBackupSyncScanResult()
        }
    }

    /// Asserts the catalog has NOT yet recorded an asset at the moment its candidate is enqueued.
    private final class OrderingEnqueuer: UploadBackupCandidateEnqueueing, @unchecked Sendable {
        private let store: any PhotoLibraryCatalogStore
        private let lock = NSLock()
        private var _absent: [String: Bool] = [:]
        var catalogAbsentAtEnqueue: [String: Bool] { lock.withLock { _absent } }

        init(store: any PhotoLibraryCatalogStore) { self.store = store }

        func enqueue(_ candidate: UploadBackupAssetCandidate) async -> UploadBackupSyncScanResult {
            let id = candidate.snapshot.source.identifier
            let absent = store.entry(for: id) == nil
            lock.withLock { _absent[id] = absent }
            return UploadBackupSyncScanResult()
        }
    }

    private final class MemoryBackupStateStore: UploadBackupStateStore, @unchecked Sendable {
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

    /// Yields the given chunks, then finishes with `thenThrow` - models a scan that aborts partway
    /// (cancellation reaching the producer, or a PhotoKit enumeration failure).
    private final class AbortingEnumerator: PhotoLibraryAssetEnumerator, @unchecked Sendable {
        private let chunks: [[PhotoBackupAssetInfo]]
        private let thenThrow: any Error
        init(chunks: [[PhotoBackupAssetInfo]], thenThrow: any Error) {
            self.chunks = chunks
            self.thenThrow = thenThrow
        }

        func infoChunks(identifiers: [String]?, startOffset: Int, chunkSize: Int) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
            let chunks = chunks
            let error = thenThrow
            return AsyncThrowingStream { continuation in
                for chunk in chunks { continuation.yield(chunk) }
                continuation.finish(throwing: error)
            }
        }
    }

    /// Canned enumerator: honors the targeted-identifier filter like PhotoKit would.
    private final class StubEnumerator: PhotoLibraryAssetEnumerator, @unchecked Sendable {
        private let lock = NSLock()
        private var _infos: [PhotoBackupAssetInfo]
        var infos: [PhotoBackupAssetInfo] {
            get { lock.withLock { _infos } }
            set { lock.withLock { _infos = newValue } }
        }

        init(infos: [PhotoBackupAssetInfo]) { _infos = infos }

        func infoChunks(identifiers: [String]?, startOffset: Int, chunkSize: Int) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
            let all = infos
            let filtered: [PhotoBackupAssetInfo]
            if let identifiers {
                let wanted = Set(identifiers)
                filtered = all.filter { wanted.contains($0.localIdentifier) }
            } else {
                filtered = all
            }
            let selected = Array(filtered.dropFirst(max(0, startOffset)))   // resume point
            return AsyncThrowingStream { continuation in
                var index = 0
                while index < selected.count {
                    let upper = min(index + max(1, chunkSize), selected.count)
                    continuation.yield(Array(selected[index ..< upper]))
                    index = upper
                }
                continuation.finish()
            }
        }
    }

    private final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _last: PhotoLibraryCatalogProgress?
        var last: PhotoLibraryCatalogProgress? { lock.withLock { _last } }
        func record(_ p: PhotoLibraryCatalogProgress) { lock.withLock { _last = p } }
    }
}
