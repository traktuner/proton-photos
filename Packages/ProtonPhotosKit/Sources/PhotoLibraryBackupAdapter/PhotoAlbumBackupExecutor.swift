import Foundation
import AlbumSyncCore
import PhotosCore
import UploadCore

/// `AlbumSyncBackupExecuting` over the standard backup pipeline, restricted to an explicit asset
/// list. Uses the SAME identity resolver (dedupe manifest + duplicate service) as full photo
/// backup and manual uploads - one duplicate authority, so album sync can never re-upload bytes
/// that any other path already settled.
///
/// The queue/state stores are album-sync-private, per-RUN scratch: they are reset at the start of
/// each run so counts are scoped to the current album. Durability does not depend on them - the
/// identity manifest is written BEFORE any queue row turns terminal (BackupSyncRunner contract),
/// so a crash mid-run simply re-resolves everything as already-backed-up on the next run.
public final class PhotoAlbumBackupExecutor: AlbumSyncBackupExecuting, @unchecked Sendable {

    static let queueDatabaseFileName = "album-sync-backup-queue-v1.sqlite"
    static let stateDatabaseFileName = "album-sync-backup-state-v1.sqlite"

    private let accountDataDirectory: URL
    private let databasePolicy: LibraryDatabasePolicy
    private let identityResolver: any UploadIdentityResolving
    private let uploader: any PhotoUploading

    private let lock = NSLock()
    private var activeRunner: BackupSyncRunner?

    public init(
        accountDataDirectory: URL,
        databasePolicy: LibraryDatabasePolicy,
        identityResolver: any UploadIdentityResolving,
        uploader: any PhotoUploading
    ) {
        self.accountDataDirectory = accountDataDirectory
        self.databasePolicy = databasePolicy
        self.identityResolver = identityResolver
        self.uploader = uploader
    }

    public func ensureBackedUp(
        localIdentifiers: [String],
        onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport {
        guard !localIdentifiers.isEmpty else { return AlbumSyncBackupReport() }

        // Per-run scratch stores (see type comment). Reset is safe: AlbumSyncRunner serializes runs.
        for name in [Self.queueDatabaseFileName, Self.stateDatabaseFileName] {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(
                    at: accountDataDirectory.appendingPathComponent(name + suffix)
                )
            }
        }
        guard
            let queueStore = UploadBackupSyncQueueManifestStore(
                url: accountDataDirectory.appendingPathComponent(Self.queueDatabaseFileName),
                policy: databasePolicy
            ),
            let stateStore = UploadBackupStateManifestStore(
                url: accountDataDirectory.appendingPathComponent(Self.stateDatabaseFileName),
                policy: databasePolicy
            )
        else {
            throw AlbumSyncError.mappingStoreUnavailable
        }
        defer {
            queueStore.close()
            stateStore.close()
        }

        let tempStore = BackupTempFileStore(
            directory: accountDataDirectory.appendingPathComponent("album-sync-temp", isDirectory: true)
        )
        let preflight = UploadBackupPreflightIndex(store: stateStore)
        let engine = UploadBackupSyncEngine(
            preflight: preflight,
            queue: queueStore,
            remoteProofResolver: identityResolver
        )
        let runner = BackupSyncRunner(
            queue: queueStore,
            preflight: preflight,
            resolver: PhotoLibraryResourceResolver(tempStore: tempStore),
            identityResolver: identityResolver,
            uploader: uploader,
            throttleInputs: { AppleBackupRuntimeSignals.current() }
        )
        lock.withLock { activeRunner = runner }
        defer { lock.withLock { activeRunner = nil } }

        await runner.setOnProgress { snapshot in onProgress(snapshot) }
        _ = try await engine.scan(PhotoLibraryBackupCatalog(localIdentifiers: localIdentifiers))
        _ = await runner.runUntilDrained()
        guard await runner.isQueueOperational(), queueStore.isOperational() else {
            throw AlbumSyncError.mappingStoreUnavailable
        }
        tempStore.sweep()

        let summary = queueStore.summary()
        guard queueStore.isOperational() else {
            throw AlbumSyncError.mappingStoreUnavailable
        }
        return AlbumSyncBackupReport(
            total: summary.total,
            backedUp: summary.resolved,
            failed: summary.failed,
            sourceMissing: summary.sourceMissing,
            skippedRemoteDeletion: summary.skippedRemoteDeletions
        )
    }

    public func stop() async {
        let runner = lock.withLock { activeRunner }
        await runner?.stop()
    }
}
