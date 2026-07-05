import Foundation
import PhotosCore

/// THE user-facing backup/sync state surface, shared by every platform. Derived purely from the
/// durable queue progress (or the manual upload queue's preparation aggregate) plus a
/// platform-provided "scanning" flag - it holds no state of its own and invents nothing:
/// when the total is unknown the fraction is nil (indeterminate), and "uploading" is claimed
/// ONLY while bytes actually move.
///
/// Wording contract (single source, keys in the shared PhotosCore catalog):
/// checking work is "Backup-Status wird geprüft" / "Checking backup status" - never "hashing",
/// never "uploading"; `backedUp` is the only count presented as safe.
public struct BackupStatus: Sendable, Equatable {

    public enum Phase: String, Sendable, Equatable {
        /// Nothing to do and nothing known - a calm resting state.
        case idle
        /// Enumerating folders/assets. Totals are still growing - indeterminate by design.
        case scanning
        /// Proving items already backed up (streamed identity + duplicate check).
        case checking
        /// Bytes are moving.
        case uploading
        /// A running pass is held by policy (thermal/power) or items are user-paused.
        case paused
        /// Work remains but nothing runs right now (interrupted pass, draft re-checks pending).
        case waiting
        /// Everything considered is settled and nothing failed.
        case completed
        /// Some items exhausted their retries - recoverable, user-visible.
        case needsAttention
    }

    public var phase: Phase = .idle
    /// Items considered so far. `nil` while scanning - any total would be a lie mid-enumeration.
    public var totalConsidered: Int?
    /// Items whose backup-status check finished (whatever the outcome).
    public var checked = 0
    public var alreadyBackedUp = 0
    /// Checked items waiting for their bytes to upload.
    public var uploadQueued = 0
    public var uploaded = 0
    public var failed = 0
    /// Respected remote deletions (trash/deleted) - never counted as backed up.
    public var skippedRemoteDeletions = 0
    /// Local files that disappeared before backup.
    public var sourceMissing = 0
    /// Items parked for a later re-check (remote draft backoff).
    public var waitingRetry = 0
    public var currentItemName: String?
    /// Honest progress; `nil` = indeterminate (unknown total or nothing measurable).
    public var fractionCompleted: Double?

    public init() {}

    /// The only number UI may call "backed up".
    public var backedUp: Int { uploaded + alreadyBackedUp }
    public var needsAttentionCount: Int { failed + sourceMissing }
    public var isActive: Bool {
        phase == .scanning || phase == .checking || phase == .uploading
    }

    // MARK: - Derivation from the folder/asset backup queue

    public init(progress: BackupSyncProgress, isScanning: Bool) {
        self.init()
        checked = progress.uploaded + progress.alreadyBackedUp + progress.skippedRemoteDeletions
            + progress.failed + progress.sourceMissing + progress.blocked + progress.uploadQueued
        alreadyBackedUp = progress.alreadyBackedUp
        uploadQueued = progress.uploadQueued
        uploaded = progress.uploaded
        failed = progress.failed
        skippedRemoteDeletions = progress.skippedRemoteDeletions
        sourceMissing = progress.sourceMissing
        waitingRetry = progress.blocked
        currentItemName = progress.currentItemName

        if isScanning {
            phase = .scanning
            totalConsidered = nil
            fractionCompleted = nil
            return
        }

        totalConsidered = progress.total
        fractionCompleted = progress.total > 0 ? progress.fraction : nil

        if progress.isRunning {
            if progress.isPausedByPolicy {
                phase = .paused
            } else if progress.uploading > 0 {
                phase = .uploading
            } else {
                phase = .checking
            }
        } else if progress.failed > 0 {
            phase = .needsAttention
        } else if progress.waiting + progress.checking + progress.uploading + progress.blocked > 0 {
            phase = .waiting
        } else if progress.total > 0 {
            phase = .completed
        } else {
            phase = .idle
        }
    }

    // MARK: - Derivation from the manual upload queue's pre-upload check

    /// Maps the manual upload queue's "checking before upload" aggregate onto the same phases and
    /// wording. The preparation aggregate cannot distinguish byte-upload from post-check work, so
    /// this surface deliberately never claims `.uploading` - the upload queue panel owns that.
    public init(manualUploadCheck status: UploadPreparationStatus) {
        self.init()
        totalConsidered = status.hasItems ? status.total : 0
        checked = status.resolved
        alreadyBackedUp = status.skippedDuplicates
        skippedRemoteDeletions = status.skippedRemoteDeletions
        failed = status.failed
        fractionCompleted = status.hasItems ? status.progressFraction : nil

        if !status.hasItems {
            phase = .idle
        } else if status.isRunning {
            phase = .checking
        } else if status.failed > 0 {
            phase = .needsAttention
        } else if status.paused > 0 {
            phase = .paused
        } else {
            phase = .completed
        }
    }

    // MARK: - Shared wording (one source for macOS/iOS/iPadOS)

    /// Stable catalog key for the phase headline - exposed so tests can pin wording honesty
    /// (checking is never the uploading key) without compiled string catalogs.
    public var titleKey: String {
        switch phase {
        case .idle: "backup.phase_idle"
        case .scanning: "backup.phase_scanning"
        case .checking: "backup.phase_checking"
        case .uploading: "backup.phase_uploading"
        case .paused: "backup.phase_paused"
        case .waiting: "backup.phase_waiting"
        case .completed: "backup.phase_completed"
        case .needsAttention: "backup.phase_attention"
        }
    }

    public var localizedTitle: String {
        switch phase {
        case .idle: L10n.string("backup.phase_idle")
        case .scanning: L10n.string("backup.phase_scanning")
        case .checking: L10n.string("backup.phase_checking")
        case .uploading: L10n.string("backup.phase_uploading")
        case .paused: L10n.string("backup.phase_paused")
        case .waiting: L10n.string("backup.phase_waiting")
        case .completed: L10n.string("backup.phase_completed")
        case .needsAttention: L10n.string("backup.phase_attention")
        }
    }

    /// One calm supporting line per phase; nil when the headline says it all.
    public var localizedDetail: String? {
        switch phase {
        case .idle, .scanning, .paused:
            return nil
        case .checking:
            guard let total = totalConsidered, total > 0 else { return currentItemName }
            return L10n.string("backup.detail_checked \(checked) \(total)")
        case .uploading:
            guard let total = totalConsidered, total > 0 else { return nil }
            return L10n.string("backup.detail_backed_up \(backedUp) \(total)")
        case .waiting:
            return L10n.string("backup.detail_waiting \(uploadQueued + waitingRetry + max(0, (totalConsidered ?? 0) - checked))")
        case .completed:
            guard alreadyBackedUp > 0 else { return nil }
            return L10n.string("backup.detail_already_backed_up \(alreadyBackedUp)")
        case .needsAttention:
            return L10n.string("backup.detail_attention \(needsAttentionCount)")
        }
    }
}
