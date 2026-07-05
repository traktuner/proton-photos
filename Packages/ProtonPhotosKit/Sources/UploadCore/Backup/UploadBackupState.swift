import Foundation

/// Microsecond-quantized asset revision. Core stores revisions as integers so SQLite/user-default
/// round-trips cannot introduce floating-point drift.
public struct UploadBackupRevision: Sendable, Hashable, Comparable, Codable {
    public static let scale: Double = 1_000_000

    public let rawValue: Int64

    public init(rawValue: Int64) {
        self.rawValue = rawValue
    }

    public init(date: Date) {
        self.rawValue = Int64((date.timeIntervalSinceReferenceDate * Self.scale).rounded())
    }

    public var date: Date {
        Date(timeIntervalSinceReferenceDate: Double(rawValue) / Self.scale)
    }

    public static func < (lhs: UploadBackupRevision, rhs: UploadBackupRevision) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Optional edit evidence supplied by a platform adapter. PhotoKit can expose adjustment metadata;
/// file-system sources can usually use `.none`.
public enum UploadBackupEditRevision: Sendable, Equatable, Codable {
    /// The source has no separate edit/adjustment marker, so a cheap metadata revision drift can
    /// be treated as the same content after a previous successful backup.
    case none
    /// The source exposes a reliable content-edit revision.
    case revision(UploadBackupRevision)
    /// The adapter could not read reliable edit evidence. Core must not assume the asset is safe.
    case unavailable
}

/// One local logical asset seen by a future backup/sync source. A Live Photo still appears as one
/// asset with multiple resources; individual resource hashing/upload remains in `UploadDedupePipeline`.
public struct UploadBackupAssetSnapshot: Sendable, Equatable {
    public let source: UploadSourceIdentity
    public let revision: UploadBackupRevision
    public let editRevision: UploadBackupEditRevision
    public let resourceCount: Int

    public init(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        editRevision: UploadBackupEditRevision = .none,
        resourceCount: Int
    ) {
        precondition(resourceCount > 0, "Upload backup assets must expose at least one resource")
        self.source = source
        self.revision = revision
        self.editRevision = editRevision
        self.resourceCount = resourceCount
    }
}

/// Persisted backup/sync state for one source revision. `pendingResourceCount == 0` means every
/// resource of that asset revision is known to be represented in Proton Photos.
public struct UploadBackupAssetRecord: Sendable, Equatable {
    public var source: UploadSourceIdentity
    public var revision: UploadBackupRevision
    public var resourceCount: Int
    public var pendingResourceCount: Int
    public var updatedAt: Date

    public init(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        resourceCount: Int,
        pendingResourceCount: Int,
        updatedAt: Date
    ) {
        precondition(resourceCount > 0, "Upload backup records must expose at least one resource")
        precondition(pendingResourceCount >= 0, "Pending resource count cannot be negative")
        self.source = source
        self.revision = revision
        self.resourceCount = resourceCount
        self.pendingResourceCount = min(pendingResourceCount, resourceCount)
        self.updatedAt = updatedAt
    }

    public var isComplete: Bool { pendingResourceCount == 0 }
}

public protocol UploadBackupStateStore: Sendable {
    func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord?
    func hasAnyRecord(for source: UploadSourceIdentity) -> Bool
    func upsert(_ record: UploadBackupAssetRecord)
    func count() -> Int
}

public enum UploadBackupCheckDecision: Sendable, Equatable {
    public enum BackendCheckReason: Sendable, Equatable {
        /// The metadata revision changed and the adapter found a reliable edit marker that has
        /// never been backed up before.
        case unseenEditRevision
        /// The metadata revision changed, but the adapter could not read enough edit evidence to
        /// safely classify it locally.
        case unreliableEditRevision
    }

    case alreadyBackedUp
    case pendingUpload(remainingResources: Int)
    case newAsset
    case needsBackendCheck(BackendCheckReason)
}

/// Shared backup/sync safety net. Platform sources do only enumeration and metadata extraction;
/// this actor owns the cross-platform "should this asset be checked/uploaded?" decision.
public actor UploadBackupPreflightIndex {
    private let store: any UploadBackupStateStore
    private let now: @Sendable () -> Date

    public init(store: any UploadBackupStateStore, now: @Sendable @escaping () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public func classify(_ snapshot: UploadBackupAssetSnapshot) -> UploadBackupCheckDecision {
        if let direct = store.record(for: snapshot.source, revision: snapshot.revision) {
            return Self.decision(for: direct)
        }

        guard store.hasAnyRecord(for: snapshot.source) else {
            return .newAsset
        }

        switch snapshot.editRevision {
        case .none:
            // A known source without edit evidence is treated as metadata drift and seeded at the
            // current revision, so future scans are O(1) direct hits.
            markBackedUp(snapshot)
            return .alreadyBackedUp

        case let .revision(editRevision):
            guard let editRecord = store.record(for: snapshot.source, revision: editRevision) else {
                return .needsBackendCheck(.unseenEditRevision)
            }
            if editRecord.isComplete {
                markBackedUp(snapshot)
                return .alreadyBackedUp
            }
            return .pendingUpload(remainingResources: editRecord.pendingResourceCount)

        case .unavailable:
            return .needsBackendCheck(.unreliableEditRevision)
        }
    }

    public func markPending(_ snapshot: UploadBackupAssetSnapshot, pendingResourceCount: Int? = nil) {
        store.upsert(UploadBackupAssetRecord(
            source: snapshot.source,
            revision: snapshot.revision,
            resourceCount: snapshot.resourceCount,
            pendingResourceCount: pendingResourceCount ?? snapshot.resourceCount,
            updatedAt: now()
        ))
    }

    public func markBackedUp(_ snapshot: UploadBackupAssetSnapshot) {
        store.upsert(UploadBackupAssetRecord(
            source: snapshot.source,
            revision: snapshot.revision,
            resourceCount: snapshot.resourceCount,
            pendingResourceCount: 0,
            updatedAt: now()
        ))
    }

    private static func decision(for record: UploadBackupAssetRecord) -> UploadBackupCheckDecision {
        record.isComplete ? .alreadyBackedUp : .pendingUpload(remainingResources: record.pendingResourceCount)
    }
}
