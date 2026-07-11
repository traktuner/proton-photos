import Foundation
import PhotosCore

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

/// O(n), side-effect-free planner for idempotent model-epoch indexing.
public enum MLIndexPlanner {
    /// Partition `allAssets` into an idempotent plan for `descriptor`.
    ///
    /// - Parameters:
    ///   - allAssets: every asset UID known to the host (typically the timeline's complete set).
    ///   - descriptor: the target model epoch.
    ///   - store: the current index state.
    /// - Returns: a plan where `toIndex` excludes already-indexed and permanent-failure assets.
    public static func plan(
        allAssets: [PhotoUID],
        descriptor: MLModelDescriptor,
        store: MLIndexStore
    ) -> MLIndexPlan {
        // Single O(n) pass: build the indexed set once, then partition.
        let indexedSet = store.indexedUIDs(for: descriptor, from: allAssets)
        let storedFailures = store.failureRecords(for: descriptor, from: allAssets)
        
        let permanentCount = storedFailures.values.reduce(into: 0) { count, failure in
            if failure.kind == .permanent { count += 1 }
        }
        var seen: Set<PhotoUID> = []
        seen.reserveCapacity(allAssets.count)
        var toIndex: [PhotoUID] = []
        var skippedIndexed: [PhotoUID] = []
        var skippedPermanent: [PhotoUID] = []
        toIndex.reserveCapacity(max(0, allAssets.count - indexedSet.count - permanentCount))
        skippedIndexed.reserveCapacity(indexedSet.count)
        skippedPermanent.reserveCapacity(permanentCount)
        
        for uid in allAssets where seen.insert(uid).inserted {
            if storedFailures[uid]?.kind == .permanent {
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
}
