import Foundation

/// Folder-sync source: streams the supported media files under one folder as backup candidates,
/// in the deterministic (case-insensitive path-sorted) order `FolderEnumerator` guarantees.
/// Platform-neutral by construction - pure Foundation file enumeration; sandbox access scoping
/// (security-scoped bookmarks on macOS) is the platform layer's job around the whole sync pass.
///
/// Revision = file modification time. Edit evidence is `.unavailable` on purpose: a mutable file
/// system cannot prove that a metadata drift wasn't a content edit, so a drifted file re-checks
/// through the pipeline (cheap: unchanged name/size/mtime reuses the manifest's hash).
public struct FolderBackupCatalog: UploadBackupAssetCatalog {
    public let folder: URL
    public let includeHidden: Bool

    public init(folder: URL, includeHidden: Bool = false) {
        self.folder = folder
        self.includeHidden = includeHidden
    }

    public func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error> {
        let folder = folder
        let includeHidden = includeHidden
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                let result = FolderEnumerator.enumerate(folder, includeHidden: includeHidden)
                for url in result.mediaFiles {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    guard let candidate = Self.candidate(for: url) else { continue }
                    continuation.yield(candidate)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One file → one single-resource candidate. Files that vanish between enumeration and
    /// attribute read are silently skipped - the next scan simply won't see them either.
    static func candidate(for url: URL) -> UploadBackupAssetCandidate? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        let modified = (attributes[.modificationDate] as? Date) ?? Date()
        let size = (attributes[.size] as? NSNumber)?.int64Value
        let snapshot = UploadBackupAssetSnapshot(
            source: .file(url),
            revision: UploadBackupRevision(date: modified),
            editRevision: .unavailable,
            resourceCount: 1
        )
        return UploadBackupAssetCandidate(
            snapshot: snapshot,
            originalFilename: url.lastPathComponent,
            byteCount: size
        )
    }
}
