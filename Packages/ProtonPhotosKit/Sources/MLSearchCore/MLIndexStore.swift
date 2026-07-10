import Foundation
import PhotosCore

/// The persistence boundary for ML embeddings.
///
/// `MLIndexStore` is the single contract every store implementation (in-memory for tests,
/// `SQLiteMLIndexStore` for production, eventually an encrypted Proton-synced shard) must
/// satisfy. Core owns the protocol; hosts pick the concrete persistence.
///
/// ## Idempotency contract
/// Every method is keyed by the composite `(PhotoUID, MLModelDescriptor)`. `upsert` is an
/// idempotent keyed write with **first-write-wins** semantics: storing the same
/// `(uid, descriptor)` twice keeps the first record and reports the second as skipped —
/// no duplicates, no silent overwrite. Records failing dimension validation are rejected
/// and counted as `permanentFailure`; report partitions always sum to `total`.
///
/// ## Batched-read/write seam
/// Methods accept and return collections rather than singletons so a SQLite implementation
/// can use a single transaction per batch without changing call sites.
///
/// ## Determinism
/// `allRecords`/`vectorBlock` row order must be deterministic for identical store state —
/// ranking ties break by row index, so a stable order makes search results reproducible.
///
/// ## Concurrency
/// Implementations must be `Sendable` and callable off the main actor. Synchronization is
/// implementation-specific (`NSLock`, actor, serialized SQLite handle) and must not leak
/// through the protocol.
public protocol MLIndexStore: Sendable {
    /// Insert embeddings for a single model epoch. Idempotent per `(uid, descriptor)`;
    /// first write wins. Dimension-mismatched records are rejected (`permanentFailure`).
    @discardableResult
    func upsert(_ records: [MLEmbeddingRecord]) -> MLIndexBatchReport

    /// `true` iff a record exists for `(uid, descriptor)`.
    func contains(uid: PhotoUID, descriptor: MLModelDescriptor) -> Bool

    /// Bulk membership check for a model epoch. Returns the subset of `uids` already indexed.
    /// Must not load vectors or scan other epochs.
    func indexedUIDs(for descriptor: MLModelDescriptor, from uids: [PhotoUID]) -> Set<PhotoUID>

    /// All UIDs indexed under a model epoch (used for coverage / eviction heuristics).
    func allIndexedUIDs(for descriptor: MLModelDescriptor) -> [PhotoUID]

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

    /// Drop every record for a model epoch (used when retiring a model version).
    func removeAll(for descriptor: MLModelDescriptor)

    /// Total record count for a model epoch.
    func count(for descriptor: MLModelDescriptor) -> Int
}

extension MLIndexStore {
    /// Default: build the block from `allRecords`. Persistent stores override this to stream
    /// rows straight from disk into the packed buffer without materializing records.
    public func vectorBlock(for descriptor: MLModelDescriptor) -> MLVectorBlock {
        MLVectorBlock(descriptor: descriptor, records: allRecords(for: descriptor))
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
                indexed += 1
            }
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

    public func allRecords(for descriptor: MLModelDescriptor) -> [MLEmbeddingRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard let bucket = recordsByDescriptor[descriptor] else { return [] }
        // Deterministic order (dictionary order is not): sort by uid, matching the
        // persistent store's key order.
        return bucket.values.sorted { Self.uidOrder($0.uid, $1.uid) }
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

    private static func uidOrder(_ a: PhotoUID, _ b: PhotoUID) -> Bool {
        a.volumeID != b.volumeID ? a.volumeID < b.volumeID : a.nodeID < b.nodeID
    }
}
