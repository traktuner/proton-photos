import Foundation
import PhotosCore

/// Sleep seam so tests drive the runner's backoff waits deterministically.
public protocol BackupSchedulerClock: Sendable {
    func sleep(for seconds: TimeInterval) async throws
}

/// Production clock - real suspension via `Task.sleep`.
public struct BackupContinuousClock: BackupSchedulerClock {
    public init() {}

    public func sleep(for seconds: TimeInterval) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// The universal backup sync executor: drains the persistent `UploadBackupSyncQueueStore` through
/// the shared dedupe pipeline and upload backend. ONE implementation for every platform - adapters
/// contribute only a `BackupResourceResolving` (how to rematerialize a source) and throttle inputs.
///
/// Safety contract (the reason this actor exists):
/// - every state transition is persisted BEFORE the expensive/irreversible work it describes,
/// - a completed upload is recorded in the identity manifest BEFORE the queue row turns terminal,
///   so a crash in between re-resolves to a remote duplicate instead of a second upload,
/// - stale active rows from a crashed run are requeued on start (`requeueStaleActive`),
/// - trashed/deleted-remote duplicates and vanished sources land in their own explicit states and
///   are NEVER counted as backed up,
/// - a remote draft parks the row as `.blockedByDraft` and re-checks with capped backoff - it can
///   never surface as success.
public actor BackupSyncRunner {

    public struct Configuration: Sendable, Equatable {
        /// Queue rows fetched per scheduling round (workers take at most the throttle limit).
        public var batchSize: Int
        /// Rows active before (start − grace) are treated as crash leftovers. 0 = every active
        /// row at start is stale, which is correct while a single runner owns the queue.
        public var staleActiveGrace: TimeInterval
        /// Poll interval while the throttle reports "pause" (thermal critical etc.).
        public var pausedPollInterval: TimeInterval
        public var retry: BackupRetryPolicy
        public var throttle: BackupThrottlePolicy

        public init(
            batchSize: Int = 32,
            staleActiveGrace: TimeInterval = 0,
            pausedPollInterval: TimeInterval = 30,
            retry: BackupRetryPolicy = BackupRetryPolicy(),
            throttle: BackupThrottlePolicy = BackupThrottlePolicy()
        ) {
            self.batchSize = max(1, batchSize)
            self.staleActiveGrace = max(0, staleActiveGrace)
            self.pausedPollInterval = max(0.01, pausedPollInterval)
            self.retry = retry
            self.throttle = throttle
        }
    }

    private let queue: any UploadBackupSyncQueueStore
    private let preflight: UploadBackupPreflightIndex
    private let resolver: any BackupResourceResolving
    /// Deliberately non-optional: automatic backup without duplicate detection would risk double
    /// uploads, so a missing manifest must fail composition, not silently degrade.
    private let identityResolver: any UploadIdentityResolving
    private let uploader: any PhotoUploading
    private let configuration: Configuration
    private let throttleInputs: @Sendable () -> BackupThrottleInputs
    private let clock: any BackupSchedulerClock
    private let now: @Sendable () -> Date

    private var isRunning = false
    private var stopRequested = false
    /// Consecutive items that could not even reserve disk space since the last one that did.
    /// Reset to 0 the moment any export succeeds; when it reaches a full wave the drain ends the
    /// pass (rows stay runnable) instead of spinning against a genuinely full volume.
    private var resourcePressureStreak = 0
    /// Consecutive transport-level network failures since the last successful settle. Subtracted from
    /// the throttle's concurrency so the drain backs off a marginal/looping connection instead of
    /// hammering it with parallel requests, and ramps back up as items succeed. Capped so it can
    /// never wedge the drain below one in-flight item.
    private var networkErrorStreak = 0
    private static let maxNetworkBackoff = 5
    /// Earliest next-attempt time per queue row (in-memory: losing it on crash only means one
    /// immediate retry; the persisted attempt count keeps the budget bounded).
    private var notBefore: [String: Date] = [:]
    /// Cancellation tokens of uploads currently in flight, so `stop()` can abort transfers.
    private var inFlightTokens: [String: UUID] = [:]
    private var inFlightNames: [String: String] = [:]

    private var progress = BackupSyncProgress()
    private var onProgress: (@Sendable (BackupSyncProgress) -> Void)?

    public init(
        queue: any UploadBackupSyncQueueStore,
        preflight: UploadBackupPreflightIndex,
        resolver: any BackupResourceResolving,
        identityResolver: any UploadIdentityResolving,
        uploader: any PhotoUploading,
        configuration: Configuration = Configuration(),
        throttleInputs: @Sendable @escaping () -> BackupThrottleInputs = { .unconstrained },
        clock: any BackupSchedulerClock = BackupContinuousClock(),
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.queue = queue
        self.preflight = preflight
        self.resolver = resolver
        self.identityResolver = identityResolver
        self.uploader = uploader
        self.configuration = configuration
        self.throttleInputs = throttleInputs
        self.clock = clock
        self.now = now
    }

    public func setOnProgress(_ handler: (@Sendable (BackupSyncProgress) -> Void)?) {
        onProgress = handler
        emitProgress()
    }

    public func currentProgress() -> BackupSyncProgress {
        progress
    }

    /// Ask the current pass to wind down: no new work starts, in-flight uploads are cancelled,
    /// and every touched row is reverted to a runnable state for the next pass.
    public func stop() {
        stopRequested = true
        for token in inFlightTokens.values {
            let uploader = uploader
            Task { await uploader.cancel(token: token) }
        }
    }

    /// Runs crash recovery, then drains the queue until nothing is runnable and no transient
    /// retry is pending. Parked `blockedByDraft` rows do NOT keep the pass alive - they get one
    /// due-based re-check per pass and otherwise wait for the next one. Returns the final
    /// progress snapshot. A second concurrent call returns the live snapshot immediately.
    @discardableResult
    public func runUntilDrained() async -> BackupSyncProgress {
        guard !isRunning else { return progress }
        isRunning = true
        stopRequested = false
        notBefore = [:]
        resourcePressureStreak = 0
        defer {
            isRunning = false
            progress.isRunning = false
            progress.currentItemName = nil
            emitProgress()
        }

        // Crash recovery FIRST: anything still marked active predates this run and must become
        // runnable again before this runner atomically claims new work.
        queue.requeueStaleActive(before: now().addingTimeInterval(-configuration.staleActiveGrace), updatedAt: now())
        await requeueDueBlockedRows()

        progress = BackupSyncProgress(summary: queue.summary(), isRunning: true)
        emitProgress()

        // Warm the dedup pipeline's remote cache for the first batch so per-item resolves are cache
        // hits (see primeRunnableLookahead). Re-warmed periodically as the queue drains.
        await primeRunnableLookahead()
        var wavesSincePrime = 0

        while !stopRequested {
            await requeueDueBlockedRows()

            let policyLimit = configuration.throttle.maxConcurrentItems(for: throttleInputs())
            // Back off concurrency while a marginal connection is dropping requests, but never below 1
            // (never stall — a single in-flight item keeps making progress and probes recovery).
            let limit = policyLimit == 0 ? 0 : max(1, policyLimit - networkErrorStreak)
            if limit == 0 {
                if !progress.isPausedByPolicy {
                    progress.isPausedByPolicy = true
                    emitProgress()
                }
                try? await clock.sleep(for: configuration.pausedPollInterval)
                continue
            }
            if progress.isPausedByPolicy {
                progress.isPausedByPolicy = false
                emitProgress()
            }

            // Re-warm the dedup cache once the current lookahead is largely consumed. prime()
            // invalidates the previous batch first, so we do this on a cadence (not every wave) to
            // avoid dropping still-useful cached state mid-drain.
            if wavesSincePrime >= Self.wavesPerPrime {
                await primeRunnableLookahead()
                wavesSincePrime = 0
            }

            let wave = nextEligibleWave(limit: limit)
            if wave.isEmpty {
                guard let wait = shortestPendingWait() else { break }
                try? await clock.sleep(for: wait)
                continue
            }

            await withTaskGroup(of: Void.self) { group in
                for entry in wave {
                    group.addTask { await self.process(entry) }
                }
            }
            wavesSincePrime += 1

            // A whole wave that could not reserve disk space means the volume is full, not busy.
            // Stop draining and leave the rows runnable: the next pass retries once space frees,
            // and the status reads "waiting" (never a permanent, unactionable failure).
            if resourcePressureStreak >= configuration.batchSize { break }
        }

        // Truth re-sync from the store: incremental counters were exact (single writer), but the
        // final snapshot should come from the durable state regardless.
        progress = BackupSyncProgress(summary: queue.summary(), isRunning: false)
        emitProgress()
        return progress
    }

    // MARK: - Scheduling

    private func nextEligibleWave(limit: Int) -> [UploadBackupSyncQueueEntry] {
        let currentTime = now()
        let claimLimit = min(configuration.batchSize, max(1, limit))
        return queue.claimRunnable(limit: claimLimit, claimedAt: currentTime)
            .filter { entry in
                guard let eligibleAt = notBefore[Self.key(entry)] else { return true }
                if eligibleAt <= currentTime {
                    notBefore[Self.key(entry)] = nil
                    return true
                }
                return false
            }
    }

    /// The wait until the next in-memory retry becomes eligible, or nil when none is pending
    /// (which - with no runnable rows - means the pass is drained).
    private func shortestPendingWait() -> TimeInterval? {
        let currentTime = now()
        // Entries whose backoff already elapsed were consumed by the wave fetch; anything left
        // here is strictly in the future. Prune rows that turned terminal in the meantime.
        let pending = notBefore.values.map { $0.timeIntervalSince(currentTime) }.filter { $0 > 0 }
        return pending.min()
    }

    /// One due-based re-check for parked draft rows: a row blocked N times re-enters the queue
    /// once `updatedAt + retryDelay(N)` has passed (delay capped by the policy, so a draft that
    /// never clears is re-checked at most once per cap window - visible, never hot-looping).
    private func requeueDueBlockedRows() async {
        let currentTime = now()
        let blocked = queue.entries(in: .blockedByDraft, updatedBefore: currentTime, limit: configuration.batchSize)
        var requeued = false
        for entry in blocked {
            let due = entry.updatedAt.addingTimeInterval(configuration.retry.delay(afterAttempts: max(1, entry.attempts)))
            guard due <= currentTime else { continue }
            queue.updateState(
                source: entry.source, revision: entry.revision,
                state: .discovered, attempts: entry.attempts, lastError: entry.lastError, updatedAt: currentTime
            )
            adjustProgress(from: .blockedByDraft, to: .discovered)
            requeued = true
        }
        if requeued {
            // A cached "this name is occupied by a draft" view would make the re-check a no-op
            // (and a cached "free" view could double-upload) - re-checks must see server truth.
            await identityResolver.invalidateCachedRemoteState()
        }
    }

    // MARK: - Dedup batch prewarm

    /// How many runnable rows to prewarm per batch, and how many waves to run before re-warming.
    /// `wavesPerPrime` is kept below `primeBatch / typical-wave` so the next batch is warmed before
    /// the current one is exhausted.
    private static let primeBatch = 400
    private static let wavesPerPrime = 50
    private static let primePlaceholderURL = URL(fileURLWithPath: "/dev/null")

    /// Batch-prewarm the dedup pipeline's remote duplicate cache for the rows about to be processed,
    /// so their per-item `resolve` is a cache hit instead of an individual server round-trip — the
    /// dominant cost when reconciling a large already-backed-up library. Name-hash + source only (no
    /// byte export), so it is cheap; worst case it warms nothing and the per-item path is unchanged.
    private func primeRunnableLookahead() async {
        let cutoff = now()
        var peek = queue.entries(in: .discovered, updatedBefore: cutoff, limit: Self.primeBatch)
        if peek.count < Self.primeBatch {
            peek += queue.entries(in: .queuedForUpload, updatedBefore: cutoff, limit: Self.primeBatch - peek.count)
        }
        guard !peek.isEmpty else { return }
        let descriptors = peek.map { entry in
            UploadResourceDescriptor(
                source: entry.source,
                fileURL: Self.primePlaceholderURL,
                filename: entry.originalFilename,
                fileSize: entry.byteCount ?? 0,
                modificationDate: entry.updatedAt,
                mainResource: nil
            )
        }
        await identityResolver.prime(descriptors)
    }

    // MARK: - Per-entry processing

    private func process(_ entry: UploadBackupSyncQueueEntry) async {
        let key = Self.key(entry)
        var persistedState = entry.state
        inFlightNames[key] = entry.originalFilename
        progress.currentItemName = entry.originalFilename
        // Released the instant this entry settles, so temp exports never accumulate across a pass.
        var resourceCleanup: (@Sendable () -> Void)?
        defer {
            resourceCleanup?()
            inFlightNames[key] = nil
            if progress.currentItemName == entry.originalFilename {
                progress.currentItemName = inFlightNames.values.first
            }
            emitProgress()
        }

        // Checking phase - persisted before any bytes are read.
        persistedState = transition(entry, from: persistedState, to: .checking)

        let resolved: BackupResolvedResource?
        do {
            resolved = try await resolver.resolve(entry)
        } catch is CancellationError {
            revert(entry, from: persistedState)
            return
        } catch {
            if stopRequested { revert(entry, from: persistedState) } else { retryOrPark(entry, from: persistedState, error: error) }
            return
        }

        guard let resolved else {
            // Verifiably gone. Explicit terminal state - never retried, never "backed up".
            finish(entry, from: persistedState, as: .sourceMissing,
                   message: L10n.string("backup.error_source_missing"), resolved: nil)
            return
        }
        resourceCleanup = resolved.cleanup
        resourcePressureStreak = 0    // an export succeeded → the volume has space again
        if stopRequested { revert(entry, from: persistedState); return }

        // Identity + duplicate decision (manifest-cached hash → HMACs → remote check). The
        // pipeline persists the identity before its remote call, so a crash from here on never
        // re-pays hashing.
        let preflightResult: UploadPreflightResult
        do {
            preflightResult = try await identityResolver.resolve(resolved.descriptor)
        } catch is CancellationError {
            revert(entry, from: persistedState)
            return
        } catch {
            if stopRequested { revert(entry, from: persistedState) } else { retryOrPark(entry, from: persistedState, error: error) }
            return
        }
        if stopRequested { revert(entry, from: persistedState); return }

        switch preflightResult.decision {
        case .upload:
            await upload(entry, from: persistedState, resolved: resolved, preflight: preflightResult)

        case let .uploadMissingSecondaries(primaryLinkID, _):
            // This entry IS the primary and the policy proved it active remotely; only paired
            // secondaries would need bytes.
            await settleCompound(
                entry, from: persistedState, resolved: resolved,
                primaryUID: PhotoUID(volumeID: "", nodeID: primaryLinkID),
                terminal: .alreadyBackedUp
            )

        case let .skip(reason, remoteLinkID):
            switch reason {
            case .activeDuplicate, .knownFromManifest:
                // The primary is proven remote. Secondaries (a Live Photo's paired video) may
                // still be missing - settle them before any "backed up" claim. The link-only
                // reference resolves to the photos volume at the transport layer.
                await settleCompound(
                    entry, from: persistedState, resolved: resolved,
                    primaryUID: remoteLinkID.map { PhotoUID(volumeID: "", nodeID: $0) },
                    terminal: .alreadyBackedUp
                )

            case .trashedDuplicate, .deletedRemotely:
                // Respect the user's remote deletion: no upload, and explicitly NOT backed up.
                // No preflight record either - the next scan re-checks, so restoring from the
                // Proton trash naturally flips this to alreadyBackedUp later.
                finish(entry, from: persistedState, as: .skippedRemoteDeletion,
                       message: L10n.string("backup.state_skipped_remote_deletion"), resolved: resolved)

            case .draftExists:
                // Another upload (possibly our own crashed one) occupies the name. Park with
                // backoff; NEVER a success state.
                let attempts = entry.attempts + 1
                queue.updateState(
                    source: entry.source, revision: entry.revision,
                    state: .blockedByDraft, attempts: attempts,
                    lastError: L10n.string("upload.error_remote_draft"), updatedAt: now()
                )
                adjustProgress(from: persistedState, to: .blockedByDraft)
                emitProgress()

            case .inconsistentRemoteState:
                retryOrPark(entry, from: persistedState,
                            error: UploadError.backend(L10n.string("upload.error_remote_inconsistent")))
            }
        }
    }

    private func upload(
        _ entry: UploadBackupSyncQueueEntry,
        from state: UploadBackupSyncQueueState,
        resolved: BackupResolvedResource,
        preflight preflightResult: UploadPreflightResult
    ) async {
        let key = Self.key(entry)
        let persistedState = transition(entry, from: state, to: .uploading)
        let token = UUID()
        inFlightTokens[key] = token
        defer { inFlightTokens[key] = nil }

        let request = PhotoUploadRequest(
            queueItemID: UUID(),
            cancellationToken: token,
            fileURL: resolved.descriptor.fileURL,
            name: resolved.descriptor.filename,
            mediaType: resolved.mediaType,
            fileSize: resolved.descriptor.fileSize,
            captureTime: resolved.captureDate,
            modificationDate: resolved.descriptor.modificationDate,
            tags: [],
            additionalMetadata: resolved.additionalMetadata
        ).applying(identity: preflightResult.identity)

        let uid: PhotoUID
        do {
            uid = try await uploader.upload(request) { _ in }
        } catch {
            // Settle the pipeline's same-content claim (identical items may be waiting on this
            // upload) and drop the cached remote view - the server may have committed the
            // attempt even though the call failed, so the retry must re-query.
            await identityResolver.uploadDidFail(resolved.descriptor)
            if error is CancellationError || stopRequested {
                revert(entry, from: persistedState)
            } else {
                retryOrPark(entry, from: persistedState, error: error)
            }
            return
        }

        // Durability order is the no-double-upload guarantee:
        // 1. identity manifest remembers the uploaded outcome (survives everything),
        // 2. backup preflight marks the source revision complete,
        // 3. only then does the queue row turn terminal.
        // A crash between any of these re-resolves to a known/active duplicate - never a re-upload.
        await identityResolver.recordUploaded(
            resolved.descriptor, identity: preflightResult.identity,
            remoteVolumeID: uid.volumeID, remoteLinkID: uid.nodeID
        )
        await settleCompound(entry, from: persistedState, resolved: resolved, primaryUID: uid, terminal: .completed)
    }

    // MARK: - Compound settlement (secondaries after the primary)

    private enum SecondaryOutcome {
        case allSettled
        case failed(remaining: Int, message: String)
        case cancelled
    }

    /// Uploads/dedupes any secondary resources, then - and only then - marks the compound backed
    /// up. Partial secondary failure records honest pending state and retries the whole entry;
    /// the primary is never re-uploaded (its manifest row short-circuits the next pass).
    private func settleCompound(
        _ entry: UploadBackupSyncQueueEntry,
        from state: UploadBackupSyncQueueState,
        resolved: BackupResolvedResource,
        primaryUID: PhotoUID?,
        terminal: UploadBackupSyncQueueState
    ) async {
        var persistedState = state
        if !resolved.secondaries.isEmpty {
            if persistedState != .uploading {
                persistedState = transition(entry, from: persistedState, to: .uploading)
            }
            guard let primaryUID else {
                // No remote reference for the primary - cannot pair secondaries safely.
                retryOrPark(entry, from: persistedState,
                            error: UploadError.backend(L10n.string("upload.error_remote_inconsistent")))
                return
            }
            switch await settleSecondaries(resolved.secondaries, primaryUID: primaryUID, entryKey: Self.key(entry)) {
            case .allSettled:
                break
            case let .failed(remaining, message):
                await preflight.markPending(resolved.candidate.snapshot, pendingResourceCount: remaining)
                retryOrPark(entry, from: persistedState, error: UploadError.backend(message))
                return
            case .cancelled:
                revert(entry, from: persistedState)
                return
            }
        }
        await preflight.markBackedUp(resolved.candidate.snapshot)
        finish(entry, from: persistedState, as: terminal, message: nil, resolved: resolved)
    }

    /// Each secondary goes through the SAME pipeline (manifest fast path skips ones already
    /// uploaded by a previous attempt) and uploads with `mainPhotoUID` referencing the primary.
    private func settleSecondaries(
        _ secondaries: [BackupSecondaryResource],
        primaryUID: PhotoUID,
        entryKey: String
    ) async -> SecondaryOutcome {
        var remaining = secondaries.count
        var lastMessage = ""
        for secondary in secondaries {
            if stopRequested { return .cancelled }
            do {
                let result = try await identityResolver.resolve(secondary.descriptor)
                switch result.decision {
                case .skip, .uploadMissingSecondaries:
                    remaining -= 1
                case .upload:
                    let token = UUID()
                    inFlightTokens["\(entryKey)#\(secondary.descriptor.source.resource.rawValue)"] = token
                    defer { inFlightTokens["\(entryKey)#\(secondary.descriptor.source.resource.rawValue)"] = nil }
                    let request = PhotoUploadRequest(
                        queueItemID: UUID(),
                        cancellationToken: token,
                        fileURL: secondary.descriptor.fileURL,
                        name: secondary.descriptor.filename,
                        mediaType: secondary.mediaType,
                        fileSize: secondary.descriptor.fileSize,
                        captureTime: resolvedCaptureDate(for: secondary),
                        modificationDate: secondary.descriptor.modificationDate,
                        tags: [],
                        additionalMetadata: secondary.additionalMetadata,
                        mainPhotoUID: primaryUID
                    ).applying(identity: result.identity)
                    let uid: PhotoUID
                    do {
                        uid = try await uploader.upload(request) { _ in }
                    } catch {
                        await identityResolver.uploadDidFail(secondary.descriptor)
                        throw error
                    }
                    await identityResolver.recordUploaded(
                        secondary.descriptor, identity: result.identity,
                        remoteVolumeID: uid.volumeID, remoteLinkID: uid.nodeID
                    )
                    remaining -= 1
                }
            } catch is CancellationError {
                return .cancelled
            } catch {
                if stopRequested { return .cancelled }
                lastMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        return remaining == 0 ? .allSettled : .failed(remaining: remaining, message: lastMessage)
    }

    private func resolvedCaptureDate(for secondary: BackupSecondaryResource) -> Date {
        secondary.descriptor.modificationDate
    }

    // MARK: - Transitions (persist first, then adjust the in-memory mirror)

    private func transition(
        _ entry: UploadBackupSyncQueueEntry,
        from oldState: UploadBackupSyncQueueState,
        to newState: UploadBackupSyncQueueState
    ) -> UploadBackupSyncQueueState {
        queue.updateState(
            source: entry.source, revision: entry.revision,
            state: newState, attempts: nil, lastError: nil, updatedAt: now()
        )
        adjustProgress(from: oldState, to: newState)
        emitProgress()
        return newState
    }

    private func finish(
        _ entry: UploadBackupSyncQueueEntry,
        from oldState: UploadBackupSyncQueueState,
        as terminal: UploadBackupSyncQueueState,
        message: String?,
        resolved: BackupResolvedResource?
    ) {
        queue.updateState(
            source: entry.source, revision: entry.revision,
            state: terminal, attempts: nil, lastError: message, updatedAt: now()
        )
        // A settled item means the connection is working again — ease the network backoff one step so
        // concurrency ramps back toward the policy limit (gentle recovery, not an all-at-once jump).
        if terminal.isTerminalSuccess, networkErrorStreak > 0 {
            networkErrorStreak -= 1
        }
        adjustProgress(from: oldState, to: terminal)
        if let resolved { closeDriftedRevisionRow(entry, resolved: resolved, as: terminal) }
        emitProgress()
    }

    /// When the file changed between scan and processing, the CURRENT revision was handled, not
    /// the scanned one. Record a row for the resolved revision too, so the next scan's direct
    /// preflight hit lines up with a queue row and totals stay truthful.
    private func closeDriftedRevisionRow(
        _ entry: UploadBackupSyncQueueEntry,
        resolved: BackupResolvedResource,
        as terminal: UploadBackupSyncQueueState
    ) {
        let snapshot = resolved.candidate.snapshot
        guard snapshot.revision != entry.revision else { return }
        queue.upsert(UploadBackupSyncQueueEntry(
            source: snapshot.source,
            revision: snapshot.revision,
            originalFilename: resolved.candidate.originalFilename,
            byteCount: resolved.candidate.byteCount,
            state: terminal,
            attempts: 0,
            lastError: nil,
            updatedAt: now()
        ))
        adjustProgress(from: nil, to: terminal)
    }

    private func retryOrPark(
        _ entry: UploadBackupSyncQueueEntry,
        from oldState: UploadBackupSyncQueueState,
        error: Error
    ) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription

        // Disk-space pressure is not the item's fault: it must NEVER burn the retry budget into a
        // permanent `.failed` (that is exactly what stranded a whole library behind an unactionable
        // "needs attention"). Requeue it runnable with a short backoff, leave its attempt count
        // untouched, and let the pass-level guard end the drain if the volume stays full.
        if Self.isTransientResourcePressure(error) {
            resourcePressureStreak += 1
            let eligibleAt = now().addingTimeInterval(configuration.retry.delay(afterAttempts: 1))
            queue.updateState(
                source: entry.source, revision: entry.revision,
                state: .discovered, attempts: entry.attempts, lastError: message, updatedAt: eligibleAt
            )
            notBefore[Self.key(entry)] = eligibleAt
            adjustProgress(from: oldState, to: .discovered)
            emitProgress()
            return
        }

        // A transport-level network failure (connection reset, timeout, offline) is environmental, not
        // the item's fault: never burn its retry budget into a permanent `.failed`. Requeue runnable
        // with a short backoff, and grow a network-error streak so the drain throttles its concurrency
        // down — many parallel requests are exactly what provokes NSURLErrorNetworkConnectionLost on a
        // marginal link — then ramps back up as calls start succeeding again.
        if Self.isTransientNetwork(error) {
            networkErrorStreak = min(Self.maxNetworkBackoff, networkErrorStreak + 1)
            let eligibleAt = now().addingTimeInterval(configuration.retry.delay(afterAttempts: 1))
            queue.updateState(
                source: entry.source, revision: entry.revision,
                state: .discovered, attempts: entry.attempts, lastError: message, updatedAt: eligibleAt
            )
            notBefore[Self.key(entry)] = eligibleAt
            adjustProgress(from: oldState, to: .discovered)
            emitProgress()
            return
        }

        let attempts = entry.attempts + 1
        if configuration.retry.shouldPark(attempts: attempts) {
            queue.updateState(
                source: entry.source, revision: entry.revision,
                state: .failed, attempts: attempts, lastError: message, updatedAt: now()
            )
            adjustProgress(from: oldState, to: .failed)
        } else {
            let eligibleAt = now().addingTimeInterval(configuration.retry.delay(afterAttempts: attempts))
            queue.updateState(
                source: entry.source, revision: entry.revision,
                state: .discovered, attempts: attempts, lastError: message, updatedAt: eligibleAt
            )
            notBefore[Self.key(entry)] = eligibleAt
            adjustProgress(from: oldState, to: .discovered)
        }
        emitProgress()
    }

    /// Stop/cancel path: put the row back where the NEXT pass picks it up, without burning an
    /// attempt (stopping the app is not a failure of the item).
    private func revert(_ entry: UploadBackupSyncQueueEntry, from oldState: UploadBackupSyncQueueState) {
        let runnable: UploadBackupSyncQueueState = (oldState == .uploading || oldState == .finalizing)
            ? .queuedForUpload
            : .discovered
        queue.updateState(
            source: entry.source, revision: entry.revision,
            state: runnable, attempts: nil, lastError: entry.lastError, updatedAt: now()
        )
        adjustProgress(from: oldState, to: runnable)
        emitProgress()
    }

    // MARK: - Progress mirror

    /// Mirrors one persisted row move onto the in-memory snapshot. The runner is the queue's
    /// only writer during a pass, so incremental mirroring stays exact; the final snapshot is
    /// re-read from the store regardless. `oldState == nil` means a row was created.
    private func adjustProgress(from oldState: UploadBackupSyncQueueState?, to newState: UploadBackupSyncQueueState) {
        addToProgress(newState, sign: 1)
        if let oldState {
            addToProgress(oldState, sign: -1)
        } else {
            progress.total += 1
        }
    }

    private func addToProgress(_ state: UploadBackupSyncQueueState, sign: Int) {
        switch state {
        case .discovered:
            progress.waiting += sign
        case .queuedForUpload:
            progress.waiting += sign
            progress.uploadQueued += sign
        case .checking, .hashing, .duplicateChecking:
            progress.checking += sign
        case .uploading, .finalizing:
            progress.uploading += sign
        case .alreadyBackedUp:
            progress.alreadyBackedUp += sign
        case .completed:
            progress.uploaded += sign
        case .skippedRemoteDeletion:
            progress.skippedRemoteDeletions += sign
        case .sourceMissing:
            progress.sourceMissing += sign
        case .blockedByDraft:
            progress.blocked += sign
        case .failed:
            progress.failed += sign
        case .paused:
            progress.paused += sign
        }
    }

    private func emitProgress() {
        onProgress?(progress)
    }

    /// Errors that reflect a temporary lack of disk space rather than a bad item. These are
    /// retried indefinitely (with backoff) and never parked as `.failed`.
    private static func isTransientResourcePressure(_ error: Error) -> Bool {
        (error as? BackupTempFileStore.BackupTempFileError) == .diskBudgetExceeded
    }

    /// Transport-level failures that are the network's fault, not the item's: a dropped/reset
    /// connection, a timeout, or being briefly offline. These must never park an item as `.failed`
    /// (the photo is fine, the link isn't) and they drive the adaptive concurrency backoff. Matches
    /// both `URLError` and an `NSError` in the URL-error domain (as the Proton SDK may surface it).
    static func isTransientNetwork(_ error: Error) -> Bool {
        let transientCodes: Set<Int> = [
            NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut, NSURLErrorNotConnectedToInternet,
            NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed,
            NSURLErrorResourceUnavailable, NSURLErrorSecureConnectionFailed, NSURLErrorCannotLoadFromNetwork,
            NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed, NSURLErrorRequestBodyStreamExhausted,
        ]
        if let urlError = error as? URLError, transientCodes.contains(urlError.errorCode) { return true }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && transientCodes.contains(ns.code)
    }

    private static func key(_ entry: UploadBackupSyncQueueEntry) -> String {
        "\(entry.source.kind.rawValue)|\(entry.source.identifier)|\(entry.source.resource.rawValue)|\(entry.revision.rawValue)"
    }
}
