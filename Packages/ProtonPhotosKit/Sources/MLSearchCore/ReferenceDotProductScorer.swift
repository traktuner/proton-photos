import Foundation
import PhotosCore

/// Pure-Swift scoring kernel: reference implementation and test oracle.
///
/// The Apple adapter's `AccelerateVectorScorer` must agree with this kernel within Float
/// epsilon. Dot product is sufficient for CLIP-style normalized embeddings; cosine similarity
/// reduces to dot product after L2 normalization.
public struct ReferenceDotProductScorer: MLVectorScorer {
    public init() {}

    public func score(block: MLVectorBlock, query: ContiguousArray<Float32>, into scores: inout [Float32]) {
        let dimension = block.dimension
        block.withUnsafeStorage { matrix in
            query.withUnsafeBufferPointer { q in
                for row in 0..<block.count {
                    var sum: Float32 = 0
                    let base = row * dimension
                    for i in 0..<dimension {
                        sum += matrix[base + i] * q[i]
                    }
                    scores[row] = sum
                }
            }
        }
    }
}
