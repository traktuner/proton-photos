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
    func enqueue(_ candidate: UploadBackupAssetCandidate) async throws -> UploadBackupSyncScanResult
    @discardableResult
    func enqueueBatch(_ candidates: [UploadBackupAssetCandidate]) async throws -> UploadBackupSyncScanResult
}

public extension UploadBackupCandidateEnqueueing {
    func enqueueBatch(_ candidates: [UploadBackupAssetCandidate]) async throws -> UploadBackupSyncScanResult {
        var result = UploadBackupSyncScanResult()
        for candidate in candidates {
            result.merge(try await enqueue(candidate))
        }
        return result
    }
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
    private let remoteProofResolver: (any UploadIdentityResolving)?
    private let now: @Sendable () -> Date

    public init(
        preflight: UploadBackupPreflightIndex,
        queue: any UploadBackupSyncQueueStore,
        remoteProofResolver: (any UploadIdentityResolving)? = nil,
        now: @Sendable @escaping () -> Date = { Date() }
    ) {
        self.preflight = preflight
        self.queue = queue
        self.remoteProofResolver = remoteProofResolver
        self.now = now
    }

    public func scan(_ catalog: any UploadBackupAssetCatalog) async throws -> UploadBackupSyncScanResult {
        var result = UploadBackupSyncScanResult()
        for try await candidate in catalog.candidates() {
            try Task.checkCancellation()
            result.merge(try await enqueue(candidate))
        }
        return result
    }

    /// Classifies ONE candidate against the preflight and durably records its queue row. The single
    /// safe decision + queue write, shared by `scan` and by callers that drive the loop themselves
    /// (the photo catalog sync interleaves this with its own persistence so the queue row is written
    /// BEFORE the catalog marks the asset seen). Returns the per-candidate result delta.
    @discardableResult
    public func enqueue(_ candidate: UploadBackupAssetCandidate) async throws -> UploadBackupSyncScanResult {
        try await enqueueBatch([candidate])
    }

    public func enqueueBatch(_ candidates: [UploadBackupAssetCandidate]) async throws -> UploadBackupSyncScanResult {
        guard !candidates.isEmpty else { return UploadBackupSyncScanResult() }
        var decisions = try await preflight.classifyBatch(candidates.map(\.snapshot))
        guard decisions.count == candidates.count else {
            throw UploadError.backend("Backup preflight classification was incomplete")
        }

        // A trusted external identity can prove an existing active remote compound before any
        // original bytes are requested. This is optional: a missing, stale, or unavailable remote
        // proof falls through to the normal SHA-1 + Proton duplicate path.
        if let remoteProofResolver {
            let identities: [UploadBackupExternalIdentity] = candidates.indices.compactMap { index -> UploadBackupExternalIdentity? in
                guard decisions[index] != .alreadyBackedUp else { return nil }
                return candidates[index].snapshot.externalIdentity
            }
            if !identities.isEmpty {
                let proofs: [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord]
                do {
                    proofs = try await remoteProofResolver.remoteAssetProofs(for: identities)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    proofs = [:]
                }
                if !proofs.isEmpty {
                    var provenSnapshots: [UploadBackupAssetSnapshot] = []
                    for index in candidates.indices {
                        guard decisions[index] != .alreadyBackedUp,
                              let identity = candidates[index].snapshot.externalIdentity,
                              let proof = proofs[identity],
                              proof.externalIdentity == identity,
                              proof.resourceCount == candidates[index].snapshot.resourceCount else {
                            continue
                        }
                        decisions[index] = .alreadyBackedUp
                        provenSnapshots.append(candidates[index].snapshot)
                    }
                    try await preflight.markBackedUpBatch(provenSnapshots)
                }
            }
        }
        var result = UploadBackupSyncScanResult()
        var entries: [UploadBackupSyncQueueEntry] = []
        entries.reserveCapacity(candidates.count)
        for (candidate, decision) in zip(candidates, decisions) {
            let prepared = prepare(candidate, decision: decision)
            result.merge(prepared.delta)
            entries.append(prepared.entry)
        }
        guard queue.upsertBatch(entries) else {
            throw UploadError.backend("Backup queue could not persist an asset batch")
        }
        return result
    }

    private func prepare(
        _ candidate: UploadBackupAssetCandidate,
        decision: UploadBackupCheckDecision
    ) -> (delta: UploadBackupSyncScanResult, entry: UploadBackupSyncQueueEntry) {
        var delta = UploadBackupSyncScanResult()
        delta.scanned = 1
        let state: UploadBackupSyncQueueState
        switch decision {
        case .alreadyBackedUp:
            delta.alreadyBackedUp = 1
            state = .alreadyBackedUp

        case let .pendingUpload(remainingResources):
            delta.pendingResources = remainingResources
            delta.queuedForWork = 1
            state = .queuedForUpload

        case .newAsset:
            delta.queuedForWork = 1
            state = .discovered

        case .needsBackendCheck:
            delta.backendChecksRequired = 1
            delta.queuedForWork = 1
            state = .checking
        }
        return (delta, entry(for: candidate, state: state))
    }

    public func markCompleted(_ candidate: UploadBackupAssetCandidate) async throws {
        try await preflight.markBackedUp(candidate.snapshot)
        guard queue.upsert(entry(for: candidate, state: .completed)) else {
            throw UploadError.backend("Backup queue could not persist completion")
        }
    }

    public func markAlreadyBackedUp(_ candidate: UploadBackupAssetCandidate) async throws {
        try await preflight.markBackedUp(candidate.snapshot)
        guard queue.upsert(entry(for: candidate, state: .alreadyBackedUp)) else {
            throw UploadError.backend("Backup queue could not persist duplicate completion")
        }
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
