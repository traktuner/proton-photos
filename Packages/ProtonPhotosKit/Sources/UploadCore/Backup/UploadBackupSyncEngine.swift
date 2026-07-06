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

/// The per-candidate enqueue seam. A scan driver that owns its own loop (the photo catalog sync)
/// depends on this rather than the concrete engine, so its ordering guarantees are testable.
public protocol UploadBackupCandidateEnqueueing: Sendable {
    @discardableResult
    func enqueue(_ candidate: UploadBackupAssetCandidate) async -> UploadBackupSyncScanResult
}

public struct UploadBackupSyncScanResult: Sendable, Equatable {
    public var scanned = 0
    public var alreadyBackedUp = 0
    public var queuedForWork = 0
    public var pendingResources = 0
    public var backendChecksRequired = 0

    public init() {}

    /// Folds a per-candidate delta into a running total (used when the loop is driven externally).
    public mutating func merge(_ delta: UploadBackupSyncScanResult) {
        scanned += delta.scanned
        alreadyBackedUp += delta.alreadyBackedUp
        queuedForWork += delta.queuedForWork
        pendingResources += delta.pendingResources
        backendChecksRequired += delta.backendChecksRequired
    }
}

/// Shared sync scanner. Platform adapters enumerate assets; this actor owns the safe local
/// decision and persistent queue update so iOS/iPadOS/macOS never fork backup semantics.
public actor UploadBackupSyncEngine: UploadBackupCandidateEnqueueing {
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
            result.merge(await enqueue(candidate))
        }
        return result
    }

    /// Classifies ONE candidate against the preflight and durably records its queue row. The single
    /// safe decision + queue write, shared by `scan` and by callers that drive the loop themselves
    /// (the photo catalog sync interleaves this with its own persistence so the queue row is written
    /// BEFORE the catalog marks the asset seen). Returns the per-candidate result delta.
    @discardableResult
    public func enqueue(_ candidate: UploadBackupAssetCandidate) async -> UploadBackupSyncScanResult {
        var delta = UploadBackupSyncScanResult()
        delta.scanned = 1
        switch await preflight.classify(candidate.snapshot) {
        case .alreadyBackedUp:
            delta.alreadyBackedUp = 1
            queue.upsert(entry(for: candidate, state: .alreadyBackedUp))

        case let .pendingUpload(remainingResources):
            delta.pendingResources = remainingResources
            delta.queuedForWork = 1
            queue.upsert(entry(for: candidate, state: .queuedForUpload))

        case .newAsset:
            delta.queuedForWork = 1
            queue.upsert(entry(for: candidate, state: .discovered))

        case .needsBackendCheck:
            delta.backendChecksRequired = 1
            delta.queuedForWork = 1
            queue.upsert(entry(for: candidate, state: .checking))
        }
        return delta
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
