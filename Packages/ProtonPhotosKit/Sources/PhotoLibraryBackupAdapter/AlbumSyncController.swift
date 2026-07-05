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
/// Consent contract: nothing scans or syncs on its own. `refreshAlbums()` and `startSync(...)`
/// are called from explicit user actions; the album list requires photo access (full or limited).
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

    /// A same-name Proton album exists and no mapping does - the user must decide. Published for
    /// the platform UI to present as a dialog; resolved via `resolveConflict(useExisting:)`.
    public struct PendingConflict: Sendable, Equatable {
        public let album: LocalAlbumSummary
        public let existing: [AlbumSyncRemoteAlbum]
    }

    public private(set) var accessState: PhotoBackupAccessState
    public private(set) var localAlbums: [LocalAlbumSummary] = []
    public private(set) var mappings: [String: AlbumSyncMapping] = [:]
    public private(set) var progress = AlbumSyncProgress()
    public private(set) var isSyncing = false
    public private(set) var pendingConflict: PendingConflict?
    public private(set) var lastMessage: String?

    /// False when the mapping store or the dedupe manifest could not open - sync then refuses to
    /// run rather than risking duplicate albums or duplicate uploads.
    public var isAvailable: Bool { runner != nil }

    private let runner: AlbumSyncRunner?
    private let backupExecutor: PhotoAlbumBackupExecutor?
    private let localSource = PhotoKitAlbumSource()
    private let mappingStore: AlbumSyncMappingStore?
    private var syncTask: Task<Void, Never>?
    private var lastProgressUpdate = Date.distantPast

    public init(
        configuration: Configuration,
        identityResolver: (any UploadIdentityResolving)?,
        uploader: any PhotoUploading,
        remoteOps: any AlbumSyncRemoteAlbumOps
    ) {
        accessState = PhotoLibraryAuthorization.currentState()

        let directory = configuration.accountDataDirectory
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

        reloadMappings()
        if let runner {
            Task {
                await runner.setOnProgress { snapshot in
                    Task { @MainActor [weak self] in self?.applyProgress(snapshot) }
                }
            }
        }
    }

    // MARK: - Album list (explicit user action; requests photo access)

    public func refreshAlbums() async {
        accessState = await PhotoLibraryAuthorization.request()
        guard accessState.allowsBackup else { return }
        do {
            localAlbums = try await localSource.listAlbums()
        } catch {
            lastMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        reloadMappings()
    }

    public func refreshAccessState() {
        accessState = PhotoLibraryAuthorization.currentState()
    }

    public func mapping(for album: LocalAlbumSummary) -> AlbumSyncMapping? {
        mappings[album.id]
    }

    // MARK: - Sync lifecycle

    /// Starts syncing `album`. When an unmapped same-name Proton album exists, no work starts:
    /// `pendingConflict` is published for the UI dialog instead.
    public func startSync(album: LocalAlbumSummary) {
        startSync(album: album, resolution: .automatic)
    }

    /// The user answered the same-name dialog.
    public func resolveConflict(useExisting remoteAlbumID: String?) {
        guard let conflict = pendingConflict else { return }
        pendingConflict = nil
        if let remoteAlbumID {
            startSync(album: conflict.album, resolution: .attachToExisting(remoteAlbumID: remoteAlbumID))
        }
    }

    public func stopSync() {
        guard let runner else { return }
        Task { await runner.stop() }
    }

    private func startSync(album: LocalAlbumSummary, resolution: AlbumSyncResolution) {
        guard let runner, !isSyncing else { return }
        isSyncing = true
        lastMessage = nil
        pendingConflict = nil

        syncTask = Task { [weak self] in
            do {
                _ = try await runner.sync(album: album, resolution: resolution)
            } catch let error as AlbumSyncError {
                switch error {
                case let .nameConflict(existing):
                    self?.pendingConflict = PendingConflict(album: album, existing: existing)
                default:
                    self?.lastMessage = error.errorDescription
                }
            } catch {
                self?.lastMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            self?.finishSync()
        }
    }

    private func finishSync() {
        isSyncing = false
        reloadMappings()
    }

    private func reloadMappings() {
        guard let mappingStore else { return }
        mappings = Dictionary(
            mappingStore.allMappings().map { ($0.localAlbumID, $0) },
            uniquingKeysWith: { a, _ in a }
        )
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
    }
}
