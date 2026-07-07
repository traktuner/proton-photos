import Foundation
import Photos
import UploadCore

/// Streams asset metadata for a catalog scan in bounded chunks. The production enumerator reads
/// PhotoKit; tests inject a canned enumerator so the whole scan → catalog → candidate → removed flow
/// runs deterministically off-device.
public protocol PhotoLibraryAssetEnumerator: Sendable {
    /// `identifiers == nil` enumerates the whole library newest-first; otherwise it fetches exactly
    /// those identifiers. `startOffset` skips that many assets from the newest-first start so an
    /// interrupted full scan can RESUME instead of restarting (ignored for a targeted fetch). Each
    /// yielded chunk is at most `chunkSize` assets so transient PhotoKit objects and catalog writes
    /// stay bounded on 20k+ libraries.
    func infoChunks(identifiers: [String]?, startOffset: Int, chunkSize: Int) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error>
}

public extension PhotoLibraryAssetEnumerator {
    func infoChunks(identifiers: [String]?, chunkSize: Int) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
        infoChunks(identifiers: identifiers, startOffset: 0, chunkSize: chunkSize)
    }
}

/// Production enumerator over `PHAsset`. Metadata-only: `PHAssetResource.assetResources(for:)` is
/// synchronous and never downloads bytes, and we never touch image/video data or thumbnails here.
public struct PhotoKitAssetEnumerator: PhotoLibraryAssetEnumerator {
    public init() {}

    public func infoChunks(identifiers: [String]?, startOffset: Int, chunkSize: Int) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
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
                // Resume point: skip assets already observed by an earlier run of this scan epoch.
                // Clamped so a shrunk library (deletions since the cursor was saved) can't index past
                // the end — it just yields nothing and the epoch completes.
                var index = min(max(0, startOffset), total)
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

    /// `identifiers == nil` = full library scan (resumable, mark-and-sweep removals); otherwise a
    /// targeted incremental scan (missing requested ids are marked removed). Returns the final tally.
    @discardableResult
    public func run(engine: any UploadBackupCandidateEnqueueing, identifiers: [String]? = nil) async throws -> PhotoLibraryCatalogProgress {
        let observedAt = now()
        var progress = PhotoLibraryCatalogProgress()

        // --- Targeted (change-token) scan: fetch exactly the requested ids; mark the missing removed. ---
        if let identifiers {
            var seen: Set<String>? = []
            for try await chunk in enumerator.infoChunks(identifiers: identifiers, startOffset: 0, chunkSize: chunkSize) {
                try Task.checkCancellation()
                await ingest(chunk, observedAt: observedAt, engine: engine, progress: &progress, seen: &seen)
            }
            let missing = Set(identifiers).subtracting(seen ?? [])
            if !missing.isEmpty {
                progress.removed += store.markRemoved(Array(missing), removedAt: observedAt)
            }
            onProgress?(progress)
            return progress
        }

        // --- Full library scan: RESUMABLE across interruptions. ---
        // A full scan of a large library rarely finishes in one foreground/BG window. Resume the
        // in-progress epoch (continue from its cursor) or start a fresh one. Crucially the removal
        // sweep uses the EPOCH START as its cutoff — never this single run's clock — so assets
        // observed by an EARLIER run of the same epoch are not falsely swept as removed when a later
        // run finally reaches the end. Enumeration is newest-first; a resumed run skips `cursor`
        // already-observed assets.
        let resume = store.fullScanProgress()
        let epochStart = resume?.epochStart ?? observedAt
        var cursor = resume?.cursor ?? 0
        if resume == nil {
            store.recordFullScanProgress(PhotoLibraryFullScanProgress(epochStart: epochStart, cursor: 0))
        }
        var noSeen: Set<String>?
        for try await chunk in enumerator.infoChunks(identifiers: nil, startOffset: cursor, chunkSize: chunkSize) {
            try Task.checkCancellation()
            await ingest(chunk, observedAt: observedAt, engine: engine, progress: &progress, seen: &noSeen)
            cursor += chunk.count
            // Persist the frontier: an interruption after this chunk resumes here, not at zero.
            store.recordFullScanProgress(PhotoLibraryFullScanProgress(epochStart: epochStart, cursor: cursor))
        }

        // The enumeration ran to the end (across however many resumed runs) → the epoch is complete.
        progress.removed += store.sweepRemoved(notSeenAfter: epochStart, removedAt: observedAt)
        store.completeFullScan()
        onProgress?(progress)
        return progress
    }

    /// Classifies + enqueues one chunk, then durably advances the catalog. Queue rows are written
    /// BEFORE the catalog (`upsertBatch`) so a crash re-yields the asset rather than stranding it.
    private func ingest(
        _ chunk: [PhotoBackupAssetInfo],
        observedAt: Date,
        engine: any UploadBackupCandidateEnqueueing,
        progress: inout PhotoLibraryCatalogProgress,
        seen: inout Set<String>?
    ) async {
        let entries = chunk.map { PhotoLibraryCatalogMapper.entry(for: $0, observedAt: observedAt) }
        for (info, entry) in zip(chunk, entries) {
            progress.scanned += 1
            if seen != nil { seen!.insert(info.localIdentifier) }
            switch store.classify(entry) {
            case .inserted: progress.discovered += 1
            case .changed: progress.changed += 1
            case .unchanged: continue
            }
            if let candidate = PhotoBackupAssetPlanner.candidate(for: info) {
                await engine.enqueue(candidate)
            }
        }
        store.upsertBatch(entries)
        onProgress?(progress)
    }
}
