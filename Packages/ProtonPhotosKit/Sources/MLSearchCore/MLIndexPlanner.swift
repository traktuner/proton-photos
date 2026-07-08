import Foundation
import PhotosCore

/// Asset status that affects whether the planner schedules (re-)indexing.
///
/// - `needsIndexing`: default state — the asset has no usable embedding for the target model.
/// - `alreadyIndexed`: an embedding exists; the planner skips it (idempotency).
/// - `permanentFailure`: a prior attempt determined the asset can never be embedded (corrupt,
///   unsupported media type, unreadable). The planner excludes it from retries so a single
///   bad asset never blocks the rest of a batch.
/// - `transientFailure`: a prior attempt failed in a recoverable way (thermal, memory, I/O).
///   The planner reschedules it so a transient blip doesn't permanently drop the asset.
public enum MLAssetIndexStatus: Sendable, Equatable {
    case needsIndexing
    case alreadyIndexed
    case permanentFailure(reason: String)
    case transientFailure(attempts: Int)
}

/// A planned indexing unit: an asset UID and its scheduling status.
public struct MLPlannedAsset: Sendable, Equatable {
    public let uid: PhotoUID
    public let status: MLAssetIndexStatus
    
    public init(uid: PhotoUID, status: MLAssetIndexStatus) {
        self.uid = uid
        self.status = status
    }
    
    /// `true` when this asset will actually be sent to the embedder this pass.
    public var willIndex: Bool {
        switch status {
        case .needsIndexing, .transientFailure: return true
        case .alreadyIndexed, .permanentFailure: return false
        }
    }
}

/// The output of a planning pass.
///
/// Partitions an input asset set into:
/// - `toIndex`: assets that need embedding this pass (new + transient-failure retries).
/// - `skippedAlreadyIndexed`: assets with a valid embedding for the target model (idempotent skip).
/// - `skippedPermanentFailure`: assets excluded permanently (do not block others).
///
/// This is a pure value — the caller (an indexing actor) consumes it and turns `toIndex`
/// into `MLEmbeddingRecord`s via an injected embedder.
public struct MLIndexPlan: Sendable {
    public let descriptor: MLModelDescriptor
    public let toIndex: [PhotoUID]
    public let skippedAlreadyIndexed: [PhotoUID]
    public let skippedPermanentFailure: [PhotoUID]
    
    public init(descriptor: MLModelDescriptor, toIndex: [PhotoUID], skippedAlreadyIndexed: [PhotoUID], skippedPermanentFailure: [PhotoUID]) {
        self.descriptor = descriptor
        self.toIndex = toIndex
        self.skippedAlreadyIndexed = skippedAlreadyIndexed
        self.skippedPermanentFailure = skippedPermanentFailure
    }
    
    public var totalAssets: Int { toIndex.count + skippedAlreadyIndexed.count + skippedPermanentFailure.count }
    
    /// `true` when nothing remains to index for this model epoch.
    public var isComplete: Bool { toIndex.isEmpty }
}

/// Pure, side-effect-free index planner.
///
/// `MLIndexPlanner` computes, given the full set of known assets and the current store state
/// for a target model, exactly which assets need embedding this pass. It is the single source
/// of truth for idempotent scheduling: re-running it on the same inputs produces the same plan,
/// and once an asset is indexed it is never planned again (until the model version changes).
///
/// ## Complexity
/// `plan(...)` is **O(n)** over assets: one pass to partition, using a `Set` for the
/// already-indexed membership check (O(1) amortized). No sorting, no heap.
///
/// ## Chunking
/// `chunked(plan:maxChunkSize:)` splits a plan's `toIndex` into independent chunks so an
/// indexing actor can bound memory/CPU per pass without re-planning. Each chunk is a
/// standalone `MLIndexPlan` referencing the same model epoch.
public enum MLIndexPlanner {
    /// Partition `allAssets` into an idempotent plan for `descriptor`.
    ///
    /// - Parameters:
    ///   - allAssets: every asset UID known to the host (typically the timeline's complete set).
    ///   - descriptor: the target model epoch.
    ///   - store: the current index state.
    ///   - permanentFailures: assets previously marked permanently unindexable (carried across passes).
    /// - Returns: a plan where `toIndex` excludes already-indexed and permanent-failure assets.
    public static func plan(
        allAssets: [PhotoUID],
        descriptor: MLModelDescriptor,
        store: MLIndexStore,
        permanentFailures: Set<PhotoUID> = []
    ) -> MLIndexPlan {
        // Single O(n) pass: build the indexed set once, then partition.
        let indexedSet = store.indexedUIDs(for: descriptor, from: allAssets)
        
        var toIndex: [PhotoUID] = []
        var skippedIndexed: [PhotoUID] = []
        var skippedPermanent: [PhotoUID] = []
        toIndex.reserveCapacity(allAssets.count)
        skippedIndexed.reserveCapacity(allAssets.count)
        skippedPermanent.reserveCapacity(allAssets.count)
        
        for uid in allAssets {
            if permanentFailures.contains(uid) {
                skippedPermanent.append(uid)
            } else if indexedSet.contains(uid) {
                skippedIndexed.append(uid)
            } else {
                toIndex.append(uid)
            }
        }
        
        return MLIndexPlan(
            descriptor: descriptor,
            toIndex: toIndex,
            skippedAlreadyIndexed: skippedIndexed,
            skippedPermanentFailure: skippedPermanent
        )
    }
    
    /// Split a plan's `toIndex` work into chunks of at most `maxChunkSize` assets.
    ///
    /// Preserves input order. Returns the skipped sets unchanged on every chunk's plan so
    /// progress aggregation stays simple. An empty `toIndex` yields a single empty chunk so
    /// callers can always iterate.
    public static func chunked(plan: MLIndexPlan, maxChunkSize: Int) -> [MLIndexPlan] {
        precondition(maxChunkSize > 0, "maxChunkSize must be > 0")
        if plan.toIndex.isEmpty {
            return [plan]
        }
        var chunks: [MLIndexPlan] = []
        chunks.reserveCapacity((plan.toIndex.count + maxChunkSize - 1) / maxChunkSize)
        var idx = 0
        while idx < plan.toIndex.count {
            let end = min(idx + maxChunkSize, plan.toIndex.count)
            let slice = Array(plan.toIndex[idx..<end])
            chunks.append(MLIndexPlan(
                descriptor: plan.descriptor,
                toIndex: slice,
                skippedAlreadyIndexed: plan.skippedAlreadyIndexed,
                skippedPermanentFailure: plan.skippedPermanentFailure
            ))
            idx = end
        }
        return chunks
    }
}
