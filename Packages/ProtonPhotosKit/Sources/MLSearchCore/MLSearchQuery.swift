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

    public init(uid: PhotoUID, score: Float) {
        self.uid = uid
        self.score = score
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

/// Scoring kernel: dot products of one query against every row of a packed block.
///
/// Implementations provide ONLY the arithmetic — pure Swift loop (reference) or one
/// vDSP matrix-vector call over the whole block (Apple adapter). Ranking, top-k selection,
/// and result assembly live once in Core (`rank(block:query:limit:)`) so every kernel shares
/// identical, tested semantics including the deterministic tie-break.
public protocol MLVectorScorer: Sendable {
    /// Write `block.count` dot products into `scores`. The caller guarantees
    /// `scores.count == block.count` and `query.count == block.dimension`.
    func score(block: MLVectorBlock, query: ContiguousArray<Float32>, into scores: inout [Float32])
}

extension MLVectorScorer {
    /// Rank a block's rows by similarity to `query`, highest score first.
    ///
    /// Deterministic: identical block + query always produce the identical result order.
    /// Ties break by ascending row index; the block's row order is store-defined and stable.
    /// Selection is O(n log k) via a bounded min-heap — no full sort and no second n-sized
    /// result buffer. A query/block dimension mismatch returns empty results (defensive:
    /// the caller picked the wrong epoch).
    public func rank(
        block: MLVectorBlock,
        query: ContiguousArray<Float32>,
        limit: Int,
        queryText: String = ""
    ) -> MLSearchResults {
        guard limit > 0, block.count > 0, query.count == block.dimension else {
            return MLSearchResults(descriptor: block.descriptor, queryText: queryText, results: [])
        }
        var scores = [Float32](repeating: 0, count: block.count)
        score(block: block, query: query, into: &scores)
        let top = MLTopKSelector.select(scores: scores, limit: limit)
        let results = top.map { MLSearchResult(uid: block.uids[$0.row], score: $0.score) }
        return MLSearchResults(descriptor: block.descriptor, queryText: queryText, results: results)
    }
}

/// Bounded top-k selection over a score buffer.
///
/// Min-heap of at most `limit` entries keyed by (score asc, row desc) so the weakest kept
/// entry sits at the root and is evicted first. O(n log k) time, O(k) memory — at 250k rows
/// with limit 50 this avoids sorting (and allocating result values for) the entire library.
enum MLTopKSelector {
    struct Entry: Equatable {
        let score: Float32
        let row: Int
    }

    /// Returns the top `limit` entries ordered (score desc, row asc).
    static func select(scores: [Float32], limit: Int) -> [Entry] {
        let k = min(limit, scores.count)
        guard k > 0 else { return [] }

        // `a` is weaker than `b` if it scores lower, or scores equal with a higher row index
        // (row asc wins ties). heap[0] is always the weakest kept entry.
        func isWeaker(_ a: Entry, _ b: Entry) -> Bool {
            a.score != b.score ? a.score < b.score : a.row > b.row
        }

        var heap: [Entry] = []
        heap.reserveCapacity(k)

        func siftDown(from start: Int) {
            var parent = start
            while true {
                let left = 2 * parent + 1
                let right = left + 1
                var weakest = parent
                if left < heap.count, isWeaker(heap[left], heap[weakest]) { weakest = left }
                if right < heap.count, isWeaker(heap[right], heap[weakest]) { weakest = right }
                if weakest == parent { return }
                heap.swapAt(parent, weakest)
                parent = weakest
            }
        }

        func siftUp(from start: Int) {
            var child = start
            while child > 0 {
                let parent = (child - 1) / 2
                guard isWeaker(heap[child], heap[parent]) else { return }
                heap.swapAt(child, parent)
                child = parent
            }
        }

        for row in scores.indices {
            let candidate = Entry(score: scores[row], row: row)
            if heap.count < k {
                heap.append(candidate)
                siftUp(from: heap.count - 1)
            } else if isWeaker(heap[0], candidate) {
                heap[0] = candidate
                siftDown(from: 0)
            }
        }

        heap.sort { isWeaker($1, $0) }
        return heap
    }
}
