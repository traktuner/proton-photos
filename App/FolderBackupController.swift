import Foundation
import Observation
import PhotosCore
import ProtonDriveBackend
import UploadCore

/// One folder the user chose to keep backed up, persisted as a security-scoped bookmark so the
/// sandboxed app can reach it across launches.
struct BackupFolder: Identifiable, Equatable {
    let id: UUID
    var bookmark: Data
    var displayPath: String
    /// True when the bookmark no longer resolves cleanly - the user must re-pick the folder.
    var needsRenewal: Bool
}

/// macOS composition of the UNIVERSAL backup sync stack: folder registry (bookmarks - the only
/// platform-specific concern here), the shared engine/runner from UploadCore, and a main-actor
/// progress mirror for the Settings UI. All sync semantics live in core; this type only owns
/// folder access and lifecycle.
@MainActor
@Observable
final class FolderBackupController {

    private(set) var folders: [BackupFolder] = []
    /// The ONE user-facing state surface (shared Core model - same phases/wording on every
    /// platform). UI reads only this; raw runner progress stays internal.
    private(set) var status = BackupStatus()
    private(set) var isSyncing = false
    private(set) var lastMessage: String?

    /// False when the account's dedupe manifest or sync stores could not open - backup is then
    /// disabled entirely instead of running without duplicate protection.
    var isAvailable: Bool { runner != nil }

    private let engine: UploadBackupSyncEngine?
    private let runner: BackupSyncRunner?
    private let queueStore: UploadBackupSyncQueueManifestStore?
    private let stateStore: UploadBackupStateManifestStore?
    private var syncTask: Task<Void, Never>?
    private var isScanning = false
    private var lastStatusUpdate = Date.distantPast

    private static let foldersDefaultsKey = "backup.folderBookmarks.v1"

    init(facade: ProtonClientFacade) {
        let directory = facade.accountDataDirectory
        let policy = facade.accountDatabasePolicy
        let queueStore = UploadBackupSyncQueueManifestStore(
            url: directory.appendingPathComponent(UploadBackupSyncQueueManifestStore.databaseFileName),
            policy: policy
        )
        let stateStore = UploadBackupStateManifestStore(
            url: directory.appendingPathComponent(UploadBackupStateManifestStore.databaseFileName),
            policy: policy
        )
        self.queueStore = queueStore
        self.stateStore = stateStore

        // Backup REQUIRES the shared dedupe pipeline: without it every sync pass would re-upload.
        if let queueStore, let stateStore, let identityResolver = facade.uploadIdentityResolver {
            let preflight = UploadBackupPreflightIndex(store: stateStore)
            engine = UploadBackupSyncEngine(
                preflight: preflight,
                queue: queueStore,
                remoteProofResolver: identityResolver
            )
            runner = BackupSyncRunner(
                queue: queueStore,
                preflight: preflight,
                resolver: FileBackupResourceResolver(),
                identityResolver: identityResolver,
                uploader: facade.photoUploader,
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

        loadFolders()
        refreshFromQueue()
        if let runner {
            Task {
                await runner.setOnProgress { snapshot in
                    Task { @MainActor [weak self] in self?.applyRunnerProgress(snapshot) }
                }
            }
        }
    }

    /// Coalesces per-transition runner emissions to a calm UI cadence: phase changes and settle
    /// points render immediately, count ticks are throttled. Dropping intermediate ticks is safe -
    /// the run's final emission always changes the phase and is therefore always applied.
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

    // MARK: - Folder registry (bookmarks are the App-side boundary)

    func addFolder(_ url: URL) {
        do {
            let bookmark = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            let folder = BackupFolder(id: UUID(), bookmark: bookmark, displayPath: url.path, needsRenewal: false)
            folders.removeAll { $0.displayPath == folder.displayPath }
            folders.append(folder)
            folders.sort { $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending }
            persistFolders()
        } catch {
            lastMessage = error.localizedDescription
        }
    }

    func removeFolder(_ id: BackupFolder.ID) {
        folders.removeAll { $0.id == id }
        persistFolders()
    }

    private func loadFolders() {
        guard let raw = UserDefaults.standard.array(forKey: Self.foldersDefaultsKey) as? [Data] else { return }
        folders = raw.compactMap { bookmark in
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else {
                return BackupFolder(id: UUID(), bookmark: bookmark, displayPath: "?", needsRenewal: true)
            }
            return BackupFolder(id: UUID(), bookmark: bookmark, displayPath: url.path, needsRenewal: stale)
        }
        .sorted { $0.displayPath.localizedCaseInsensitiveCompare($1.displayPath) == .orderedAscending }
    }

    private func persistFolders() {
        UserDefaults.standard.set(folders.map(\.bookmark), forKey: Self.foldersDefaultsKey)
    }

    // MARK: - Sync lifecycle

    func syncNow() {
        guard !isSyncing, let engine, let runner else { return }
        isSyncing = true
        isScanning = true
        lastMessage = nil
        status = BackupStatus(progress: currentQueueProgress(), isScanning: true)
        let snapshotFolders = folders
        syncTask = Task { [weak self] in
            var accessedURLs: [URL] = []
            defer {
                for url in accessedURLs { url.stopAccessingSecurityScopedResource() }
            }

            // Scan every reachable folder first (cheap, no bytes), then drain the shared queue.
            for folder in snapshotFolders {
                var stale = false
                guard let url = try? URL(
                    resolvingBookmarkData: folder.bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                ), !stale, url.startAccessingSecurityScopedResource() else {
                    await self?.markFolderNeedsRenewal(folder.id)
                    continue
                }
                accessedURLs.append(url)
                do {
                    _ = try await engine.scan(FolderBackupCatalog(folder: url))
                } catch {
                    await self?.reportSyncMessage(error.localizedDescription)
                }
            }

            await self?.finishScanPhase()
            _ = await runner.runUntilDrained()
            await self?.finishSync()
        }
    }

    func stopSync() {
        guard let runner else { return }
        Task { await runner.stop() }
    }

    private func markFolderNeedsRenewal(_ id: BackupFolder.ID) {
        if let index = folders.firstIndex(where: { $0.id == id }) {
            folders[index].needsRenewal = true
        }
    }

    private func reportSyncMessage(_ message: String) {
        lastMessage = message
    }

    private func finishScanPhase() {
        isScanning = false
    }

    private func finishSync() {
        isSyncing = false
        isScanning = false
        refreshFromQueue()
    }

    /// Seeds the UI snapshot from the durable queue - shows outstanding work from a previous
    /// launch before any sync pass runs (relaunch-resume visibility).
    private func refreshFromQueue() {
        status = BackupStatus(progress: currentQueueProgress(), isScanning: false)
    }

    private func currentQueueProgress() -> BackupSyncProgress {
        guard let queueStore else { return BackupSyncProgress() }
        return BackupSyncProgress(summary: queueStore.summary())
    }
}
