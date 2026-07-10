import Foundation
import Photos
import PhotosCore
import UploadCore

/// Resolves a PhotoKit queue entry in two stages. It first streams each original only to compute its
/// identity (O(chunk) memory, no temp file). Core materializes verbatim bytes into the bounded temp
/// store only if dedupe returns `.upload`. HEIC stays HEIC and MOV stays MOV; `PHImageManager` is
/// never used.
public struct PhotoLibraryResourceResolver: BackupResourceResolving {

    private let tempStore: BackupTempFileStore
    private let cloudIdentifierProvider: @Sendable (String) -> String?

    public init(
        tempStore: BackupTempFileStore,
        cloudIdentifierProvider: @Sendable @escaping (String) -> String? = { _ in nil }
    ) {
        self.tempStore = tempStore
        self.cloudIdentifierProvider = cloudIdentifierProvider
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
        let additionalMetadata = try PhotoLibraryUploadMetadataBuilder.metadata(
            for: asset,
            cloudIdentifier: cloudIdentifierProvider(entry.source.identifier)
        )
        // Track deferred exports so the runner can release them as soon as the entry settles.
        let exportedURLs = ExportedURLBox()
        var didResolve = false
        defer {
            if !didResolve {
                for url in exportedURLs.urls { tempStore.discard(url) }
            }
        }
        let primaryIdentity = try await readIdentity(primaryResource)
        let primaryDescriptor = Self.identityDescriptor(
            source: candidate.snapshot.source,
            identity: primaryIdentity,
            filename: plan.primary.uploadFilename,
            stableDate: captureDate,
            tempStore: tempStore
        )
        let primaryRole = plan.primary.role
        let localIdentifier = entry.source.identifier
        let tempStore = self.tempStore
        let primaryMaterializer: @Sendable () async throws -> UploadResourceDescriptor = {
            guard let currentAsset = PHAsset.fetchAssets(
                withLocalIdentifiers: [localIdentifier], options: nil
            ).firstObject,
                  let resource = PhotoKitAssetMapper.resource(for: primaryRole, of: currentAsset) else {
                throw UploadError.backend("PhotoKit primary resource is no longer available")
            }
            let export = try await Self.export(
                resource,
                uploadFilename: plan.primary.uploadFilename,
                tempStore: tempStore,
                tracking: exportedURLs
            )
            return Self.materializedDescriptor(
                source: candidate.snapshot.source,
                export: export,
                filename: plan.primary.uploadFilename,
                stableDate: captureDate
            )
        }

        var secondaries: [BackupSecondaryResource] = []
        for item in plan.secondaries {
            guard let resource = PhotoKitAssetMapper.resource(for: item.role, ordinal: item.ordinal, of: asset) else {
                throw UploadError.backend("missing PhotoKit resource \(item.role.rawValue)#\(item.ordinal)")
            }
            let identity = try await readIdentity(resource)
            let source = UploadSourceIdentity(
                kind: .photoLibraryAsset,
                identifier: entry.source.identifier,
                resource: item.sourceResource
            )
            let role = item.role
            let ordinal = item.ordinal
            let filename = item.uploadFilename
            let materializer: @Sendable () async throws -> UploadResourceDescriptor = {
                guard let currentAsset = PHAsset.fetchAssets(
                    withLocalIdentifiers: [localIdentifier], options: nil
                ).firstObject,
                      let currentResource = PhotoKitAssetMapper.resource(
                        for: role, ordinal: ordinal, of: currentAsset
                      ) else {
                    throw UploadError.backend("PhotoKit secondary resource is no longer available")
                }
                let export = try await Self.export(
                    currentResource,
                    uploadFilename: filename,
                    tempStore: tempStore,
                    tracking: exportedURLs
                )
                return Self.materializedDescriptor(
                    source: source,
                    export: export,
                    filename: filename,
                    stableDate: captureDate
                )
            }
            secondaries.append(BackupSecondaryResource(
                descriptor: Self.identityDescriptor(
                    source: source,
                    identity: identity,
                    filename: item.uploadFilename,
                    stableDate: captureDate,
                    tempStore: tempStore
                ),
                mediaType: item.mimeType
                    ?? SupportedMedia.mimeType(for: URL(fileURLWithPath: item.uploadFilename))
                    ?? "application/octet-stream",
                additionalMetadata: additionalMetadata,
                materialize: materializer
            ))
        }

        didResolve = true
        return BackupResolvedResource(
            candidate: candidate,
            descriptor: primaryDescriptor,
            mediaType: plan.primary.mimeType
                ?? SupportedMedia.mimeType(for: URL(fileURLWithPath: plan.primary.uploadFilename))
                ?? "application/octet-stream",
            additionalMetadata: additionalMetadata,
            captureDate: captureDate,
            secondaries: secondaries,
            materialize: primaryMaterializer,
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

    private struct IdentityResult {
        let byteCount: Int64
        let sha1Digest: Data
    }

    private static func identityDescriptor(
        source: UploadSourceIdentity,
        identity: IdentityResult,
        filename: String,
        stableDate: Date,
        tempStore: BackupTempFileStore
    ) -> UploadResourceDescriptor {
        return UploadResourceDescriptor(
            source: source,
            fileURL: tempStore.directory.appendingPathComponent(".not-materialized"),
            filename: filename,
            fileSize: identity.byteCount,
            modificationDate: stableDate,
            precomputedSHA1Digest: identity.sha1Digest
        )
    }

    private static func materializedDescriptor(
        source: UploadSourceIdentity,
        export: ExportResult,
        filename: String,
        stableDate: Date
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: source,
            fileURL: export.url,
            filename: filename,
            fileSize: export.byteCount,
            modificationDate: stableDate,
            precomputedSHA1Digest: export.sha1Digest
        )
    }

    private struct ExportResult {
        let url: URL
        let byteCount: Int64
        let sha1Digest: Data
    }

    private final class DataRequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var requestID: PHAssetResourceDataRequestID?
        private var isCancelled = false

        func register(_ id: PHAssetResourceDataRequestID) {
            let cancelImmediately = lock.withLock {
                requestID = id
                return isCancelled
            }
            if cancelImmediately { PHAssetResourceManager.default().cancelDataRequest(id) }
        }

        func cancel() {
            let id = lock.withLock {
                isCancelled = true
                return requestID
            }
            if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
        }
    }

    /// Hashes one PhotoKit resource without materializing it. This is the common path for a library
    /// that is already backed up: original bytes are read once, but no temp I/O is paid.
    private func readIdentity(_ resource: PHAssetResource) async throws -> IdentityResult {
        #if DEBUG
        let startedAt = Date()
        #endif
        let sha1 = UploadSHA1Accumulator()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        final class ReadBox: @unchecked Sendable {
            var bytes: Int64 = 0
        }
        let box = ReadBox()
        let requestBox = DataRequestBox()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let requestID = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    sha1.update(data)
                    box.bytes += Int64(data.count)
                } completionHandler: { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
                requestBox.register(requestID)
            }
            try Task.checkCancellation()
        } onCancel: {
            requestBox.cancel()
        }
        let result = IdentityResult(byteCount: box.bytes, sha1Digest: sha1.finalizeDigest())
        #if DEBUG
        PhotoLibraryBackupPerformanceReporter.shared.recordIdentityRead(
            byteCount: result.byteCount,
            startedAt: startedAt,
            finishedAt: Date()
        )
        #endif
        return result
    }

    /// Materializes one resource only after Core selected it for upload. Chunks go straight to the
    /// temp file and are hashed again so the runner can reject a source that changed after preflight.
    private static func export(
        _ resource: PHAssetResource,
        uploadFilename: String,
        tempStore: BackupTempFileStore,
        tracking exported: ExportedURLBox
    ) async throws -> ExportResult {
        let partialURL = try tempStore.reserve(filename: uploadFilename, expectedBytes: 0)
        do {
            guard FileManager.default.createFile(atPath: partialURL.path, contents: nil) else {
                throw UploadError.backend("PhotoKit export file could not be created")
            }
            let handle = try FileHandle(forWritingTo: partialURL)
            let sha1 = UploadSHA1Accumulator()
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true

            final class WriteBox: @unchecked Sendable {
                var error: Error?
                var bytes: Int64 = 0
            }
            let box = WriteBox()
            let requestBox = DataRequestBox()
            #if DEBUG
            let _tRead = Date()
            #endif

            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let requestID = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                        guard box.error == nil else { return }
                        do {
                            try tempStore.recordWrite(to: partialURL, byteCount: data.count)
                            try handle.write(contentsOf: data)
                            sha1.update(data)
                            box.bytes += Int64(data.count)
                        } catch {
                            box.error = error
                        }
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
                    requestBox.register(requestID)
                }
                try Task.checkCancellation()
            } onCancel: {
                requestBox.cancel()
            }

            let finalURL = try tempStore.commit(partialURL)
            exported.append(finalURL)
            let digest = sha1.finalizeDigest()
            #if DEBUG
            let _sec = Date().timeIntervalSince(_tRead)
            let _mb = Double(box.bytes) / 1_048_576
            if _sec >= 1 {
                PhotoDiagnostics.shared.emit("BackupPerf", [
                    "step": "materializeSlow",
                    "file": uploadFilename,
                    "mb": String(format: "%.1f", _mb),
                    "ms": String(format: "%.0f", _sec * 1000),
                    "mb_s": _sec > 0.001 ? String(format: "%.0f", _mb / _sec) : "-",
                ])
            }
            #endif
            return ExportResult(url: finalURL, byteCount: box.bytes, sha1Digest: digest)
        } catch {
            tempStore.discard(partialURL)
            throw error
        }
    }
}
