import Foundation
import Observation
import PhotosCore
import MediaCache

/// Owns the local offline-cache roots and bridges the Settings UI to the running thumbnail feed
/// (Deliverables 1–3). One shared instance: the main window registers its feed here on appear, and
/// the Settings scene — a separate window with no access to `MainView`'s state — reads/writes through
/// it. Toggling "Offline Photo Library" off stops the background prefetcher but keeps the cache;
/// "Delete Offline Cache…" is the only thing that erases it.
@MainActor
@Observable
final class OfflineLibraryManager {
    static let shared = OfflineLibraryManager()

    /// Disk thumbnail cache (decoded grid previews) — shared with `MainView`'s `ThumbnailFeed`.
    let cache = ThumbnailCache(namespace: "thumbnails")
    /// Larger display-preview derivatives, persisted when the viewer fetches them.
    let previewCache = ThumbnailCache(namespace: "previews")

    /// Master switch, persisted. Set via `setOfflineEnabled(_:)` so the side effects (persist +
    /// start/stop prefetch) run; the stored property stays observable for the Settings toggle.
    private(set) var offlineEnabled: Bool

    /// Latest computed status for the Developer/Cache surface (refreshed on demand).
    private(set) var status = OfflineCacheStatus()

    private var feed: ThumbnailFeed?
    private var statsProvider: (any LibraryStatsProvider)?
    /// Set by `MainView` so re-enabling offline mode can restart the library crawl (the feed clears
    /// its queue when prefetch is disabled).
    var restartPrefetch: (() -> Void)?
    /// Live count of photos currently loaded into the timeline (pushed by `MainView`).
    var liveAssetCount = 0

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [AppSettingsKey.offlineLibraryEnabled: AppSettingsDefault.offlineLibraryEnabled])
        offlineEnabled = defaults.bool(forKey: AppSettingsKey.offlineLibraryEnabled)
    }

    /// Called by `MainView` once the backend + feed exist. Applies the persisted toggle immediately.
    func attach(feed: ThumbnailFeed, stats: any LibraryStatsProvider) {
        self.feed = feed
        self.statsProvider = stats
        applyOfflineEnabled()
    }

    /// Flips the Offline Photo Library switch: persists it, and starts/stops the prefetcher. Turning
    /// it off keeps the cache on disk.
    func setOfflineEnabled(_ enabled: Bool) {
        guard enabled != offlineEnabled else { return }
        offlineEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettingsKey.offlineLibraryEnabled)
        applyOfflineEnabled()
    }

    private func applyOfflineEnabled() {
        guard let feed else { return }
        let enabled = offlineEnabled
        let restart = restartPrefetch
        Task {
            await feed.setPrefetchEnabled(enabled)
            if enabled { restart?() }
        }
    }

    /// Erases the offline cache on disk (thumbnails + previews). Never called implicitly — only from
    /// the explicit "Delete Offline Cache…" button.
    func deleteOfflineCache() async {
        await cache.clear()
        await previewCache.clear()
        VideoByteRangeCache.shared.clearAll()   // also drop streamed video blocks
        await refreshStatus()
    }

    /// Recomputes `status` from the cache actors, the feed, and the diagnostics counters.
    @discardableResult
    func refreshStatus() async -> OfflineCacheStatus {
        let prefetch = await feed?.prefetchStatus()
        let metadataRows = await statsProvider?.metadataRowCount() ?? 0
        let totalAssets = max(liveAssetCount, metadataRows)
        let onDisk = cache.diskFileCount()
        let decode = PhotoDiagnostics.shared.decodeStats()

        var s = OfflineCacheStatus()
        s.offlineEnabled = offlineEnabled
        s.totalAssets = totalAssets
        s.metadataRows = metadataRows
        s.thumbnailsOnDisk = onDisk
        s.thumbnailsMissing = max(0, totalAssets - onDisk)
        // NSCache count isn't observable; bound the cumulative decode count by the cache limit.
        s.ramDecodedEstimate = min(1500, max(0, decode.ramDecodeCompleted - decode.ramDecodeFailed))
        s.prefetchQueueDepth = prefetch?.currentQueueLength ?? 0
        s.activePrefetchJobs = prefetch?.activeJobs ?? 0
        s.prefetchPausedReason = prefetch?.pausedReason ?? (offlineEnabled ? "none" : "disabled")
        s.failedThumbnailCount = prefetch?.failed ?? 0
        s.cacheSizeBytes = cache.diskSizeBytes()
        s.previewCacheSizeBytes = previewCache.diskSizeBytes()
        s.lastError = prefetch?.lastErrors.last
        status = s
        return s
    }
}
