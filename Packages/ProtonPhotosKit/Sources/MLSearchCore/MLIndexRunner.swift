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
    /// Assets newly persisted as permanently unindexable this pass.
    public let newPermanentFailures: Set<PhotoUID>
    /// Progress snapshot at the end of the pass.
    public let progress: MLIndexProgress

    /// Coverage derived from the pass partition. This avoids a second full membership query
    /// after the planner already classified every asset.
    public var coverage: MLIndexCoverage {
        MLIndexCoverage(
            total: progress.totalAssets,
            indexed: progress.indexed + progress.alreadyIndexed,
            permanentlyUnindexable: progress.permanentFailure
        )
    }
}

/// Chunk-durable, idempotent indexing runner. Platform scheduling enters through
/// `shouldContinue`; Core never reads thermal, power or background state directly.
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
    private let now: @Sendable () -> Date

    public init(
        store: any MLIndexStore,
        embedder: any MLAssetEmbedder,
        configuration: Configuration = Configuration(),
        shouldContinue: @escaping @Sendable () -> Bool = { true },
        onProgress: (@Sendable (MLIndexProgress) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.embedder = embedder
        self.configuration = configuration
        self.shouldContinue = shouldContinue
        self.onProgress = onProgress
        self.now = now
    }

    /// Run one catch-up pass for `descriptor` over the host's full asset set.
    ///
    /// Safe to call repeatedly (idempotent), safe to interrupt (chunk-durable), safe to run
    /// after a crash (plans from store state). Returns when the plan drains or the gate closes.
    public func runPass(
        allAssets: [PhotoUID],
        descriptor: MLModelDescriptor
    ) async -> MLIndexPassOutcome {
        let plan = MLIndexPlanner.plan(
            allAssets: allAssets,
            descriptor: descriptor,
            store: store
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
        var chunkStart = 0

        while chunkStart < plan.toIndex.count {
            let chunkEnd = min(chunkStart + configuration.chunkSize, plan.toIndex.count)
            let chunk = plan.toIndex[chunkStart..<chunkEnd]
            chunkStart = chunkEnd
            var records: [MLEmbeddingRecord] = []
            var failureRecords: [MLIndexFailureRecord] = []
            var chunkPermanentUIDs: Set<PhotoUID> = []
            records.reserveCapacity(chunk.count)
            failureRecords.reserveCapacity(chunk.count)
            var chunkPermanent = 0
            var chunkTransient = 0
            var processedCount = 0
            var stopAfterCommit = false

            for uid in chunk {
                guard shouldContinue(), !Task.isCancelled else {
                    completed = false
                    stopAfterCommit = true
                    break
                }

                let outcome = await embedder.embed(uid: uid, descriptor: descriptor)
                processedCount += 1
                switch outcome {
                case .embedded(let vector):
                    guard vector.count == descriptor.embeddingDimension,
                          let normalized = MLVectorNormalization.normalized(vector) else {
                        chunkPermanentUIDs.insert(uid)
                        chunkPermanent += 1
                        failureRecords.append(MLIndexFailureRecord(
                            uid: uid,
                            descriptor: descriptor,
                            kind: .permanent,
                            reason: "invalid embedding",
                            attempts: 1,
                            updatedAt: now()
                        ))
                        continue
                    }
                    records.append(MLEmbeddingRecord(uid: uid, descriptor: descriptor, vector: normalized))
                case .permanentFailure(let reason):
                    chunkPermanentUIDs.insert(uid)
                    chunkPermanent += 1
                    failureRecords.append(MLIndexFailureRecord(
                        uid: uid,
                        descriptor: descriptor,
                        kind: .permanent,
                        reason: reason,
                        attempts: 1,
                        updatedAt: now()
                    ))
                case .transientFailure:
                    chunkTransient += 1
                    // Cache misses and temporary resource pressure are expected during the
                    // initial crawl. They stay pending in the pass result; persisting them
                    // would turn every retry into a large write-only SQLite workload.
                }
                // Cancellation may arrive while CoreML is executing. Persist this completed
                // asset, then return without starting another inference.
                if Task.isCancelled {
                    completed = false
                    stopAfterCommit = true
                    break
                }
            }

            guard processedCount > 0 else { break }

            // Durable commit before the next chunk: this is the resume point.
            let stored = store.upsert(records)
            let failuresPersisted = store.recordFailures(failureRecords)
            if failuresPersisted {
                newPermanent.formUnion(chunkPermanentUIDs)
            } else {
                completed = false
            }
            let chunkReport = MLIndexBatchReport(
                total: processedCount,
                indexed: stored.indexed,
                skippedAlreadyIndexed: stored.skippedAlreadyIndexed,
                permanentFailure: (failuresPersisted ? chunkPermanent : 0) + stored.permanentFailure,
                transientFailure: chunkTransient
                    + (failuresPersisted ? 0 : failureRecords.count)
                    + stored.transientFailure
            )
            aggregate = aggregate.merge(chunkReport)
            progress.apply(chunkReport)
            onProgress?(progress)

            if stopAfterCommit { break }
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
