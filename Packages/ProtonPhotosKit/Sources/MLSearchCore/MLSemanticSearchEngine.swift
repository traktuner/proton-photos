import Foundation
import PhotosCore

public protocol MLTextQueryEncoder: Sendable {
    func encode(text: String, descriptor: MLModelDescriptor) async throws -> ContiguousArray<Float32>
}

public enum MLSemanticSearchError: Error, Equatable {
    case emptyQuery
    case invalidQueryEmbedding
    case queryDimensionMismatch(expected: Int, actual: Int)
}

/// Shared semantic query path for every host platform.
///
/// The engine owns query normalization, index snapshot reuse and deterministic ranking. CoreML
/// model execution and Accelerate arithmetic remain injected adapters, so iOS, iPadOS and macOS
/// cannot diverge in search semantics.
public actor MLSemanticSearchEngine {
    private struct CachedBlock {
        let descriptor: MLModelDescriptor
        let generation: UInt64
        let block: MLVectorBlock
    }

    private let store: any MLIndexStore
    private let encoder: any MLTextQueryEncoder
    private let scorer: any MLVectorScorer
    // A 512-dimensional Float32 block costs roughly 2 KiB per asset. Keep one active model
    // epoch only so switching descriptors cannot retain hundreds of MiB from an old model.
    private var cachedBlock: CachedBlock?

    public init(store: any MLIndexStore, encoder: any MLTextQueryEncoder, scorer: any MLVectorScorer) {
        self.store = store
        self.encoder = encoder
        self.scorer = scorer
    }

    public func search(_ query: MLSearchQuery) async throws -> MLSearchResults {
        let text = query.queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MLSemanticSearchError.emptyQuery }

        let raw = try await encoder.encode(text: text, descriptor: query.descriptor)
        guard raw.count == query.descriptor.embeddingDimension else {
            throw MLSemanticSearchError.queryDimensionMismatch(
                expected: query.descriptor.embeddingDimension,
                actual: raw.count
            )
        }
        guard let normalized = MLVectorNormalization.normalized(raw) else {
            throw MLSemanticSearchError.invalidQueryEmbedding
        }

        let startedAt = ContinuousClock.now
        let block = currentBlock(for: query.descriptor)
        var results = scorer.rank(block: block, query: normalized, limit: query.limit, queryText: text)
        let duration = ContinuousClock.now - startedAt
        results = MLSearchResults(
            descriptor: results.descriptor,
            queryText: results.queryText,
            results: results.results,
            durationMs: Double(duration.components.seconds) * 1_000
                + Double(duration.components.attoseconds) / 1_000_000_000_000_000
        )
        return results
    }

    public func coverage(for descriptor: MLModelDescriptor, allAssets: [PhotoUID]) -> MLIndexCoverage {
        store.coverage(for: descriptor, allAssets: allAssets)
    }

    public func purgeCachedBlocks() {
        cachedBlock = nil
    }

    private func currentBlock(for descriptor: MLModelDescriptor) -> MLVectorBlock {
        let generation = store.generation(for: descriptor)
        if let cached = cachedBlock,
           cached.descriptor == descriptor,
           cached.generation == generation {
            return cached.block
        }

        // Release the old storage before materializing its replacement. Assignment after the
        // load would briefly double the query cache's peak memory on large libraries.
        cachedBlock = nil
        let block = store.vectorBlock(for: descriptor)
        cachedBlock = CachedBlock(descriptor: descriptor, generation: generation, block: block)
        return block
    }
}
