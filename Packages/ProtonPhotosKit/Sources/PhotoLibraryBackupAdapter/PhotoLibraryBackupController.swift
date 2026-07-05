import Foundation
import Observation
import PhotosCore
import UploadCore

/// The ONE photo-library backup orchestrator, shared verbatim by iOS, iPadOS, and macOS. It
/// composes the universal core (engine, runner, dedupe pipeline, status model) with the PhotoKit
/// adapter pieces (catalog, resolver, change monitor). Platform apps contribute ONLY: dependency
/// injection, OS scheduling hooks (BGTask on iOS), permission UI, and settings screens.
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

    public private(set) var accessState: PhotoBackupAccessState
    public private(set) var isEnabled: Bool
    public private(set) var status = BackupStatus()
    public private(set) var isSyncing = false
    public private(set) var lastMessage: String?

    /// False when the dedupe manifest or the backup stores could not open - backup then refuses
    /// to run rather than risking duplicate uploads.
    public var isAvailable: Bool { runner != nil }

    private let engine: UploadBackupSyncEngine?
    private let runner: BackupSyncRunner?
    private let queueStore: UploadBackupSyncQueueManifestStore?
    private let stateStore: UploadBackupStateManifestStore?
    private let tempStore: BackupTempFileStore
    private let monitor: PhotoLibraryChangeMonitor
    private let defaults: UserDefaults
    private var syncTask: Task<Void, Never>?
    private var changeDebounceTask: Task<Void, Never>?
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

    public func syncNow() {
        guard isEnabled, accessState.allowsBackup, !isSyncing, let engine, let runner else { return }
        isSyncing = true
        isScanning = true
        lastMessage = nil
        status = BackupStatus(progress: currentQueueProgress(), isScanning: true)

        // The task inherits the main actor, but all heavy phases (`scan`, `runUntilDrained`) are
        // awaits onto other actors/detached work - the main thread stays free for UI.
        syncTask = Task { [weak self, monitor, tempStore] in
            // Incremental first: persistent change history tells us exactly which assets moved.
            // A missing/expired token falls back to the full cheap scan, which preflight keeps
            // read-mostly (known revisions classify without touching any resource bytes).
            let changes = monitor.consumeChanges()
            do {
                if changes.requiresFullRescan {
                    _ = try await engine.scan(PhotoLibraryBackupCatalog())
                } else if !changes.changedIdentifiers.isEmpty {
                    _ = try await engine.scan(PhotoLibraryBackupCatalog(localIdentifiers: changes.changedIdentifiers))
                }
            } catch {
                self?.reportSyncMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
            }
            self?.finishScanPhase()
            _ = await runner.runUntilDrained()
            tempStore.sweep()    // every export is re-derivable; nothing to keep between passes
            self?.finishSync()
        }
    }

    public func stopSync() {
        guard let runner else { return }
        Task { await runner.stop() }
    }

    /// One full catch-up pass for OS background windows (BGProcessingTask on iOS). Returns when
    /// the pass drains or is stopped by the expiration handler via `stopSync()` - every state
    /// transition is already checkpointed, so expiration simply resumes next time.
    public func backgroundCatchUp() async {
        syncNow()
        await syncTask?.value
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

    private func finishSync() {
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
}
