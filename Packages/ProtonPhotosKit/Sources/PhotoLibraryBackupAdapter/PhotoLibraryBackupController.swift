import Foundation
import Observation
import PhotosCore
import UploadCore

/// The ONE photo-library backup orchestrator, shared verbatim by iOS, iPadOS, and macOS. It
/// composes the universal core (engine, runner, dedupe pipeline, status model, catalog, execution
/// lock) with the PhotoKit adapter pieces (catalog scan source, resolver, change monitor). Platform
/// apps contribute ONLY: dependency injection, OS scheduling hooks (BGTask on iOS), permission UI,
/// and settings screens.
///
/// Consent contract: backup NEVER starts on its own. `enableBackup()` is the only entry point
/// that requests photo access, and it must be called from an explicit user action.
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
    public private(set) var status = BackupStatus()
    public private(set) var isSyncing = false
    public private(set) var lastMessage: String?
    /// Latest local-catalog scan tally (inventory only, never implies upload). Exposed for debug /
    /// optional status; no UI depends on it, so surfacing it later needs no Core change.
    public private(set) var lastCatalogProgress: PhotoLibraryCatalogProgress?

    /// False when the dedupe manifest or the backup stores could not open - backup then refuses
    /// to run rather than risking duplicate uploads.
    public var isAvailable: Bool { runner != nil }

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
    private var activeRunID: String?
    private var isScanning = false
    private var lastStatusUpdate = Date.distantPast

    public init(
        configuration: Configuration,
        identityResolver: (any UploadIdentityResolving)?,
        uploader: any PhotoUploading
    ) {
        let directory = configuration.accountDataDirectory
        defaults = configuration.defaults
        accessState = PhotoLibraryAuthorization.currentState()
        isEnabled = configuration.defaults.bool(forKey: Self.enabledDefaultsKey)
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
        syncNow()
    }

    public func disableBackup() {
        stopSync()
        isEnabled = false
        defaults.set(false, forKey: Self.enabledDefaultsKey)
    }

    public func refreshAccessState() {
        accessState = PhotoLibraryAuthorization.currentState()
    }

    // MARK: - Sync lifecycle

    /// Foreground/user-initiated pass.
    public func syncNow() {
        startSync(owner: .foreground)
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
        guard isEnabled, accessState.allowsBackup, !isSyncing, let engine, let runner else { return }

        let runID = UUID().uuidString
        if let lockStore {
            // Recovery must precede the drain: clear any owner that stopped heartbeating (crash,
            // OS kill, BG expiration) so a dead run can never permanently block backup.
            lockStore.recoverStaleLocks(olderThan: Date().addingTimeInterval(-Self.lockLease))
            switch lockStore.acquire(owner: owner, runID: runID, phase: "scanning", processContext: Self.processContext) {
            case .acquired:
                break
            case .busy:
                // Another live run owns the queue (e.g. a foreground pass while a BG window fires).
                // Stand down: its own drain covers the work; a second drainer is never allowed.
                return
            case .unavailable:
                // The lock store write failed. The identity manifest still guarantees no double
                // upload, so degrade to unlocked rather than block backup entirely.
                break
            }
        }
        activeRunID = runID

        isSyncing = true
        isScanning = true
        lastMessage = nil
        status = BackupStatus(progress: currentQueueProgress(), isScanning: true)
        startHeartbeat(runID: runID)

        // The task inherits the main actor, but all heavy phases (`scan`, `runUntilDrained`) are
        // awaits onto other actors/off-actor structs - the main thread stays free for UI.
        syncTask = Task { [weak self, monitor, tempStore, engine, runner, catalogStore] in
            // Incremental first: persistent change history tells us exactly which assets moved.
            // A missing/expired token falls back to the full catalog scan, which the persistent
            // catalog keeps cheap by re-checking only new/changed assets.
            let changes = monitor.consumeChanges()
            do {
                try await self?.runScanPass(engine: engine, catalogStore: catalogStore, changes: changes)
            } catch {
                self?.reportSyncMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self?.finishScanPhase()
            _ = await runner.runUntilDrained()
            tempStore.sweep()    // every export is re-derivable; nothing to keep between passes
            self?.finishSync(runID: runID)
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
            if changes.requiresFullRescan {
                _ = try await sync.run(engine: engine, identifiers: nil)
            } else if !changes.changedIdentifiers.isEmpty {
                _ = try await sync.run(engine: engine, identifiers: changes.changedIdentifiers)
            }
            return
        }
        // Catalog unavailable: preserve the pre-catalog behavior so backup still works.
        if changes.requiresFullRescan {
            _ = try await engine.scan(PhotoLibraryBackupCatalog())
        } else if !changes.changedIdentifiers.isEmpty {
            _ = try await engine.scan(PhotoLibraryBackupCatalog(localIdentifiers: changes.changedIdentifiers))
        }
    }

    public func stopSync() {
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
        let candidate = BackupStatus(progress: snapshot, isScanning: isScanning)
        guard candidate != status else { return }
        let now = Date()
        if candidate.phase == status.phase, snapshot.isRunning, now.timeIntervalSince(lastStatusUpdate) < 0.15 {
            return
        }
        lastStatusUpdate = now
        status = candidate
    }

    private func finishScanPhase() {
        isScanning = false
    }

    private func finishSync(runID: String) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        lockStore?.release(runID: runID)
        if activeRunID == runID { activeRunID = nil }
        isSyncing = false
        isScanning = false
        refreshFromQueue()
    }

    private func reportSyncMessage(_ message: String) {
        lastMessage = message
    }

    private func refreshFromQueue() {
        status = BackupStatus(progress: currentQueueProgress(), isScanning: false)
    }

    private func currentQueueProgress() -> BackupSyncProgress {
        guard let queueStore else { return BackupSyncProgress() }
        return BackupSyncProgress(summary: queueStore.summary())
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
}
