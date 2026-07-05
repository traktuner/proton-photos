import Foundation
import XCTest
import PhotosCore
@testable import UploadCore

// MARK: - Test doubles

/// Fake time: `now` only advances when the runner sleeps, so backoff scheduling is fully
/// deterministic and instant.
final class BackupTestClock: BackupSchedulerClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    private var _sleeps: [TimeInterval] = []

    init(start: Date = Date(timeIntervalSince1970: 1_720_000_000)) {
        current = start
    }

    var now: Date { lock.withLock { current } }
    var sleeps: [TimeInterval] { lock.withLock { _sleeps } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }

    func sleep(for seconds: TimeInterval) async throws {
        lock.withLock {
            _sleeps.append(seconds)
            current = current.addingTimeInterval(max(0, seconds))
        }
        await Task.yield()
    }
}

/// Scripted `BackupResourceResolving`: per-source behavior, resolve counting.
final class ScriptedBackupResolver: BackupResourceResolving, @unchecked Sendable {
    enum Behavior {
        case standard
        case missing
        /// Throw `error` for the first `times` resolves, then behave like `.standard`.
        case transientFailure(times: Int)
    }

    private let lock = NSLock()
    private var behaviors: [String: Behavior] = [:]
    private var remainingFailures: [String: Int] = [:]
    private var _resolveCounts: [String: Int] = [:]
    /// Fixed mtime so resolved revisions match the seeded queue rows (no drift) unless a test
    /// overrides it per source.
    let defaultModified: Date
    private var modifiedOverrides: [String: Date] = [:]
    /// Secondary filenames per source id - resolved entries become Live-Photo-style compounds.
    private var secondaryNames: [String: [String]] = [:]
    private var metadataByIdentifier: [String: [PhotoUploadAdditionalMetadata]] = [:]

    func setSecondaries(_ names: [String], for identifier: String) {
        lock.withLock { secondaryNames[identifier] = names }
    }

    func setAdditionalMetadata(_ metadata: [PhotoUploadAdditionalMetadata], for identifier: String) {
        lock.withLock { metadataByIdentifier[identifier] = metadata }
    }

    init(defaultModified: Date) {
        self.defaultModified = defaultModified
    }

    func set(_ behavior: Behavior, for identifier: String) {
        lock.withLock {
            behaviors[identifier] = behavior
            if case let .transientFailure(times) = behavior { remainingFailures[identifier] = times }
        }
    }

    func setModified(_ date: Date, for identifier: String) {
        lock.withLock { modifiedOverrides[identifier] = date }
    }

    func resolveCount(for identifier: String) -> Int {
        lock.withLock { _resolveCounts[identifier] ?? 0 }
    }

    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        let id = entry.source.identifier
        let behavior: Behavior = lock.withLock {
            _resolveCounts[id, default: 0] += 1
            return behaviors[id] ?? .standard
        }
        switch behavior {
        case .missing:
            return nil
        case let .transientFailure(times):
            let shouldFail: Bool = lock.withLock {
                let left = remainingFailures[id] ?? times
                if left > 0 { remainingFailures[id] = left - 1; return true }
                return false
            }
            if shouldFail { throw UploadError.backend("transient resolve failure for \(id)") }
            fallthrough
        case .standard:
            let modified = lock.withLock { modifiedOverrides[id] } ?? defaultModified
            let secondaries = lock.withLock { secondaryNames[id] } ?? []
            let additionalMetadata = lock.withLock { metadataByIdentifier[id] } ?? []
            let snapshot = UploadBackupAssetSnapshot(
                source: entry.source,
                revision: UploadBackupRevision(date: modified),
                editRevision: .unavailable,
                resourceCount: 1 + secondaries.count
            )
            let descriptor = UploadResourceDescriptor(
                source: entry.source,
                fileURL: URL(fileURLWithPath: entry.source.identifier),
                filename: entry.originalFilename,
                fileSize: entry.byteCount ?? 1,
                modificationDate: modified
            )
            return BackupResolvedResource(
                candidate: UploadBackupAssetCandidate(
                    snapshot: snapshot,
                    originalFilename: entry.originalFilename,
                    byteCount: entry.byteCount
                ),
                descriptor: descriptor,
                mediaType: "image/jpeg",
                additionalMetadata: additionalMetadata,
                captureDate: modified,
                secondaries: secondaries.map { name in
                    BackupSecondaryResource(
                        descriptor: UploadResourceDescriptor(
                            source: UploadSourceIdentity(
                                kind: entry.source.kind,
                                identifier: entry.source.identifier,
                                resource: .livePairedVideo
                            ),
                            fileURL: URL(fileURLWithPath: "\(entry.source.identifier)#\(name)"),
                            filename: name,
                            fileSize: 2,
                            modificationDate: modified
                        ),
                        mediaType: "video/quicktime",
                        additionalMetadata: additionalMetadata
                    )
                }
            )
        }
    }
}

/// Shared ordered event log for cross-component ordering assertions.
final class BackupEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [String] = []

    func append(_ event: String) { lock.withLock { _events.append(event) } }
    var events: [String] { lock.withLock { _events } }

    func firstIndex(of event: String) -> Int? { events.firstIndex(of: event) }
}

/// Queue store spy: delegates to the real SQLite store while logging every state write.
final class SpyQueueStore: UploadBackupSyncQueueStore, @unchecked Sendable {
    private let inner: UploadBackupSyncQueueManifestStore
    private let log: BackupEventLog

    init(inner: UploadBackupSyncQueueManifestStore, log: BackupEventLog) {
        self.inner = inner
        self.log = log
    }

    func upsert(_ entry: UploadBackupSyncQueueEntry) {
        log.append("queue.upsert:\(entry.state.rawValue)")
        inner.upsert(entry)
    }

    func entry(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupSyncQueueEntry? {
        inner.entry(for: source, revision: revision)
    }

    func nextRunnable(limit: Int) -> [UploadBackupSyncQueueEntry] { inner.nextRunnable(limit: limit) }

    func entries(in state: UploadBackupSyncQueueState, updatedBefore: Date, limit: Int) -> [UploadBackupSyncQueueEntry] {
        inner.entries(in: state, updatedBefore: updatedBefore, limit: limit)
    }

    @discardableResult
    func requeueStaleActive(before cutoff: Date, updatedAt: Date) -> Int {
        log.append("queue.requeueStaleActive")
        return inner.requeueStaleActive(before: cutoff, updatedAt: updatedAt)
    }

    func updateState(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        state: UploadBackupSyncQueueState,
        attempts: Int?,
        lastError: String?,
        updatedAt: Date
    ) {
        log.append("queue.state:\(state.rawValue)")
        inner.updateState(source: source, revision: revision, state: state,
                          attempts: attempts, lastError: lastError, updatedAt: updatedAt)
    }

    func summary() -> UploadBackupSyncQueueSummary { inner.summary() }
    func count() -> Int { inner.count() }
}

/// Identity-resolver spy: delegates to the real pipeline while logging `recordUploaded`.
final class SpyIdentityResolver: UploadIdentityResolving, @unchecked Sendable {
    private let inner: UploadDedupePipeline
    private let log: BackupEventLog

    init(inner: UploadDedupePipeline, log: BackupEventLog) {
        self.inner = inner
        self.log = log
    }

    func resolve(_ descriptor: UploadResourceDescriptor) async throws -> UploadPreflightResult {
        try await inner.resolve(descriptor)
    }

    func prime(_ descriptors: [UploadResourceDescriptor]) async {
        await inner.prime(descriptors)
    }

    func recordUploaded(
        _ descriptor: UploadResourceDescriptor,
        identity: UploadIdentity,
        remoteVolumeID: String,
        remoteLinkID: String
    ) async {
        log.append("manifest.recordUploaded")
        await inner.recordUploaded(descriptor, identity: identity,
                                   remoteVolumeID: remoteVolumeID, remoteLinkID: remoteLinkID)
    }

    func invalidateCachedRemoteState() async {
        log.append("manifest.invalidateCachedRemoteState")
        await inner.invalidateCachedRemoteState()
    }

    func uploadDidFail(_ descriptor: UploadResourceDescriptor) async {
        log.append("manifest.uploadDidFail")
        await inner.uploadDidFail(descriptor)
    }
}

/// Uploader that "crashes" after the remote side already accepted the bytes: the first call
/// registers an active remote duplicate with the checker, then throws - simulating a process
/// death between upload success and the manifest write.
final class CrashAfterUploadUploader: PhotoUploading, @unchecked Sendable {
    let capabilities = UploadBackendCapabilities.sdkUploader
    private let lock = NSLock()
    private let checker: FakeChecker
    private let contentHashByName: [String: String]
    private var _attempts = 0

    init(checker: FakeChecker, contentHashByName: [String: String]) {
        self.checker = checker
        self.contentHashByName = contentHashByName
    }

    var attempts: Int { lock.withLock { _attempts } }

    func upload(_ request: PhotoUploadRequest, onProgress: @Sendable @escaping (UploadProgress) -> Void) async throws -> PhotoUID {
        let attempt: Int = lock.withLock { _attempts += 1; return _attempts }
        let nameHash = "nh(\(request.name))"
        checker.remoteItemsByNameHash[nameHash] = [RemotePhotoDuplicate(
            nameHash: nameHash,
            contentHash: contentHashByName[request.name],
            linkState: .active,
            linkID: "remote-\(request.name)"
        )]
        if attempt == 1 {
            throw UploadError.backend("process died after server accepted the upload")
        }
        return testUID(request.name)
    }

    func cancel(token: UUID) async {}
}

// MARK: - Tests

final class BackupSyncRunnerTests: XCTestCase {

    private var tempDir: URL!
    private var clock: BackupTestClock!
    private var queueStore: UploadBackupSyncQueueManifestStore!
    private var stateStore: MemoryBackupStateStore!
    private var preflight: UploadBackupPreflightIndex!
    private var identityStore: FakeIdentityStore!
    private var hasher: FakeHasher!
    private var checker: FakeChecker!
    private var resolver: ScriptedBackupResolver!
    private var uploader: MockUploader!

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

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-sync-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        clock = BackupTestClock()
        queueStore = try XCTUnwrap(UploadBackupSyncQueueManifestStore(
            url: tempDir.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName)
        ))
        stateStore = MemoryBackupStateStore()
        preflight = UploadBackupPreflightIndex(store: stateStore, now: { [clock] in clock!.now })
        identityStore = FakeIdentityStore()
        hasher = FakeHasher()
        checker = FakeChecker()
        resolver = ScriptedBackupResolver(defaultModified: clock.now.addingTimeInterval(-3600))
        uploader = MockUploader(workDuration: .milliseconds(1), deliverProgress: false)
    }

    override func tearDownWithError() throws {
        queueStore.close()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: Composition helpers

    private func makePipeline() -> UploadDedupePipeline {
        UploadDedupePipeline(store: identityStore, hasher: hasher, checker: checker, now: { [clock] in clock!.now })
    }

    private func makeRunner(
        uploader: (any PhotoUploading)? = nil,
        identityResolver: (any UploadIdentityResolving)? = nil,
        queue: (any UploadBackupSyncQueueStore)? = nil,
        retry: BackupRetryPolicy = BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 4),
        throttle: BackupThrottlePolicy = BackupThrottlePolicy(baseConcurrency: 2),
        throttleInputs: @Sendable @escaping () -> BackupThrottleInputs = { .unconstrained }
    ) -> BackupSyncRunner {
        BackupSyncRunner(
            queue: queue ?? queueStore,
            preflight: preflight,
            resolver: resolver,
            identityResolver: identityResolver ?? makePipeline(),
            uploader: uploader ?? self.uploader,
            configuration: BackupSyncRunner.Configuration(retry: retry, throttle: throttle),
            throttleInputs: throttleInputs,
            clock: clock,
            now: { [clock] in clock!.now }
        )
    }

    private func seedEntry(
        _ id: String,
        state: UploadBackupSyncQueueState = .discovered,
        attempts: Int = 0,
        ageSeconds: TimeInterval = 60
    ) -> UploadBackupSyncQueueEntry {
        let entry = UploadBackupSyncQueueEntry(
            source: .file(URL(fileURLWithPath: "/backup/\(id)")),
            revision: UploadBackupRevision(date: resolver.defaultModified),
            originalFilename: id,
            byteCount: 4,
            state: state,
            attempts: attempts,
            updatedAt: clock.now.addingTimeInterval(-ageSeconds)
        )
        queueStore.upsert(entry)
        return entry
    }

    /// The (nameHash, contentHash) pair the pipeline will compute for a standard resolved entry.
    private func expectedHashes(id: String) -> (nameHash: String, contentHash: String) {
        let path = URL(fileURLWithPath: "/backup/\(id)").standardizedFileURL.path
        var digest = Data(repeating: 0, count: 20)
        for (i, byte) in path.utf8.enumerated() { digest[i % 20] ^= byte }
        let hex = UploadContentSHA1.hexString(digest: digest)
        return ("nh(\(id))", "ch(\(hex))")
    }

    private func state(of entry: UploadBackupSyncQueueEntry) -> UploadBackupSyncQueueState? {
        queueStore.entry(for: entry.source, revision: entry.revision)?.state
    }

    // MARK: 1. Crash recovery runs first and stale rows are processed

    func testRunRequeuesStaleActiveRowsAndProcessesThem() async throws {
        let log = BackupEventLog()
        let spyQueue = SpyQueueStore(inner: queueStore, log: log)
        let stuckUploading = seedEntry("stuck-upload.jpg", state: .uploading)
        let stuckChecking = seedEntry("stuck-check.jpg", state: .checking)

        let runner = makeRunner(queue: spyQueue)
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(log.events.first, "queue.requeueStaleActive", "recovery must run before any draining")
        XCTAssertEqual(state(of: stuckUploading), .completed)
        XCTAssertEqual(state(of: stuckChecking), .completed)
        XCTAssertEqual(uploader.requests.count, 2)
        XCTAssertEqual(progress.uploaded, 2)
        XCTAssertEqual(progress.backedUp, 2)
        XCTAssertFalse(progress.isRunning)
    }

    // MARK: 2. Source missing is terminal and never retried

    func testSourceMissingIsTerminalAndNotRetried() async throws {
        let entry = seedEntry("gone.jpg")
        resolver.set(.missing, for: entry.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .sourceMissing)
        XCTAssertEqual(progress.sourceMissing, 1)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertEqual(progress.needsAttention, 1)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 1)

        // A second pass must not resurrect or re-resolve it.
        _ = await runner.runUntilDrained()
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 1)
        XCTAssertEqual(state(of: entry), .sourceMissing)
    }

    // MARK: 3. Remote draft blocks without ever claiming success

    func testDraftBlocksWithBackoffAndNeverCountsAsBackedUp() async throws {
        let entry = seedEntry("draft.jpg")
        let hashes = expectedHashes(id: "draft.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [RemotePhotoDuplicate(
            nameHash: hashes.nameHash, contentHash: nil, linkState: .draft, linkID: nil
        )]

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .blockedByDraft)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 1)
        XCTAssertEqual(progress.blocked, 1)
        XCTAssertEqual(progress.backedUp, 0)
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertLessThan(progress.fraction, 1.0, "a blocked row must keep the fraction honest")

        // Next pass after the backoff window: re-checked once more, still blocked, attempts grow.
        clock.advance(by: 120)
        let findsBefore = checker.findCallCount
        _ = await runner.runUntilDrained()
        XCTAssertGreaterThan(checker.findCallCount, findsBefore, "the draft must be re-checked")
        XCTAssertEqual(state(of: entry), .blockedByDraft)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 2)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    // MARK: 4. Active duplicate resolves without uploading bytes

    func testActiveDuplicateBecomesAlreadyBackedUpWithoutUpload() async throws {
        let entry = seedEntry("dup.jpg")
        let hashes = expectedHashes(id: "dup.jpg")
        checker.remoteItemsByNameHash[hashes.nameHash] = [RemotePhotoDuplicate(
            nameHash: hashes.nameHash, contentHash: hashes.contentHash, linkState: .active, linkID: "remote-1"
        )]

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .alreadyBackedUp)
        XCTAssertTrue(uploader.requests.isEmpty, "an active duplicate must never re-upload bytes")
        XCTAssertEqual(progress.alreadyBackedUp, 1)
        XCTAssertEqual(progress.backedUp, 1)
        XCTAssertEqual(progress.fraction, 1.0)

        // The preflight index now PROVES the revision complete - the "backed up" claim is durable.
        let record = stateStore.record(
            for: entry.source,
            revision: UploadBackupRevision(date: resolver.defaultModified)
        )
        XCTAssertEqual(record?.isComplete, true)
    }

    // MARK: 5. Trashed/deleted remote duplicates are NOT backed up

    func testTrashedAndDeletedRemoteDuplicatesAreNotBackedUp() async throws {
        let trashed = seedEntry("trashed.jpg")
        let deleted = seedEntry("deleted.jpg")
        let trashedHashes = expectedHashes(id: "trashed.jpg")
        let deletedHashes = expectedHashes(id: "deleted.jpg")
        checker.remoteItemsByNameHash[trashedHashes.nameHash] = [RemotePhotoDuplicate(
            nameHash: trashedHashes.nameHash, contentHash: trashedHashes.contentHash, linkState: .trashed, linkID: "t-1"
        )]
        checker.remoteItemsByNameHash[deletedHashes.nameHash] = [RemotePhotoDuplicate(
            nameHash: deletedHashes.nameHash, contentHash: deletedHashes.contentHash, linkState: nil, linkID: "d-1"
        )]

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: trashed), .skippedRemoteDeletion)
        XCTAssertEqual(state(of: deleted), .skippedRemoteDeletion)
        XCTAssertTrue(uploader.requests.isEmpty)
        XCTAssertEqual(progress.skippedRemoteDeletions, 2)
        XCTAssertEqual(progress.backedUp, 0, "respected deletions must never count as backed up")
        XCTAssertEqual(stateStore.count(), 0, "no preflight completeness record may exist for skipped deletions")
    }

    // MARK: 6. Manifest write ordering

    func testUploadRecordsManifestBeforeQueueCompletion() async throws {
        let log = BackupEventLog()
        let spyQueue = SpyQueueStore(inner: queueStore, log: log)
        let spyResolver = SpyIdentityResolver(inner: makePipeline(), log: log)
        _ = seedEntry("fresh.jpg")

        let runner = makeRunner(identityResolver: spyResolver, queue: spyQueue)
        _ = await runner.runUntilDrained()

        let recordIndex = try XCTUnwrap(log.firstIndex(of: "manifest.recordUploaded"))
        let completedIndex = try XCTUnwrap(log.firstIndex(of: "queue.state:completed"))
        XCTAssertLessThan(recordIndex, completedIndex,
                          "the manifest must remember the upload before the queue row turns terminal")
    }

    // MARK: 7. Crash after upload, before the manifest write

    func testCrashAfterUploadBeforeRecordResolvesToDuplicateOnRetry() async throws {
        let entry = seedEntry("crash.jpg")
        let hashes = expectedHashes(id: "crash.jpg")
        let crashingUploader = CrashAfterUploadUploader(
            checker: checker,
            contentHashByName: ["crash.jpg": hashes.contentHash]
        )

        let runner = makeRunner(uploader: crashingUploader)
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(crashingUploader.attempts, 1, "the retry must NOT upload the bytes again")
        XCTAssertEqual(state(of: entry), .alreadyBackedUp)
        XCTAssertEqual(progress.backedUp, 1)
        XCTAssertEqual(hasher.hashCount, 1, "the persisted identity must spare the rehash on retry")
    }

    // MARK: 8. Retry policy: backoff waits, then park

    func testTransientFailuresBackOffAndEventuallySucceed() async throws {
        let entry = seedEntry("flaky.jpg")
        resolver.set(.transientFailure(times: 3), for: entry.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(uploader.requests.count, 1)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 4)
        // Exponential waits for attempts 1..3 must actually be scheduled (no hot loop).
        for expected in [1.0, 2.0, 4.0] {
            XCTAssertTrue(clock.sleeps.contains(expected), "missing backoff wait of \(expected)s in \(clock.sleeps)")
        }
        XCTAssertEqual(progress.uploaded, 1)
    }

    func testRetryBudgetParksAsFailedInsteadOfHotLooping() async throws {
        let entry = seedEntry("broken.jpg")
        resolver.set(.transientFailure(times: 99), for: entry.source.identifier)

        let runner = makeRunner(retry: BackupRetryPolicy(baseDelay: 1, maxDelay: 64, maxAttempts: 3))
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .failed)
        XCTAssertEqual(queueStore.entry(for: entry.source, revision: entry.revision)?.attempts, 3)
        XCTAssertEqual(resolver.resolveCount(for: entry.source.identifier), 3, "parked items must stop consuming attempts")
        XCTAssertEqual(progress.failed, 1)
        XCTAssertEqual(progress.needsAttention, 1)
        XCTAssertTrue(uploader.requests.isEmpty)
    }

    // MARK: 9. Throttle pauses scheduling entirely

    func testCriticalThermalInputPausesWithoutFailingWork() async throws {
        let entry = seedEntry("hot.jpg")
        let gate = ThrottleGate()

        let runner = makeRunner(throttleInputs: { gate.inputs })
        // Flip back to nominal after the runner observed the pause twice.
        let observer = Task {
            while gate.pauseObservations < 2 { await Task.yield() }
            gate.set(BackupThrottleInputs())
        }
        gate.set(BackupThrottleInputs(thermalLevel: .critical))
        let progress = await runner.runUntilDrained()
        observer.cancel()

        XCTAssertEqual(state(of: entry), .completed, "paused work must resume, not fail")
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertGreaterThanOrEqual(gate.pauseObservations, 2)
    }

    private final class ThrottleGate: @unchecked Sendable {
        private let lock = NSLock()
        private var _inputs = BackupThrottleInputs()
        private var _pauseObservations = 0

        var inputs: BackupThrottleInputs {
            lock.withLock {
                if _inputs.thermalLevel == .critical { _pauseObservations += 1 }
                return _inputs
            }
        }

        var pauseObservations: Int { lock.withLock { _pauseObservations } }

        func set(_ inputs: BackupThrottleInputs) {
            lock.withLock { _inputs = inputs }
        }
    }

    // MARK: 9b. Identical content discovered concurrently uploads exactly once

    func testConcurrentIdenticalContentUploadsExactlyOnce() async throws {
        let first = seedEntry("copy-a.jpg")
        let second = seedEntry("copy-b.jpg")
        hasher.contentSeeds["/backup/copy-a.jpg"] = "identical-bytes"
        hasher.contentSeeds["/backup/copy-b.jpg"] = "identical-bytes"
        let slowUploader = MockUploader(workDuration: .milliseconds(40), deliverProgress: false)

        let runner = makeRunner(uploader: slowUploader, throttle: BackupThrottlePolicy(baseConcurrency: 2))
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(slowUploader.requests.count, 1,
                       "identical bytes in the same wave must coalesce to one upload")
        XCTAssertEqual(progress.uploaded, 1)
        XCTAssertEqual(progress.alreadyBackedUp, 1)
        XCTAssertEqual(progress.backedUp, 2, "both sources must end up proven backed up")
        let states = [state(of: first), state(of: second)]
        XCTAssertTrue(states.contains(.completed) && states.contains(.alreadyBackedUp), "got \(states)")
    }

    // MARK: 9c. Live Photo compounds (primary + paired video)

    func testLivePhotoCompoundUploadsPairedVideoWithPrimaryReference() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)

        let runner = makeRunner()
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(uploader.requests.map(\.name), ["live.heic", "live.mov"],
                       "the paired video uploads after its primary")
        let pairedRequest = try XCTUnwrap(uploader.requests.last)
        XCTAssertEqual(pairedRequest.mainPhotoUID, testUID("live.heic"),
                       "the paired video must reference its freshly-uploaded primary")
        XCTAssertEqual(state(of: entry), .completed)
        XCTAssertEqual(progress.uploaded, 1, "a compound is ONE user-facing item")
        let record = stateStore.record(
            for: entry.source, revision: UploadBackupRevision(date: resolver.defaultModified)
        )
        XCTAssertEqual(record?.isComplete, true)
        XCTAssertEqual(record?.resourceCount, 2)
    }

    func testPhotoMetadataFlowsToPrimaryAndSecondaryUploads() async throws {
        let entry = seedEntry("metadata.heic")
        let metadata = PhotoUploadAdditionalMetadata(name: "Media", utf8JsonValue: Data(#"{"Width":4032}"#.utf8))
        resolver.setSecondaries(["metadata.mov"], for: entry.source.identifier)
        resolver.setAdditionalMetadata([metadata], for: entry.source.identifier)

        let runner = makeRunner()
        _ = await runner.runUntilDrained()

        XCTAssertEqual(uploader.requests.map(\.additionalMetadata), [[metadata], [metadata]])
    }

    func testPairedVideoFailureRetriesWithoutReuploadingPrimary() async throws {
        let entry = seedEntry("live.heic")
        resolver.setSecondaries(["live.mov"], for: entry.source.identifier)
        let flaky = MockUploader(
            workDuration: .milliseconds(1),
            deliverProgress: false,
            transientFailures: ["live.mov": 1]
        )

        let runner = makeRunner(uploader: flaky)
        let progress = await runner.runUntilDrained()

        // The retry pass resolves the primary via the manifest, so the compound settles as
        // alreadyBackedUp - either success state is honest; what matters is the byte counts.
        XCTAssertEqual(state(of: entry)?.isTerminalSuccess, true)
        XCTAssertEqual(flaky.requests.filter { $0.name == "live.heic" }.count, 1,
                       "the primary must never re-upload when only its paired video failed")
        XCTAssertEqual(flaky.requests.filter { $0.name == "live.mov" }.count, 2,
                       "the paired video retries after its transient failure")
        // The retried paired video references the primary via its manifest link (no volume known
        // from a skip row - the transport resolves the photos volume for it).
        let retriedPaired = try XCTUnwrap(flaky.requests.last)
        XCTAssertEqual(retriedPaired.mainPhotoUID?.nodeID, testUID("live.heic").nodeID)
        XCTAssertEqual(progress.backedUp, 1)
    }

    // MARK: 9d. Composite resolver routes by source kind

    func testCompositeResolverRoutesAndRejectsUnknownKinds() async throws {
        let composite = CompositeBackupResourceResolver([.fileURL: resolver])
        let fileEntry = seedEntry("routed.jpg")
        let resolved = try await composite.resolve(fileEntry)
        XCTAssertEqual(resolved?.descriptor.filename, "routed.jpg")

        let photoEntry = UploadBackupSyncQueueEntry(
            source: UploadSourceIdentity(kind: .photoLibraryAsset, identifier: "asset-1"),
            revision: UploadBackupRevision(rawValue: 1),
            originalFilename: "IMG.HEIC",
            updatedAt: clock.now
        )
        do {
            _ = try await composite.resolve(photoEntry)
            XCTFail("unregistered source kinds must fail loudly, not guess")
        } catch {}
    }

    // MARK: 10. Concurrency stays bounded

    func testUploadConcurrencyRespectsThrottleLimit() async throws {
        for index in 0..<8 { _ = seedEntry("file-\(index).jpg") }
        let slowUploader = MockUploader(workDuration: .milliseconds(30), deliverProgress: false)

        let runner = makeRunner(uploader: slowUploader, throttle: BackupThrottlePolicy(baseConcurrency: 2))
        let progress = await runner.runUntilDrained()

        XCTAssertEqual(progress.uploaded, 8)
        XCTAssertLessThanOrEqual(slowUploader.peakConcurrent, 2)
    }

    // MARK: 11. Drifted file revision is recorded truthfully

    func testFileChangedAfterScanUploadsCurrentContentAndClosesBothRows() async throws {
        let entry = seedEntry("edited.jpg")
        let newModified = resolver.defaultModified.addingTimeInterval(500)
        resolver.setModified(newModified, for: entry.source.identifier)

        let runner = makeRunner()
        _ = await runner.runUntilDrained()

        XCTAssertEqual(state(of: entry), .completed, "the scanned row must not linger as runnable")
        let driftedRow = queueStore.entry(for: entry.source, revision: UploadBackupRevision(date: newModified))
        XCTAssertEqual(driftedRow?.state, .completed, "the resolved revision must get its own truthful row")
        let record = stateStore.record(for: entry.source, revision: UploadBackupRevision(date: newModified))
        XCTAssertEqual(record?.isComplete, true, "backed-up proof must be recorded for the revision that was uploaded")
        XCTAssertEqual(uploader.requests.count, 1)
    }
}
