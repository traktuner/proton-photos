import Foundation
import PhotosCore

/// A semantic search query over one model epoch.
///
/// Core only receives an opaque `queryText` string; the caller injects an adapter that
/// transforms text into a floating-point embedding matching `descriptor.embeddingDimension`.
/// This keeps Core pure: it never touches CoreML/Vision/NaturalLanguage, it only ranks
/// by dot-product over already-indexed vectors.
public struct MLSearchQuery: Sendable, Equatable {
    public let descriptor: MLModelDescriptor
    public let queryText: String
    public let limit: Int
    
    public init(descriptor: MLModelDescriptor, queryText: String, limit: Int = 50) {
        self.descriptor = descriptor
        self.queryText = queryText
        self.limit = limit
    }
}

/// A single ranked result from a semantic search.
public struct MLSearchResult: Sendable, Equatable {
    public let uid: PhotoUID
    public let score: Float
    public let timestamp: Date
    
    public init(uid: PhotoUID, score: Float, timestamp: Date) {
        self.uid = uid
        self.score = score
        self.timestamp = timestamp
    }
}

/// A collection of ranked results.
public struct MLSearchResults: Sendable, Equatable {
    public let descriptor: MLModelDescriptor
    public let queryText: String
    public let results: [MLSearchResult]
    public let durationMs: Double?
    
    public init(descriptor: MLModelDescriptor, queryText: String, results: [MLSearchResult], durationMs: Double? = nil) {
        self.descriptor = descriptor
        self.queryText = queryText
        self.results = results
        self.durationMs = durationMs
    }
    
    public var isEmpty: Bool { results.isEmpty }
    public var count: Int { results.count }
    
    /// Top-N slice without allocating a new array if the caller requests <= what's present.
    public func top(_ n: Int) -> MLSearchResults {
        guard n < results.count else { return self }
        return MLSearchResults(
            descriptor: descriptor,
            queryText: queryText,
            results: Array(results.prefix(n)),
            durationMs: durationMs
        )
    }
}

/// Contract for scoring a query embedding over indexed assets.
///
/// Implementations may be pure Swift (dot product over contiguous arrays), Accelerate-backed
/// (`vDSP_dotpr`), or delegate to a hardware-accelerated search index. The protocol ensures
/// Core remains vendor-agnostic while the Apple adapter provides the optimized path.
///
/// ## Determinism requirement
/// Given the same query vector and the same index state, `rank(query:)` must return results
/// in the same order. Ties are broken by stable metadata (e.g. ascending `timestamp`, then
/// descending score) — the implementation defines the tie-breaker.
public protocol MLVectorScorer: Sendable {
    /// Rank indexed embeddings by similarity to `queryVector`.
    ///
    /// - Parameters:
    ///   - records: the full set of embeddings for a model epoch (owned by a `MLIndexStore`).
    ///   - queryVector: a floating-point vector whose dimensionality matches the descriptor.
    ///   - limit: maximum number of results to emit.
    /// - Returns: a sorted results collection, highest score first.
    func rank(records: [MLEmbeddingRecord], queryVector: ContiguousArray<Float32>, limit: Int) -> MLSearchResults
}
