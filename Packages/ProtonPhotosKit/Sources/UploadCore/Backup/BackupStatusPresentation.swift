import Foundation
import PhotosCore

/// Platform-neutral display projection of `BackupStatus` for the settings backup row.
///
/// It exists to keep the row calm and honest with ONE tested mapping instead of per-platform ad-hoc
/// wording:
/// - While a run is active the headline is a STABLE umbrella ("Backup in progress") so the title
///   never flaps as the underlying phase cycles checking↔uploading many times a second during a
///   drain; the changing work is a calm subtitle underneath.
/// - "Uploading" wording (`backup.status_uploading_detail`) appears ONLY for the `.uploading` phase,
///   i.e. only when bytes are actually moving - checking/hashing/dedupe is never called upload.
///
/// This is pure and time-free. The iOS view layers `BackupStatusStabilizer` on top for the timeful
/// hysteresis (dwell) that stops the subtitle switching more than about once a second.
public struct BackupStatusPresentation: Sendable, Equatable {

    /// The single activity treatment for the row's one icon (there is never a second spinner).
    public enum Accessory: String, Sendable, Equatable {
        case idle
        case activity
        case success
        case attention
        case paused
    }

    /// A numeric progress line ("12 of 340 checked"). Value-first; the view formats via the catalog.
    public struct Count: Sendable, Equatable {
        /// Base catalog key, e.g. `backup.detail_checked`.
        public var key: String
        public var value: Int
        /// nil for single-argument keys (e.g. "%lld files need attention").
        public var total: Int?

        public init(key: String, value: Int, total: Int? = nil) {
            self.key = key
            self.value = value
            self.total = total
        }

        /// Localized numeric line. A finite, explicit switch (rather than a dynamic key) so argument
        /// binding and plural selection are compiler-checked.
        public var localized: String {
            switch (key, total) {
            case let ("backup.detail_checked", total?):
                return L10n.string("backup.detail_checked \(value) \(total)")
            case let ("backup.detail_backed_up", total?):
                return L10n.string("backup.detail_backed_up \(value) \(total)")
            case ("backup.detail_already_backed_up", _):
                return L10n.string("backup.detail_already_backed_up \(value)")
            case ("backup.detail_attention", _):
                return L10n.string("backup.detail_attention \(value)")
            case ("backup.detail_waiting", _):
                return L10n.string("backup.detail_waiting \(value)")
            default:
                return "\(value)"
            }
        }
    }

    /// Stable headline key. `backup.status_active` while active (never flaps); otherwise a resting
    /// phase key.
    public var headlineKey: String
    /// Calm subtitle key describing the current work, or nil.
    public var detailKey: String?
    /// Numeric progress line, or nil when there is no honest total.
    public var count: Count?
    /// Determinate fraction (0...1), or nil = indeterminate.
    public var progressFraction: Double?
    /// True while a run is active - drives the one spinning icon and the reserved progress slot.
    public var isActive: Bool
    public var accessory: Accessory
    /// The item the pass is working on right now (a filename), shown as a small "still-moving" line
    /// under the count. This is the ONLY honest liveness signal when the settled count sits still for
    /// a while because a handful of large new photos are uploading: the count reflects *finished*
    /// items, so it can be flat for a minute while bytes actually move - the rotating name proves the
    /// pass is alive rather than stuck. nil outside active phases (nothing is being worked on).
    public var liveItemName: String?
    /// True when `liveItemName` is a file whose bytes are actually moving (the `.uploading` step), so
    /// the line reads "wird gesichert: X"; false means it is only being checked ("Aktuell: X").
    public var liveItemIsUploading: Bool
    /// Byte progress (0…1) and size of the uploading item, so the line can read
    /// "Wird gesichert: IMG_5560.MOV — 43 % (465 MB)" and prove a big video is moving.
    public var liveItemFraction: Double?
    public var liveItemByteCount: Int?

    public init(
        headlineKey: String,
        detailKey: String?,
        count: Count?,
        progressFraction: Double?,
        isActive: Bool,
        accessory: Accessory,
        liveItemName: String? = nil,
        liveItemIsUploading: Bool = false,
        liveItemFraction: Double? = nil,
        liveItemByteCount: Int? = nil
    ) {
        self.headlineKey = headlineKey
        self.detailKey = detailKey
        self.count = count
        self.progressFraction = progressFraction
        self.isActive = isActive
        self.accessory = accessory
        self.liveItemName = liveItemName
        self.liveItemIsUploading = liveItemIsUploading
        self.liveItemFraction = liveItemFraction
        self.liveItemByteCount = liveItemByteCount
    }

    // MARK: - Mapping from the shared status

    public init(_ status: BackupStatus) {
        switch status.phase {
        case .scanning:
            // Enumerating: no honest total yet, so no count and no determinate bar.
            self.init(headlineKey: Self.activeHeadline, detailKey: "backup.status_scanning_detail",
                      count: nil, progressFraction: nil, isActive: true, accessory: .activity)

        case .checking:
            // Even while the pass as a whole is still "checking" a big backlog, a specific file may
            // already be uploading - surface THAT as "wird gesichert" so the proof is honest.
            let live = Self.liveItem(status)
            self.init(headlineKey: Self.activeHeadline, detailKey: "backup.status_checking_detail",
                      count: Self.countOfTotal("backup.detail_checked", value: status.checked, total: status.totalConsidered),
                      progressFraction: status.fractionCompleted, isActive: true, accessory: .activity,
                      liveItemName: live.name, liveItemIsUploading: live.isUploading,
                      liveItemFraction: live.fraction, liveItemByteCount: live.byteCount)

        case .uploading:
            let live = Self.liveItem(status)
            self.init(headlineKey: Self.activeHeadline, detailKey: "backup.status_uploading_detail",
                      count: Self.countOfTotal("backup.detail_backed_up", value: status.backedUp, total: status.totalConsidered),
                      progressFraction: status.fractionCompleted, isActive: true, accessory: .activity,
                      liveItemName: live.name, liveItemIsUploading: live.isUploading,
                      liveItemFraction: live.fraction, liveItemByteCount: live.byteCount)

        case .paused:
            self.init(headlineKey: "backup.phase_paused", detailKey: nil,
                      count: Self.countOfTotal("backup.detail_backed_up", value: status.backedUp, total: status.totalConsidered),
                      progressFraction: status.fractionCompleted, isActive: false, accessory: .paused)

        case .waiting:
            let remaining = status.uploadQueued + status.waitingRetry
                + max(0, (status.totalConsidered ?? 0) - status.checked)
            self.init(headlineKey: "backup.phase_waiting", detailKey: nil,
                      count: remaining > 0 ? Count(key: "backup.detail_waiting", value: remaining) : nil,
                      progressFraction: nil, isActive: false, accessory: .idle)

        case .completed:
            self.init(headlineKey: "backup.phase_completed", detailKey: nil,
                      count: status.alreadyBackedUp > 0 ? Count(key: "backup.detail_already_backed_up", value: status.alreadyBackedUp) : nil,
                      progressFraction: nil, isActive: false, accessory: .success)

        case .needsAttention:
            // Plain-language explanation first, the number second - never just a scary count.
            self.init(headlineKey: "backup.phase_attention", detailKey: "backup.status_attention_detail",
                      count: Count(key: "backup.detail_attention", value: status.needsAttentionCount),
                      progressFraction: nil, isActive: false, accessory: .attention)

        case .idle:
            self.init(headlineKey: "backup.phase_idle", detailKey: nil,
                      count: nil, progressFraction: nil, isActive: false, accessory: .idle)
        }
    }

    private static let activeHeadline = "backup.status_active"

    private static func countOfTotal(_ key: String, value: Int, total: Int?) -> Count? {
        guard let total, total > 0 else { return nil }
        return Count(key: key, value: value, total: total)
    }

    /// Prefer the file actually pushing bytes (so the line can honestly say "wird gesichert"); fall
    /// back to whatever is merely being checked.
    private static func liveItem(_ status: BackupStatus)
        -> (name: String?, isUploading: Bool, fraction: Double?, byteCount: Int?) {
        if let uploading = status.uploadingItemName, !uploading.isEmpty {
            return (uploading, true, status.uploadingFraction, status.uploadingByteCount)
        }
        return (status.currentItemName, false, nil, nil)
    }

    // MARK: - Localized accessors (finite key sets; no dynamic-key lookups)

    public var localizedHeadline: String {
        switch headlineKey {
        case "backup.status_active": return L10n.string("backup.status_active")
        case "backup.phase_paused": return L10n.string("backup.phase_paused")
        case "backup.phase_waiting": return L10n.string("backup.phase_waiting")
        case "backup.phase_completed": return L10n.string("backup.phase_completed")
        case "backup.phase_attention": return L10n.string("backup.phase_attention")
        default: return L10n.string("backup.phase_idle")
        }
    }

    public var localizedDetail: String? {
        switch detailKey {
        case "backup.status_scanning_detail": return L10n.string("backup.status_scanning_detail")
        case "backup.status_checking_detail": return L10n.string("backup.status_checking_detail")
        case "backup.status_uploading_detail": return L10n.string("backup.status_uploading_detail")
        case "backup.status_attention_detail": return L10n.string("backup.status_attention_detail")
        default: return nil
        }
    }

    public var localizedCount: String? { count?.localized }

    /// "Working on <file>" liveness line, or nil when nothing is being worked on. Rendered small and
    /// truncatable under the count; changes as items finish, which is what tells the user apart
    /// "still moving" from "stuck" when the settled count is momentarily flat.
    public var localizedLiveItem: String? {
        guard let name = liveItemName, !name.isEmpty else { return nil }
        guard liveItemIsUploading else { return L10n.string("backup.status_working_on \(name)") }
        // "Wird gesichert: IMG_5560.MOV — 43 % · 465 MB": localized base + locale-neutral numeric
        // suffix. Percentage and size are the proof a large upload is moving while the count sits still.
        var line = L10n.string("backup.status_backing_up_item \(name)")
        var extras: [String] = []
        if let fraction = liveItemFraction, fraction > 0 {
            extras.append("\(Int((fraction * 100).rounded())) %")
        }
        if let bytes = liveItemByteCount, bytes > 0 {
            extras.append(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))
        }
        if !extras.isEmpty { line += " — " + extras.joined(separator: " · ") }
        return line
    }
}
