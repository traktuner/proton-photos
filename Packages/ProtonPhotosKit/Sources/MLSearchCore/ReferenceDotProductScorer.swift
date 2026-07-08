import Foundation
import PhotosCore

/// Pure-Swift dot-product scorer used as the reference implementation and fallback.
///
/// The Apple adapter provides an Accelerate-backed alternative. Both conform to `MLVectorScorer`
/// so Core remains agnostic. Dot product is sufficient for CLIP-style normalized embeddings;
/// cosine similarity reduces to dot product after L2 normalization.
public struct ReferenceDotProductScorer: MLVectorScorer {
    public init() {}
    
    public func rank(records: [MLEmbeddingRecord], queryVector: ContiguousArray<Float32>, limit: Int) -> MLSearchResults {
        var scored: [(uid: PhotoUID, score: Float, timestamp: Date)] = []
        scored.reserveCapacity(records.count)
        
        // Compute dot products. This is O(n * d) with minimal heap churn (single output buffer).
        for record in records {
            guard record.vector.count == queryVector.count else { continue }
            let score = computeDotProduct(record.vector, queryVector)
            scored.append((record.uid, score, record.timestamp))
        }
        
        // Sort: highest score first; ties broken by newest-first (stable).
        scored.sort { (a, b) in
            if a.score != b.score { return a.score > b.score }
            return a.timestamp > b.timestamp
        }
        
        let top = Array(scored.prefix(limit)).map { MLSearchResult(uid: $0.uid, score: $0.score, timestamp: $0.timestamp) }
        return MLSearchResults(descriptor: records.first?.descriptor ?? MLModelDescriptor(identifier: "unknown", version: 0, embeddingDimension: queryVector.count), queryText: "", results: top)
    }
    
    private func computeDotProduct(_ a: ContiguousArray<Float32>, _ b: ContiguousArray<Float32>) -> Float {
        precondition(a.count == b.count, "Vector mismatch: \(a.count) vs \(b.count)")
        var sum: Float = 0
        for i in 0..<a.count {
            sum += a[i] * b[i]
        }
        return sum
    }
}
