import Foundation
import Observation
import SwiftUI
import CryptoKit
import PhotosCore
import MediaCache
import ProtonAuth
import ProtonDriveBackend

/// Owns the local offline-cache roots and bridges the Settings window to the running thumbnail feed.
/// The thumbnail crawl is mandatory grid infrastructure and is independent from the Offline Library toggle.
@MainActor
@Observable
final class OfflineLibraryManager {
    static let shared = OfflineLibraryManager()

    /// Disk thumbnail cache (decoded grid previews) - shared with `MainView`'s `ThumbnailFeed`. Encrypted
    /// per-account (AES-GCM); `configure(session:)` installs a key derived from the restored Proton session.
    let cache = ThumbnailCache(
        namespace: "thumbnails",
        derivative: "thumbnail",
        configuration: MacMediaCachePolicy.thumbnailByteCacheConfiguration()
    )
    /// Larger display-preview derivatives, persisted when the viewer fetches them. Also encrypted.
    let previewCache = ThumbnailCache(
        namespace: "previews",
        derivative: "preview",
        configuration: MacMediaCachePolicy.thumbnailByteCacheConfiguration()
    )
    /// Full-resolution originals viewed in the photo viewer, persisted encrypted when the Offline Library is on
    /// and bounded by an LRU size cap.
    let originalsCache = ThumbnailCache(
        namespace: "originals",
        derivative: "original",
        configuration: MacMediaCachePolicy.thumbnailByteCacheConfiguration()
    )

    /// Whole-library GPS index for the Map view. GPS is sensitive PII, so it is encrypted at rest
    /// (`PhotoLocationStore`, same per-account key as the media caches) and decrypted only into the in-memory
    /// `PhotoLocationIndex`. Filled by a low-priority background crawl behind the thumbnail crawl; purged on
    /// sign-out. The Map UI binds to `locationIndex`.
    let locationStore = PhotoLocationStore()
    let locationIndex = PhotoLocationIndex()
    private let locationCrawl = LocationCrawl()
    private var locationCrawlStarted = false

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

    /// Live thumbnail-cache warm progress (0…100) for the toolbar "preparing library" pill. A lightweight
    /// poll updates it while the background crawl fills; the pill hides once warm.
    private(set) var cachePreparePercent: Double = 0
    /// True while the shared thumbnail/preview feed still has crawl work after content is presentable.
    /// Unlike the first-run toolbar pill, this is not dismissed for the session: a later remote sync or manual
    /// refresh can seed new crawl work and should surface as a tiny title activity indicator.
    private(set) var isLibraryActivityActive = false
    private var prepareMonitor: Task<Void, Never>?
    /// Became true once this session saw an un-warm cache (the pill is an INITIAL-LOAD affordance only).
    private var prepareActive = false
    /// The pill whooshed away after the first warm-up; it stays hidden for the rest of the session. Later
    /// thumbnail work is still surfaced by `isLibraryActivityActive` in the title chrome, not by re-showing this
    /// toolbar pill.
    private var prepareDismissed = false
    /// Drives the toolbar "preparing library" pill: shown only during the session's first warm-up, hidden the
    /// instant it completes (after the native whoosh-out) and not re-shown.
    var isPreparingLibrary: Bool { prepareActive && !prepareDismissed && liveAssetCount > 0 }

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
        startPrepareMonitor()
    }

    /// Polls the thumbnail crawl's coverage. The first un-warm launch still gets the existing toolbar pill, but
    /// later crawl work (for example after a remote sync adds new assets) keeps driving the tiny title activity
    /// indicator. Cheap: one actor read every 1.5 s while the signed-in library is attached.
    private func startPrepareMonitor() {
        prepareMonitor?.cancel()
        cachePreparePercent = 0
        isLibraryActivityActive = false
        prepareActive = false
        prepareDismissed = false
        prepareMonitor = Task { [weak self] in
            while let self, !Task.isCancelled {
                // Only trust coverage once the crawl is SEEDED (`diskThumbnailTotal > 0`). An empty crawl reports
                // a false 1.0 "warm"; at launch the monitor runs before the timeline seeds the crawl, so without
                // this gate it would conclude warm and exit before the first thumbnail ever loads - and the pill
                // would never appear on a genuine first load (e.g. right after a cache reset).
                if let status = await self.feed?.prefetchStatus(), status.diskThumbnailTotal > 0 {
                    let percent = status.diskThumbnailCoverageFraction * 100   // fraction → 0…100 percent
                    self.cachePreparePercent = percent
                    self.isLibraryActivityActive = self.liveAssetCount > 0 && status.activeJobs + status.currentQueueLength > 0
                    if percent < 99.5 {
                        self.prepareActive = true   // un-warm cache → show the pill for this initial load
                    } else if self.prepareActive, !self.prepareDismissed {
                        // Only whoosh out a pill that was actually shown (a cache warm at launch never set
                        // prepareActive). Hold 100 % briefly so completion registers, then hide the initial pill;
                        // later background work uses the title activity indicator instead.
                        self.cachePreparePercent = 100
                        try? await Task.sleep(for: .seconds(0.4))
                        guard !Task.isCancelled else { return }
                        withAnimation(.smooth(duration: 0.45)) { self.prepareDismissed = true }
                    }
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }

    /// Installs the per-account encryption key for the thumbnail + preview caches (and purges any legacy
    /// plaintext cache). Called at sign-in, before the grid starts crawling. The key is derived from the
    /// already-unlocked session secret, so startup needs only the session Keychain item rather than a second
    /// Keychain prompt for a separate cache key item.
    func configure(session: ProtonSession) {
        // One-shot cleanup of the legacy plaintext aspects.json (write-only, cross-account, never
        // purged on sign-out). Learned dimensions now live in the per-account library metadata DB
        // (photos.w/h), so the file must not linger; AspectRegistry itself is gone.
        try? FileManager.default.removeItem(
            at: FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ProtonPhotos/aspects.json")
        )
        let key = Self.cacheKey(for: session)
        cache.configure(accountUID: session.uid, key: key)
        previewCache.configure(accountUID: session.uid, key: key)
        originalsCache.configure(accountUID: session.uid, key: key)
        // Same per-account key; decrypt the persisted GPS index into RAM once → instant Map on relaunch.
        locationStore.configure(accountUID: session.uid, key: key)
        locationIndex.replaceAll(locationStore.load())
        if let cap = originalsCapBytes { let oc = originalsCache; Task.detached { oc.enforceByteCap(cap) } }
    }

    /// Sign-out purge: erase encrypted thumbnail/preview blobs + their account Keychain keys, and the
    /// streamed video blocks. Leaves nothing decryptable on disk for the signed-out account.
    func purgeOnSignOut() {
        cache.clearAndForgetKey()
        previewCache.clearAndForgetKey()
        originalsCache.clearAndForgetKey()
        VideoByteRangeCache.shared.clearAll()
        locationStore.clear()
        locationIndex.replaceAll([])
        locationIndex.updateScanProgress(PhotoLocationScanProgress())
        locationCrawlStarted = false
        Task { await locationCrawl.cancel() }
        prepareMonitor?.cancel()
        cachePreparePercent = 0
        isLibraryActivityActive = false
        prepareActive = false
        prepareDismissed = false
    }

    /// Kicks off the background GPS crawl that builds the Map view's location index - once per session.
    /// Lower priority than VISIBLE thumbnail work: a single throttled worker, resumable (only photos not
    /// yet indexed are fetched), persisting the encrypted snapshot periodically. Safe to call repeatedly;
    /// only the first non-empty call starts it.
    func startLocationCrawl(items: [PhotoItem], metadata: any PhotoMetadataProvider) {
        guard !locationCrawlStarted, !items.isEmpty else { return }
        locationCrawlStarted = true
        let uids = items.reversed().map(\.uid)   // newest first - recent photos are likelier geotagged → pins appear fast
        let dates = Dictionary(items.map { ($0.uid, $0.captureTime) }, uniquingKeysWith: { first, _ in first })
        let index = locationIndex
        let store = locationStore
        let feed = self.feed
        Task {
            // Give the thumbnail crawl a head start, then crawl GPS whenever the grid isn't actively
            // demanding on-screen thumbnails - so the Map crawl shares the rate-limit budget as P2 and
            // never stalls scrolling (thumbnails are P1).
            try? await Task.sleep(for: .seconds(8))
            await locationCrawl.start(
                uids: uids,
                captureDates: dates,
                location: LocationCrawl.metadataProbe(metadata),
                index: index,
                store: store,
                // P2: back off while the grid has LIVE visible demand (scrolling / queued visible-priority
                // thumbnails). Deliberately NOT `hasPendingThumbnailWork()` - that includes the whole-library
                // sequential fill and parked the Map behind a 20k-thumbnail crawl for hours.
                shouldYield: { await feed?.hasVisibleThumbnailPressure() ?? false },
                log: { DebugLog.log($0) }
            )
        }
    }

    /// Flips the Offline Photo Library switch and persists it. ON ⇒ the viewer persists full originals to the
    /// encrypted `originals` cache; OFF ⇒ it stops (and the Settings UI calls `purgeOriginalsCache()` to drop the
    /// ones already kept). The thumbnail crawl is decoupled and always runs (per `OfflineLibraryPolicy`).
    func setOfflineEnabled(_ enabled: Bool) {
        guard enabled != offlineEnabled else { return }
        offlineEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: AppSettingsKey.offlineLibraryEnabled)
    }

    /// Persists the originals-cache cap and enforces it immediately - lowering it (or switching from unbounded to
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

    /// Clears ONLY the full-resolution originals cache - used when the user turns the Offline Photo Library OFF.
    /// Thumbnails + previews (mandatory grid + browsing infrastructure) and the account key are kept.
    func purgeOriginalsCache() async {
        await originalsCache.clear()
        await refreshStatus()
    }

    private static func cacheKey(for session: ProtonSession) -> SymmetricKey {
        LocalCacheKeyDerivation.thumbnailPreviewCacheKey(accountUID: session.uid, keyPassword: session.keyPassword)
    }

    /// MASTER RESET: erases EVERYTHING on disk for the current account - thumbnails, previews, full originals, and
    /// streamed video blocks - leaving the state as if freshly signed in (the account key is kept, so the grid
    /// simply re-crawls). Never called implicitly - only from the explicit "Delete Offline Cache…" button.
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
        // NSCache count isn't observable; bound the cumulative decode count by a fixed display ceiling.
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
