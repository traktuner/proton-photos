import Foundation
import Photos
import UploadCore

/// Rematerializes a photo-library queue entry: exports the asset's CURRENT original resources
/// into the journaled temp store (streamed to disk, O(chunk) memory, iCloud originals allowed)
/// and describes them for the shared pipeline. Bytes are exported verbatim - HEIC stays HEIC,
/// MOV stays MOV; `PHImageManager` is never used.
public struct PhotoLibraryResourceResolver: BackupResourceResolving {

    private let tempStore: BackupTempFileStore

    public init(tempStore: BackupTempFileStore) {
        self.tempStore = tempStore
    }

    public func resolve(_ entry: UploadBackupSyncQueueEntry) async throws -> BackupResolvedResource? {
        guard entry.source.kind == .photoLibraryAsset else {
            throw UploadError.backend("photo resolver received source kind \(entry.source.kind.rawValue)")
        }
        let fetch = PHAsset.fetchAssets(withLocalIdentifiers: [entry.source.identifier], options: nil)
        guard let asset = fetch.firstObject else {
            return nil    // deleted locally (or dropped from a limited selection) → sourceMissing
        }

        let info = PhotoKitAssetMapper.info(for: asset)
        guard let plan = PhotoBackupAssetPlanner.exportPlan(for: info),
              let candidate = PhotoBackupAssetPlanner.candidate(for: info),
              let primaryResource = PhotoKitAssetMapper.resource(for: plan.primary.role, of: asset) else {
            return nil
        }

        // Stable descriptor dates: capture time drives the remote timeline; the descriptor's
        // modification date must NOT be the temp file's mtime (that would defeat manifest hash
        // reuse across re-exports), so it uses the asset's stable creation date.
        let captureDate = asset.creationDate ?? asset.modificationDate ?? Date()
        let primaryURL = try await export(primaryResource, uploadFilename: plan.primary.uploadFilename)
        let primaryDescriptor = descriptor(
            source: candidate.snapshot.source,
            fileURL: primaryURL,
            filename: plan.primary.uploadFilename,
            stableDate: captureDate
        )

        var secondaries: [BackupSecondaryResource] = []
        if let paired = plan.pairedVideo,
           let pairedResource = PhotoKitAssetMapper.resource(for: paired.role, of: asset) {
            let pairedURL = try await export(pairedResource, uploadFilename: paired.uploadFilename)
            let pairedSource = UploadSourceIdentity(
                kind: .photoLibraryAsset,
                identifier: entry.source.identifier,
                resource: .livePairedVideo
            )
            secondaries.append(BackupSecondaryResource(
                descriptor: descriptor(
                    source: pairedSource,
                    fileURL: pairedURL,
                    filename: paired.uploadFilename,
                    stableDate: captureDate
                ),
                mediaType: paired.mimeType ?? "video/quicktime"
            ))
        }

        return BackupResolvedResource(
            candidate: candidate,
            descriptor: primaryDescriptor,
            mediaType: plan.primary.mimeType
                ?? SupportedMedia.mimeType(for: primaryURL)
                ?? "application/octet-stream",
            captureDate: captureDate,
            secondaries: secondaries
        )
    }

    private func descriptor(
        source: UploadSourceIdentity,
        fileURL: URL,
        filename: String,
        stableDate: Date
    ) -> UploadResourceDescriptor {
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? NSNumber)?.int64Value ?? 0
        return UploadResourceDescriptor(
            source: source,
            fileURL: fileURL,
            filename: filename,
            fileSize: size,
            modificationDate: stableDate
        )
    }

    /// Streams one resource's original bytes into the temp store: chunks arrive on PhotoKit's
    /// serial queue and go straight to disk - the whole file is never in memory. Write errors
    /// fail the export loudly (a silently truncated file would hash "consistently wrong").
    private func export(_ resource: PHAssetResource, uploadFilename: String) async throws -> URL {
        let partialURL = try tempStore.reserve(filename: uploadFilename, expectedBytes: 0)
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partialURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true    // iCloud-optimized originals download on demand

        final class WriteBox: @unchecked Sendable {
            var error: Error?
        }
        let box = WriteBox()

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    guard box.error == nil else { return }
                    do { try handle.write(contentsOf: data) } catch { box.error = error }
                } completionHandler: { error in
                    try? handle.close()
                    if let error {
                        continuation.resume(throwing: error)
                    } else if let writeError = box.error {
                        continuation.resume(throwing: writeError)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            tempStore.discard(partialURL)
            throw error
        }
        return try tempStore.commit(partialURL)
    }
}
