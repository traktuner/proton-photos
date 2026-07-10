import Foundation
import MediaByteCache
import MediaCacheCore
import MediaCacheUIKitAdapter
import MediaFeedCore
import MediaLocationCore
import MLSearchAppleAdapter
import MLSearchCore
import Observation
import PhotoLibraryBackupAdapter
import PhotosCore
import ProtonAuth
import ProtonDriveBackend
import SwiftUI
import TimelineCore
import UIKit

struct MobilePreviewLoadStatus: Equatable {
    var total = 0
    var onDisk = 0
    var unavailable = 0
    var queueDepth = 0
    var activeJobs = 0
    var isVerified = false

    init() {}

    init(status: UIKitThumbnailFeed.PrefetchStatus) {
        total = status.diskThumbnailTotal
        onDisk = status.diskFileCount
        unavailable = status.unfetchableCount
        queueDepth = status.currentQueueLength
        activeJobs = status.activeJobs
        isVerified = status.diskCoverageVerified
    }

    var remaining: Int {
        max(0, total - onDisk - unavailable)
    }

    var hasWork: Bool {
        queueDepth > 0 || activeJobs > 0
    }
}

/// Owns the signed-in library for iOS/iPadOS: it builds the shared backend + thumbnail feed and drives the
/// timeline load through the shared `LibraryLoadState` machine so the first-load experience matches macOS.
///
/// The heavy lifting (auth, the Drive backend, the thumbnail feed, the crawl order) is all shared Core - this
/// model only sequences `cachedTimeline → loadTimeline → crawl` and maps outcomes onto `LibraryLoadState`.
///
/// `@Observable` (not `ObservableObject`): SwiftUI then tracks each property INDIVIDUALLY, so the Settings,
/// Collections and Map tabs - which read only `loadState`/`backend`/`thumbnailFeed`, never the 20k-item
/// `snapshot` - are not re-rendered every time a new timeline snapshot is published. Only views that actually
/// read `items`/`snapshot` (the Photos grid) invalidate on a timeline change.
@MainActor
@Observable
final class MobileLibraryModel {
    /// The single source of truth for the onboarding/loading UI. Shared, tested policy - see `LibraryLoadState`.
    private(set) var loadState: LibraryLoadState = .initial
    /// The flattened, ordered, indexed timeline. Built OFF the main actor (`TimelineSnapshot` is a pure,
    /// `Sendable` value) and published here as one immutable assignment, so the main actor never flattens/
    /// sorts a large library and open/share/trash lookups are O(1)/O(k) instead of O(n) scans.
    private(set) var snapshot = TimelineSnapshot()
    /// The ordered items, for the grid and callers that pass the whole list (e.g. the viewer pager). Reads
    /// register a dependency on `snapshot`, so a timeline change invalidates only views that read items.
    var items: [PhotoItem] { snapshot.items }
    private(set) var thumbnailFeed: UIKitThumbnailFeed?
    /// True while the background thumbnail crawl is still filling the library AFTER the grid became
    /// presentable - drives the small persistent top-left indicator. Deliberately NOT part of
    /// `LibraryLoadState` (which models the first-load lifecycle, see its docs): crawl coverage is a
    /// background signal, so it is polled from the feed and ends the first time the crawl runs dry.
    private(set) var isBackgroundLoading = false
    /// Lightweight status for the mandatory preview crawl. Derived from the feed actor's existing counters, so
    /// Settings can be transparent for large libraries without walking the cache directory.
    private(set) var previewLoadStatus = MobilePreviewLoadStatus()

    /// The shared backend, exposed so the Albums / Map / Viewer tabs can reuse it without re-building anything.
    private(set) var backend: (any PhotosBackend)?
    private(set) var facade: ProtonClientFacade?
    /// Photos-library backup: the SHARED cross-platform controller (same code as macOS).
    private(set) var photoBackup: PhotoLibraryBackupController?
    /// Local-album → Proton-album sync: the SHARED cross-platform controller (same code as macOS).
    private(set) var albumSync: AlbumSyncController?
    /// Bumped by the shared album-sync controller after remote album mutations so Collections can
    /// refresh without reloading the whole timeline.
    private(set) var albumCatalogRevision = 0
    /// Smart Search (on-device semantic search): the SHARED cross-platform controller over the
    /// universal lifecycle actor (same code as macOS). Built with the session feed; every
    /// lifecycle decision stays in MLSearchCore.
    private(set) var smartSearch: MLSmartSearchController?

    /// Whole-library GPS index for the Map tab (shared MediaLocationCore). Persisted encrypted at rest with the
    /// same per-account key as the media caches, so the Map is instant on relaunch.
    let locationIndex = PhotoLocationIndex()
    private let locationStore = PhotoLocationStore()
    private let locationCrawl = LocationCrawl()
    private var locationCrawlStarted = false

    /// The encrypted on-disk thumbnail cache, retained so Settings can report its size and clear it. It is the
    /// app's only on-disk media cache (previews live in a RAM cache; video bytes are backend-managed).
    private var thumbnailCache: ThumbnailCache?

    /// The encrypted on-disk ORIGINALS cache. Seeded when the fullscreen viewer decrypts an original, then
    /// reused (cache-first, before the network) by later fullscreen opens and by share/export - giving iOS the
    /// same E2EE-safe originals reuse macOS already has (`OfflineLibraryManager.originalsCache`). Plaintext
    /// originals are NEVER written outside this AES-GCM store. Exposed so the share/export path can read it.
    private(set) var originalsCache: ThumbnailCache?

    /// LRU byte ceiling for `originalsCache`, enforced after each viewer store so a long session of large
    /// HEIC/video originals can't grow the on-disk cache without bound.
    let originalsCacheCapBytes: Int64 = 512 * 1024 * 1024

    private var configuredUID: String?
    private var store: SessionKeychainStore?
    private var session: ProtonSession?
    private var loadTask: Task<Void, Never>?
    /// Monotonic id for the current load. Bumped whenever a load starts or the model tears down, so an
    /// off-main snapshot sort that finishes AFTER a newer load/teardown superseded it never publishes stale
    /// items. Belt-and-suspenders alongside `loadTask` cancellation - and makes the "newest load wins"
    /// invariant explicit if the load sequence is ever refactored to build snapshots concurrently.
    private var loadToken = 0
    private var firstContentGuard: Task<Void, Never>?
    private var backgroundActivityTask: Task<Void, Never>?
    @ObservationIgnored private var smartSearchMemoryRegistration: MemoryPressureRegistration?

    /// Safety net: if the grid never reports a first drawn frame (e.g. every visible thumbnail is unfetchable),
    /// the loading overlay must still lift onto whatever the grid shows rather than hang forever.
    private let firstContentTimeout: Duration = .seconds(6)

    func configure(session: ProtonSession?, store: SessionKeychainStore) {
        self.store = store
        guard let session else {
            teardown()
            return
        }
        // Already configured for this account → nothing to do (relaunch/route changes must not re-crawl).
        guard configuredUID != session.uid || backend == nil else { return }
        self.session = session
        start(session: session, store: store)
    }

    /// Move the given items to Trash via the shared backend - a REAL, recoverable move (never a permanent
    /// delete), matching the only capability the backend exposes (`TrashProvider`). On success the items are
    /// dropped from the visible library; the call throws so the caller can surface a failure honestly.
    func trashItems(_ uids: Set<PhotoUID>) async throws {
        guard let backend, !uids.isEmpty else { return }
        try await backend.trash(Array(uids))
        snapshot = snapshot.removingItems(withUIDs: uids)   // order-preserving, re-indexed
    }

    func emptyTrash() async throws {
        guard let backend else { return }
        try await backend.emptyTrash()
    }

    /// Position of `uid` in the ordered timeline, or nil - O(1) via the snapshot index (viewer paging, map/
    /// grid open), replacing the previous O(n) `firstIndex`.
    func index(of uid: PhotoUID) -> Int? { snapshot.index(of: uid) }

    /// The chosen items in timeline order - O(k log k) from the snapshot index, for share/export of a
    /// selection, instead of an O(n) `filter` of the whole library on the main thread.
    func selectedItems(_ uids: Set<PhotoUID>) -> [PhotoItem] { snapshot.items(withUIDs: uids) }

    /// The on-disk size (bytes) of the encrypted thumbnail cache - the app's media-cache footprint, for Settings.
    /// Computed off the main actor (it sums file sizes on disk), so a large cache never stalls the UI.
    func cacheDiskSizeBytes() async -> Int64 {
        guard let cache = thumbnailCache else { return 0 }
        return await Task.detached { cache.diskSizeBytes() }.value
    }

    /// Clears the on-disk thumbnail cache, then restarts the crawl so the grid refills. Crash-safe with the
    /// grid/viewer active: the feed keeps its already-decoded RAM thumbnails (no broken rendering) and misses are
    /// re-downloaded. Only the app's own cache directory is touched - never anything outside it.
    func clearCache() async {
        guard let cache = thumbnailCache else { return }
        if let feed = thumbnailFeed {
            await feed.clearCacheAndRestartPrefetch()
            startBackgroundActivityMonitorIfNeeded()
        } else {
            await cache.clear()
        }
    }

    /// Retry after a failure - restarts the whole load for the current session.
    func retry() {
        guard let session, let store else { return }
        configuredUID = nil
        start(session: session, store: store)
    }

    /// Called by the grid the first time it draws a fully-populated frame → lift the loading UI onto the grid.
    func markFirstContentReady() {
        firstContentGuard?.cancel()
        firstContentGuard = nil
        apply(.firstContentReady)
        startBackgroundActivityMonitorIfNeeded()
    }

    /// Polls the feed's crawl backlog once the grid is presentable, keeping the small "still loading"
    /// indicator honest, and stops for good the first time the crawl runs dry (later scroll-driven warms
    /// are moments, not "the library is still loading").
    private func startBackgroundActivityMonitorIfNeeded() {
        guard backgroundActivityTask == nil, let feed = thumbnailFeed else { return }
        backgroundActivityTask = Task { [weak self] in
            while !Task.isCancelled {
                let status = await feed.prefetchStatus()
                let previewStatus = MobilePreviewLoadStatus(status: status)
                let pending = previewStatus.hasWork
                guard let self, !Task.isCancelled else { return }
                if self.isBackgroundLoading != pending { self.isBackgroundLoading = pending }
                if self.previewLoadStatus != previewStatus { self.previewLoadStatus = previewStatus }
                if !pending { break }
                try? await Task.sleep(for: .seconds(1))
            }
            self?.backgroundActivityTask = nil
        }
    }

    /// Lazily kicks off the background GPS crawl that fills the Map's location index - once per session, only
    /// when the Map is first opened (so users who never open it never pay for the crawl).
    func startLocationCrawlIfNeeded() {
        guard !locationCrawlStarted, let backend, let session, !items.isEmpty else { return }
        locationCrawlStarted = true
        locationStore.configure(
            accountUID: session.uid,
            key: LocalCacheKeyDerivation.thumbnailPreviewCacheKey(
                accountUID: session.uid,
                keyPassword: session.keyPassword
            )
        )
        locationIndex.replaceAll(locationStore.load())   // instant Map on relaunch

        // Newest first - recent photos are likelier geotagged, so pins appear fast.
        let uids = items.reversed().map(\.uid)
        let dates = Dictionary(items.map { ($0.uid, $0.captureTime) }, uniquingKeysWith: { first, _ in first })
        let index = locationIndex
        let store = locationStore
        let crawl = locationCrawl
        let feed = thumbnailFeed
        let governor = LibraryWorkloadGovernorPolicy()
        Task {
            // Give the thumbnail crawl a head start, then yield only to LIVE visible demand so the map
            // crawl never stalls scrolling - but is also never parked behind the whole-library sequential
            // fill (`hasPendingThumbnailWork` includes it, which kept the Map empty until all 20k+
            // thumbnails were cached).
            try? await Task.sleep(for: .seconds(3))
            await crawl.start(
                uids: uids,
                captureDates: dates,
                location: LocationCrawl.metadataProbe(backend),
                index: index,
                store: store,
                shouldYield: {
                    let visibleDemand = await feed?.hasVisibleThumbnailPressure() ?? false
                    return governor.budget(
                        for: .backgroundLocationCrawl,
                        signals: LibraryWorkloadSignals(hasVisibleMediaDemand: visibleDemand)
                    ).shouldYield
                },
                log: { DebugLog.log($0) }
            )
        }
    }

    func restartLocationCrawlIfNeeded() {
        guard !items.isEmpty else { return }
        locationCrawlStarted = false
        startLocationCrawlIfNeeded()
    }

    /// Builds the Smart Search stack for this session (composition only; the shared Core actor
    /// owns every lifecycle decision). Same bootstrap as macOS.
    private func configureSmartSearch(session: ProtonSession, client: ProtonClientFacade, feed: UIKitThumbnailFeed) {
        #if DEBUG
        let allowsDeveloperModels = true
        #else
        let allowsDeveloperModels = false
        #endif
        let lifecycle = AppleSmartSearchBootstrap.makeLifecycle(
            accountDirectory: client.accountDataDirectory,
            accountUID: session.uid,
            keyPassword: session.keyPassword,
            feed: feed.feedCore,
            assetsProvider: { [weak self] in
                await MainActor.run { self?.items.map(\.uid) ?? [] }
            },
            allowsDeveloperModels: allowsDeveloperModels,
            databasePolicy: client.accountDatabasePolicy
        )
        smartSearch = MLSmartSearchController(lifecycle: lifecycle)
        // Under memory pressure the search stack drops cached vector blocks and unloads the
        // CoreML model; both rebuild on demand.
        smartSearchMemoryRegistration?.end()
        smartSearchMemoryRegistration = MemoryPressureGovernor.shared.register { tier in
            guard tier.requiresImmediatePurge else { return }
            Task { await lifecycle.releaseMemory() }
        }
    }

    private func teardown() {
        loadToken &+= 1   // supersede any in-flight snapshot sort
        loadTask?.cancel()
        firstContentGuard?.cancel()
        firstContentGuard = nil
        backgroundActivityTask?.cancel()
        backgroundActivityTask = nil
        isBackgroundLoading = false
        previewLoadStatus = MobilePreviewLoadStatus()
        configuredUID = nil
        session = nil
        backend = nil
        facade = nil
        photoBackup?.stopSync()
        photoBackup = nil
        albumSync?.stopSync()
        albumSync = nil
        albumCatalogRevision = 0
        snapshot = TimelineSnapshot()
        thumbnailFeed = nil
        smartSearch = nil
        smartSearchMemoryRegistration?.end()
        smartSearchMemoryRegistration = nil
        thumbnailCache = nil
        originalsCache?.clearAndForgetKey()   // sign-out purges decrypted-originals blobs + the account key
        originalsCache = nil
        loadState = .initial
        locationCrawlStarted = false
        locationIndex.replaceAll([])
        locationIndex.updateScanProgress(PhotoLocationScanProgress())
        Task { [locationCrawl] in await locationCrawl.cancel() }
        // Purges ONLY when an explicit sign-out armed it (never on a transient session re-check), and
        // only now that backup is stopped and the session-scoped stores above are released.
        BackupLocalDataPurge.purgeIfSignOutRequested()
    }

    private func start(session: ProtonSession, store: SessionKeychainStore) {
        loadToken &+= 1   // this load supersedes any older in-flight snapshot sort
        loadTask?.cancel()
        firstContentGuard?.cancel()
        firstContentGuard = nil   // must re-nil so armFirstContentGuardIfNeeded re-arms the safety net next load
        backgroundActivityTask?.cancel()
        backgroundActivityTask = nil
        isBackgroundLoading = false
        previewLoadStatus = MobilePreviewLoadStatus()
        configuredUID = session.uid
        backend = nil
        facade = nil
        photoBackup?.stopSync()
        photoBackup = nil
        albumSync?.stopSync()
        albumSync = nil
        snapshot = TimelineSnapshot()
        thumbnailFeed = nil
        smartSearch = nil
        loadState = .preparingInventory

        let cache = ThumbnailCache(
            namespace: "mobile-thumbnails",
            derivative: "thumbnail",
            configuration: UIKitMediaCachePolicy.thumbnailByteCacheConfiguration()
        )
        cache.configure(
            accountUID: session.uid,
            key: LocalCacheKeyDerivation.thumbnailPreviewCacheKey(
                accountUID: session.uid,
                keyPassword: session.keyPassword
            )
        )
        thumbnailCache = cache

        // Parallel encrypted store for decrypted ORIGINALS (own namespace/derivative so it never collides
        // with thumbnails/previews), keyed to the same account. Seeded by the viewer, reused by share/export.
        let originals = ThumbnailCache(namespace: "mobile-originals", derivative: "original")
        originals.configure(
            accountUID: session.uid,
            key: LocalCacheKeyDerivation.thumbnailPreviewCacheKey(
                accountUID: session.uid,
                keyPassword: session.keyPassword
            )
        )
        originals.enforceByteCap(originalsCacheCapBytes)   // trim any prior-session overflow up front
        originalsCache = originals

        // Drive the shared memory governor from UIKit pressure/thermal/lifecycle events and register the
        // session's cache owners (identity-keyed: a new session's cache/feed replaces the previous
        // registration). Same Core mechanism macOS wires through AppMemoryPressureCoordinator.
        UIKitMemoryPressureCoordinator.shared.install()
        UIKitMemoryPressureCoordinator.shared.attachByteCache(cache)

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let client = try await ProtonDriveBackendFactory.makeFacade(
                    session: session,
                    store: store,
                    policy: .standard(
                        libraryDatabasePolicy: ProtonDriveBackendPolicy.mobileLibraryDatabasePolicy,
                        videoCacheBudgetBytes: 128 * 1024 * 1024
                    )
                )
                try Task.checkCancellation()
                let backend = client.backend
                let feed = UIKitThumbnailFeed(
                    cache: cache,
                    loader: backend,
                    dimensions: PhotoDimensionCoalescer(store: backend),
                    targetPixels: 288
                )
                self.facade = client
                self.photoBackup = PhotoLibraryBackupController(
                    configuration: .init(
                        accountDataDirectory: client.accountDataDirectory,
                        databasePolicy: client.accountDatabasePolicy
                    ),
                    identityResolver: client.uploadIdentityResolver,
                    uploader: client.photoUploader
                )
                // Keep the display awake while a backup pass is actively running so iOS does not
                // suspend the app mid-upload when the screen auto-locks (the documented overnight
                // freeze). Reset the moment a pass ends — the controller drives this from isSyncing.
                self.photoBackup?.idleTimerHook = { isBackingUp in
                    UIApplication.shared.isIdleTimerDisabled = isBackingUp
                }
                let albumSync = AlbumSyncController(
                    configuration: .init(
                        accountDataDirectory: client.accountDataDirectory,
                        databasePolicy: client.accountDatabasePolicy
                    ),
                    identityResolver: client.uploadIdentityResolver,
                    uploader: client.photoUploader,
                    remoteOps: client.albumSyncRemoteOps
                )
                albumSync.setRemoteAlbumsChangedHandler { [weak self] in
                    self?.albumCatalogRevision &+= 1
                }
                self.albumSync = albumSync
                PhotoLibraryBackupSharedRef.shared.controller = self.photoBackup
                await client.uploadCoordinator.start()
                self.backend = backend
                self.thumbnailFeed = feed
                // The live feed's RAM tiers (UIImage wrappers + decoded core) respond to pressure tiers.
                UIKitMemoryPressureCoordinator.shared.attachFeed(feed)
                self.configureSmartSearch(session: session, client: client, feed: feed)

                // Stale-while-revalidate: show the cached snapshot instantly (its count + a crawl seed), then
                // refresh from the server. The grid mounts under the loading overlay so it can report first
                // content, which lifts the overlay onto real thumbnails (never a blank grid).
                if let cached = await backend.cachedTimeline() {
                    try Task.checkCancellation()   // a newer session may have superseded us during the await
                    if await applyItems(cached, cached: true) {
                        await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
                        startBackgroundActivityMonitorIfNeeded()
                    }
                }

                let refreshed = try await backend.loadTimeline()
                try Task.checkCancellation()
                if await applyItems(refreshed, cached: false) {
                    await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
                    startBackgroundActivityMonitorIfNeeded()
                }
            } catch is CancellationError {
                // A newer session/configuration replaced this task.
            } catch {
                apply(.failed(message: Self.message(for: error), retryable: true))
            }
        }
    }

    /// Flatten + sort the sections into an immutable `TimelineSnapshot` OFF the main actor, then publish the
    /// finished value on it. For a large library this keeps the O(n log n) sort off the main thread entirely,
    /// so a timeline load/refresh never blocks menu/tab interaction. A newer session that superseded us while
    /// the sort ran drops the result (the cancellation check), never clobbering the newer state.
    @discardableResult
    private func applyItems(_ sections: [TimelineSection], cached: Bool) async -> Bool {
        let token = loadToken
        let prepared = await Task.detached(priority: .userInitiated) {
            TimelineSnapshot(sections: sections)
        }.value
        // Publish only if THIS load is still the current one: not cancelled, and no newer load/teardown
        // bumped the token while we sorted off-main.
        guard !Task.isCancelled, token == loadToken else { return false }
        let changed = prepared != snapshot
        if changed {
            snapshot = prepared
            // New/removed assets flow into the Smart Search index on its next background pass.
            smartSearch?.noteLibraryChanged()
        }
        apply(.inventoryResolved(count: prepared.count, cached: cached))
        armFirstContentGuardIfNeeded()
        return changed
    }

    private func apply(_ event: LibraryLoadEvent) {
        loadState = LibraryLoadPolicy.reduce(loadState, event)
    }

    /// Arm the fallback that force-lifts the overlay if the grid never reports first content while a non-empty
    /// inventory is loading.
    private func armFirstContentGuardIfNeeded() {
        guard case .loadingContent = loadState, firstContentGuard == nil else { return }
        firstContentGuard = Task { [weak self] in
            try? await Task.sleep(for: self?.firstContentTimeout ?? .seconds(6))
            guard let self, !Task.isCancelled else { return }
            if case .loadingContent = self.loadState {
                self.apply(.firstContentReady)
                self.startBackgroundActivityMonitorIfNeeded()
            }
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
