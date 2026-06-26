import Foundation
import Observation
import CryptoKit
import PhotosCore
import MediaCache
import ProtonAuth

/// Owns the local offline-cache roots and bridges the Settings UI to the running thumbnail feed
/// (Deliverables 1–3). One shared instance: the main window registers its feed here on appear, and
/// the Settings scene — a separate window with no access to `MainView`'s state — reads/writes through
/// it. The thumbnail crawl is mandatory grid infrastructure and is not controlled by the Offline
/// Photo Library toggle; "Delete Offline Cache…" is the explicit cache-erasing action.
@MainActor
@Observable
final class OfflineLibraryManager {
    static let shared = OfflineLibraryManager()

    /// Disk thumbnail cache (decoded grid previews) — shared with `MainView`'s `ThumbnailFeed`. Encrypted
    /// per-account (AES-GCM); `configure(session:)` installs a key derived from the restored Proton session.
    let cache = ThumbnailCache(namespace: "thumbnails", derivative: "thumbnail")
    /// Larger display-preview derivatives, persisted when the viewer fetches them. Also encrypted.
    let previewCache = ThumbnailCache(namespace: "previews", derivative: "preview")

    /// Master switch, persisted. It is reserved for future larger-derivative/original offline caching;
    /// thumbnails always crawl while signed in.
    private(set) var offlineEnabled: Bool

    /// Latest computed status for the Developer/Cache surface (refreshed on demand).
    private(set) var status = OfflineCacheStatus()

    private var feed: ThumbnailFeed?
    private var statsProvider: (any LibraryStatsProvider)?
    /// Live count of photos currently loaded into the timeline (pushed by `MainView`).
    var liveAssetCount = 0

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [AppSettingsKey.offlineLibraryEnabled: AppSettingsDefault.offlineLibraryEnabled])
        offlineEnabled = defaults.bool(forKey: AppSettingsKey.offlineLibraryEnabled)
    }

    /// Called by `MainView` once the backend + feed exist. Thumbnails are MANDATORY grid infrastructure
    /// (see `OfflineLibraryPolicy`): the crawl is always enabled here, decoupled from the offline toggle.
    func attach(feed: ThumbnailFeed, stats: any LibraryStatsProvider) {
        self.feed = feed
        self.statsProvider = stats
        Task { await feed.setPrefetchEnabled(OfflineLibraryPolicy.shouldCrawlThumbnails(offlineEnabled: offlineEnabled)) }
    }

    /// Installs the per-account encryption key for the thumbnail + preview caches (and purges any legacy
    /// plaintext cache). Called at sign-in, before the grid starts crawling. The key is derived from the
    /// already-unlocked session secret, so startup needs only the session Keychain item rather than a second
    /// Keychain prompt for a separate cache key item.
    func configure(session: ProtonSession) {
        let key = Self.cacheKey(for: session)
        cache.configure(accountUID: session.uid, key: key)
        previewCache.configure(accountUID: session.uid, key: key)
    }

    /// Sign-out purge: erase encrypted thumbnail/preview blobs + their account Keychain keys, and the
    /// streamed video blocks. Leaves nothing decryptable on disk for the signed-out account.
    func purgeOnSignOut() {
        cache.clearAndForgetKey()
        previewCache.clearAndForgetKey()
        VideoByteRangeCache.shared.clearAll()
    }

    /// Flips the Offline Photo Library switch. Persists it ONLY — it deliberately does NOT start/stop the
    /// thumbnail crawl (thumbnails are decoupled from this toggle per `OfflineLibraryPolicy`). The toggle is
    /// reserved for future preview/original offline caching.
    func setOfflineEnabled(_ enabled: Bool) {
        guard enabled != offlineEnabled else { return }
        offlineEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettingsKey.offlineLibraryEnabled)
    }

    private static func cacheKey(for session: ProtonSession) -> SymmetricKey {
        let input = SymmetricKey(data: Data(session.keyPassword.utf8))
        let salt = Data("ProtonPhotos.local-cache.v1.\(session.uid)".utf8)
        let info = Data("thumbnail-preview-cache".utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: info, outputByteCount: 32)
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
        // Thumbnails always crawl, so the offline toggle never reports "disabled" here.
        s.prefetchPausedReason = prefetch?.pausedReason ?? "none"
        s.failedThumbnailCount = prefetch?.failed ?? 0
        s.cacheSizeBytes = cache.diskSizeBytes()
        s.previewCacheSizeBytes = previewCache.diskSizeBytes()
        s.lastError = prefetch?.lastErrors.last
        status = s
        return s
    }
}
