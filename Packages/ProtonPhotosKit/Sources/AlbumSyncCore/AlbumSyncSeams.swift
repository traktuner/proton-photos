import Foundation
import PhotosCore
import UploadCore

/// The platform adapter's view of local albums (PhotoKit on Apple platforms). Permission handling
/// stays in the platform layer: these calls are made only after access is granted.
public protocol AlbumSyncLocalAlbumSource: Sendable {
    /// User-created albums, in the platform's display order.
    func listAlbums() async throws -> [LocalAlbumSummary]
    /// Asset identifiers of one album, in the album's stable display order. May be large;
    /// implementations must enumerate chunked and never load asset bytes.
    func assetIdentifiers(albumID: String) async throws -> [String]
}

/// Outcome of the "make sure these local assets are backed up" step, aggregated from the backup
/// queue's terminal states.
public struct AlbumSyncBackupReport: Sendable, Equatable {
    public var total = 0
    /// Uploaded now or verified already backed up.
    public var backedUp = 0
    public var failed = 0
    /// Local asset vanished (deleted / dropped from a limited selection) - honest non-success.
    public var sourceMissing = 0
    /// The only remote copy is intentionally deleted/trashed - backup respects that, so does sync.
    public var skippedRemoteDeletion = 0

    public init() {}

    public init(total: Int, backedUp: Int, failed: Int, sourceMissing: Int, skippedRemoteDeletion: Int) {
        self.total = total
        self.backedUp = backedUp
        self.failed = failed
        self.sourceMissing = sourceMissing
        self.skippedRemoteDeletion = skippedRemoteDeletion
    }
}

/// Runs the standard backup pipeline (scan → dedupe preflight → upload) restricted to the given
/// local assets. Implemented over the SAME engine/runner/manifest as full photo backup, so skip
/// decisions can never drift between features. Must be cancellable via `stop()`.
public protocol AlbumSyncBackupExecuting: Sendable {
    func ensureBackedUp(
        localIdentifiers: [String],
        onProgress: @Sendable @escaping (BackupSyncProgress) -> Void
    ) async throws -> AlbumSyncBackupReport
    func stop() async
}

/// Remote (Proton) album operations the sync engine needs. Implemented by the backend package;
/// swappable for a future official SDK adapter without touching this module.
public protocol AlbumSyncRemoteAlbumOps: Sendable {
    /// The user's Proton albums with decrypted titles (for the same-name conflict pre-check).
    func listAlbums() async throws -> [AlbumSyncRemoteAlbum]
    /// Creates an album and returns its id. Must throw on failure - never a fake id.
    func createAlbum(name: String) async throws -> String
    /// Link ids of the album's current main photos (Live Photo motion parts stay nested).
    func childMainLinkIDs(albumID: String) async throws -> Set<String>
    /// Attaches existing remote photos (no media re-upload). Per-item failures are aggregated,
    /// never masked; "already a member" is reported as convergence.
    func attach(_ photos: [AlbumSyncAttachCandidate], albumID: String) async throws -> AlbumSyncAttachResult
}

/// Maps local asset identifiers to their remote counterparts via the upload identity manifest.
public protocol AlbumSyncRemoteLinkLookup: Sendable {
    func remoteLinks(for localIdentifiers: [String]) async -> [String: AlbumSyncRemoteLink]
}

/// `AlbumSyncRemoteLinkLookup` over the shared `upload-manifest-v1.sqlite` (read-only role; the
/// dedupe pipeline owns writes). Opening a second WAL connection is safe and keeps this module
/// free of any backend dependency.
public struct UploadManifestRemoteLinkLookup: AlbumSyncRemoteLinkLookup {
    private let store: UploadIdentityManifestStore

    public init?(manifestURL: URL, policy: LibraryDatabasePolicy) {
        guard let store = UploadIdentityManifestStore(url: manifestURL, policy: policy) else { return nil }
        self.store = store
    }

    public func remoteLinks(for localIdentifiers: [String]) async -> [String: AlbumSyncRemoteLink] {
        var result: [String: AlbumSyncRemoteLink] = [:]
        result.reserveCapacity(localIdentifiers.count)
        for identifier in localIdentifiers {
            let source = UploadSourceIdentity(kind: .photoLibraryAsset, identifier: identifier, resource: .primary)
            guard let record = store.record(for: source),
                  let linkID = record.remoteLinkID, !linkID.isEmpty,
                  let outcome = record.outcome.flatMap(UploadIdentityManifestStore.Outcome.init(rawValue:)) else {
                continue
            }
            switch outcome {
            case .uploaded, .duplicateActive:
                result[identifier] = AlbumSyncRemoteLink(
                    uid: PhotoUID(volumeID: record.remoteVolumeID ?? "", nodeID: linkID),
                    sha1Hex: record.sha1Hex.isEmpty ? nil : record.sha1Hex,
                    isTrashed: false
                )
            case .duplicateTrashed:
                result[identifier] = AlbumSyncRemoteLink(
                    uid: PhotoUID(volumeID: record.remoteVolumeID ?? "", nodeID: linkID),
                    sha1Hex: record.sha1Hex.isEmpty ? nil : record.sha1Hex,
                    isTrashed: true
                )
            }
        }
        return result
    }
}
