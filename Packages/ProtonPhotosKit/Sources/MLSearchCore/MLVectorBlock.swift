import Foundation
import PhotosCore

/// Storage precision of a persisted embedding vector. Persisted per row so further precisions
/// (int8) can be added without schema churn; readers skip precisions they don't understand.
public enum MLEmbeddingPrecision: String, Sendable {
    case float32 = "f32"
    /// IEEE-754 binary16 rows — the production storage format (half the disk and I/O of f32;
    /// normalized CLIP-family vectors lose ~2^-11 relative precision, far below ranking noise).
    case float16 = "f16"
}

/// A packed, query-ready matrix of embeddings for one model epoch.
///
/// This is the memory representation the scorer works on: **one** contiguous row-major
/// `Float32` buffer (`count × dimension`) plus a parallel `uids` array. Compared to
/// `[MLEmbeddingRecord]` this removes the per-record heap allocation, `Date`, and descriptor
/// duplication from the hot path — at 250k × 512-d the block is a single ~512 MB buffer
/// instead of 250k separate arrays, and it is the shape a single BLAS matrix-vector call needs.
///
/// Row order is defined by the producing store and must be deterministic for identical store
/// state (SQLite orders by key; the in-memory store sorts). Ranking ties break by row index,
/// so deterministic row order gives deterministic results.
public struct MLVectorBlock: Sendable {
    public let descriptor: MLModelDescriptor
    public private(set) var uids: [PhotoUID]
    // Row-major `count × dimension`. Kept private so the invariant
    // `storage.count == uids.count * dimension` cannot be broken from outside.
    private var storage: ContiguousArray<Float32>

    public var count: Int { uids.count }
    public var dimension: Int { descriptor.embeddingDimension }
    public var isEmpty: Bool { uids.isEmpty }

    public init(descriptor: MLModelDescriptor) {
        self.descriptor = descriptor
        self.uids = []
        self.storage = []
    }

    /// Convenience for tests and the default store path.
    public init(descriptor: MLModelDescriptor, records: [MLEmbeddingRecord]) {
        self.init(descriptor: descriptor)
        reserveCapacity(records.count)
        for record in records where record.descriptor == descriptor {
            append(uid: record.uid, vector: record.vector)
        }
    }

    public mutating func reserveCapacity(_ rows: Int) {
        uids.reserveCapacity(rows)
        storage.reserveCapacity(rows * dimension)
    }

    /// Append one row. Rejects (returns `false`) instead of trapping on a dimension mismatch
    /// so a corrupt persisted row degrades to "not searchable" rather than a crash.
    @discardableResult
    public mutating func append(uid: PhotoUID, vector: ContiguousArray<Float32>) -> Bool {
        guard vector.count == dimension else { return false }
        uids.append(uid)
        storage.append(contentsOf: vector)
        return true
    }

    /// Append one row from raw little-endian `Float32` bytes (legacy blob format).
    /// Avoids materializing an intermediate `ContiguousArray` when streaming from disk.
    @discardableResult
    public mutating func append(uid: PhotoUID, rawLittleEndianFloat32 bytes: UnsafeRawBufferPointer) -> Bool {
        guard bytes.count == dimension * MemoryLayout<Float32>.size else { return false }
        uids.append(uid)
        // Apple platforms are little-endian; the blob is the native memory layout.
        storage.append(contentsOf: bytes.bindMemory(to: Float32.self))
        return true
    }

    /// Append one row from raw little-endian binary16 bytes (the persisted blob format),
    /// widening straight into the packed `Float32` scoring buffer — one pass, no intermediate
    /// array, so loading a large epoch stays a single streamed conversion.
    @discardableResult
    public mutating func append(uid: PhotoUID, rawLittleEndianFloat16 bytes: UnsafeRawBufferPointer) -> Bool {
        guard bytes.count == dimension * MLFloat16Codec.bytesPerElement else { return false }
        uids.append(uid)
        storage.reserveCapacity(storage.count + dimension)
        for index in 0..<dimension {
            let bits = UInt16(littleEndian: bytes.loadUnaligned(
                fromByteOffset: index * MLFloat16Codec.bytesPerElement,
                as: UInt16.self
            ))
            storage.append(MLFloat16Codec.float32(fromBits: bits))
        }
        return true
    }

    /// Expose the packed buffer to a scoring kernel without copying.
    public func withUnsafeStorage<R>(_ body: (UnsafeBufferPointer<Float32>) throws -> R) rethrows -> R {
        try storage.withUnsafeBufferPointer(body)
    }
}
