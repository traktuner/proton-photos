import Foundation

public struct UploadBackupAssetCandidate: Sendable, Equatable {
    public let snapshot: UploadBackupAssetSnapshot
    public let originalFilename: String
    public let byteCount: Int64?

    public init(snapshot: UploadBackupAssetSnapshot, originalFilename: String, byteCount: Int64? = nil) {
        self.snapshot = snapshot
        self.originalFilename = originalFilename
        self.byteCount = byteCount
    }
}

public protocol UploadBackupAssetCatalog: Sendable {
    func candidates() -> AsyncThrowingStream<UploadBackupAssetCandidate, any Error>
}

public struct UploadBackupSyncScanResult: Sendable, Equatable {
    public var scanned = 0
    public var alreadyBackedUp = 0
    public var queuedForWork = 0
    public var pendingResources = 0
    public var backendChecksRequired = 0

    public init() {}
}

/// Shared sync scanner. Platform adapters enumerate assets; this actor owns the safe local
/// decision and persistent queue update so iOS/iPadOS/macOS never fork backup semantics.
public actor UploadBackupSyncEngine {
    private let preflight: UploadBackupPreflightIndex
    private let queue: any UploadBackupSyncQueueStore
    private let now: @Sendable () -> Date

    public init(
        preflight: UploadBackupPreflightIndex,
        queue: any UploadBackupSyncQueueStore,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.preflight = preflight
        self.queue = queue
        self.now = now
    }

    public func scan(_ catalog: any UploadBackupAssetCatalog) async throws -> UploadBackupSyncScanResult {
        var result = UploadBackupSyncScanResult()
        for try await candidate in catalog.candidates() {
            try Task.checkCancellation()
            result.scanned += 1
            let decision = await preflight.classify(candidate.snapshot)
            switch decision {
            case .alreadyBackedUp:
                result.alreadyBackedUp += 1
                queue.upsert(entry(for: candidate, state: .alreadyBackedUp))

            case let .pendingUpload(remainingResources):
                result.pendingResources += remainingResources
                result.queuedForWork += 1
                queue.upsert(entry(for: candidate, state: .queuedForUpload))

            case .newAsset:
                result.queuedForWork += 1
                queue.upsert(entry(for: candidate, state: .discovered))

            case .needsBackendCheck:
                result.backendChecksRequired += 1
                result.queuedForWork += 1
                queue.upsert(entry(for: candidate, state: .checking))
            }
        }
        return result
    }

    public func markCompleted(_ candidate: UploadBackupAssetCandidate) async {
        await preflight.markBackedUp(candidate.snapshot)
        queue.upsert(entry(for: candidate, state: .completed))
    }

    public func markAlreadyBackedUp(_ candidate: UploadBackupAssetCandidate) async {
        await preflight.markBackedUp(candidate.snapshot)
        queue.upsert(entry(for: candidate, state: .alreadyBackedUp))
    }

    public func markFailed(_ candidate: UploadBackupAssetCandidate, message: String, attempts: Int) {
        var entry = entry(for: candidate, state: .failed)
        entry.attempts = max(0, attempts)
        entry.lastError = message
        queue.upsert(entry)
    }

    public func summary() -> UploadBackupSyncQueueSummary {
        queue.summary()
    }

    private func entry(
        for candidate: UploadBackupAssetCandidate,
        state: UploadBackupSyncQueueState
    ) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: candidate.snapshot.source,
            revision: candidate.snapshot.revision,
            originalFilename: candidate.originalFilename,
            byteCount: candidate.byteCount,
            state: state,
            updatedAt: now()
        )
    }
}
