import Foundation
import PhotosCore

public enum MLIndexFailureKind: String, Sendable, Codable {
    case transient
    case permanent
}

public struct MLIndexFailureRecord: Sendable, Equatable {
    public let uid: PhotoUID
    public let descriptor: MLModelDescriptor
    public let kind: MLIndexFailureKind
    public let reason: String?
    public let attempts: Int
    public let updatedAt: Date

    public init(
        uid: PhotoUID,
        descriptor: MLModelDescriptor,
        kind: MLIndexFailureKind,
        reason: String? = nil,
        attempts: Int,
        updatedAt: Date = Date()
    ) {
        self.uid = uid
        self.descriptor = descriptor
        self.kind = kind
        self.reason = reason
        self.attempts = max(1, attempts)
        self.updatedAt = updatedAt
    }
}

public struct MLIndexCoverage: Sendable, Equatable {
    public let total: Int
    public let indexed: Int
    public let permanentlyUnindexable: Int

    public init(total: Int, indexed: Int, permanentlyUnindexable: Int) {
        self.total = max(0, total)
        self.indexed = max(0, min(indexed, self.total))
        self.permanentlyUnindexable = max(0, min(permanentlyUnindexable, self.total - self.indexed))
    }

    public var pending: Int { max(0, total - indexed - permanentlyUnindexable) }
    public var searchableFraction: Double { total > 0 ? Double(indexed) / Double(total) : 0 }
    public var accountedFraction: Double {
        total > 0 ? Double(indexed + permanentlyUnindexable) / Double(total) : 0
    }
    public var isComplete: Bool { pending == 0 }
}

public enum MLVectorNormalization {
    public static func normalized(_ vector: ContiguousArray<Float32>) -> ContiguousArray<Float32>? {
        guard !vector.isEmpty else { return nil }
        var sum: Float32 = 0
        for value in vector {
            guard value.isFinite else { return nil }
            sum += value * value
        }
        guard sum.isFinite, sum > 0 else { return nil }
        let inverseMagnitude = 1 / sum.squareRoot()
        return ContiguousArray(vector.map { $0 * inverseMagnitude })
    }
}
