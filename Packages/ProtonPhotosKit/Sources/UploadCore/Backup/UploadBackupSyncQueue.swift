import Foundation

public enum UploadBackupSyncQueueState: String, Sendable, Codable, CaseIterable {
    case discovered
    case checking
    case hashing
    case duplicateChecking
    case queuedForUpload
    case uploading
    case finalizing
    case alreadyBackedUp
    case completed
    case sourceMissing
    case blockedByDraft
    case failed
    case paused

    public var isTerminalSuccess: Bool {
        self == .alreadyBackedUp || self == .completed
    }

    public var isTerminalFailure: Bool {
        self == .failed || self == .sourceMissing
    }

    public var isActive: Bool {
        switch self {
        case .checking, .hashing, .duplicateChecking, .uploading, .finalizing:
            return true
        default:
            return false
        }
    }

    public var isRunnable: Bool {
        switch self {
        case .discovered, .checking, .hashing, .duplicateChecking, .queuedForUpload:
            return true
        default:
            return false
        }
    }
}

public struct UploadBackupSyncQueueEntry: Sendable, Equatable {
    public var source: UploadSourceIdentity
    public var revision: UploadBackupRevision
    public var originalFilename: String
    public var byteCount: Int64?
    public var state: UploadBackupSyncQueueState
    public var attempts: Int
    public var lastError: String?
    public var updatedAt: Date

    public init(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        originalFilename: String,
        byteCount: Int64? = nil,
        state: UploadBackupSyncQueueState = .discovered,
        attempts: Int = 0,
        lastError: String? = nil,
        updatedAt: Date
    ) {
        self.source = source
        self.revision = revision
        self.originalFilename = originalFilename
        self.byteCount = byteCount
        self.state = state
        self.attempts = max(0, attempts)
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

public struct UploadBackupSyncQueueSummary: Sendable, Equatable {
    public var total = 0
    public var waiting = 0
    public var active = 0
    public var alreadyBackedUp = 0
    public var uploaded = 0
    public var sourceMissing = 0
    public var blocked = 0
    public var failed = 0
    public var paused = 0

    public init() {}

    public var resolved: Int {
        alreadyBackedUp + uploaded
    }

    public var progressFraction: Double {
        guard total > 0 else { return 0 }
        return Double(resolved) / Double(total)
    }

    public var hasWork: Bool {
        total > 0 && resolved < total
    }

    public mutating func include(_ state: UploadBackupSyncQueueState, count: Int = 1) {
        let count = max(0, count)
        total += count
        switch state {
        case .discovered, .queuedForUpload:
            waiting += count
        case .checking, .hashing, .duplicateChecking, .uploading, .finalizing:
            active += count
        case .alreadyBackedUp:
            alreadyBackedUp += count
        case .completed:
            uploaded += count
        case .sourceMissing:
            sourceMissing += count
        case .blockedByDraft:
            blocked += count
        case .failed:
            failed += count
        case .paused:
            paused += count
        }
    }
}

public protocol UploadBackupSyncQueueStore: Sendable {
    func upsert(_ entry: UploadBackupSyncQueueEntry)
    func entry(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupSyncQueueEntry?
    func nextRunnable(limit: Int) -> [UploadBackupSyncQueueEntry]
    @discardableResult
    func requeueStaleActive(before cutoff: Date, updatedAt: Date) -> Int
    func updateState(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        state: UploadBackupSyncQueueState,
        attempts: Int?,
        lastError: String?,
        updatedAt: Date
    )
    func summary() -> UploadBackupSyncQueueSummary
    func count() -> Int
}
