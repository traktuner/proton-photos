import Foundation
import Observation
import AlbumSyncCore
import PhotosCore
import UploadCore

/// The ONE album-sync orchestrator, shared verbatim by iOS, iPadOS, and macOS. Composes the
/// universal engine (`AlbumSyncRunner`) with the PhotoKit pieces (album source, targeted backup
/// executor) and the injected backend remote ops. Platform apps contribute ONLY dependency
/// injection, permission UI, and settings screens.
///
/// UX model: the user picks albums in a dedicated picker (search + multi-select); Settings shows
/// ONLY that selection. Deselecting removes the album from sync but keeps its Proton mapping, so
/// re-selecting reuses the same remote album. "Sync now" runs the whole selection sequentially.
///
/// Consent contract: nothing scans or syncs on its own. Loading the album list and syncing are
/// called from explicit user actions; the album list requires photo access (full or limited).
@MainActor
@Observable
public final class AlbumSyncController {

    public struct Configuration {
        /// Per-account directory holding the sync stores (sign-out purge covers it wholesale).
        public var accountDataDirectory: URL
        public var databasePolicy: LibraryDatabasePolicy

        public init(accountDataDirectory: URL, databasePolicy: LibraryDatabasePolicy) {
            self.accountDataDirectory = accountDataDirectory
            self.databasePolicy = databasePolicy
        }
    }

    /// One row of the Settings list: a selected album with its live library info (when photo
    /// access allowed reading it this session) and its persisted sync state.
    public struct SelectedAlbum: Identifiable, Sendable, Equatable {
        public enum State: Sendable, Equatable {
            case notSynced
            case synced(Date)
            /// The album vanished from the library (deleted or dropped from a limited selection).
            case missingLocally
            /// A same-name Proton album exists; the user has not answered the dialog yet.
            case needsDecision
        }

        public let id: String
        public var title: String
        /// nil until the library was read this session (needs photo access).
        public var assetCount: Int?
        public var state: State
        /// Photos of the last run that could not be backed up or attached.
        public var needsAttentionCount: Int

        public var hasNeedsAttention: Bool { needsAttentionCount > 0 }

        /// Shared en/de wording (PhotosCore catalog) - platforms never re-invent these states.
        public var localizedStateDescription: String {
            switch state {
            case .notSynced:
                L10n.string("albumsync.state_not_synced")
            case let .synced(date):
                L10n.string("albumsync.state_synced \(date.formatted(.relative(presentation: .named)))")
            case .missingLocally:
                L10n.string("albumsync.state_missing")
            case .needsDecision:
                L10n.string("albumsync.state_needs_decision")
            }
        }

        /// Row-level status with the correct priority. A previous failed photo means this album is
        /// not cleanly synced, even when `lastSyncedAt` is recent.
        public var localizedRowStatusDescription: String {
            hasNeedsAttention
                ? L10n.string("albumsync.detail_needs_attention \(needsAttentionCount)")
                : localizedStateDescription
        }
    }

    /// A same-name Proton album exists and no mapping does - the user must decide. Published for
    /// the platform UI to present as a dialog; resolved via `resolveConflict(useExisting:)`.
    public struct PendingConflict: Sendable, Equatable {
        public let album: LocalAlbumSummary
        public let existing: [AlbumSyncRemoteAlbum]
    }

    public private(set) var accessState: PhotoBackupAccessState
    /// Albums the user selected for sync - the ONLY list Settings shows.
    public private(set) var selectedAlbums: [SelectedAlbum] = []
    /// All local albums, for the picker sheet. Loaded on demand (explicit user action).
    public private(set) var availableAlbums: [LocalAlbumSummary] = []
    public private(set) var isLoadingAlbums = false
    public private(set) var progress = AlbumSyncProgress()
    public private(set) var isSyncing = false
    public private(set) var pendingConflict: PendingConflict?
    public private(set) var lastMessage: String?

    /// False when the mapping store or the dedupe manifest could not open - sync then refuses to
    /// run rather than risking duplicate albums or duplicate uploads.
    public var isAvailable: Bool { runner != nil }

    /// The ids currently in the persisted selection (for pre-checking the picker).
    public var selectedAlbumIDs: Set<String> { Set(selectedAlbums.map(\.id)) }

    private let runner: AlbumSyncRunner?
    private let backupExecutor: PhotoAlbumBackupExecutor?
    private let localSource = PhotoKitAlbumSource()
    private let mappingStore: AlbumSyncMappingStore?
    private let changeMonitor: PhotoLibraryChangeMonitor
    private var syncTask: Task<Void, Never>?
    private var changeDebounceTask: Task<Void, Never>?
    private var queuedAlbumIDs: [String] = []
    /// Unanswered same-name conflicts by album id (one dialog at a time; rows offer "Decide…").
    private var openConflicts: [String: [AlbumSyncRemoteAlbum]] = [:]
    /// True once `availableAlbums` was read this session - only then can "missing locally" be
    /// claimed honestly.
    private var libraryWasRead = false
    private var lastProgressUpdate = Date.distantPast
    private var isObservingChanges = false
    private var changePendingDuringSync = false
    private var remoteAlbumsChangedDuringBatch = false
    private var onRemoteAlbumsChanged: (@MainActor @Sendable () -> Void)?

    public init(
        configuration: Configuration,
        identityResolver: (any UploadIdentityResolving)?,
        uploader: any PhotoUploading,
        remoteOps: any AlbumSyncRemoteAlbumOps
    ) {
        accessState = PhotoLibraryAuthorization.currentState()

        let directory = configuration.accountDataDirectory
        changeMonitor = PhotoLibraryChangeMonitor(tokenURL: directory.appendingPathComponent("album-sync-change-token.v1"))
        let mappingStore = AlbumSyncMappingStore(
            url: directory.appendingPathComponent(AlbumSyncMappingStore.databaseFileName),
            policy: configuration.databasePolicy
        )
        self.mappingStore = mappingStore

        let lookup = UploadManifestRemoteLinkLookup(
            manifestURL: directory.appendingPathComponent(UploadIdentityManifestStore.databaseFileName),
            policy: configuration.databasePolicy
        )

        if let mappingStore, let lookup, let identityResolver {
            let executor = PhotoAlbumBackupExecutor(
                accountDataDirectory: directory,
                databasePolicy: configuration.databasePolicy,
                identityResolver: identityResolver,
                uploader: uploader
            )
            backupExecutor = executor
            runner = AlbumSyncRunner(
                localSource: localSource,
                backup: executor,
                remoteOps: remoteOps,
                linkLookup: lookup,
                mappingStore: mappingStore
            )
        } else {
            backupExecutor = nil
            runner = nil
        }

        reloadSelection()
        startObservingChangesIfNeeded(scheduleCatchUp: true)
        if let runner {
            Task {
                await runner.setOnProgress { snapshot in
                    Task { @MainActor [weak self] in self?.applyProgress(snapshot) }
                }
            }
        }
    }

    /// Platform shells call this once at composition time to refresh their visible Proton album
    /// lists after this shared controller creates or mutates a remote album. The callback is UI
    /// invalidation only; sync correctness never depends on it.
    public func setRemoteAlbumsChangedHandler(_ handler: (@MainActor @Sendable () -> Void)?) {
        onRemoteAlbumsChanged = handler
    }

    // MARK: - Album list (explicit user action; requests photo access)

    /// Loads all local albums for the picker. The FIRST call may present the system photo-access
    /// prompt, so only invoke from an explicit user action (opening the picker).
    public func loadAvailableAlbums() async {
        isLoadingAlbums = true
        defer { isLoadingAlbums = false }
        accessState = await PhotoLibraryAuthorization.request()
        guard accessState.allowsBackup else { return }
        do {
            availableAlbums = try await localSource.listAlbums()
            libraryWasRead = true
        } catch {
            lastMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        reloadSelection()
        startObservingChangesIfNeeded()
    }

    public func refreshAccessState() {
        accessState = PhotoLibraryAuthorization.currentState()
    }

    // MARK: - Selection

    /// Applies the picker result: `ids` becomes the new selection. Removed albums keep their
    /// Proton mapping (re-selecting reuses the same remote album); nothing remote is touched.
    public func applySelection(_ ids: Set<String>) {
        guard let mappingStore else { return }
        let current = selectedAlbumIDs
        let byID = Dictionary(availableAlbums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for added in ids.subtracting(current) {
            guard let album = byID[added] else { continue }
            mappingStore.addSelection(AlbumSyncSelection(localAlbumID: album.id, title: album.title, addedAt: Date()))
        }
        for removed in current.subtracting(ids) {
            mappingStore.removeSelection(localAlbumID: removed)
            openConflicts[removed] = nil
        }
        reloadSelection()
        startObservingChangesIfNeeded()
    }

    /// The row's ✕: stop syncing this album. Keeps the mapping - never touches Proton.
    public func removeFromSelection(_ albumID: String) {
        mappingStore?.removeSelection(localAlbumID: albumID)
        openConflicts[albumID] = nil
        queuedAlbumIDs.removeAll { $0 == albumID }
        if pendingConflict?.album.id == albumID { pendingConflict = nil }
        reloadSelection()
    }

    // MARK: - Sync lifecycle

    /// Syncs every selected album, sequentially. Albums missing from the library are skipped
    /// honestly (their row says so); same-name conflicts pause only the affected album.
    public func syncSelected() {
        startObservingChangesIfNeeded()
        let ids = selectedAlbums
            .filter { $0.state != .missingLocally }
            .map(\.id)
        enqueue(ids)
    }

    /// Re-sync one album from its row.
    public func syncNow(albumID: String) {
        startObservingChangesIfNeeded()
        enqueue([albumID])
    }

    /// The user answered the same-name dialog. "Use existing" persists the mapping (that IS the
    /// decision) and queues the album; cancel leaves it selected but unsynced.
    public func resolveConflict(useExisting remoteAlbumID: String?) {
        guard let conflict = pendingConflict else { return }
        pendingConflict = nil
        openConflicts[conflict.album.id] = nil
        if let remoteAlbumID, let mappingStore {
            mappingStore.upsert(AlbumSyncMapping(
                localAlbumID: conflict.album.id,
                remoteAlbumID: remoteAlbumID,
                title: conflict.album.title,
                createdAt: Date()
            ))
            enqueue([conflict.album.id])
        }
        reloadSelection()
    }

    /// Re-opens the dialog for a row whose conflict was dismissed earlier.
    public func presentConflict(albumID: String) {
        guard let existing = openConflicts[albumID],
              let album = selectedAlbums.first(where: { $0.id == albumID }) else { return }
        pendingConflict = PendingConflict(
            album: LocalAlbumSummary(id: album.id, title: album.title, assetCount: album.assetCount ?? 0),
            existing: existing
        )
    }

    public func stopSync() {
        queuedAlbumIDs.removeAll()
        changeDebounceTask?.cancel()
        changeDebounceTask = nil
        changePendingDuringSync = false
        guard let runner else { return }
        Task { await runner.stop() }
    }

    // MARK: - Batch engine

    private func enqueue(_ ids: [String]) {
        guard runner != nil, !ids.isEmpty else { return }
        for id in ids where !queuedAlbumIDs.contains(id) {
            queuedAlbumIDs.append(id)
        }
        startBatchIfIdle()
    }

    private func startBatchIfIdle() {
        guard let runner, !isSyncing, !queuedAlbumIDs.isEmpty else { return }
        isSyncing = true
        remoteAlbumsChangedDuringBatch = false
        lastMessage = nil

        syncTask = Task { [weak self] in
            while let album = self?.dequeueNextAlbum() {
                do {
                    _ = try await runner.sync(album: album, resolution: .automatic)
                    self?.remoteAlbumsChangedDuringBatch = true
                } catch let error as AlbumSyncError {
                    switch error {
                    case let .nameConflict(existing):
                        self?.recordConflict(album: album, existing: existing)
                    case .stopped:
                        self?.queuedAlbumIDs.removeAll()
                    default:
                        self?.lastMessage = error.errorDescription
                    }
                } catch {
                    self?.lastMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }
            self?.finishSync()
        }
    }

    private func dequeueNextAlbum() -> LocalAlbumSummary? {
        while !queuedAlbumIDs.isEmpty {
            let id = queuedAlbumIDs.removeFirst()
            guard let row = selectedAlbums.first(where: { $0.id == id }) else { continue }
            if libraryWasRead, row.state == .missingLocally { continue }
            return LocalAlbumSummary(id: row.id, title: row.title, assetCount: row.assetCount ?? 0)
        }
        return nil
    }

    private func recordConflict(album: LocalAlbumSummary, existing: [AlbumSyncRemoteAlbum]) {
        openConflicts[album.id] = existing
        if pendingConflict == nil {
            pendingConflict = PendingConflict(album: album, existing: existing)
        }
        reloadSelection()
    }

    private func finishSync() {
        isSyncing = false
        reloadSelection()
        if remoteAlbumsChangedDuringBatch {
            remoteAlbumsChangedDuringBatch = false
            onRemoteAlbumsChanged?()
        }
        if changePendingDuringSync {
            changePendingDuringSync = false
            scheduleChangeDrivenSync()
        }
    }

    // MARK: - Change-driven sync for selected albums

    private func startObservingChangesIfNeeded(scheduleCatchUp: Bool = false) {
        guard accessState.allowsBackup, !selectedAlbums.isEmpty else { return }
        if !isObservingChanges {
            isObservingChanges = true
            changeMonitor.startObserving { [weak self] in
                Task { @MainActor in self?.scheduleChangeDrivenSync() }
            }
        }
        if scheduleCatchUp {
            scheduleChangeDrivenSync()
        }
    }

    private func scheduleChangeDrivenSync() {
        guard accessState.allowsBackup, !selectedAlbums.isEmpty else { return }
        if isSyncing {
            changePendingDuringSync = true
            return
        }
        changeDebounceTask?.cancel()
        changeDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.refreshLocalAlbumsForAutomaticSync()
            await MainActor.run { [weak self] in
                guard let self, self.accessState.allowsBackup, !self.selectedAlbums.isEmpty, !self.isSyncing else { return }
                self.syncSelected()
            }
        }
    }

    private func refreshLocalAlbumsForAutomaticSync() async {
        guard accessState.allowsBackup else { return }
        do {
            availableAlbums = try await localSource.listAlbums()
            libraryWasRead = true
            reloadSelection()
        } catch {
            lastMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    // MARK: - Row derivation

    private func reloadSelection() {
        guard let mappingStore else {
            selectedAlbums = []
            return
        }
        let mappings = Dictionary(
            mappingStore.allMappings().map { ($0.localAlbumID, $0) },
            uniquingKeysWith: { a, _ in a }
        )
        let live = Dictionary(availableAlbums.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        selectedAlbums = mappingStore.selections().map { selection in
            let liveAlbum = live[selection.localAlbumID]
            let mapping = mappings[selection.localAlbumID]
            let state: SelectedAlbum.State
            if openConflicts[selection.localAlbumID] != nil {
                state = .needsDecision
            } else if libraryWasRead, liveAlbum == nil {
                state = .missingLocally
            } else if let synced = mapping?.lastSyncedAt {
                state = .synced(synced)
            } else {
                state = .notSynced
            }
            return SelectedAlbum(
                id: selection.localAlbumID,
                title: liveAlbum?.title ?? selection.title,
                assetCount: liveAlbum?.assetCount,
                state: state,
                needsAttentionCount: mapping?.lastFailedCount ?? 0
            )
        }
    }

    // MARK: - Progress mirror (throttled, phase changes immediate)

    private func applyProgress(_ snapshot: AlbumSyncProgress) {
        guard snapshot != progress else { return }
        let now = Date()
        if snapshot.phase == progress.phase, now.timeIntervalSince(lastProgressUpdate) < 0.15 {
            return
        }
        lastProgressUpdate = now
        progress = snapshot
        if snapshot.phase == .completed || snapshot.phase == .needsAttention {
            reloadSelection()
        }
    }
}
