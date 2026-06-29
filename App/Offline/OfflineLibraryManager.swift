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
    /// Full-resolution ORIGINALS viewed in the photo viewer, persisted (encrypted) when the offline library is
    /// ON, bounded by an LRU size cap (see `originalsCapBytes`). Makes reopening a photo instant even after a
    /// relaunch / while offline — the bug this fixes was that originals lived only in a per-process RAM cache.
    let originalsCache = ThumbnailCache(namespace: "originals", derivative: "original")

    /// Offline Photo Library master switch, persisted. ON ⇒ viewed originals are kept locally (encrypted) up to
    /// the cap; thumbnails always crawl regardless of this toggle.
    private(set) var offlineEnabled: Bool

    /// Current originals-cache byte budget, or `nil` when the user chose "unbounded".
    var originalsCapBytes: Int64? {
        let d = UserDefaults.standard
        if d.bool(forKey: AppSettingsKey.offlineOriginalsCapUnlimited) { return nil }
        let gb = d.object(forKey: AppSettingsKey.offlineOriginalsCapGB) as? Double ?? AppSettingsDefault.offlineOriginalsCapGB
        return Int64(max(0, gb) * 1_073_741_824)   // GiB → bytes
    }

    /// Latest computed status for the Developer/Cache surface (refreshed on demand).
    private(set) var status = OfflineCacheStatus()

    private var feed: ThumbnailFeed?
    private var statsProvider: (any LibraryStatsProvider)?
    /// Live count of photos currently loaded into the timeline (pushed by `MainView`).
    var liveAssetCount = 0

    private init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            AppSettingsKey.offlineLibraryEnabled: AppSettingsDefault.offlineLibraryEnabled,
            AppSettingsKey.offlineOriginalsCapUnlimited: AppSettingsDefault.offlineOriginalsCapUnlimited,
            AppSettingsKey.offlineOriginalsCapGB: AppSettingsDefault.offlineOriginalsCapGB,
        ])
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
        originalsCache.configure(accountUID: session.uid, key: key)
        if let cap = originalsCapBytes { let oc = originalsCache; Task.detached { oc.enforceByteCap(cap) } }
    }

    /// Sign-out purge: erase encrypted thumbnail/preview blobs + their account Keychain keys, and the
    /// streamed video blocks. Leaves nothing decryptable on disk for the signed-out account.
    func purgeOnSignOut() {
        cache.clearAndForgetKey()
        previewCache.clearAndForgetKey()
        originalsCache.clearAndForgetKey()
        VideoByteRangeCache.shared.clearAll()
    }

    /// Flips the Offline Photo Library switch and persists it. ON ⇒ the viewer persists full originals to the
    /// encrypted `originals` cache; OFF ⇒ it stops (and the Settings UI calls `purgeOriginalsCache()` to drop the
    /// ones already kept). The thumbnail crawl is decoupled and always runs (per `OfflineLibraryPolicy`).
    func setOfflineEnabled(_ enabled: Bool) {
        guard enabled != offlineEnabled else { return }
        offlineEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettingsKey.offlineLibraryEnabled)
    }

    /// Persists the originals-cache cap and enforces it immediately — lowering it (or switching from unbounded to
    /// bounded) purges the least-recently-used originals down to the new budget right away.
    func setOriginalsCap(unlimited: Bool, gigabytes: Double) {
        let d = UserDefaults.standard
        d.set(unlimited, forKey: AppSettingsKey.offlineOriginalsCapUnlimited)
        d.set(gigabytes, forKey: AppSettingsKey.offlineOriginalsCapGB)
        guard let cap = originalsCapBytes else { return }   // unbounded → nothing to enforce
        let oc = originalsCache
        Task {
            await Task.detached { oc.enforceByteCap(cap) }.value   // file I/O off the main actor
            await refreshStatus()
        }
    }

    /// Clears ONLY the full-resolution originals cache — used when the user turns the Offline Photo Library OFF.
    /// Thumbnails + previews (mandatory grid + browsing infrastructure) and the account key are kept.
    func purgeOriginalsCache() async {
        await originalsCache.clear()
        await refreshStatus()
    }

    private static func cacheKey(for session: ProtonSession) -> SymmetricKey {
        let input = SymmetricKey(data: Data(session.keyPassword.utf8))
        let salt = Data("ProtonPhotos.local-cache.v1.\(session.uid)".utf8)
        let info = Data("thumbnail-preview-cache".utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: info, outputByteCount: 32)
    }

    /// MASTER RESET: erases EVERYTHING on disk for the current account — thumbnails, previews, full originals, and
    /// streamed video blocks — leaving the state as if freshly signed in (the account key is kept, so the grid
    /// simply re-crawls). Never called implicitly — only from the explicit "Delete Offline Cache…" button.
    func deleteOfflineCache() async {
        await cache.clear()
        await previewCache.clear()
        await originalsCache.clear()
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
        s.originalsCacheSizeBytes = originalsCache.diskSizeBytes()
        s.lastError = prefetch?.lastErrors.last
        status = s
        return s
    }
}
