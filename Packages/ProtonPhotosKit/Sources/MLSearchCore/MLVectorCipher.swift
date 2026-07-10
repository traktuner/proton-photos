import Foundation
import PhotosCore

public struct MLVectorCipherContext: Sendable, Equatable {
    public let uid: PhotoUID
    public let descriptor: MLModelDescriptor

    public init(uid: PhotoUID, descriptor: MLModelDescriptor) {
        self.uid = uid
        self.descriptor = descriptor
    }
}

/// Authenticated-encryption boundary for persistent embedding vectors.
///
/// Core owns the requirement; platform adapters provide the implementation and key material.
/// The SQLite store has no plaintext fallback.
public protocol MLVectorCipher: Sendable {
    func seal(_ plaintext: Data, context: MLVectorCipherContext) throws -> Data
    func open(_ ciphertext: Data, context: MLVectorCipherContext) throws -> Data
    /// Exact ciphertext size for a plaintext of the given size, or `nil` when the scheme is
    /// not length-deterministic. Stores use it to reject wrong-sized rows BEFORE spending a
    /// decryption on them (corrupt/truncated blobs fail fast and cheap).
    func sealedByteCount(forPlaintextByteCount plaintextByteCount: Int) -> Int?
}

extension MLVectorCipher {
    public func sealedByteCount(forPlaintextByteCount plaintextByteCount: Int) -> Int? { nil }
}
