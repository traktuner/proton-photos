import Foundation

/// Persisted-settings keys + defaults for the Offline Photo Library and window/sidebar chrome.
/// Centralised here (in the SDK-agnostic core) so the App glue and the test target share one
/// source of truth — UserDefaults key strings drift silently otherwise.
public enum AppSettingsKey {
    /// Offline Photo Library master switch. When on, the app keeps metadata, thumbnails, and
    /// display previews locally and runs the background prefetcher.
    public static let offlineLibraryEnabled = "ProtonPhotos.offlineLibraryEnabled"
    /// Future tier (off by default): keep full-resolution originals/videos locally.
    public static let offlineOriginalsEnabled = "ProtonPhotos.offlineOriginalsEnabled"
    /// User-resizable left sidebar width (points).
    public static let sidebarWidth = "ProtonPhotos.sidebarWidth"
    /// Whether the left sidebar is visible.
    public static let sidebarVisible = "ProtonPhotos.sidebarVisible"
    /// Saved main-window frame string (NSStringFromRect).
    public static let mainWindowFrame = "ProtonPhotos.mainWindowFrame"
}

public enum AppSettingsDefault {
    /// Offline Photo Library is **ON by default**: the app already cached thumbnails for the whole
    /// library in the background, so defaulting on preserves existing behaviour while making it
    /// user-controllable. Turning it off stops the prefetcher and keeps the cache.
    public static let offlineLibraryEnabled = true
    public static let offlineOriginalsEnabled = false
}

/// Optional backend capability: report how many photo rows the local metadata store (the SQLite
/// timeline cache) currently holds. Surfaced as "metadata rows" on the Developer/Cache page.
public protocol LibraryStatsProvider: Sendable {
    func metadataRowCount() async -> Int
}

/// Aggregated, displayable state of the on-disk offline cache — the data behind the Developer/Cache
/// settings surface (Deliverable 3). All fields are plain values so the view layer and tests can use
/// it without touching the cache actors.
public struct OfflineCacheStatus: Sendable, Equatable {
    public var offlineEnabled: Bool
    public var totalAssets: Int
    public var metadataRows: Int
    public var thumbnailsOnDisk: Int
    public var thumbnailsMissing: Int
    public var ramDecodedEstimate: Int
    public var prefetchQueueDepth: Int
    public var activePrefetchJobs: Int
    public var prefetchPausedReason: String
    public var failedThumbnailCount: Int
    public var cacheSizeBytes: Int64
    public var previewCacheSizeBytes: Int64
    public var lastError: String?

    public init(
        offlineEnabled: Bool = false,
        totalAssets: Int = 0,
        metadataRows: Int = 0,
        thumbnailsOnDisk: Int = 0,
        thumbnailsMissing: Int = 0,
        ramDecodedEstimate: Int = 0,
        prefetchQueueDepth: Int = 0,
        activePrefetchJobs: Int = 0,
        prefetchPausedReason: String = "none",
        failedThumbnailCount: Int = 0,
        cacheSizeBytes: Int64 = 0,
        previewCacheSizeBytes: Int64 = 0,
        lastError: String? = nil
    ) {
        self.offlineEnabled = offlineEnabled
        self.totalAssets = totalAssets
        self.metadataRows = metadataRows
        self.thumbnailsOnDisk = thumbnailsOnDisk
        self.thumbnailsMissing = thumbnailsMissing
        self.ramDecodedEstimate = ramDecodedEstimate
        self.prefetchQueueDepth = prefetchQueueDepth
        self.activePrefetchJobs = activePrefetchJobs
        self.prefetchPausedReason = prefetchPausedReason
        self.failedThumbnailCount = failedThumbnailCount
        self.cacheSizeBytes = cacheSizeBytes
        self.previewCacheSizeBytes = previewCacheSizeBytes
        self.lastError = lastError
    }

    /// Disk thumbnail coverage as a 0…1 fraction (1 when there are no assets yet).
    public var thumbnailCoverage: Double {
        guard totalAssets > 0 else { return 1 }
        return min(1, Double(thumbnailsOnDisk) / Double(totalAssets))
    }

    public var totalCacheSizeBytes: Int64 { cacheSizeBytes + previewCacheSizeBytes }
}
