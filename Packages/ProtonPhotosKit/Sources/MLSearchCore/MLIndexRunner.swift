import Foundation
import PhotosCore

/// Outcome of embedding one asset. The embedder (Apple adapter: pixels → CoreML on the
/// Neural Engine) classifies its own failures so the runner can schedule correctly:
/// permanent failures are never retried, transient ones re-enter the next pass.
public enum MLEmbeddingOutcome: Sendable {
    case embedded(ContiguousArray<Float32>)
    case permanentFailure(reason: String)
    case transientFailure
}

/// Produces an embedding for one asset. Implementations run off-main and own their pixel
/// source (decoded thumbnail) and model execution; Core never sees either.
public protocol MLAssetEmbedder: Sendable {
    func embed(uid: PhotoUID, descriptor: MLModelDescriptor) async -> MLEmbeddingOutcome
}

/// Result of one indexing pass.
public struct MLIndexPassOutcome: Sendable {
    /// Aggregated report over every processed chunk (partitions sum to processed inputs).
    public let report: MLIndexBatchReport
    /// `true` when the pass drained the plan; `false` when it stopped early (gate closed or
    /// task cancelled). A stopped pass is safe: every finished chunk is already persisted,
    /// so the next pass resumes from store state with no duplicates.
    public let ranToCompletion: Bool
    /// Assets the embedder declared permanently unindexable this pass. The caller feeds these
    /// into future `plan` calls (and persists them; durable failure storage is a later slice).
    public let newPermanentFailures: Set<PhotoUID>
    /// Progress snapshot at the end of the pass.
    public let progress: MLIndexProgress
}

/// Drives one model epoch from "assets known" to "assets embedded": plan → chunk →
/// embed (injected) → upsert (injected store) → report, with a durable commit per chunk.
///
/// ## Restart safety
/// The runner keeps no state of its own. Progress is derived from the store on every pass
/// (`MLIndexPlanner.plan` skips already-indexed assets), each chunk is upserted before the
/// next begins, and upserts are idempotent first-write-wins. An app kill, background
/// expiration, or gate stop between chunks loses at most one chunk of compute.
///
/// ## Gating
/// `shouldContinue` is consulted before every chunk. The host wires it to its scheduling
/// reality (thermal state, Low Power Mode, memory pressure, BG-task expiration, user pause) —
/// Core does not read platform signals. `Task` cancellation is honored at the same boundary.
///
/// ## Memory
/// Peak transient footprint is one chunk of embeddings (`chunkSize × dimension × 4 B`,
/// ~128 KiB at 64 × 512d) plus whatever the embedder holds for a single asset. Assets embed
/// sequentially: on-device the encoder saturates the ANE per image, so concurrency here would
/// only add memory, not throughput.
public actor MLIndexRunner {
    public struct Configuration: Sendable {
        /// Assets per durable commit. Smaller = finer resume granularity, more transactions.
        public var chunkSize: Int

        public init(chunkSize: Int = 64) {
            self.chunkSize = max(1, chunkSize)
        }
    }

    private let store: any MLIndexStore
    private let embedder: any MLAssetEmbedder
    private let configuration: Configuration
    private let shouldContinue: @Sendable () -> Bool
    private let onProgress: (@Sendable (MLIndexProgress) -> Void)?

    public init(
        store: any MLIndexStore,
        embedder: any MLAssetEmbedder,
        configuration: Configuration = Configuration(),
        shouldContinue: @escaping @Sendable () -> Bool = { true },
        onProgress: (@Sendable (MLIndexProgress) -> Void)? = nil
    ) {
        self.store = store
        self.embedder = embedder
        self.configuration = configuration
        self.shouldContinue = shouldContinue
        self.onProgress = onProgress
    }

    /// Run one catch-up pass for `descriptor` over the host's full asset set.
    ///
    /// Safe to call repeatedly (idempotent), safe to interrupt (chunk-durable), safe to run
    /// after a crash (plans from store state). Returns when the plan drains or the gate closes.
    public func runPass(
        allAssets: [PhotoUID],
        descriptor: MLModelDescriptor,
        permanentFailures: Set<PhotoUID> = []
    ) async -> MLIndexPassOutcome {
        let plan = MLIndexPlanner.plan(
            allAssets: allAssets,
            descriptor: descriptor,
            store: store,
            permanentFailures: permanentFailures
        )

        var progress = MLIndexProgress(
            phase: plan.isComplete ? .completed : .indexing,
            descriptor: descriptor,
            totalAssets: plan.totalAssets,
            alreadyIndexed: plan.skippedAlreadyIndexed.count,
            permanentFailure: plan.skippedPermanentFailure.count
        )
        onProgress?(progress)

        var aggregate = MLIndexBatchReport()
        var newPermanent: Set<PhotoUID> = []
        var completed = true

        for chunk in MLIndexPlanner.chunked(plan: plan, maxChunkSize: configuration.chunkSize) where !chunk.toIndex.isEmpty {
            guard shouldContinue(), !Task.isCancelled else {
                completed = false
                break
            }

            var records: [MLEmbeddingRecord] = []
            records.reserveCapacity(chunk.toIndex.count)
            var chunkPermanent = 0
            var chunkTransient = 0

            for uid in chunk.toIndex {
                switch await embedder.embed(uid: uid, descriptor: descriptor) {
                case .embedded(let vector):
                    records.append(MLEmbeddingRecord(uid: uid, descriptor: descriptor, vector: vector))
                case .permanentFailure:
                    newPermanent.insert(uid)
                    chunkPermanent += 1
                case .transientFailure:
                    chunkTransient += 1
                }
            }

            // Durable commit before the next chunk: this is the resume point.
            let stored = store.upsert(records)
            let chunkReport = MLIndexBatchReport(
                total: chunk.toIndex.count,
                indexed: stored.indexed,
                skippedAlreadyIndexed: stored.skippedAlreadyIndexed,
                permanentFailure: chunkPermanent + stored.permanentFailure,
                transientFailure: chunkTransient + stored.transientFailure
            )
            aggregate = aggregate.merge(chunkReport)
            progress.apply(chunkReport)
            onProgress?(progress)
        }

        if progress.phase == .indexing {
            // Honest state: the pass ended without epoch completion (gate stop, cancellation,
            // or transient failures pending retry). Never claim .completed here — the next
            // pass resumes from store state.
            progress.phase = .idle
        }
        onProgress?(progress)

        return MLIndexPassOutcome(
            report: aggregate,
            ranToCompletion: completed,
            newPermanentFailures: newPermanent,
            progress: progress
        )
    }
}
