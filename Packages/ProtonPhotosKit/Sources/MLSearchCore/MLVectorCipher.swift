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
}
