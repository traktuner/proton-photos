import Foundation
import UploadCore

/// How the sync run binds a local album to a Proton album.
public enum AlbumSyncResolution: Sendable, Equatable {
    /// Stored mapping if present; otherwise create a new Proton album - UNLESS a remote album
    /// already carries the same name, in which case `AlbumSyncError.nameConflict` is thrown so the
    /// UI can ask the user (we never attach by name match on our own).
    case automatic
    /// The user explicitly chose an existing Proton album (from the conflict dialog).
    case attachToExisting(remoteAlbumID: String)
    /// The user explicitly asked for a new album even though a name twin exists. The server may
    /// still reject the duplicate name - that error surfaces honestly.
    case createNew
}

/// Universal local-album → Proton-album sync engine. Platform-neutral: local albums come from an
/// injected source (PhotoKit adapter on Apple platforms), backup goes through the injected
/// executor (the standard upload/dedupe pipeline - media bytes are NEVER uploaded twice), and
/// remote album operations go through the injected backend ops.
///
/// v1 is strictly additive (`AlbumSyncMode.additive`): nothing is removed from Proton, ever.
///
/// Durability: the local↔remote album mapping is persisted BEFORE any backup/attach work, so a
/// crash mid-run can never cause a second album to be created for the same local album. Attach
/// work is re-derived per run from the manifest + the album's current children (idempotent -
/// "already a member" converges), so no separate pending-operation log is needed.
public actor AlbumSyncRunner {
    private let localSource: any AlbumSyncLocalAlbumSource
    private let backup: any AlbumSyncBackupExecuting
    private let remoteOps: any AlbumSyncRemoteAlbumOps
    private let linkLookup: any AlbumSyncRemoteLinkLookup
    private let mappingStore: AlbumSyncMappingStore?
    private let now: @Sendable () -> Date

    /// Photos per `attach` call - a progress-granularity choice (the backend further batches to
    /// the API's own limit internally).
    private let attachChunkSize: Int

    private var onProgress: (@Sendable (AlbumSyncProgress) -> Void)?
    private var progress = AlbumSyncProgress()
    private var isRunning = false
    private var stopRequested = false

    public init(
        localSource: any AlbumSyncLocalAlbumSource,
        backup: any AlbumSyncBackupExecuting,
        remoteOps: any AlbumSyncRemoteAlbumOps,
        linkLookup: any AlbumSyncRemoteLinkLookup,
        mappingStore: AlbumSyncMappingStore?,
        attachChunkSize: Int = 50,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.localSource = localSource
        self.backup = backup
        self.remoteOps = remoteOps
        self.linkLookup = linkLookup
        self.mappingStore = mappingStore
        self.attachChunkSize = max(1, attachChunkSize)
        self.now = now
    }

    // MARK: - Observation

    public func setOnProgress(_ callback: @Sendable @escaping (AlbumSyncProgress) -> Void) {
        onProgress = callback
    }

    public var currentProgress: AlbumSyncProgress { progress }

    // MARK: - Precheck (for the UI's conflict dialog)

    public enum Precheck: Sendable, Equatable {
        /// A stored mapping exists - sync continues into that album, no questions.
        case mapped(remoteAlbumID: String)
        /// No mapping, and remote albums with the exact same (trimmed) name exist.
        case nameConflict([AlbumSyncRemoteAlbum])
        /// No mapping, no name twin - `automatic` will create a fresh album.
        case clear
    }

    /// What starting a sync for `album` would do. UI calls this to decide whether to show the
    /// "use existing Proton album?" dialog before `sync`.
    public func precheck(album: LocalAlbumSummary) async throws -> Precheck {
        guard let mappingStore else { throw AlbumSyncError.mappingStoreUnavailable }
        if let mapping = mappingStore.mapping(localAlbumID: album.id) {
            return .mapped(remoteAlbumID: mapping.remoteAlbumID)
        }
        let twins = try await nameTwins(of: album.title)
        return twins.isEmpty ? .clear : .nameConflict(twins)
    }

    // MARK: - Sync

    /// Runs one full additive sync of `album`. Throws `AlbumSyncError.nameConflict` when
    /// `resolution == .automatic` and an unmapped name twin exists.
    @discardableResult
    public func sync(album: LocalAlbumSummary, resolution: AlbumSyncResolution = .automatic) async throws -> AlbumSyncReport {
        guard !isRunning else { throw AlbumSyncError.alreadyRunning }
        guard let mappingStore else { throw AlbumSyncError.mappingStoreUnavailable }
        isRunning = true
        stopRequested = false
        defer { isRunning = false }

        do {
            let report = try await run(album: album, resolution: resolution, mappingStore: mappingStore)
            return report
        } catch {
            if progress.phase != .needsAttention {
                progress.phase = .needsAttention
                progress.message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                publish()
            }
            throw error
        }
    }

    /// Requests a stop. The current attach chunk finishes; backup checkpoints and stops. Work
    /// already done is durable server-side, so the next run resumes/converges.
    public func stop() async {
        stopRequested = true
        await backup.stop()
    }

    // MARK: - Phases

    private func run(
        album: LocalAlbumSummary,
        resolution: AlbumSyncResolution,
        mappingStore: AlbumSyncMappingStore
    ) async throws -> AlbumSyncReport {
        progress = AlbumSyncProgress()
        progress.localAlbumID = album.id
        progress.albumTitle = album.title
        progress.phase = .scanningLocal
        publish()

        // 1. Local album contents (identifiers only - no asset bytes).
        let identifiers = try await localSource.assetIdentifiers(albumID: album.id)
        progress.totalAssets = identifiers.count
        publish()
        try checkStop()

        // 2. Resolve the Proton album FIRST and persist the mapping - fail fast on conflicts,
        //    and make a crash mid-run unable to create a second album later.
        let remoteAlbumID = try await resolveRemoteAlbum(album: album, resolution: resolution, mappingStore: mappingStore)
        try checkStop()

        // 3. Ensure every album asset is backed up via the standard pipeline (dedupe manifest is
        //    the single duplicate authority - already-backed-up assets cost one preflight lookup).
        progress.phase = .backingUp
        publish()
        let updateBackupProgress: @Sendable (BackupSyncProgress) -> Void = { [weak self] snapshot in
            Task { await self?.applyBackupProgress(snapshot) }
        }
        _ = try await backup.ensureBackedUp(localIdentifiers: identifiers, onProgress: updateBackupProgress)
        try checkStop()

        // 4. Current album members + manifest links → attach plan (pure, idempotent).
        progress.phase = .checkingAlbum
        publish()
        let links = await linkLookup.remoteLinks(for: identifiers)
        let children = try await remoteOps.childMainLinkIDs(albumID: remoteAlbumID)
        let plan = AlbumSyncPlanner.plan(
            orderedLocalIdentifiers: identifiers,
            remoteLinks: links,
            existingChildLinkIDs: children
        )
        progress.alreadyMember = plan.alreadyMember
        progress.unattachable = plan.missingRemote
        progress.trashedSkipped = plan.trashedRemote
        progress.attachTotal = plan.toAttach.count
        publish()
        try checkStop()

        // 5. Attach in chunks (progress + stop granularity; the backend batches to the API limit).
        progress.phase = .attaching
        publish()
        var attachResult = AlbumSyncAttachResult()
        var index = 0
        while index < plan.toAttach.count {
            try checkStop()
            let chunk = Array(plan.toAttach[index ..< min(index + attachChunkSize, plan.toAttach.count)])
            let result = try await remoteOps.attach(chunk, albumID: remoteAlbumID)
            attachResult += result
            index += chunk.count
            progress.attachDone = attachResult.attached
            progress.alreadyMember = plan.alreadyMember + attachResult.alreadyMember
            progress.attachFailed = attachResult.failed
            progress.message = attachResult.firstFailureMessage
            publish()
        }

        // 6. Persist the run outcome on the mapping and settle the status.
        let report = AlbumSyncReport(
            remoteAlbumID: remoteAlbumID,
            totalAssets: identifiers.count,
            attached: attachResult.attached,
            alreadyMember: plan.alreadyMember + attachResult.alreadyMember,
            attachFailed: attachResult.failed,
            unattachable: plan.missingRemote,
            trashedSkipped: plan.trashedRemote
        )
        var mapping = mappingStore.mapping(localAlbumID: album.id)
            ?? AlbumSyncMapping(localAlbumID: album.id, remoteAlbumID: remoteAlbumID, title: album.title, createdAt: now())
        mapping.title = album.title
        mapping.lastSyncedAt = now()
        mapping.lastAttachedCount = report.attached
        mapping.lastFailedCount = report.attachFailed + report.unattachable
        mappingStore.upsert(mapping)

        progress.phase = report.isFullySynced ? .completed : .needsAttention
        if !report.isFullySynced, progress.message == nil {
            progress.message = attachResult.firstFailureMessage
        }
        publish()
        return report
    }

    private func resolveRemoteAlbum(
        album: LocalAlbumSummary,
        resolution: AlbumSyncResolution,
        mappingStore: AlbumSyncMappingStore
    ) async throws -> String {
        if let mapping = mappingStore.mapping(localAlbumID: album.id) {
            return mapping.remoteAlbumID
        }
        let remoteAlbumID: String
        switch resolution {
        case .automatic:
            let twins = try await nameTwins(of: album.title)
            guard twins.isEmpty else { throw AlbumSyncError.nameConflict(existing: twins) }
            remoteAlbumID = try await remoteOps.createAlbum(name: album.title)
        case let .attachToExisting(existingID):
            remoteAlbumID = existingID
        case .createNew:
            remoteAlbumID = try await remoteOps.createAlbum(name: album.title)
        }
        mappingStore.upsert(AlbumSyncMapping(
            localAlbumID: album.id,
            remoteAlbumID: remoteAlbumID,
            title: album.title,
            createdAt: now()
        ))
        return remoteAlbumID
    }

    private func nameTwins(of title: String) async throws -> [AlbumSyncRemoteAlbum] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let remote = try await remoteOps.listAlbums()
        return remote.filter { $0.title.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed }
    }

    // MARK: - Helpers

    private func applyBackupProgress(_ snapshot: BackupSyncProgress) {
        guard progress.phase == .backingUp else { return }
        progress.backedUp = snapshot.backedUp
        progress.backupFailed = snapshot.failed
        publish()
    }

    private func checkStop() throws {
        if stopRequested { throw AlbumSyncError.stopped }
        if Task.isCancelled { throw AlbumSyncError.stopped }
    }

    private func publish() {
        onProgress?(progress)
    }
}
