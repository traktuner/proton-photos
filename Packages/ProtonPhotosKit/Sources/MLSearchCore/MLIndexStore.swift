import Foundation
import PhotosCore

/// Batched persistence boundary for ML embeddings and failure state. Keys are
/// `(PhotoUID, MLModelDescriptor)`, writes are first-write-wins, and reads are deterministic.
public protocol MLIndexStore: Sendable {
    /// Insert embeddings for a single model epoch. Idempotent per `(uid, descriptor)`;
    /// first write wins. A present embedding clears failure state for the same key in the
    /// same operation. Dimension-mismatched records are rejected (`permanentFailure`).
    @discardableResult
    func upsert(_ records: [MLEmbeddingRecord]) -> MLIndexBatchReport

    /// `true` iff a record exists for `(uid, descriptor)`.
    func contains(uid: PhotoUID, descriptor: MLModelDescriptor) -> Bool

    /// Bulk membership check for a model epoch. Returns the subset of `uids` already indexed.
    /// Must not load vectors or scan other epochs.
    func indexedUIDs(for descriptor: MLModelDescriptor, from uids: [PhotoUID]) -> Set<PhotoUID>

    /// All UIDs indexed under a model epoch (used for coverage / eviction heuristics).
    func allIndexedUIDs(for descriptor: MLModelDescriptor) -> [PhotoUID]

    /// All UIDs with an embedding or persisted failure for an epoch. Used to remove state for
    /// assets that left the library without scanning vector payloads.
    func allTrackedUIDs(for descriptor: MLModelDescriptor) -> [PhotoUID]

    /// All embeddings for a model epoch, in the store's deterministic order.
    /// Prefer `vectorBlock(for:)` on the query path — it avoids per-record allocations.
    func allRecords(for descriptor: MLModelDescriptor) -> [MLEmbeddingRecord]

    /// The epoch's embeddings as one packed, query-ready matrix. This is the scoring input:
    /// a single contiguous buffer instead of N per-record arrays. Implementations should
    /// stream rows directly into the block.
    func vectorBlock(for descriptor: MLModelDescriptor) -> MLVectorBlock

    /// Remove the record for `(uid, descriptor)` — used when an asset is deleted or must be
    /// re-embedded (explicit remove-then-upsert is the only reindex path).
    func remove(uid: PhotoUID, descriptor: MLModelDescriptor)

    /// Remove embeddings and failure state for multiple assets in one durable operation.
    /// Implementations must bump the vector generation at most once for the batch.
    func remove(uids: [PhotoUID], descriptor: MLModelDescriptor)

    /// Drop every record for a model epoch (used when retiring a model version).
    func removeAll(for descriptor: MLModelDescriptor)

    /// Total record count for a model epoch.
    func count(for descriptor: MLModelDescriptor) -> Int

    /// Monotonic epoch generation. Search engines use it to invalidate packed vector snapshots.
    func generation(for descriptor: MLModelDescriptor) -> UInt64

    /// Persist retry/permanent failure state independently from embeddings.
    @discardableResult
    func recordFailures(_ records: [MLIndexFailureRecord]) -> Bool
    func failureRecords(for descriptor: MLModelDescriptor, from uids: [PhotoUID]) -> [PhotoUID: MLIndexFailureRecord]
}

extension MLIndexStore {
    /// Default: build the block from `allRecords`. Persistent stores override this to stream
    /// rows straight from disk into the packed buffer without materializing records.
    public func vectorBlock(for descriptor: MLModelDescriptor) -> MLVectorBlock {
        MLVectorBlock(descriptor: descriptor, records: allRecords(for: descriptor))
    }

    public func coverage(for descriptor: MLModelDescriptor, allAssets: [PhotoUID]) -> MLIndexCoverage {
        let uniqueAssets = Array(Set(allAssets))
        let indexed = indexedUIDs(for: descriptor, from: uniqueAssets)
        let failures = failureRecords(for: descriptor, from: uniqueAssets)
        let permanent = failures.values.reduce(into: 0) { count, failure in
            if failure.kind == .permanent, !indexed.contains(failure.uid) { count += 1 }
        }
        return MLIndexCoverage(total: uniqueAssets.count, indexed: indexed.count, permanentlyUnindexable: permanent)
    }
}

/// Pure in-memory `MLIndexStore` for tests and ephemeral previews.
///
/// Production persistence is `SQLiteMLIndexStore`; this stays behind the same protocol so
/// Core logic tests need no filesystem. Thread-safe via `NSLock`, cheap to construct.
///
/// Not a cache: there is no size limit and no eviction. Hosts that want bounded memory
/// must layer that policy above the store.
public final class InMemoryMLIndexStore: MLIndexStore, @unchecked Sendable {
    private var recordsByDescriptor: [MLModelDescriptor: [PhotoUID: MLEmbeddingRecord]] = [:]
    private var failuresByDescriptor: [MLModelDescriptor: [PhotoUID: MLIndexFailureRecord]] = [:]
    private var generations: [MLModelDescriptor: UInt64] = [:]
    private let lock = NSLock()

    public init() {}

    @discardableResult
    public func upsert(_ records: [MLEmbeddingRecord]) -> MLIndexBatchReport {
        var indexed = 0
        var skipped = 0
        var rejected = 0

        lock.lock()
        defer { lock.unlock() }

        for record in records {
            guard record.isDimensionConsistent else {
                rejected += 1
                continue
            }
            // In-place mutation through the defaulted subscript: no bucket copy per record
            // (a take-mutate-put loop would CoW-copy the whole epoch on every insert).
            if recordsByDescriptor[record.descriptor, default: [:]][record.uid] != nil {
                // First-write-wins: the stored record and the "skipped" report agree.
                skipped += 1
            } else {
                recordsByDescriptor[record.descriptor, default: [:]][record.uid] = record
                generations[record.descriptor, default: 0] &+= 1
                indexed += 1
            }
            failuresByDescriptor[record.descriptor]?.removeValue(forKey: record.uid)
        }

        return MLIndexBatchReport(
            total: records.count,
            indexed: indexed,
            skippedAlreadyIndexed: skipped,
            permanentFailure: rejected
        )
    }

    public func contains(uid: PhotoUID, descriptor: MLModelDescriptor) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return recordsByDescriptor[descriptor]?[uid] != nil
    }

    public func indexedUIDs(for descriptor: MLModelDescriptor, from uids: [PhotoUID]) -> Set<PhotoUID> {
        lock.lock()
        defer { lock.unlock() }
        guard let bucket = recordsByDescriptor[descriptor] else { return [] }
        return Set(uids.filter { bucket[$0] != nil })
    }

    public func allIndexedUIDs(for descriptor: MLModelDescriptor) -> [PhotoUID] {
        lock.lock()
        defer { lock.unlock() }
        guard let bucket = recordsByDescriptor[descriptor] else { return [] }
        return bucket.keys.sorted(by: Self.uidOrder)
    }

    public func allTrackedUIDs(for descriptor: MLModelDescriptor) -> [PhotoUID] {
        lock.withLock {
            let indexed = recordsByDescriptor[descriptor].map { Set($0.keys) } ?? []
            let failed = failuresByDescriptor[descriptor].map { Set($0.keys) } ?? []
            return indexed.union(failed).sorted(by: Self.uidOrder)
        }
    }

    public func allRecords(for descriptor: MLModelDescriptor) -> [MLEmbeddingRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let bucket = recordsByDescriptor[descriptor] else { return [] }
        // Deterministic order (dictionary order is not): sort by uid, matching the
        // persistent store's key order.
        return bucket.values.sorted { Self.uidOrder($0.uid, $1.uid) }
    }

    public func remove(uid: PhotoUID, descriptor: MLModelDescriptor) {
        remove(uids: [uid], descriptor: descriptor)
    }

    public func remove(uids: [PhotoUID], descriptor: MLModelDescriptor) {
        guard !uids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var vectorsChanged = false
        for uid in Set(uids) {
            vectorsChanged = recordsByDescriptor[descriptor]?.removeValue(forKey: uid) != nil || vectorsChanged
            failuresByDescriptor[descriptor]?.removeValue(forKey: uid)
        }
        if vectorsChanged {
            generations[descriptor, default: 0] &+= 1
        }
    }

    public func removeAll(for descriptor: MLModelDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        let changed = recordsByDescriptor.removeValue(forKey: descriptor) != nil
        failuresByDescriptor.removeValue(forKey: descriptor)
        if changed { generations[descriptor, default: 0] &+= 1 }
    }

    public func count(for descriptor: MLModelDescriptor) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recordsByDescriptor[descriptor]?.count ?? 0
    }

    public func generation(for descriptor: MLModelDescriptor) -> UInt64 {
        lock.withLock { generations[descriptor] ?? 0 }
    }

    @discardableResult
    public func recordFailures(_ records: [MLIndexFailureRecord]) -> Bool {
        lock.withLock {
            for record in records where recordsByDescriptor[record.descriptor]?[record.uid] == nil {
                failuresByDescriptor[record.descriptor, default: [:]][record.uid] = record
            }
            return true
        }
    }

    public func failureRecords(
        for descriptor: MLModelDescriptor,
        from uids: [PhotoUID]
    ) -> [PhotoUID: MLIndexFailureRecord] {
        lock.withLock {
            guard let bucket = failuresByDescriptor[descriptor] else { return [:] }
            return Dictionary(uniqueKeysWithValues: uids.compactMap { uid in
                bucket[uid].map { (uid, $0) }
            })
        }
    }

    private static func uidOrder(_ a: PhotoUID, _ b: PhotoUID) -> Bool {
        a.volumeID != b.volumeID ? a.volumeID < b.volumeID : a.nodeID < b.nodeID
    }
}
