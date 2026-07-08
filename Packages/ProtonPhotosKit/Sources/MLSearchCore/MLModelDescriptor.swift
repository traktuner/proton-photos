import Foundation

/// Metadata describing a shippable embedding model.
///
/// `MLModelDescriptor` is the pure Core value that identifies *which* model produced an
/// embedding epoch. It is the unit of index invalidation: when `identifier` or `version`
/// changes, every existing embedding is stale and a new epoch must begin.
///
/// Keeping this type in Core (not in the Apple adapter) means a macOS host and an iOS host
/// agree on epoch identity without importing CoreML. The adapter only resolves a descriptor
/// to a concrete `.mlmodelc` URL — that lookup is the platform concern, never the identity.
public struct MLModelDescriptor: Hashable, Sendable, Codable {
    /// Stable, human-readable model name (e.g. `"mobileclip-s0"`). Must not encode a version.
    public let identifier: String
    /// Monotonically increasing model version. A bump forces a full re-index epoch.
    public let version: Int
    /// Embedding dimensionality the model emits. Index records must agree with this.
    public let embeddingDimension: Int
    /// A short, display-safe label suitable for diagnostics (`"mobileclip-s0 v3 (512d)"`).
    public var displayName: String { "\(identifier) v\(version) (\(embeddingDimension)d)" }

    public init(identifier: String, version: Int, embeddingDimension: Int) {
        self.identifier = identifier
        self.version = version
        self.embeddingDimension = embeddingDimension
    }
}

extension MLModelDescriptor: Comparable {
    public static func < (lhs: MLModelDescriptor, rhs: MLModelDescriptor) -> Bool {
        if lhs.identifier != rhs.identifier { return lhs.identifier < rhs.identifier }
        return lhs.version < rhs.version
    }
}
