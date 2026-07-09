import Foundation
import Accelerate
import MLSearchCore

/// Accelerate-backed scoring kernel — the production scorer.
///
/// One `vDSP_mmul` matrix-vector multiply covers the entire packed block
/// (`count × dimension` · `dimension × 1`), instead of N separate dot-product calls.
/// That is the memory-bandwidth-optimal shape on Apple silicon (AMX/NEON backed) and the
/// reason `MLVectorBlock` exists: at 250k × 512-d this is a single pass over one contiguous
/// buffer with zero per-record overhead.
///
/// Ranking/top-k live in Core (`MLVectorScorer.rank`); this type supplies arithmetic only
/// and must agree with `ReferenceDotProductScorer` within Float epsilon (test-enforced).
public struct AccelerateVectorScorer: MLVectorScorer {
    public init() {}

    public func score(block: MLVectorBlock, query: ContiguousArray<Float32>, into scores: inout [Float32]) {
        let rows = block.count
        let dimension = block.dimension
        guard rows > 0, dimension > 0, query.count == dimension, scores.count == rows else { return }

        block.withUnsafeStorage { matrix in
            query.withUnsafeBufferPointer { q in
                scores.withUnsafeMutableBufferPointer { out in
                    guard let a = matrix.baseAddress, let x = q.baseAddress, let y = out.baseAddress else { return }
                    // C(rows×1) = A(rows×dimension) · B(dimension×1), all row-major.
                    vDSP_mmul(a, 1, x, 1, y, 1, vDSP_Length(rows), 1, vDSP_Length(dimension))
                }
            }
        }
    }
}
