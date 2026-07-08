import Foundation
import Accelerate
import MLSearchCore

/// Accelerate-backed implementation of `MLVectorScorer`.
///
/// Uses `vDSP.dot` (which wraps `vDSP_dotpr`) for the dot product — a single BLAS call per
/// vector pair that avoids per-element heap churn compared to a manual loop. This is the
/// production scorer; the pure-Swift `ReferenceDotProductScorer` in Core is the reference
/// fallback and test oracle.
///
/// ## Performance notes
/// - **No per-vector allocation**: `withUnsafeBufferPointer` exposes the underlying storage
///   of `ContiguousArray` directly to vDSP without copying.
/// - **Single sort pass**: scores accumulate into one `[MLSearchResult]` buffer; sort happens once.
/// - **Dimension guard**: vectors of mismatched dimension are skipped (defensive).
public struct AccelerateVectorScorer: MLVectorScorer {
    public init() {}
    
    public func rank(records: [MLEmbeddingRecord], queryVector: ContiguousArray<Float32>, limit: Int) -> MLSearchResults {
        var scored: [MLSearchResult] = []
        scored.reserveCapacity(records.count)
        
        // Snapshot the query vector's dimension once.
        let queryDim = queryVector.count
        guard queryDim > 0 else {
            return MLSearchResults(
                descriptor: records.first?.descriptor ?? MLModelDescriptor(identifier: "unknown", version: 0, embeddingDimension: 0),
                queryText: "",
                results: []
            )
        }
        
        for record in records {
            guard record.vector.count == queryDim else { continue }
            
            let score = computeDotProduct(record.vector, queryVector)
            scored.append(MLSearchResult(uid: record.uid, score: score, timestamp: record.timestamp))
        }
        
        // Sort: highest score first; ties broken by newest-first (deterministic).
        scored.sort { (a, b) in
            if a.score != b.score { return a.score > b.score }
            return a.timestamp > b.timestamp
        }
        
        let top = Array(scored.prefix(limit))
        return MLSearchResults(
            descriptor: records.first?.descriptor ?? MLModelDescriptor(identifier: "unknown", version: 0, embeddingDimension: queryDim),
            queryText: "",
            results: top
        )
    }
    
    /// `vDSP_dotpr` over two `ContiguousArray<Float32>` — zero-copy via unsafe buffer pointer.
    private func computeDotProduct(_ a: ContiguousArray<Float32>, _ b: ContiguousArray<Float32>) -> Float {
        precondition(a.count == b.count, "Vector mismatch: \(a.count) vs \(b.count)")
        // Empty vectors yield a zero dot product without invoking vDSP (which would receive a
        // nil baseAddress for a zero-length ContiguousArray — safe to guard explicitly).
        guard a.count > 0 else { return 0 }
        var result: Float = 0
        a.withUnsafeBufferPointer { aBuf in
            b.withUnsafeBufferPointer { bBuf in
                guard let aBase = aBuf.baseAddress, let bBase = bBuf.baseAddress else { return }
                vDSP_dotpr(aBase, 1, bBase, 1, &result, vDSP_Length(a.count))
            }
        }
        return result
    }
}
