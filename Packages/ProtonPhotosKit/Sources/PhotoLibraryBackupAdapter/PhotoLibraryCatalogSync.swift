import Foundation
import Photos
import UploadCore

/// Streams asset metadata for a catalog scan in bounded chunks. The production enumerator reads
/// PhotoKit; tests inject a canned enumerator so the whole scan → catalog → candidate → removed flow
/// runs deterministically off-device.
public protocol PhotoLibraryAssetEnumerator: Sendable {
    /// `identifiers == nil` enumerates the whole library newest-first; otherwise it fetches exactly
    /// those identifiers. Each yielded chunk is at most `chunkSize` assets so transient PhotoKit
    /// objects and catalog writes stay bounded on 20k+ libraries.
    func infoChunks(identifiers: [String]?, chunkSize: Int) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error>
}

/// Production enumerator over `PHAsset`. Metadata-only: `PHAssetResource.assetResources(for:)` is
/// synchronous and never downloads bytes, and we never touch image/video data or thumbnails here.
public struct PhotoKitAssetEnumerator: PhotoLibraryAssetEnumerator {
    public init() {}

    public func infoChunks(identifiers: [String]?, chunkSize: Int) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
        let chunkSize = max(1, chunkSize)
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                let fetchResult: PHFetchResult<PHAsset>
                if let identifiers {
                    fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
                } else {
                    let options = PHFetchOptions()
                    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                    fetchResult = PHAsset.fetchAssets(with: options)
                }

                let total = fetchResult.count
                var index = 0
                while index < total {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let upperBound = min(index + chunkSize, total)
                    autoreleasepool {
                        var chunk: [PhotoBackupAssetInfo] = []
                        chunk.reserveCapacity(upperBound - index)
                        for position in index ..< upperBound {
                            chunk.append(PhotoKitAssetMapper.info(for: fetchResult.object(at: position)))
                        }
                        continuation.yield(chunk)
                    }
                    index = upperBound
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Drives one photo-library catalog scan and feeds the backup engine. It runs a full or targeted
/// scan, persists every observed asset to the shared `PhotoLibraryCatalogStore`, and enqueues
/// backup candidates ONLY for assets that are new or whose content changed - so a repeat pass over
/// an unchanged 20k library re-checks nothing and never re-touches the backup queue.
///
/// Durability contract (the reason this is a driver, not just an `UploadBackupAssetCatalog`): for
/// every chunk the queue rows are written FIRST (`engine.enqueue`), and only THEN is the catalog
/// advanced (`upsertBatch`). A crash between the two re-yields the asset on the next pass (the queue
/// upsert is idempotent) instead of leaving the catalog claiming an unbacked-up asset is "seen".
/// Removed assets are marked in the catalog (never enqueued); the backup queue still resolves them
/// lazily to `sourceMissing`, so deletions are never mirrored.
///
/// Being a plain (non-actor) struct, its `async` methods run off the caller's actor - the SQLite
/// writes and PhotoKit enumeration never touch the main thread.
public struct PhotoLibraryCatalogSync: Sendable {
    private let store: any PhotoLibraryCatalogStore
    private let enumerator: any PhotoLibraryAssetEnumerator
    private let chunkSize: Int
    private let now: @Sendable () -> Date
    private let onProgress: (@Sendable (PhotoLibraryCatalogProgress) -> Void)?

    public init(
        store: any PhotoLibraryCatalogStore,
        enumerator: any PhotoLibraryAssetEnumerator = PhotoKitAssetEnumerator(),
        chunkSize: Int = 200,
        now: @Sendable @escaping () -> Date = { Date() },
        onProgress: (@Sendable (PhotoLibraryCatalogProgress) -> Void)? = nil
    ) {
        self.store = store
        self.enumerator = enumerator
        self.chunkSize = max(1, chunkSize)
        self.now = now
        self.onProgress = onProgress
    }

    /// `identifiers == nil` = full library scan (mark-and-sweep removals); otherwise a targeted
    /// incremental scan (missing requested ids are marked removed). Returns the final tally.
    @discardableResult
    public func run(engine: any UploadBackupCandidateEnqueueing, identifiers: [String]? = nil) async throws -> PhotoLibraryCatalogProgress {
        let observedAt = now()
        var progress = PhotoLibraryCatalogProgress()
        // Only a targeted scan needs the seen set (to diff against the requested ids); a full scan
        // detects removals via the last-seen sweep, so it keeps no per-asset set in memory.
        var seenForTargeted: Set<String>? = identifiers == nil ? nil : []

        for try await chunk in enumerator.infoChunks(identifiers: identifiers, chunkSize: chunkSize) {
            try Task.checkCancellation()
            let entries = chunk.map { PhotoLibraryCatalogMapper.entry(for: $0, observedAt: observedAt) }
            for (info, entry) in zip(chunk, entries) {
                progress.scanned += 1
                if seenForTargeted != nil { seenForTargeted!.insert(info.localIdentifier) }
                let change = store.classify(entry)
                switch change {
                case .inserted: progress.discovered += 1
                case .changed: progress.changed += 1
                case .unchanged: continue
                }
                // Durable queue row BEFORE the catalog is advanced for this chunk.
                if let candidate = PhotoBackupAssetPlanner.candidate(for: info) {
                    await engine.enqueue(candidate)
                }
            }
            store.upsertBatch(entries)
            onProgress?(progress)
        }

        if let identifiers {
            let missing = Set(identifiers).subtracting(seenForTargeted ?? [])
            if !missing.isEmpty {
                progress.removed += store.markRemoved(Array(missing), removedAt: observedAt)
            }
        } else {
            progress.removed += store.sweepRemoved(notSeenAfter: observedAt, removedAt: observedAt)
        }
        onProgress?(progress)
        return progress
    }
}
