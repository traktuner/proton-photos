import Foundation
import PhotosCore

/// The persistence boundary for ML embeddings.
///
/// `MLIndexStore` is the single contract every store implementation (in-memory for tests,
/// SQLite in Stage 1B, eventually an encrypted Proton-synced shard) must satisfy. Core owns
/// the protocol; adapters/hosts own concrete persistence.
///
/// ## Idempotency contract
/// Every method is keyed by the composite `(PhotoUID, MLModelDescriptor)`. `upsert` is an
/// idempotent keyed write: storing the same `(uid, descriptor)` twice produces exactly one
/// record — no duplicates, no append-only growth. `contains` checks the same key.
///
/// ## Batched-read/write seam
/// Methods accept and return collections rather than singletons so a SQLite implementation
/// can use a single transaction per batch without changing call sites. The in-memory store
/// satisfies the same shape trivially.
///
/// ## Concurrency
/// Implementations must be `Sendable`. Synchronization strategy is implementation-specific
/// (`NSLock`, actor, or serialized SQLite queue) and must not leak through the protocol.
public protocol MLIndexStore: Sendable {
    /// Insert/replace embeddings for a single model epoch. Idempotent per `(uid, descriptor)`.
    /// Records whose dimension mismatches `descriptor.embeddingDimension` are rejected.
    @discardableResult
    func upsert(_ records: [MLEmbeddingRecord]) -> MLIndexBatchReport
    
    /// `true` iff a record exists for `(uid, descriptor)`.
    func contains(uid: PhotoUID, descriptor: MLModelDescriptor) -> Bool
    
    /// Bulk membership check for a model epoch. Returns the subset of `uids` already indexed.
    func indexedUIDs(for descriptor: MLModelDescriptor, from uids: [PhotoUID]) -> Set<PhotoUID>
    
    /// All UIDs indexed under a model epoch (used for coverage / eviction heuristics).
    func allIndexedUIDs(for descriptor: MLModelDescriptor) -> [PhotoUID]
    
    /// All embeddings for a model epoch, in insertion order. Used by the scorer.
    /// Returns a value type so callers can iterate without holding the store's lock.
    func allRecords(for descriptor: MLModelDescriptor) -> [MLEmbeddingRecord]
    
    /// Remove all records for `(uid, descriptor)` — used when an asset is deleted or re-indexed
    /// after a transient failure.
    func remove(uid: PhotoUID, descriptor: MLModelDescriptor)
    
    /// Drop every record for a model epoch (used when retiring a model version).
    func removeAll(for descriptor: MLModelDescriptor)
    
    /// Total record count for a model epoch.
    func count(for descriptor: MLModelDescriptor) -> Int
}

/// Pure in-memory `MLIndexStore` for tests and ephemeral previews.
///
/// This is the Stage-1 default store: no SQLite, no migrations, no app-DB impact. A real
/// persistent store replaces it in Stage 1B behind the same protocol. It is thread-safe via
/// an `OSAllocatedUnfairLock`-style `NSLock` and cheap to construct.
///
/// Not a cache: there is no size limit and no eviction. Hosts that want bounded memory
/// must layer that policy above the store (e.g. an LRU actor wrapping a persistent store).
public final class InMemoryMLIndexStore: MLIndexStore, @unchecked Sendable {
    // Keyed by descriptor, then by uid. ContiguousArray keeps per-vector heap churn low
    // compared to [Float] (one contiguous allocation, no CoW indirection on reads).
    private var recordsByDescriptor: [MLModelDescriptor: [PhotoUID: MLEmbeddingRecord]] = [:]
    private let lock = NSLock()
    
    public init() {}
    
    @discardableResult
    public func upsert(_ records: [MLEmbeddingRecord]) -> MLIndexBatchReport {
        var indexed = 0
        var skipped = 0
        
        lock.lock()
        defer { lock.unlock() }
        
        for record in records {
            guard record.vector.count == record.descriptor.embeddingDimension else { continue }
            var bucket = recordsByDescriptor[record.descriptor] ?? [:]
            // First-write-wins idempotency: a record already present for (uid, descriptor) is
            // kept as-is and reported as skipped. This matches the planner's assumption that
            // an indexed asset is never re-embedded in the same epoch, and makes the report
            // ("skippedAlreadyIndexed") and the stored data agree.
            if bucket[record.uid] != nil {
                skipped += 1
            } else {
                bucket[record.uid] = record
                indexed += 1
            }
            recordsByDescriptor[record.descriptor] = bucket
        }
        
        return MLIndexBatchReport(total: records.count, indexed: indexed, skippedAlreadyIndexed: skipped)
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
        return Array(bucket.keys)
    }
    
    public func allRecords(for descriptor: MLModelDescriptor) -> [MLEmbeddingRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let bucket = recordsByDescriptor[descriptor] else { return [] }
        return Array(bucket.values)
    }
    
    public func remove(uid: PhotoUID, descriptor: MLModelDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        recordsByDescriptor[descriptor]?.removeValue(forKey: uid)
    }
    
    public func removeAll(for descriptor: MLModelDescriptor) {
        lock.lock()
        defer { lock.unlock() }
        recordsByDescriptor.removeValue(forKey: descriptor)
    }
    
    public func count(for descriptor: MLModelDescriptor) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return recordsByDescriptor[descriptor]?.count ?? 0
    }
}
