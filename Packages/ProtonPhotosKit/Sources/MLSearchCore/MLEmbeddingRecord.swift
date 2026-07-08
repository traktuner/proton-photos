import Foundation
import PhotosCore

/// One stored embedding for a single asset, indexed by model + asset.
///
/// The composite key `(PhotoUID, MLModelDescriptor)` guarantees that:
/// 1. A new model (different `descriptor.identifier/version`) creates an entirely new epoch of records.
/// 2. The same asset under the same model cannot be indexed twice (idempotent upsert).
/// 3. Vector dimensions are validated at write-time via `MLIndexStore`.
///
/// `timestamp` reflects when the embedding was computed on this device and may be used for
/// eviction heuristics (oldest-first) when the store grows beyond capacity. The timestamp does
/// *not* imply freshness of the underlying image data — that is the caller's responsibility.
public struct MLEmbeddingRecord: Hashable, Sendable {
    public let uid: PhotoUID
    public let descriptor: MLModelDescriptor
    public let vector: ContiguousArray<Float32>
    public let timestamp: Date
    
    public init(uid: PhotoUID, descriptor: MLModelDescriptor, vector: ContiguousArray<Float32>, timestamp: Date = Date.now) {
        precondition(vector.count == descriptor.embeddingDimension, "Vector dimension \(vector.count) != expected \(descriptor.embeddingDimension)")
        self.uid = uid
        self.descriptor = descriptor
        self.vector = vector
        self.timestamp = timestamp
    }
    
    /// Dimensionality shorthand (matches `descriptor.embeddingDimension`).
    public var dimension: Int { descriptor.embeddingDimension }
}

/// Lightweight status report after indexing a batch of assets.
///
/// `indexed` / `skippedAlreadyIndexed` / `permanentFailure` / `transientFailure` partition every
/// input `PhotoUID` exhaustively. The caller can aggregate multiple reports across batches to
/// drive the overall `MLIndexProgress` shown in the UI. Transient failures are eligible for retry
/// without invalidating already-indexed assets.
public struct MLIndexBatchReport: Sendable {
    public let total: Int
    public let indexed: Int
    public let skippedAlreadyIndexed: Int
    public let permanentFailure: Int
    public let transientFailure: Int
    
    public init(total: Int = 0, indexed: Int = 0, skippedAlreadyIndexed: Int = 0, permanentFailure: Int = 0, transientFailure: Int = 0) {
        self.total = total
        self.indexed = indexed
        self.skippedAlreadyIndexed = skippedAlreadyIndexed
        self.permanentFailure = permanentFailure
        self.transientFailure = transientFailure
    }
    
    /// All inputs handled deterministically (no pending retries).
    public var settled: Bool { transientFailure == 0 }
    
    public func merge(_ other: MLIndexBatchReport) -> MLIndexBatchReport {
        MLIndexBatchReport(
            total: total + other.total,
            indexed: indexed + other.indexed,
            skippedAlreadyIndexed: skippedAlreadyIndexed + other.skippedAlreadyIndexed,
            permanentFailure: permanentFailure + other.permanentFailure,
            transientFailure: transientFailure + other.transientFailure
        )
    }
}
