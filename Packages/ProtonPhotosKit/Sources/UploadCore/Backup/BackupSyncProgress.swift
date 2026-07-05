import Foundation

/// UI-facing snapshot of one backup sync pass. Every count comes from the persistent queue, so
/// the snapshot can never claim more than the durable state proves. The wording contract for
/// consumers: `backedUp` is the only number that may be presented as "gesichert"; checking work
/// is "wird geprüft" (never "hashing"); `skippedRemoteDeletions`, `sourceMissing`, `blocked`, and
/// `failed` each get their own honest bucket instead of inflating success.
public struct BackupSyncProgress: Sendable, Equatable {
    public var total = 0
    /// Discovered/queued rows that no worker has picked up yet.
    public var waiting = 0
    /// Subset of `waiting` already past its duplicate check and waiting for bytes only.
    public var uploadQueued = 0
    /// In the pre-upload phase (resolve + hash + duplicate check) - "wird geprüft".
    public var checking = 0
    /// Pushing bytes right now - "wird gesichert".
    public var uploading = 0
    /// Uploaded by this app.
    public var uploaded = 0
    /// Confirmed as already present (active) in the Proton library without uploading bytes.
    public var alreadyBackedUp = 0
    /// The identical photo is in the Proton trash or was deleted remotely - respected, NOT backed up.
    public var skippedRemoteDeletions = 0
    /// The local source file disappeared before it could be backed up.
    public var sourceMissing = 0
    /// A remote draft occupies the name - re-checked later, NOT backed up.
    public var blocked = 0
    /// Retry budget exhausted - needs user attention.
    public var failed = 0
    public var paused = 0
    /// The file currently being processed, for "wird geprüft: IMG_0042.HEIC" style rows.
    public var currentItemName: String?
    /// True while a runner pass is draining the queue.
    public var isRunning = false
    /// True while the throttle policy holds the running pass at zero concurrency
    /// (e.g. critical thermal pressure) - "paused", not "working".
    public var isPausedByPolicy = false

    public init() {}

    /// The only number UI may call "backed up": proven uploads + proven active duplicates.
    public var backedUp: Int { uploaded + alreadyBackedUp }

    /// Rows this pass can no longer move: proven safe, deliberately skipped, gone, or parked
    /// failed. `blocked` is deliberately NOT settled - a draft retry is still pending, and a
    /// fraction that hits 1.0 with work outstanding would lie.
    public var settled: Int { backedUp + skippedRemoteDeletions + sourceMissing + failed }

    /// Honest progress: settled work over total. Stays below 1.0 while anything waits,
    /// runs, or is blocked on a draft re-check.
    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(settled) / Double(total)
    }

    /// Items the user should look at (parked failures + vanished sources).
    public var needsAttention: Int { failed + sourceMissing }

    public var hasOutstandingWork: Bool {
        waiting + checking + uploading + blocked > 0
    }

    /// Seeds the queue-derived counters from a summary; live fields stay as set by the runner.
    public init(summary: UploadBackupSyncQueueSummary, currentItemName: String? = nil, isRunning: Bool = false) {
        self.init()
        total = summary.total
        waiting = summary.waiting
        uploadQueued = summary.queuedForUpload
        checking = summary.checkingActive
        uploading = summary.uploadingActive
        uploaded = summary.uploaded
        alreadyBackedUp = summary.alreadyBackedUp
        skippedRemoteDeletions = summary.skippedRemoteDeletions
        sourceMissing = summary.sourceMissing
        blocked = summary.blocked
        failed = summary.failed
        paused = summary.paused
        self.currentItemName = currentItemName
        self.isRunning = isRunning
    }
}
