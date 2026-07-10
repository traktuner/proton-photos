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
    /// Cheap full-library identifier snapshot. Production reads only `localIdentifier`; source
    /// metadata and resources are materialized later in bounded chunks from the durable snapshot.
    func identifierChunks(chunkSize: Int) -> AsyncThrowingStream<[String], any Error>
}

public extension PhotoLibraryAssetEnumerator {
    func infoChunks(identifiers: [String]?, chunkSize: Int) -> AsyncThrowingStream<[PhotoBackupAssetInfo], any Error> {
        infoChunks(identifiers: identifiers, startOffset: 0, chunkSize: chunkSize)
    }

    func identifierChunks(chunkSize: Int) -> AsyncThrowingStream<[String], any Error> {
        let source = infoChunks(identifiers: nil, startOffset: 0, chunkSize: chunkSize)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in source {
                        continuation.yield(chunk.map(\.localIdentifier))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
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
                        let assets = (index ..< upperBound).map { fetchResult.object(at: $0) }
                        let chunk = PhotoKitAssetMapper.infos(for: assets)
                        continuation.yield(chunk)
                    }
                    index = upperBound
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func identifierChunks(chunkSize: Int) -> AsyncThrowingStream<[String], any Error> {
        let chunkSize = max(1, chunkSize)
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                let options = PHFetchOptions()
                options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
                let result = PHAsset.fetchAssets(with: options)
                var index = 0
                while index < result.count {
                    if Task.isCancelled {
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let upperBound = min(index + chunkSize, result.count)
                    let identifiers = autoreleasepool {
                        (index ..< upperBound).map { result.object(at: $0).localIdentifier }
                    }
                    continuation.yield(identifiers)
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
        guard store.isOperational() else {
            throw UploadError.backend("Photo library catalog is unavailable")
        }
        let observedAt = now()
        var progress = PhotoLibraryCatalogProgress()

        // --- Targeted (change-token) scan: fetch exactly the requested ids; mark the missing removed. ---
        if let identifiers {
            var seen: Set<String>? = []
            for try await chunk in enumerator.infoChunks(identifiers: identifiers, startOffset: 0, chunkSize: chunkSize) {
                try Task.checkCancellation()
                try await ingest(chunk, observedAt: observedAt, engine: engine, progress: &progress, seen: &seen)
            }
            let missing = Set(identifiers).subtracting(seen ?? [])
            if !missing.isEmpty {
                let result = store.markRemoved(Array(missing), removedAt: observedAt)
                guard result.succeeded else {
                    throw UploadError.backend("Photo library removals could not be saved")
                }
                progress.removed += result.affectedRows
            }
            onProgress?(progress)
            return progress
        }

        // --- Full library scan: stable and resumable across interruptions. ---
        // A numeric cursor over a live PHFetchResult is unsafe: deleting an earlier item shifts an
        // unseen item behind the cursor. Persist the epoch's identifiers first, then resolve that
        // immutable list in chunks. New assets are handled independently by persistent changes.
        let existingProgress = store.fullScanProgress()
        guard store.isOperational() else {
            throw UploadError.backend("Photo library scan state is unavailable")
        }
        if existingProgress == nil {
            guard store.beginFullScanSnapshot(epochStart: observedAt) else {
                throw UploadError.backend("Photo library scan snapshot could not be started")
            }
            do {
                for try await identifiers in enumerator.identifierChunks(chunkSize: chunkSize) {
                    try Task.checkCancellation()
                    guard store.appendFullScanSnapshotIdentifiers(identifiers) else {
                        throw UploadError.backend("Photo library scan snapshot could not be saved")
                    }
                }
                guard store.finishFullScanSnapshot() else {
                    throw UploadError.backend("Photo library scan snapshot could not be published")
                }
            } catch {
                _ = store.clearFullScanResumePoint()
                throw error
            }
        }

        guard let resume = store.fullScanProgress() else {
            throw UploadError.backend("Photo library scan snapshot is unavailable")
        }
        guard store.isOperational() else {
            throw UploadError.backend("Photo library scan state is unavailable")
        }
        let epochStart = resume.epochStart
        let total = store.fullScanSnapshotCount()
        guard store.isOperational() else {
            throw UploadError.backend("Photo library scan snapshot could not be read")
        }
        var cursor = resume.cursor
        while cursor < total {
            try Task.checkCancellation()
            let identifiers = store.fullScanSnapshotIdentifiers(startingAt: cursor, limit: chunkSize)
            guard store.isOperational() else {
                throw UploadError.backend("Photo library scan snapshot could not be read")
            }
            guard !identifiers.isEmpty else {
                _ = store.clearFullScanResumePoint()
                throw UploadError.backend("Photo library scan snapshot is incomplete")
            }

            var seen: Set<String>? = []
            for try await chunk in enumerator.infoChunks(identifiers: identifiers, startOffset: 0, chunkSize: chunkSize) {
                try Task.checkCancellation()
                try await ingest(chunk, observedAt: observedAt, engine: engine, progress: &progress, seen: &seen)
            }
            let missing = Set(identifiers).subtracting(seen ?? [])
            if !missing.isEmpty {
                let result = store.markRemoved(Array(missing), removedAt: observedAt)
                guard result.succeeded else {
                    throw UploadError.backend("Photo library removals could not be saved")
                }
                progress.removed += result.affectedRows
            }
            cursor += identifiers.count
            guard store.recordFullScanProgress(PhotoLibraryFullScanProgress(epochStart: epochStart, cursor: cursor)) else {
                throw UploadError.backend("Photo library scan progress could not be saved")
            }
            onProgress?(progress)
        }

        // The enumeration ran to the end (across however many resumed runs) → the epoch is complete.
        let sweep = store.sweepRemoved(notSeenAfter: epochStart, removedAt: observedAt)
        guard sweep.succeeded else {
            throw UploadError.backend("Photo library removal sweep could not be saved")
        }
        progress.removed += sweep.affectedRows
        guard store.completeFullScan() else {
            throw UploadError.backend("Photo library scan could not be completed")
        }
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
    ) async throws {
        let entries = chunk.map { PhotoLibraryCatalogMapper.entry(for: $0, observedAt: observedAt) }
        let changes = store.classifyBatch(entries)
        guard store.isOperational(), changes.count == entries.count else {
            throw UploadError.backend("Photo library catalog classification was incomplete")
        }
        var candidates: [UploadBackupAssetCandidate] = []
        candidates.reserveCapacity(entries.count)
        for (info, change) in zip(chunk, changes) {
            progress.scanned += 1
            if seen != nil { seen!.insert(info.localIdentifier) }
            switch change {
            case .inserted: progress.discovered += 1
            case .changed: progress.changed += 1
            case .unchanged: continue
            }
            if let candidate = PhotoBackupAssetPlanner.candidate(for: info) {
                candidates.append(candidate)
            }
        }
        _ = try await engine.enqueueBatch(candidates)
        guard store.upsertBatch(entries) else {
            throw UploadError.backend("Photo library catalog could not be updated")
        }
        onProgress?(progress)
    }
}
