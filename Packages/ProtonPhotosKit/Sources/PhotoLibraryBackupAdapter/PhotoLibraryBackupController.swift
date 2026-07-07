import Foundation
import Observation
import PhotosCore
import UploadCore
#if canImport(Darwin)
import Darwin
#endif

/// The ONE photo-library backup orchestrator, shared verbatim by iOS, iPadOS, and macOS. It
/// composes the universal core (engine, runner, dedupe pipeline, status model, catalog, execution
/// lock) with the PhotoKit adapter pieces (catalog scan source, resolver, change monitor). Platform
/// apps contribute ONLY: dependency injection, OS scheduling hooks (BGTask on iOS), permission UI,
/// and settings screens.
///
/// Consent contract: backup never enables itself. `enableBackup()` is the only entry point that
/// requests photo access, and it must be called from an explicit user action. Once enabled, the
/// controller may resume interrupted work on launch.
@MainActor
@Observable
public final class PhotoLibraryBackupController {

    public struct Configuration {
        /// Per-account directory holding the backup stores (sign-out purge covers it wholesale).
        public var accountDataDirectory: URL
        public var databasePolicy: LibraryDatabasePolicy
        public var defaults: UserDefaults

        public init(
            accountDataDirectory: URL,
            databasePolicy: LibraryDatabasePolicy,
            defaults: UserDefaults = .standard
        ) {
            self.accountDataDirectory = accountDataDirectory
            self.databasePolicy = databasePolicy
            self.defaults = defaults
        }
    }

    private static let enabledDefaultsKey = "photoBackup.enabled.v1"
    private static let userPausedDefaultsKey = "photoBackup.userPaused.v1"
    static let queueDatabaseFileName = "photo-backup-sync-queue-v1.sqlite"
    static let stateDatabaseFileName = "photo-backup-state-v1.sqlite"
    static let catalogDatabaseFileName = "photo-library-catalog-v1.sqlite"
    static let lockDatabaseFileName = "backup-execution-lock-v1.sqlite"

    /// Lease used when reaping abandoned locks before a start; matches the lock store default so a
    /// crashed/expired owner is recoverable while a healthy owner (heartbeat every 30s) never is.
    private static let lockLease: TimeInterval = BackupExecutionLockManifestStore.defaultLeaseInterval
    private static let heartbeatInterval: TimeInterval = 30

    public private(set) var accessState: PhotoBackupAccessState
    public private(set) var isEnabled: Bool
    /// Durable user "pause": no passes run and no auto-resume fires until the user resumes. Distinct
    /// from a policy pause (thermal/battery, transient) and from `isEnabled` (the whole feature off).
    public private(set) var isUserPaused: Bool
    public private(set) var status = BackupStatus()
    public private(set) var isSyncing = false
    public private(set) var lastMessage: String?
    /// Latest local-catalog scan tally (scanned/discovered/changed/removed) - pure inventory, it
    /// never implies upload. DELIBERATELY not shown in the backup status row: mid-scan these counts
    /// have no known denominator, so a live "1,240 scanned" would be indeterminate noise next to the
    /// honest scanning/checking/uploading phases the shared `BackupStatus` already drives (and would
    /// risk reading as a second, competing progress surface). Kept as a debug/telemetry hook - and
    /// the scan-progress seam the catalog-sync tests exercise; surfacing it later needs no Core change.
    public private(set) var lastCatalogProgress: PhotoLibraryCatalogProgress?

    /// False when the dedupe manifest, backup stores, or execution lock could not open - backup
    /// then refuses to run rather than risking duplicate uploads or multiple drainers.
    public var isAvailable: Bool { runner != nil && lockStore != nil }

    private let engine: UploadBackupSyncEngine?
    private let runner: BackupSyncRunner?
    private let queueStore: UploadBackupSyncQueueManifestStore?
    private let stateStore: UploadBackupStateManifestStore?
    private let catalogStore: PhotoLibraryCatalogManifestStore?
    private let lockStore: BackupExecutionLockManifestStore?
    private let tempStore: BackupTempFileStore
    private let monitor: PhotoLibraryChangeMonitor
    private let defaults: UserDefaults
    private var syncTask: Task<Void, Never>?
    private var changeDebounceTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    /// Periodically refreshes the UI status from the durable queue summary while a pass runs. The
    /// runner's emitted in-memory progress mirror only counts ITS OWN transitions; since scan and
    /// reconcile now write the queue concurrently, that mirror can drift/freeze (the "stuck at 829"
    /// counter). The queue summary is the single source of truth, so we poll it.
    private var statusRefreshTask: Task<Void, Never>?
    /// Re-triggers a pass a short while after one ends with work still outstanding (e.g. items in
    /// network backoff), so the backup CONTINUES on its own instead of sitting in "waiting" forever.
    private var autoResumeTask: Task<Void, Never>?
    private static let autoResumeDelay: TimeInterval = 45
    private var activeRunID: String?
    private var pendingSyncAfterStop = false
    private var isScanning = false
    private var lastStatusUpdate = Date.distantPast
    /// Last item the runner reported working on. The 1s status refresh reads the DURABLE queue (which
    /// has no notion of "current item"), so without caching it the liveness line would blink out
    /// every refresh. The runner's in-memory mirror is the only source of the in-flight name, so we
    /// stash it here and fold it into `currentQueueProgress()`. Cleared when a pass ends.
    private var lastRunnerItemName: String?
    /// Same caching for the item whose bytes are moving right now, so the "wird gesichert: X" line
    /// survives the DB-truth refresh. nil whenever nothing is mid-transfer.
    private var lastRunnerUploadingName: String?

    public init(
        configuration: Configuration,
        identityResolver: (any UploadIdentityResolving)?,
        uploader: any PhotoUploading
    ) {
        let directory = configuration.accountDataDirectory
        defaults = configuration.defaults
        accessState = PhotoLibraryAuthorization.currentState()
        isEnabled = configuration.defaults.bool(forKey: Self.enabledDefaultsKey)
        isUserPaused = configuration.defaults.bool(forKey: Self.userPausedDefaultsKey)
        tempStore = BackupTempFileStore(directory: directory.appendingPathComponent("photo-backup-temp", isDirectory: true))
        monitor = PhotoLibraryChangeMonitor(tokenURL: directory.appendingPathComponent("photo-backup-change-token.v1"))

        let queueStore = UploadBackupSyncQueueManifestStore(
            url: directory.appendingPathComponent(Self.queueDatabaseFileName),
            policy: configuration.databasePolicy
        )
        let stateStore = UploadBackupStateManifestStore(
            url: directory.appendingPathComponent(Self.stateDatabaseFileName),
            policy: configuration.databasePolicy
        )
        self.queueStore = queueStore
        self.stateStore = stateStore
        // Catalog + lock are independent of the upload composition: they open even before an
        // identity resolver exists, so inventory/ownership survive a partial account bring-up.
        catalogStore = PhotoLibraryCatalogManifestStore(
            url: directory.appendingPathComponent(Self.catalogDatabaseFileName),
            policy: configuration.databasePolicy
        )
        lockStore = BackupExecutionLockManifestStore(
            url: directory.appendingPathComponent(Self.lockDatabaseFileName),
            policy: configuration.databasePolicy,
            leaseInterval: Self.lockLease
        )

        if let queueStore, let stateStore, let identityResolver {
            let preflight = UploadBackupPreflightIndex(store: stateStore)
            engine = UploadBackupSyncEngine(preflight: preflight, queue: queueStore)
            runner = BackupSyncRunner(
                queue: queueStore,
                preflight: preflight,
                resolver: PhotoLibraryResourceResolver(tempStore: tempStore),
                identityResolver: identityResolver,
                uploader: uploader,
                throttleInputs: {
                    let process = ProcessInfo.processInfo
                    let level: BackupThermalLevel = switch process.thermalState {
                    case .nominal: .nominal
                    case .fair: .fair
                    case .serious: .serious
                    case .critical: .critical
                    @unknown default: .serious
                    }
                    return BackupThrottleInputs(thermalLevel: level, isLowPowerMode: process.isLowPowerModeEnabled)
                }
            )
        } else {
            engine = nil
            runner = nil
        }

        tempStore.sweep()
        refreshFromQueue()
        if let runner {
            Task {
                await runner.setOnProgress { snapshot in
                    Task { @MainActor [weak self] in self?.applyRunnerProgress(snapshot) }
                }
            }
        }
        if isEnabled {
            startObservingChanges()
            Task { @MainActor [weak self] in
                self?.resumeEnabledBackupAfterLaunch()
            }
        }
    }

    // MARK: - Enable / disable (explicit consent only)

    /// Requests read-write photo access and, when granted (full OR limited), turns backup on and
    /// starts the first pass. Call only from an explicit user action - the UI must explain what
    /// will happen BEFORE invoking this.
    public func enableBackup() async {
        accessState = await PhotoLibraryAuthorization.request()
        guard accessState.allowsBackup else { return }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledDefaultsKey)
        startObservingChanges()
        // Re-enabling is an explicit user action: give anything previously parked as failed a fresh
        // start so toggling backup off/on is a real recovery path, not a no-op.
        queueStore?.requeueFailed(updatedAt: Date())
        refreshFromQueue()
        if isSyncing {
            pendingSyncAfterStop = true
            stopSync()
            return
        }
        syncNow()
    }

    public func disableBackup() {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledDefaultsKey)
        pendingSyncAfterStop = false
        changeDebounceTask?.cancel()
        changeDebounceTask = nil
        monitor.stopObserving()
        stopSync()
        if !isSyncing {
            refreshFromQueue()
        }
    }

    public func refreshAccessState() {
        accessState = PhotoLibraryAuthorization.currentState()
    }

    // MARK: - Sync lifecycle

    /// Foreground/user-initiated pass.
    public func syncNow() {
        startSync(owner: .foreground)
    }

    /// Durable user pause: stop the current pass AND suppress every automatic (re)start until the user
    /// resumes. Persisted so it survives relaunch. This is what the Pause button does — unlike a bare
    /// `stopSync()`, a change notification or the auto-resume can't quietly restart behind the user.
    public func pauseBackup() {
        guard !isUserPaused else { return }
        isUserPaused = true
        defaults.set(true, forKey: Self.userPausedDefaultsKey)
        pendingSyncAfterStop = false
        stopSync()
        if !isSyncing { refreshFromQueue() }   // reflect "Pausiert" immediately
    }

    /// Clears the durable pause and immediately resumes (retrying anything parked as `.failed`).
    public func resumeBackup() {
        guard isUserPaused else { return }
        isUserPaused = false
        defaults.set(false, forKey: Self.userPausedDefaultsKey)
        retryFailedAndSync()
    }

    /// The manual "back up now" entry point. Unlike `syncNow()` (also used by automatic
    /// change-driven passes), this first requeues everything parked as `.failed`, so a user who
    /// sees "needs attention" and taps back-up-now actually retries those items instead of
    /// triggering a pass that skips them. A no-op while a pass is already running.
    public func retryFailedAndSync() {
        guard !isSyncing else { return }
        queueStore?.requeueFailed(updatedAt: Date())
        refreshFromQueue()
        syncNow()
    }

    /// One full catch-up pass for OS background windows (BGProcessingTask on iOS, background
    /// activity on macOS). Returns when the pass drains or is stopped by the expiration handler via
    /// `stopSync()` - every state transition is already checkpointed, so expiration simply resumes
    /// next time. Callers pass the specific owner so the durable lock records who ran.
    public func backgroundCatchUp(owner: BackupExecutionOwner = .background) async {
        startSync(owner: owner)
        await syncTask?.value
    }

    /// The single entry point that starts a pass. Acquires durable execution ownership BEFORE any
    /// draining: a crashed/expired owner's stale lock is reaped here, and a live lock held by a
    /// different run makes this call stand down instead of starting a second drainer.
    private func startSync(owner: BackupExecutionOwner) {
        guard isEnabled, !isUserPaused, accessState.allowsBackup, !isSyncing, let engine, let runner else { return }
        guard let lockStore else {
            lastMessage = L10n.string("backup.error_execution_lock_unavailable")
            refreshFromQueue()
            return
        }

        let runID = UUID().uuidString
        // Recovery must precede the drain: clear any owner that stopped heartbeating (crash,
        // OS kill, BG expiration) so a dead run can never permanently block backup.
        let processContext = Self.processContext
        lockStore.recoverAbandonedProcessLocks(
            currentProcessContext: processContext,
            isProcessAlive: Self.processIsAlive
        )
        lockStore.recoverStaleLocks(olderThan: Date().addingTimeInterval(-Self.lockLease))
        switch lockStore.acquire(owner: owner, runID: runID, phase: "scanning", processContext: processContext) {
        case .acquired:
            break
        case .busy:
            // Another live run owns the queue (e.g. a foreground pass while a BG window fires).
            // Stand down: its own drain covers the work; a second drainer is never allowed.
            return
        case .unavailable:
            lastMessage = L10n.string("backup.error_execution_lock_unavailable")
            refreshFromQueue()
            return
        }
        activeRunID = runID

        autoResumeTask?.cancel(); autoResumeTask = nil   // a pass is starting; the timer's job is done
        isSyncing = true
        isScanning = false
        lastMessage = nil
        status = BackupStatus(progress: currentQueueProgress(), isScanning: false)
        startHeartbeat(runID: runID)
        startStatusRefresh()

        // The task inherits the main actor, but all heavy phases (`scan`, `runUntilDrained`) are
        // awaits onto other actors/off-actor structs - the main thread stays free for UI.
        syncTask = Task { [weak self, monitor, tempStore, engine, runner, catalogStore] in
            // The INDEX (scan) and the RECONCILE (drain → upload) run as two INDEPENDENT loops, not
            // one serial pass. The reconcile loop runs CONCURRENTLY with the scan and starts by
            // draining whatever is already runnable — so a large backlog from an earlier pass uploads
            // immediately, and newly-scanned assets upload the moment they are enqueued. A slow,
            // interrupted, or resuming scan can therefore NEVER block uploads. Only the reconcile loop
            // drives the runner (the two never overlap); the queue store they share is transaction-safe.
            // This is the structural guarantee that "a backup must not block itself".
            let scanDone = BackupScanSignal()
            async let reconcile: Void = Self.reconcileWhileScanning(runner: runner, scanDone: scanDone)

            self?.beginScanPhase()
            let preparedChanges = monitor.prepareChanges()
            do {
                try await self?.runScanPass(engine: engine, catalogStore: catalogStore, changes: preparedChanges.changes)
                monitor.commit(preparedChanges)
            } catch {
                self?.reportSyncMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self?.finishScanPhase()

            await scanDone.markDone()
            await reconcile             // drains the tail enqueued during the scan, then returns
            tempStore.sweep()           // every export is re-derivable; nothing to keep between passes
            self?.finishSync(runID: runID)
        }
    }

    /// The reconcile loop: repeatedly drains runnable queue rows to the backend until the index scan
    /// has signalled completion AND nothing runnable remains. Runs concurrently with the scan, so a
    /// slow or resuming scan never delays uploads. Static + the heavy work is on the runner actor, so
    /// it never touches the main thread and does not depend on the controller's lifetime.
    private static func reconcileWhileScanning(runner: BackupSyncRunner, scanDone: BackupScanSignal) async {
        while !Task.isCancelled {
            await runner.runUntilDrained()
            if await scanDone.isDone() {
                // The scan may have enqueued rows between our last claim and its done-signal; one more
                // drain guarantees they upload before we return.
                await runner.runUntilDrained()
                return
            }
            // Yield the CPU and let the scan enqueue more before the next drain (no hot empty spin).
            // A cancelled sleep drops straight out via the loop condition — no busy loop on stop.
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    /// Runs the scan phase for this pass. Prefers the persistent catalog driver (writes durable
    /// queue rows before advancing the catalog, and skips unchanged assets on repeat passes); falls
    /// back to the direct streaming enumeration only if the catalog store failed to open. `nonisolated`
    /// so the SQLite/PhotoKit work runs off the main actor.
    private nonisolated func runScanPass(
        engine: UploadBackupSyncEngine,
        catalogStore: PhotoLibraryCatalogManifestStore?,
        changes: PhotoLibraryChangeMonitor.ChangeSet
    ) async throws {
        if let catalogStore {
            let sync = PhotoLibraryCatalogSync(
                store: catalogStore,
                onProgress: { [weak self] progress in
                    Task { @MainActor in self?.lastCatalogProgress = progress }
                }
            )
            let needsFullScan = changes.requiresFullRescan || !catalogStore.hasCompletedFullScan()

            // Fast-path recently added/changed assets FIRST, every pass — even mid-backfill. A photo
            // saved by another app (e.g. a WhatsApp image) or edited WHILE the initial full scan is
            // still running must not wait for that scan to finish: the change token names it, so
            // enqueue it now and let the concurrent reconcile upload it. Skipped only when the token is
            // untrusted (requiresFullRescan) — then its id list is unreliable and the full scan covers it.
            if !changes.requiresFullRescan {
                let targeted = Array(Set(changes.changedIdentifiers + changes.deletedIdentifiers))
                if !targeted.isEmpty {
                    _ = try await sync.run(engine: engine, identifiers: targeted)
                }
            }

            if needsFullScan {
                // A lost/expired token means we can no longer trust an in-progress epoch's frontier to
                // have covered every change, so re-observe the whole library from the start. Otherwise
                // resume: the full scan is resumable and marks itself complete only when it reaches the
                // library's end (across however many interrupted runs), so it never restarts needlessly.
                if changes.requiresFullRescan {
                    catalogStore.clearFullScanResumePoint()
                }
                _ = try await sync.run(engine: engine, identifiers: nil)
            }
            return
        }
        // Catalog unavailable: there is no durable proof that we know the full library, so prefer a
        // complete pass. This is slower only in the degraded path, but avoids silently backing up a
        // PhotoKit delta as if it were the entire library.
        _ = try await engine.scan(PhotoLibraryBackupCatalog())
    }

    private func resumeEnabledBackupAfterLaunch() {
        refreshAccessState()
        guard isEnabled, accessState.allowsBackup, !isSyncing else { return }
        syncNow()
    }

    public func stopSync() {
        // Cancel the pass so BOTH the scan and the concurrent reconcile loop wind down (a loop that
        // kept calling runUntilDrained would otherwise reset the runner's stop flag on its next call
        // and never actually stop). runner.stop() additionally aborts any in-flight upload promptly.
        syncTask?.cancel()
        statusRefreshTask?.cancel(); statusRefreshTask = nil
        autoResumeTask?.cancel(); autoResumeTask = nil
        guard let runner else { return }
        Task { await runner.stop() }
    }

    // MARK: - Execution-lock heartbeat

    private func startHeartbeat(runID: String) {
        heartbeatTask?.cancel()
        guard let lockStore else { heartbeatTask = nil; return }
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.heartbeatInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                // Lost the lock (reaped as stale, or stolen) → stop refreshing; the pass winds down
                // naturally and the new owner drives the queue.
                if !lockStore.heartbeat(runID: runID, phase: nil) { return }
                _ = self
            }
        }
    }

    /// Keeps the visible counter honest from the DURABLE queue while a pass runs (see statusRefreshTask).
    private func startStatusRefresh() {
        statusRefreshTask?.cancel()
        statusRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.isSyncing, !Task.isCancelled else { return }
                self.status = BackupStatus(progress: self.currentQueueProgress(), isScanning: self.isScanning, isUserPaused: self.isUserPaused)
            }
        }
    }

    // MARK: - Change-driven incremental sync (foreground sessions)

    private func startObservingChanges() {
        monitor.startObserving { [weak self] in
            Task { @MainActor in self?.scheduleChangeDrivenSync() }
        }
    }

    private func scheduleChangeDrivenSync() {
        guard isEnabled, !isSyncing else { return }
        changeDebounceTask?.cancel()
        changeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.isEnabled, !self.isSyncing else { return }
                self.syncNow()
            }
        }
    }

    // MARK: - Status mirror (throttled, phase changes immediate)

    private func applyRunnerProgress(_ snapshot: BackupSyncProgress) {
        // Capture the in-flight name unconditionally (even when the throttle below drops this update)
        // so the periodic DB-truth refresh can keep showing a live "Working on <file>" line.
        if let name = snapshot.currentItemName { lastRunnerItemName = name }
        lastRunnerUploadingName = snapshot.currentUploadingName
        let candidate = BackupStatus(progress: snapshot, isScanning: isScanning, isUserPaused: isUserPaused)
        guard candidate != status else { return }
        let now = Date()
        if candidate.phase == status.phase, snapshot.isRunning, now.timeIntervalSince(lastStatusUpdate) < 0.15 {
            return
        }
        lastStatusUpdate = now
        status = candidate
    }

    private func beginScanPhase() {
        isScanning = true
        status = BackupStatus(progress: currentQueueProgress(), isScanning: true, isUserPaused: isUserPaused)
    }

    private func finishScanPhase() {
        isScanning = false
    }

    private func finishSync(runID: String) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        statusRefreshTask?.cancel()
        statusRefreshTask = nil
        lockStore?.release(runID: runID)
        if activeRunID == runID { activeRunID = nil }
        isSyncing = false
        isScanning = false
        lastRunnerItemName = nil
        lastRunnerUploadingName = nil
        let shouldRestart = pendingSyncAfterStop && isEnabled && accessState.allowsBackup
        pendingSyncAfterStop = false
        refreshFromQueue()
        if shouldRestart { syncNow() } else { scheduleAutoResumeIfOutstanding() }
    }

    /// After a pass ends, if backup is on, not user-paused, and work is still outstanding (typically
    /// items parked in network backoff), schedule ONE delayed re-trigger so the backup continues on
    /// its own. Idempotent (replaces any pending timer); cancelled the moment a pass starts or the
    /// user pauses. This is why the queue never just sits at "Wartet auf Fortsetzung".
    private func scheduleAutoResumeIfOutstanding() {
        autoResumeTask?.cancel(); autoResumeTask = nil
        guard isEnabled, !isUserPaused, accessState.allowsBackup, !isSyncing else { return }
        let p = currentQueueProgress()
        guard p.waiting + p.checking + p.uploading + p.blocked > 0 else { return }   // nothing left → don't loop
        autoResumeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.autoResumeDelay * 1_000_000_000))
            guard let self, !Task.isCancelled, self.isEnabled, !self.isUserPaused, !self.isSyncing else { return }
            self.syncNow()
        }
    }

    private func reportSyncMessage(_ message: String) {
        lastMessage = message
    }

    private func refreshFromQueue() {
        status = BackupStatus(progress: currentQueueProgress(), isScanning: false, isUserPaused: isUserPaused)
    }

    private func currentQueueProgress() -> BackupSyncProgress {
        guard let queueStore else { return BackupSyncProgress() }
        // isRunning reflects whether a pass is actually active, so the periodic status refresh never
        // misreads an active pass (between micro-batches) as ".waiting" ("Wartet auf Fortsetzung").
        // Fold in the runner's last in-flight name (only while a pass runs) so the DB-derived progress
        // still carries a liveness signal; nil when idle so no stale name lingers.
        return BackupSyncProgress(
            summary: queueStore.summary(),
            currentItemName: isSyncing ? lastRunnerItemName : nil,
            currentUploadingName: isSyncing ? lastRunnerUploadingName : nil,
            isRunning: isSyncing
        )
    }

    /// Non-secret debugging hint recorded on the lock (platform + pid); never load-bearing.
    private static var processContext: String {
        let process = ProcessInfo.processInfo
        #if os(macOS)
        let platform = "macos"
        #else
        let platform = "ios"
        #endif
        return "\(platform)/pid-\(process.processIdentifier)"
    }

    private static func processIsAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if pid == Int32(ProcessInfo.processInfo.processIdentifier) { return true }
        #if canImport(Darwin)
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
        #else
        return true
        #endif
    }
}

/// One-shot completion flag shared between the index scan and the concurrent reconcile loop: the scan
/// sets it when it finishes (or gives up) so the reconcile loop knows to make one final drain pass and
/// stop, instead of polling forever.
actor BackupScanSignal {
    private var done = false
    func markDone() { done = true }
    func isDone() -> Bool { done }
}
