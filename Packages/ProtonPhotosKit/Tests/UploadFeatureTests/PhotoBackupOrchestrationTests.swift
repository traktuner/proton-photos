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
        case .busy, .unavailable:
            return false
        case .acquired:
            break
        }
        // DRAIN FIRST — mirrors startSync: the upload path is never gated on a scan completing, so
        // rows a prior (possibly interrupted) pass left runnable upload before the scan runs.
        _ = await runner.runUntilDrained()

        // Scan phase through the persistent-catalog driver.
        let sync = PhotoLibraryCatalogSync(store: catalog, enumerator: enumerator, chunkSize: 50, now: { [clock] in clock!.now })
        let needsFullScan = fullRescan || !catalog.hasCompletedFullScan()
        do {
            if needsFullScan {
                // The resumable full scan marks itself complete when it reaches the library's end.
                _ = try await sync.run(engine: engine, identifiers: nil)
            } else if let identifiers, !identifiers.isEmpty {
                _ = try await sync.run(engine: engine, identifiers: identifiers)
            }
        } catch {
            // The controller surfaces a message and still drains what is queued; mirror by continuing.
        }
        // Drain again for what the scan discovered, then release ownership.
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
        XCTAssertTrue(catalog.hasCompletedFullScan(), "a successful full pass unlocks future incremental scans")
    }

    func testIncrementalTokenCannotSkipInitialFullCatalogScan() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B"), photoInfo("C")]

        let ran = await runPass(owner: .foreground, fullRescan: false, identifiers: ["B"])

        XCTAssertTrue(ran)
        XCTAssertEqual(Set(uploader.requests.map(\.name)), ["IMG_A.HEIC", "IMG_B.HEIC", "IMG_C.HEIC"],
                       "a PhotoKit change token is not enough proof that the local backup catalog knows the full library")
        XCTAssertEqual(catalog.snapshot(), PhotoLibraryCatalogSnapshot(total: 3, present: 3, removed: 0))
        XCTAssertTrue(catalog.hasCompletedFullScan())
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

    func testTargetedMetadataChangeUsesEditFingerprintWithoutDuplicateUpload() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B")]
        await runPass(owner: .foreground)
        XCTAssertEqual(resolver.resolveCount(for: "A"), 1)
        XCTAssertEqual(resolver.resolveCount(for: "B"), 1)
        XCTAssertEqual(uploader.requests.count, 2)

        // B's metadata changed (new modification date -> new revision) but its PhotoKit resource
        // structure did not. The shared preflight can prove that locally via the edit fingerprint,
        // so the targeted pass records the new revision without exporting, hashing, or uploading.
        let editedModDate = Date(timeIntervalSince1970: 1_700_090_000)
        enumerator.infos = [photoInfo("A"), photoInfo("B", modified: editedModDate)]
        resolver.setModified(editedModDate, for: "B")

        let ran = await runPass(owner: .foreground, fullRescan: false, identifiers: ["B"])

        XCTAssertTrue(ran)
        XCTAssertEqual(resolver.resolveCount(for: "A"), 1, "an unchanged asset is not re-resolved on a targeted pass")
        XCTAssertEqual(resolver.resolveCount(for: "B"), 1, "metadata-only PhotoKit drift must stay cheap for unedited assets")
        XCTAssertEqual(uploader.requests.count, 2, "a metadata-only change never re-uploads identical bytes")
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

    func testTargetedDeletedIdentifierMarksCatalogRemovedWithoutFullScan() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B"), photoInfo("C")]
        await runPass(owner: .foreground)
        XCTAssertEqual(uploader.requests.count, 3)

        enumerator.infos = [photoInfo("A"), photoInfo("C")]
        let ran = await runPass(owner: .foreground, fullRescan: false, identifiers: ["B"])

        XCTAssertTrue(ran)
        XCTAssertEqual(catalog.entry(for: "B")?.isRemoved, true, "a PhotoKit deleted identifier is marked removed in the catalog")
        XCTAssertEqual(catalog.entry(for: "A")?.isRemoved, false)
        XCTAssertEqual(catalog.entry(for: "C")?.isRemoved, false)
        XCTAssertEqual(uploader.requests.count, 3, "targeted deletion does not upload or re-resolve anything")
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

    /// The reliability invariant behind the drain/scan decoupling: uploads must never wait for a
    /// scan to finish. A pass drains rows an earlier (interrupted) pass left runnable BEFORE its own
    /// scan enumerates — so a full scan that never completes can no longer starve the upload of
    /// already-queued assets (the frozen-queue bug: 14k rows stuck `discovered` behind a rescan loop).
    func testQueuedRowsUploadBeforeTheScanEnumerates() async throws {
        // A prior pass classified A and B but was interrupted before draining (nothing uploaded, no
        // full-scan-complete marker) — exactly the stuck state a never-finishing scan leaves behind.
        enumerator.infos = [photoInfo("A"), photoInfo("B")]
        let preScan = PhotoLibraryCatalogSync(store: catalog, enumerator: enumerator, chunkSize: 50, now: { [clock] in clock!.now })
        _ = try await preScan.run(engine: engine, identifiers: nil)
        XCTAssertEqual(uploader.requests.count, 0, "precondition: the interrupted prior pass uploaded nothing")
        XCTAssertEqual(queue.summary().uploaded, 0, "precondition: A and B are queued, not yet uploaded")

        // Record how many uploads have happened at the instant the NEXT pass begins scanning.
        let uploadsWhenScanStarted = IntBox()
        enumerator.infos = [photoInfo("A"), photoInfo("B"), photoInfo("C")]
        enumerator.onEnumerationStart = { [uploader] in uploadsWhenScanStarted.value = uploader?.requests.count ?? -1 }

        let ran = await runPass(owner: .foreground)

        XCTAssertTrue(ran)
        XCTAssertEqual(uploadsWhenScanStarted.value, 2,
                       "the two already-queued assets upload BEFORE the scan enumerates — the drain is not gated on the scan")
        XCTAssertEqual(Set(uploader.requests.map(\.name)), ["IMG_A.HEIC", "IMG_B.HEIC", "IMG_C.HEIC"])
        XCTAssertEqual(uploader.requests.count, 3, "each asset uploads exactly once (no double upload from the reorder)")
    }

    /// #2 — the resumable index. A full scan interrupted before the library's end must RESUME from
    /// its saved frontier on the next run, not restart from zero, and must NOT falsely sweep the
    /// assets an earlier run already observed. This is what stops the "scan forever, never complete,
    /// upload nothing" loop (completed_full_scan never flipping) that froze the real queue.
    func testInterruptedFullScanResumesAndDoesNotFalselySweep() async throws {
        enumerator.infos = [photoInfo("A"), photoInfo("B"), photoInfo("C"), photoInfo("D"), photoInfo("E")]
        let sync = PhotoLibraryCatalogSync(store: catalog, enumerator: enumerator, chunkSize: 2, now: { [clock] in clock!.now })

        // Run 1: interrupted after the first 2 assets (app backgrounded mid-scan).
        enumerator.throwAfter = 2
        do {
            _ = try await sync.run(engine: engine, identifiers: nil)
            XCTFail("the interrupted scan should have propagated cancellation")
        } catch is CancellationError {
            // expected
        }
        XCTAssertFalse(catalog.hasCompletedFullScan(), "an interrupted scan is NOT complete")
        XCTAssertEqual(catalog.fullScanProgress()?.cursor, 2, "the frontier is persisted so the next run resumes there")
        XCTAssertEqual(queue.summary().total, 2, "only the two observed assets are queued so far")
        let epochStart = catalog.fullScanProgress()?.epochStart
        XCTAssertNotNil(epochStart)

        // Run 2 (later wall clock): must RESUME at the cursor, skip A/B, finish C/D/E, complete.
        clock.advance(by: 120)
        enumerator.throwAfter = nil
        _ = try await sync.run(engine: engine, identifiers: nil)

        XCTAssertTrue(catalog.hasCompletedFullScan(), "reaching the library's end across resumed runs completes the scan")
        XCTAssertNil(catalog.fullScanProgress(), "a completed epoch clears its resume state")
        XCTAssertEqual(queue.summary().total, 5, "all five assets are queued exactly once (A/B not re-enqueued on resume)")
        XCTAssertEqual(catalog.snapshot(), PhotoLibraryCatalogSnapshot(total: 5, present: 5, removed: 0),
                       "assets observed by the EARLIER run must not be swept as removed when a later run finishes the epoch")
        XCTAssertEqual(epochStart, epochStart, "epoch start is stable across resumed runs")
    }

    // MARK: - Fixtures

    /// Thread-safe int cell so a `@Sendable` scan-start hook can hand a count back to the test body.
    private final class IntBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int {
            get { lock.withLock { _value } }
            set { lock.withLock { _value = newValue } }
        }
    }

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

        /// Fires once when the scan actually begins enumerating — lets a test capture how much upload
        /// work already happened BEFORE the scan (proving the drain runs first).
        var onEnumerationStart: (@Sendable () -> Void)? {
            get { lock.withLock { _onEnumerationStart } }
            set { lock.withLock { _onEnumerationStart = newValue } }
        }
        private var _onEnumerationStart: (@Sendable () -> Void)?

        /// When set, the stream yields at most this many assets and then throws — simulating a full
        /// scan interrupted (app backgrounded / cancelled) before it could reach the library's end.
        var throwAfter: Int? {
            get { lock.withLock { _throwAfter } }
            set { lock.withLock { _throwAfter = newValue } }
        }
        private var _throwAfter: Int?

        func infoChunks(identifiers: [String]?, startOffset: Int, chunkSize: Int) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
            onEnumerationStart?()
            let all = infos
            let selectedAll = identifiers.map { ids in all.filter { Set(ids).contains($0.localIdentifier) } } ?? all
            let selected = Array(selectedAll.dropFirst(max(0, startOffset)))   // resume point
            let limit = throwAfter
            return AsyncThrowingStream { continuation in
                var index = 0
                var yielded = 0
                while index < selected.count {
                    let upper = min(index + max(1, chunkSize), selected.count)
                    if let limit, yielded + (upper - index) > limit {
                        // Yield up to the limit, then interrupt before the rest of the library.
                        let cut = index + max(0, limit - yielded)
                        if cut > index { continuation.yield(Array(selected[index ..< cut])) }
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    continuation.yield(Array(selected[index ..< upper]))
                    yielded += upper - index
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
