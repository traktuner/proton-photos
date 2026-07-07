import Foundation
import Photos
import PhotosCore
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
        let additionalMetadata = try PhotoLibraryUploadMetadataBuilder.metadata(for: asset)
        // Track every temp export so the runner can release them the moment the entry settles.
        // Without this the store's footprint grows across a pass until it trips the disk budget
        // and every remaining item fails - the exact failure that stranded a full library.
        let exportedURLs = ExportedURLBox()
        let primaryURL = try await export(primaryResource, uploadFilename: plan.primary.uploadFilename, tracking: exportedURLs)
        let primaryDescriptor = descriptor(
            source: candidate.snapshot.source,
            fileURL: primaryURL,
            filename: plan.primary.uploadFilename,
            stableDate: captureDate
        )

        var secondaries: [BackupSecondaryResource] = []
        for item in plan.secondaries {
            guard let resource = PhotoKitAssetMapper.resource(for: item.role, ordinal: item.ordinal, of: asset) else {
                throw UploadError.backend("missing PhotoKit resource \(item.role.rawValue)#\(item.ordinal)")
            }
            let url = try await export(resource, uploadFilename: item.uploadFilename, tracking: exportedURLs)
            let source = UploadSourceIdentity(
                kind: .photoLibraryAsset,
                identifier: entry.source.identifier,
                resource: item.sourceResource
            )
            secondaries.append(BackupSecondaryResource(
                descriptor: descriptor(
                    source: source,
                    fileURL: url,
                    filename: item.uploadFilename,
                    stableDate: captureDate
                ),
                mediaType: item.mimeType
                    ?? SupportedMedia.mimeType(for: url)
                    ?? "application/octet-stream",
                additionalMetadata: additionalMetadata
            ))
        }

        let tempStore = self.tempStore
        return BackupResolvedResource(
            candidate: candidate,
            descriptor: primaryDescriptor,
            mediaType: plan.primary.mimeType
                ?? SupportedMedia.mimeType(for: primaryURL)
                ?? "application/octet-stream",
            additionalMetadata: additionalMetadata,
            captureDate: captureDate,
            secondaries: secondaries,
            cleanup: { for url in exportedURLs.urls { tempStore.discard(url) } }
        )
    }

    /// Collects committed export URLs so the whole compound can be discarded in one cleanup call.
    /// A reference box (not an inout array) so it survives the async export hops and is captured
    /// by the `cleanup` closure.
    private final class ExportedURLBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URL] = []
        func append(_ url: URL) { lock.withLock { stored.append(url) } }
        var urls: [URL] { lock.withLock { stored } }
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
    private func export(_ resource: PHAssetResource, uploadFilename: String, tracking exported: ExportedURLBox) async throws -> URL {
        let partialURL = try tempStore.reserve(filename: uploadFilename, expectedBytes: Self.expectedBytes(of: resource))
        FileManager.default.createFile(atPath: partialURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partialURL)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true    // iCloud-optimized originals download on demand

        final class WriteBox: @unchecked Sendable {
            var error: Error?
            var bytes: Int64 = 0
        }
        let box = WriteBox()
        #if DEBUG
        let _tRead = Date()
        #endif

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    guard box.error == nil else { return }
                    do { try handle.write(contentsOf: data); box.bytes += Int64(data.count) } catch { box.error = error }
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
        let finalURL = try tempStore.commit(partialURL)
        exported.append(finalURL)
        #if DEBUG
        // [BackupPerf] step 1: rematerialize the original from PhotoKit onto disk. read throughput.
        let _sec = Date().timeIntervalSince(_tRead)
        let _mb = Double(box.bytes) / 1_048_576
        PhotoDiagnostics.shared.emit("BackupPerf", [
            "step": "read",
            "file": uploadFilename,
            "mb": String(format: "%.1f", _mb),
            "ms": String(format: "%.0f", _sec * 1000),
            "mb_s": _sec > 0.001 ? String(format: "%.0f", _mb / _sec) : "-",
        ])
        #endif
        return finalURL
    }

    /// Best-effort byte estimate for the disk-budget reservation. PhotoKit exposes the resource
    /// size only through the undocumented `fileSize` key; a miss simply falls back to 0 (the
    /// reservation then still enforces the free-space floor, just not a size-aware headroom).
    private static func expectedBytes(of resource: PHAssetResource) -> Int64 {
        if let size = resource.value(forKey: "fileSize") as? Int64 { return size }
        if let size = resource.value(forKey: "fileSize") as? Int { return Int64(size) }
        return 0
    }
}
