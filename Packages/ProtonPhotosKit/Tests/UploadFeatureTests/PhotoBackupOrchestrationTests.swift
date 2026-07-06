import Foundation
import XCTest
import PhotoLibraryBackupAdapter
import PhotosCore
@testable import UploadCore

/// Near-controller orchestration proof. `PhotoLibraryBackupController` cannot be unit-tested
/// directly (its init needs PhotoKit authorization, a real photo library, and the main actor), so
/// this harness composes the SAME shared-Core pieces the controller composes - execution lock,
/// persistent catalog + sync driver, engine, dedupe pipeline, runner - and runs them in the
/// controller's exact pass order:
///
///   recoverStaleLocks → acquire → [busy ⇒ stand down] → catalog scan (driver) → runUntilDrained → release
///
/// (mirrors `PhotoLibraryBackupController.startSync` / `runScanPass` / `finishSync`).
///
/// It proves the phases interlock: a full pass enqueues + drains + releases; a repeat over an
/// unchanged catalog does O(changed) work (no re-upload); targeted changes enqueue only the changed
/// asset; removed assets are marked and never uploaded; a live lock held by another owner blocks the
/// scan/drain non-destructively; and a stale lock is recovered so backup is never permanently stuck.
final class PhotoBackupOrchestrationTests: XCTestCase {

    private var tempDir: URL!
    private var clock: BackupTestClock!
    private var catalog: PhotoLibraryCatalogManifestStore!
    private var lockStore: BackupExecutionLockManifestStore!
    private var queue: UploadBackupSyncQueueManifestStore!
    private var stateStore: MemoryBackupStateStore!
    private var preflight: UploadBackupPreflightIndex!
    private var engine: UploadBackupSyncEngine!
    private var identityStore: FakeIdentityStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var resolver: ScriptedBackupResolver!
    private var uploader: MockUploader!
    private var runner: BackupSyncRunner!
    private var enumerator: CannedEnumerator!

    /// Every catalogued asset shares this modification date so the resolved revision matches the
    /// enqueued queue-row revision (no drift-row noise); content differs by path.
    private let modDate = Date(timeIntervalSince1970: 1_700_000_000)
    private static let lease: TimeInterval = 120

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("photo-backup-orchestration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        clock = BackupTestClock(start: Date(timeIntervalSince1970: 1_720_000_000))

        catalog = try XCTUnwrap(PhotoLibraryCatalogManifestStore(
            url: tempDir.appendingPathComponent(PhotoLibraryCatalogManifestStore.databaseFileName)))
        lockStore = try XCTUnwrap(BackupExecutionLockManifestStore(
            url: tempDir.appendingPathComponent(BackupExecutionLockManifestStore.databaseFileName),
            leaseInterval: Self.lease, now: { [clock] in clock!.now }))
        queue = try XCTUnwrap(UploadBackupSyncQueueManifestStore(
            url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)))
        stateStore = MemoryBackupStateStore()
        preflight = UploadBackupPreflightIndex(store: stateStore, now: { [clock] in clock!.now })
        engine = UploadBackupSyncEngine(preflight: preflight, queue: queue, now: { [clock] in clock!.now })

        identityStore = FakeIdentityStore()
        hasher = FakeHasher()
        checker = FakeChecker()
        resolver = ScriptedBackupResolver(defaultModified: modDate)
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
        runner = BackupSyncRunner(
            queue: queue,
            preflight: preflight,
            resolver: resolver,
            identityResolver: UploadDedupePipeline(store: identityStore, hasher: hasher, checker: checker, now: { [clock] in clock!.now }),
            uploader: uploader,
            clock: clock,
            now: { [clock] in clock!.now }
        )
        enumerator = CannedEnumerator(infos: [])
    }

    override func tearDownWithError() throws {
        queue.close()
        catalog.close()
        lockStore.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Controller-order pass (mirrors startSync → runScanPass → finishSync)

    /// Returns false when the pass stood down because another owner held a live lock.
    @discardableResult
    private func runPass(owner: BackupExecutionOwner, fullRescan: Bool = true, identifiers: [String]? = nil) async -> Bool {
        // Each pass happens at a later wall-clock instant (the controller uses a fresh `Date()` per
        // scan); the catalog's last-seen sweep relies on that strictly-increasing observation time.
        clock.advance(by: 60)
        let runID = UUID().uuidString
        // Gate: recovery precedes the drain; a live foreign lock makes us stand down.
        _ = lockStore.recoverStaleLocks(olderThan: clock.now.addingTimeInterval(-Self.lease))
        switch lockStore.acquire(owner: owner, runID: runID) {
        case .busy:
            return false
        case .acquired, .unavailable:
            break
        }
        // Scan phase through the persistent-catalog driver.
        let sync = PhotoLibraryCatalogSync(store: catalog, enumerator: enumerator, chunkSize: 50, now: { [clock] in clock!.now })
        do {
            if fullRescan {
                _ = try await sync.run(engine: engine, identifiers: nil)
            } else if let identifiers, !identifiers.isEmpty {
                _ = try await sync.run(engine: engine, identifiers: identifiers)
            }
        } catch {
            // The controller surfaces a message and still drains what is queued; mirror by continuing.
        }
        // Drain, then release ownership.
        _ = await runner.runUntilDrained()
        lockStore.release(runID: runID)
        return true
    }

    // MARK: - Tests

    func testFullPassEnqueuesDrainsUploadsAndReleasesLock() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B")]

        let ran = await runPass(owner: .foreground)

        XCTAssertTrue(ran)
        XCTAssertEqual(Set(uploader.requests.map(\.name)), ["IMG_A.HEIC", "IMG_B.HEIC"], "both new assets upload once")
        XCTAssertEqual(queue.summary().uploaded, 2)
        XCTAssertEqual(catalog.snapshot(), PhotoLibraryCatalogSnapshot(total: 2, present: 2, removed: 0))
        XCTAssertNil(lockStore.currentLock(), "the lock is released when the pass finishes")
    }

    func testRepeatPassOverUnchangedCatalogUploadsNothingNew() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B")]
        await runPass(owner: .foreground)
        XCTAssertEqual(uploader.requests.count, 2)
        let resolvesAfterFirst = resolver.resolveCount(for: "A") + resolver.resolveCount(for: "B")

        // Second pass, catalog unchanged → O(changed): nothing re-enqueued, nothing re-resolved,
        // nothing re-uploaded. This is the whole point of the persistent catalog.
        let ran = await runPass(owner: .foreground)

        XCTAssertTrue(ran)
        XCTAssertEqual(uploader.requests.count, 2, "an unchanged library must not re-upload everything")
        XCTAssertEqual(resolver.resolveCount(for: "A") + resolver.resolveCount(for: "B"), resolvesAfterFirst,
                       "unchanged assets are never re-handed to the runner")
        XCTAssertNil(lockStore.currentLock())
    }

    func testTargetedChangeReChecksOnlyChangedAssetWithoutDuplicateUpload() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B")]
        await runPass(owner: .foreground)
        XCTAssertEqual(resolver.resolveCount(for: "A"), 1)
        XCTAssertEqual(resolver.resolveCount(for: "B"), 1)
        XCTAssertEqual(uploader.requests.count, 2)

        // B's metadata changed (new modification date → new revision) but its bytes are identical.
        // The targeted pass must re-enqueue ONLY B, and dedupe must recognise the identical content
        // and NOT upload a duplicate.
        let editedModDate = Date(timeIntervalSince1970: 1_700_090_000)
        enumerator.infos = [photoInfo("A"), photoInfo("B", modified: editedModDate)]
        resolver.setModified(editedModDate, for: "B")

        let ran = await runPass(owner: .foreground, fullRescan: false, identifiers: ["B"])

        XCTAssertTrue(ran)
        XCTAssertEqual(resolver.resolveCount(for: "A"), 1, "an unchanged asset is not re-resolved on a targeted pass")
        XCTAssertEqual(resolver.resolveCount(for: "B"), 2, "only the changed asset is re-enqueued and re-checked")
        XCTAssertEqual(uploader.requests.count, 2, "a metadata-only change re-checks but never re-uploads identical bytes")
    }

    func testRemovedAssetIsMarkedRemovedAndNeverUploaded() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B")]
        await runPass(owner: .foreground)
        XCTAssertEqual(uploader.requests.count, 2)

        // B is deleted from the library. Next full scan sweeps it removed.
        enumerator.infos = [photoInfo("A")]
        let ran = await runPass(owner: .foreground)

        XCTAssertTrue(ran)
        XCTAssertEqual(catalog.entry(for: "B")?.isRemoved, true, "the vanished asset is marked removed")
        XCTAssertEqual(resolver.resolveCount(for: "B"), 1, "a removed asset is never re-resolved")
        XCTAssertEqual(uploader.requests.count, 2, "removed assets are never uploaded; deletions are not mirrored")
    }

    func testBackgroundStandsDownWhileForegroundOwnsLiveLock() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B")]
        // A foreground run owns a live lock (fresh heartbeat) - as if a foreground pass is mid-drain.
        XCTAssertTrue(lockStore.acquire(owner: .foreground, runID: "fg-live").didAcquire)

        let ran = await runPass(owner: .iOSBackgroundTask)

        XCTAssertFalse(ran, "a background window must not start a second drain while foreground owns the lock")
        XCTAssertEqual(uploader.requests.count, 0, "no scan and no drain happen when the pass stands down")
        XCTAssertEqual(catalog.count(), 0, "a stood-down pass must not touch the catalog")
        XCTAssertEqual(lockStore.currentLock()?.runID, "fg-live", "the live owner's lock is left intact (non-destructive)")
    }

    func testStaleLockIsRecoveredSoBackupIsNeverPermanentlyBlocked() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B")]
        // A previous run crashed holding the lock (no release, no more heartbeats).
        XCTAssertTrue(lockStore.acquire(owner: .iOSBackgroundTask, runID: "crashed").didAcquire)

        clock.advance(by: 200)   // past the 120s lease
        let ran = await runPass(owner: .foreground)

        XCTAssertTrue(ran, "a stale lock is reaped so the next start proceeds")
        XCTAssertEqual(uploader.requests.count, 2, "the recovered pass uploads normally")
        XCTAssertNil(lockStore.currentLock(), "the recovered pass releases its own lock at the end")
    }

    // MARK: - Fixtures

    private func photoInfo(_ id: String, modified: Date? = nil) -> PhotoBackupAssetInfo {
        PhotoBackupAssetInfo(
            localIdentifier: id,
            creationDate: Date(timeIntervalSince1970: 1_699_000_000),
            modificationDate: modified ?? modDate,
            pixelWidth: 4032, pixelHeight: 3024,
            durationSeconds: 0, isLivePhoto: false, isVideo: false,
            resources: [.init(role: .originalPhoto, originalFilename: "IMG_\(id).HEIC", mimeType: "image/heic")]
        )
    }

    private final class CannedEnumerator: PhotoLibraryAssetEnumerator, @unchecked Sendable {
        private let lock = NSLock()
        private var _infos: [PhotoBackupAssetInfo]
        var infos: [PhotoBackupAssetInfo] {
            get { lock.withLock { _infos } }
            set { lock.withLock { _infos = newValue } }
        }
        init(infos: [PhotoBackupAssetInfo]) { _infos = infos }

        func infoChunks(identifiers: [String]?, chunkSize: Int) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
            let all = infos
            let selected = identifiers.map { ids in all.filter { Set(ids).contains($0.localIdentifier) } } ?? all
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
}
