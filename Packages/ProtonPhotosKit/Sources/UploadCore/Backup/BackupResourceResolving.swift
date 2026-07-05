import Foundation

/// A queue entry rematerialized into everything the pipeline and uploader need. The queue stores
/// only identities and revisions; adapters rebuild the concrete resource when work actually runs
/// (after a relaunch the original export/URL may be gone, so this is the resume seam).
public struct BackupResolvedResource: Sendable {
    /// Snapshot of the source AS RESOLVED NOW (current revision) - what gets recorded as backed
    /// up on success. May be newer than the queue entry's revision when the file changed since
    /// the scan; the runner uploads current content and records the truth for what it uploaded.
    public let candidate: UploadBackupAssetCandidate
    /// Pipeline + upload input describing the same resolved state.
    public let descriptor: UploadResourceDescriptor
    public let mediaType: String
    /// Best local capture-time evidence (file creation date for folder sync).
    public let captureDate: Date

    public init(
        candidate: UploadBackupAssetCandidate,
        descriptor: UploadResourceDescriptor,
        mediaType: String,
        captureDate: Date
    ) {
        self.candidate = candidate
        self.descriptor = descriptor
        self.mediaType = mediaType
        self.captureDate = captureDate
    }
}

/// Platform seam: turn a persisted queue entry back into a readable local resource.
/// Contract: return `nil` when the source is VERIFIABLY gone (drives the terminal
/// `.sourceMissing` state); throw for transient problems (drives retry with backoff).
public protocol BackupResourceResolving: Sendable {
    func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource?
}

/// The file-URL resolver shared by every platform's folder/file backup path. Reads current
/// attributes so a file edited after the scan is backed up as it exists now. Security-scoped
/// access (macOS sandbox bookmarks) is session-scoped by the platform layer around the whole
/// sync pass - this resolver only touches the file system.
public struct FileBackupResourceResolver: BackupResourceResolving {
    public init() {}

    public func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        guard entry.source.kind == .fileURL else {
            throw UploadError.backend("unsupported backup source kind \(entry.source.kind.rawValue)")
        }
        let url = URL(fileURLWithPath: entry.source.identifier)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        } catch let error as NSError
            where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) {
            return nil
        }

        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        let created = (attributes[.creationDate] as? Date) ?? modified
        let filename = url.lastPathComponent

        let snapshot = UploadBackupAssetSnapshot(
            source: entry.source,
            revision: UploadBackupRevision(date: modified),
            editRevision: .unavailable,
            resourceCount: 1
        )
        let descriptor = UploadResourceDescriptor(
            source: entry.source,
            fileURL: url,
            filename: filename,
            fileSize: fileSize,
            modificationDate: modified
        )
        return BackupResolvedResource(
            candidate: UploadBackupAssetCandidate(snapshot: snapshot, originalFilename: filename, byteCount: fileSize),
            descriptor: descriptor,
            mediaType: SupportedMedia.mimeType(for: url) ?? "application/octet-stream",
            captureDate: created
        )
    }
}
