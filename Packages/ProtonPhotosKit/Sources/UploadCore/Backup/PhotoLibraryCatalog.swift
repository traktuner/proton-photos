import Foundation

/// Platform-neutral local photo-library inventory. This is the persistent index of what the device
/// currently exposes for backup discovery (one row per logical asset), NOT a record of what is
/// already backed up - that stays the job of `UploadBackupStateStore`. Keeping the two separate is
/// deliberate: the catalog answers "what does the library look like and what changed since last
/// time?"; the backup state answers "which revisions are proven safe in Proton Photos?".
///
/// The model carries ZERO PhotoKit types on purpose. The PhotoKit adapter maps `PHAsset` +
/// `PHAssetResource` into these plain values (roles travel as their stable string identity), so
/// this store is fully testable off-device and shared verbatim by iOS/iPadOS/macOS.

/// The broad media class of a catalogued asset. The Live-Photo flag is separate (a Live Photo is a
/// still `image` with a paired video resource), matching how the planner reasons about resources.
public enum PhotoLibraryCatalogMediaKind: String, Sendable, Equatable, Codable, CaseIterable {
    case image
    case video
}

/// One resource of a catalogued asset. `role` is the stable string identity of the adapter's
/// resource role (originalPhoto, fullSizePhoto, pairedVideo, …) so no PhotoKit enum leaks in and a
/// future resource type needs no schema migration.
public struct PhotoLibraryCatalogResource: Sendable, Equatable, Codable {
    public var role: String
    public var originalFilename: String
    public var mimeType: String?
    /// Stable ordinal among resources of the same role after the adapter's deterministic sort.
    public var ordinal: Int

    public init(role: String, originalFilename: String, mimeType: String? = nil, ordinal: Int = 0) {
        self.role = role
        self.originalFilename = originalFilename
        self.mimeType = mimeType
        self.ordinal = ordinal
    }
}

/// One catalogued asset plus its inventory bookkeeping. Everything above `firstSeenAt` is derived
/// from the library; `firstSeenAt`/`lastSeenAt`/`isRemoved`/`removedAt` are owned by the store.
public struct PhotoLibraryCatalogEntry: Sendable, Equatable {
    public var localIdentifier: String
    public var creationDate: Date?
    public var modificationDate: Date?
    public var pixelWidth: Int
    public var pixelHeight: Int
    public var durationSeconds: Double
    public var mediaKind: PhotoLibraryCatalogMediaKind
    public var isLivePhoto: Bool
    public var resources: [PhotoLibraryCatalogResource]
    /// Structural fingerprint (resource roles + names + mime + dimensions + duration + live flag).
    /// A metadata-only change (favourite, album membership) leaves this untouched; the first real
    /// content edit changes the resource structure and moves it. Same value the planner fingerprints.
    public var contentFingerprint: Int64
    /// Cheap metadata revision derived from `modificationDate`. Drifts on any change PhotoKit dates,
    /// so a differing value is the signal that an asset is worth handing to the backup preflight.
    public var metadataRevision: Int64
    public var firstSeenAt: Date
    public var lastSeenAt: Date
    public var isRemoved: Bool
    public var removedAt: Date?

    public init(
        localIdentifier: String,
        creationDate: Date?,
        modificationDate: Date?,
        pixelWidth: Int,
        pixelHeight: Int,
        durationSeconds: Double,
        mediaKind: PhotoLibraryCatalogMediaKind,
        isLivePhoto: Bool,
        resources: [PhotoLibraryCatalogResource],
        contentFingerprint: Int64,
        metadataRevision: Int64,
        firstSeenAt: Date,
        lastSeenAt: Date,
        isRemoved: Bool = false,
        removedAt: Date? = nil
    ) {
        self.localIdentifier = localIdentifier
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.durationSeconds = durationSeconds
        self.mediaKind = mediaKind
        self.isLivePhoto = isLivePhoto
        self.resources = resources
        self.contentFingerprint = contentFingerprint
        self.metadataRevision = metadataRevision
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
        self.isRemoved = isRemoved
        self.removedAt = removedAt
    }

    /// True when `other` describes the same asset content as this row: identical structure and the
    /// same metadata revision. Used by the store to classify an observation as unchanged.
    public func matchesContent(of other: PhotoLibraryCatalogEntry) -> Bool {
        contentFingerprint == other.contentFingerprint && metadataRevision == other.metadataRevision
    }
}

/// What an upsert did to the catalog. Drives whether the adapter emits a backup candidate.
public enum PhotoLibraryCatalogChange: Sendable, Equatable {
    /// No prior row for this identifier.
    case inserted
    /// A prior row existed but the content/metadata revision moved, or a removed asset reappeared.
    case changed
    /// A prior row existed and nothing backup-relevant changed - skip the expensive candidate path.
    case unchanged

    /// Inserted or changed assets are the only ones worth re-checking against the backup preflight.
    public var isCandidate: Bool { self != .unchanged }
}

/// Running tally of one catalog scan pass. Reported to the UI throttled (per chunk), so a 20k-asset
/// scan never spams the main actor. Wording contract: this is INVENTORY progress ("scanning"), it
/// never implies upload - only `BackupSyncProgress` may speak to backup work.
public struct PhotoLibraryCatalogProgress: Sendable, Equatable {
    /// Assets observed from the library this pass.
    public var scanned = 0
    /// Assets new to the catalog this pass.
    public var discovered = 0
    /// Assets whose content/metadata revision moved this pass.
    public var changed = 0
    /// Assets marked removed this pass (gone from the library / dropped from a limited selection).
    public var removed = 0

    public init(scanned: Int = 0, discovered: Int = 0, changed: Int = 0, removed: Int = 0) {
        self.scanned = scanned
        self.discovered = discovered
        self.changed = changed
        self.removed = removed
    }
}

/// Inventory totals for status/debug surfaces.
public struct PhotoLibraryCatalogSnapshot: Sendable, Equatable {
    public var total = 0
    public var present = 0
    public var removed = 0

    public init(total: Int = 0, present: Int = 0, removed: Int = 0) {
        self.total = total
        self.present = present
        self.removed = removed
    }
}

/// Persistence seam for the local photo-library catalog. Implemented by a SQLite store in Core; the
/// PhotoKit adapter is the only writer of observations, and the backup engine reads candidates the
/// adapter produced from `isCandidate` classifications.
public protocol PhotoLibraryCatalogStore: Sendable {
    func entry(for localIdentifier: String) -> PhotoLibraryCatalogEntry?
    /// Read-only classification of an observation against the stored row, WITHOUT writing. The sync
    /// driver uses this to decide whether to enqueue a backup candidate BEFORE it advances the
    /// catalog, so the durable queue row is always written first.
    func classify(_ entry: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange
    /// Records one observation, preserving `firstSeenAt` and clearing any removed marker, and
    /// returns how it classified against the prior row.
    @discardableResult
    func upsert(_ entry: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange
    /// Batched observations in one transaction; classifications line up with `entries` by index.
    @discardableResult
    func upsertBatch(_ entries: [PhotoLibraryCatalogEntry]) -> [PhotoLibraryCatalogChange]
    /// Marks the given present identifiers removed (targeted-scan deletions). Returns rows changed.
    @discardableResult
    func markRemoved(_ identifiers: [String], removedAt: Date) -> Int
    /// Marks removed every present row not touched since `cutoff` (full-scan mark-and-sweep).
    @discardableResult
    func sweepRemoved(notSeenAfter cutoff: Date, removedAt: Date) -> Int
    func snapshot() -> PhotoLibraryCatalogSnapshot
    func count() -> Int

    // MARK: Resumable full-scan state
    /// True once a full-library scan has completed at least once. An incremental (change-token) scan
    /// is only trusted after this — a token can exist before our own catalog knows the whole library.
    func hasCompletedFullScan() -> Bool
    /// The in-progress full-scan epoch, or nil if none is underway (the next full scan starts fresh).
    /// A full scan of a large library rarely finishes in one foreground/BG window; persisting this lets
    /// an interrupted scan RESUME from `cursor` instead of restarting, so it converges instead of
    /// looping forever and never marking itself complete.
    func fullScanProgress() -> PhotoLibraryFullScanProgress?
    /// Persists mid-scan progress so a resumed scan continues within the SAME epoch.
    func recordFullScanProgress(_ progress: PhotoLibraryFullScanProgress)
    /// Marks the current full scan complete and clears the in-progress epoch.
    func completeFullScan()
    /// Discards any in-progress epoch's resume point so the next full scan starts fresh from the
    /// beginning (used when a lost change token means the frontier can no longer be trusted).
    func clearFullScanResumePoint()
}

/// Persisted progress of a resumable full-library scan (see `PhotoLibraryCatalogSync`).
public struct PhotoLibraryFullScanProgress: Sendable, Equatable {
    /// Start of the current scan epoch. The completion sweep uses THIS instant as its cutoff — never a
    /// single run's clock — so assets observed by an EARLIER run of the same epoch are not falsely
    /// swept as removed when a later run finishes the epoch.
    public var epochStart: Date
    /// How many assets, counted from the enumeration start, have already been observed this epoch.
    public var cursor: Int
    public init(epochStart: Date, cursor: Int) {
        self.epochStart = epochStart
        self.cursor = cursor
    }
}
