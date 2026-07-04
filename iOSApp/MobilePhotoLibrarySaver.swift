import Foundation
import MediaByteCache
import Photos
import PhotosCore

/// Saves the selected media's ORIGINAL files into the user's Apple Photos library (iOS/iPadOS) as individual
/// assets — images as photos, videos as videos, and Live Photos as true Live Photos when the paired motion
/// video is available.
///
/// There is NO ZIP and NO transcoding: the exact decrypted original bytes are fetched cache-first through the
/// shared `EncryptedOriginalProvider` (the same E2EE path as share/export), written to a short-lived temp file,
/// handed to PhotoKit, and the temp directory is deleted afterwards — so plaintext originals never persist
/// outside the encrypted cache. PhotoKit lives ONLY in this iOS app target, never in Core.
///
/// The API is a prepared ``Session`` the caller drives one item at a time, so the UI can update a progress
/// overlay on the main actor after each item without any cross-actor callback (each item's decrypt/download/
/// PhotoKit write still runs OFF the main actor).
enum MobilePhotoLibrarySaver {
    /// The per-item result, so the UI can be honest about partial success.
    enum ItemOutcome: Sendable {
        /// Saved as a full asset (a proper Live Photo counts here).
        case saved
        /// A Live Photo saved as a still-only asset because the paired motion video was unavailable or PhotoKit
        /// rejected the pairing.
        case savedStillOnly
        /// Could not be saved at all (download failure or a PhotoKit error).
        case failed
    }

    /// The outcome of `prepare`: either add-only access was denied, or a ready ``Session``.
    enum Prepared {
        case denied
        case ready(Session)
    }

    /// A running tally the caller accumulates across the per-item saves.
    struct Tally {
        var saved = 0
        var failed = 0
        var livePhotoDegraded = 0

        mutating func add(_ outcome: ItemOutcome) {
            switch outcome {
            case .saved: saved += 1
            case .savedStillOnly: saved += 1; livePhotoDegraded += 1
            case .failed: failed += 1
            }
        }
    }

    /// The dedicated temp subfolder for pending saves, cleared before each run and removed after so decrypted
    /// originals never linger on disk.
    private static var saveDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PhotosSave", isDirectory: true)
    }

    /// Requests add-only Photos authorization and, if granted, prepares a save ``Session``. Add-only because the
    /// app only ever ADDS assets — it never reads the user's library.
    static func prepare(
        backend: any FullMediaProvider,
        cache: ThumbnailCache?,
        cacheCapBytes: Int64
    ) async -> Prepared {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { return .denied }

        let directory = saveDirectory
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Cache-first bytes, reusing whatever the viewer/share already decrypted; seed the cache on a miss when
        // one exists (same policy as `MobileMediaExporter`). Bytes only ever live in the AES-GCM cache or RAM.
        let policy: OriginalsCachePolicy = cache != nil ? .persisting(capBytes: cacheCapBytes) : .readOnly
        let provider = EncryptedOriginalProvider(media: backend, cache: cache, policy: policy)
        return .ready(Session(directory: directory, provider: provider))
    }

    /// A prepared save session. Drive it item-by-item from the UI, then call ``cleanup()`` when done.
    struct Session: Sendable {
        fileprivate let directory: URL
        fileprivate let provider: EncryptedOriginalProvider

        /// Saves one item's original into Apple Photos. Never throws: any failure is reported as `.failed`.
        func save(_ item: PhotoItem) async -> ItemOutcome {
            do {
                let data = try await provider.originalData(for: item.uid)
                let stillURL = try writeTemp(data, uid: item.uid, isVideo: item.isVideo)

                // A plain video → a single video asset.
                if item.isVideo {
                    try await createAsset { request in
                        request.addResource(with: .video, fileURL: stillURL, options: resourceOptions())
                    }
                    return .saved
                }

                // A Live Photo → still + paired motion video in ONE asset when the motion video is available;
                // degrade honestly to a still-only asset when it is not — whether the paired-video id was never
                // enriched onto the item (`relatedVideoUID == nil`, an SDK timeline-enumeration gap), the motion
                // video can't be downloaded, or PhotoKit later rejects the pairing (a Proton round-trip can
                // strip the Apple content-identifier the pair needs). Every "no motion" case returns
                // `.savedStillOnly` so the count surfaces to the user rather than masquerading as a full save.
                if item.isLivePhoto {
                    guard let videoUID = item.relatedVideoUID,
                          let pairedURL = try? await writeTemp(
                              provider.originalData(for: videoUID), uid: videoUID, isVideo: true
                          )
                    else {
                        try await createStill(stillURL)
                        return .savedStillOnly
                    }
                    do {
                        try await createAsset { request in
                            request.addResource(with: .photo, fileURL: stillURL, options: resourceOptions())
                            request.addResource(with: .pairedVideo, fileURL: pairedURL, options: resourceOptions())
                        }
                        return .saved
                    } catch {
                        try await createStill(stillURL)
                        return .savedStillOnly
                    }
                }

                // A plain still image.
                try await createStill(stillURL)
                return .saved
            } catch {
                return .failed
            }
        }

        /// Removes the run's temp directory (and every decrypted original it held).
        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }

        private func createStill(_ url: URL) async throws {
            try await createAsset { request in
                request.addResource(with: .photo, fileURL: url, options: resourceOptions())
            }
        }

        /// Writes decrypted bytes to a temp file whose extension is sniffed from the ACTUAL bytes, so PhotoKit
        /// infers the correct UTI — a HEIC is ingested as HEIC (never re-tagged `jpg`) and a MOV/MP4 keeps its
        /// container. The node id keeps a still and its paired video distinct within the run.
        private func writeTemp(_ data: Data, uid: PhotoUID, isVideo: Bool) throws -> URL {
            let ext = OriginalFileNaming.resolvedExtension(
                filename: nil, mimeType: nil, header: data, fallbackMediaType: nil, isVideo: isVideo
            )
            let url = directory.appendingPathComponent("\(uid.nodeID).\(ext)")
            try data.write(to: url, options: .atomic)
            return url
        }

        private func resourceOptions() -> PHAssetResourceCreationOptions {
            let options = PHAssetResourceCreationOptions()
            // PhotoKit copies the bytes during the change block; the run's temp directory is deleted afterwards.
            options.shouldMoveFile = false
            return options
        }

        private func createAsset(
            _ configure: @escaping @Sendable (PHAssetCreationRequest) -> Void
        ) async throws {
            try await PHPhotoLibrary.shared().performChanges {
                configure(PHAssetCreationRequest.forAsset())
            }
        }
    }
}
