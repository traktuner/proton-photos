import Foundation
import PhotosCore

/// Platform-neutral display projection of `BackupStatus` for the backup status row. ONE mapping so
/// iOS and macOS render the exact same thing - a compact, honest row instead of per-platform ad-hoc
/// stacks of lines.
///
/// The row is at most: an icon, a headline (the phase), one subtitle line, and a progress bar.
/// Design contract:
/// - The headline tells the truth about the phase, and the single distinction that MUST always be
///   right is checking vs uploading. It is driven by whether bytes are ACTUALLY moving
///   (`uploadingItemName`), never by a count heuristic - so it can never claim "backing up" while it
///   is only hashing/checking, nor hide a real upload behind "checking".
/// - The subtitle is one line: "<backed up> of <total>", and ONLY while a real byte transfer is in
///   flight it appends the current file's upload percentage ("· 43 %"). No filename is ever shown -
///   a filename next to "backing up" reads as a promise the item is safe when it is only mid-check.
/// - A separate attention line appears only when something actually needs the user.
///
/// This is pure and time-free; iOS layers `BackupStatusStabilizer` on top for dwell so the headline
/// does not strobe as the phase flips many times a second during a fast drain.
public struct BackupStatusPresentation: Sendable, Equatable {

    /// The single activity treatment for the row's one icon (there is never a second spinner).
    public enum Accessory: String, Sendable, Equatable {
        case idle
        case activity
        case success
        case attention
        case paused
    }

    /// Stable phase key, used both for the headline text and by the stabilizer's dwell.
    public var headlineKey: String
    /// True while a run is active - drives the one spinning icon.
    public var isActive: Bool
    public var accessory: Accessory
    /// Determinate overall fraction (settled/total), or nil = indeterminate (scanning) / none.
    public var progressFraction: Double?

    // Subtitle inputs kept raw so the localized strings are compiler-checked, not built from a
    // dynamic key. `backedUp`/`total` render "<n> of <m>"; `uploadPercent` is non-nil ONLY while a
    // real transfer is moving; `attentionCount` drives the optional attention line.
    public var backedUp: Int
    public var total: Int
    public var uploadPercent: Int?
    public var attentionCount: Int

    public init(
        headlineKey: String,
        isActive: Bool,
        accessory: Accessory,
        progressFraction: Double?,
        backedUp: Int = 0,
        total: Int = 0,
        uploadPercent: Int? = nil,
        attentionCount: Int = 0
    ) {
        self.headlineKey = headlineKey
        self.isActive = isActive
        self.accessory = accessory
        self.progressFraction = progressFraction
        self.backedUp = backedUp
        self.total = total
        self.uploadPercent = uploadPercent
        self.attentionCount = attentionCount
    }

    // MARK: - Mapping from the shared status

    public init(_ status: BackupStatus) {
        let uploadingNow = status.uploadingItemName != nil
        let percent = uploadingNow
            ? status.uploadingFraction.map { max(0, min(100, Int(($0 * 100).rounded()))) }
            : nil

        switch status.phase {
        case .scanning:
            self.init(headlineKey: "backup.phase_scanning", isActive: true, accessory: .activity,
                      progressFraction: nil, backedUp: status.backedUp, total: status.totalConsidered ?? 0)

        case .checking, .uploading:
            // The one distinction that must always be right: bytes actually moving => "backing up".
            // No attention line mid-run - failures self-heal on the next pass; only the terminal
            // needsAttention state surfaces what genuinely couldn't be backed up.
            self.init(headlineKey: uploadingNow ? "backup.phase_uploading" : "backup.phase_checking",
                      isActive: true, accessory: .activity,
                      progressFraction: status.fractionCompleted,
                      backedUp: status.backedUp, total: status.totalConsidered ?? 0,
                      uploadPercent: percent)

        case .paused:
            self.init(headlineKey: "backup.phase_paused", isActive: false, accessory: .paused,
                      progressFraction: status.fractionCompleted,
                      backedUp: status.backedUp, total: status.totalConsidered ?? 0)

        case .waiting:
            self.init(headlineKey: "backup.phase_waiting", isActive: false, accessory: .idle,
                      progressFraction: status.fractionCompleted,
                      backedUp: status.backedUp, total: status.totalConsidered ?? 0)

        case .completed:
            self.init(headlineKey: "backup.phase_completed", isActive: false, accessory: .success,
                      progressFraction: nil, backedUp: status.backedUp, total: status.totalConsidered ?? 0)

        case .needsAttention:
            self.init(headlineKey: "backup.phase_attention", isActive: false, accessory: .attention,
                      progressFraction: nil, backedUp: status.backedUp, total: status.totalConsidered ?? 0,
                      attentionCount: status.needsAttentionCount)

        case .idle:
            self.init(headlineKey: "backup.phase_idle", isActive: false, accessory: .idle,
                      progressFraction: nil)
        }
    }

    // MARK: - Localized accessors (finite key sets; no dynamic-key lookups)

    public var localizedHeadline: String {
        switch headlineKey {
        case "backup.phase_scanning": return L10n.string("backup.phase_scanning")
        case "backup.phase_checking": return L10n.string("backup.phase_checking")
        case "backup.phase_uploading": return L10n.string("backup.phase_uploading")
        case "backup.phase_paused": return L10n.string("backup.phase_paused")
        case "backup.phase_waiting": return L10n.string("backup.phase_waiting")
        case "backup.phase_completed": return L10n.string("backup.phase_completed")
        case "backup.phase_attention": return L10n.string("backup.phase_attention")
        default: return L10n.string("backup.phase_idle")
        }
    }

    /// "<n> of <m> backed up", plus "· 43 %" only while a real upload is moving. nil when there is no
    /// honest total yet (scanning / idle).
    public var localizedSubtitle: String? {
        guard total > 0 else { return nil }
        var line = L10n.string("backup.progress_backed_up \(backedUp) \(total)")
        if let uploadPercent { line += " · \(uploadPercent) %" }
        return line
    }

    /// Shown only when something actually needs the user; nil otherwise.
    public var localizedAttention: String? {
        guard attentionCount > 0 else { return nil }
        return L10n.string("backup.progress_attention \(attentionCount)")
    }
}
