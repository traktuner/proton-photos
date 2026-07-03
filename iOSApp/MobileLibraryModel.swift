import Foundation
import MediaByteCache
import MediaCacheCore
import MediaCacheUIKitAdapter
import MediaLocationCore
import Observation
import PhotosCore
import ProtonAuth
import ProtonDriveBackend
import SwiftUI
import TimelineCore

/// Owns the signed-in library for iOS/iPadOS: it builds the shared backend + thumbnail feed and drives the
/// timeline load through the shared `LibraryLoadState` machine so the first-load experience matches macOS.
///
/// The heavy lifting (auth, the Drive backend, the thumbnail feed, the crawl order) is all shared Core — this
/// model only sequences `cachedTimeline → loadTimeline → crawl` and maps outcomes onto `LibraryLoadState`.
///
/// `@Observable` (not `ObservableObject`): SwiftUI then tracks each property INDIVIDUALLY, so the Settings,
/// Collections and Map tabs — which read only `loadState`/`backend`/`thumbnailFeed`, never the 20k-item
/// `snapshot` — are not re-rendered every time a new timeline snapshot is published. Only views that actually
/// read `items`/`snapshot` (the Photos grid) invalidate on a timeline change.
@MainActor
@Observable
final class MobileLibraryModel {
    /// The single source of truth for the onboarding/loading UI. Shared, tested policy — see `LibraryLoadState`.
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
    /// presentable — drives the small persistent top-left indicator. Deliberately NOT part of
    /// `LibraryLoadState` (which models the first-load lifecycle, see its docs): crawl coverage is a
    /// background signal, so it is polled from the feed and ends the first time the crawl runs dry.
    private(set) var isBackgroundLoading = false

    /// The shared backend, exposed so the Albums / Map / Viewer tabs can reuse it without re-building anything.
    private(set) var backend: (any PhotosBackend)?
    private(set) var facade: ProtonClientFacade?

    /// Whole-library GPS index for the Map tab (shared MediaLocationCore). Persisted encrypted at rest with the
    /// same per-account key as the media caches, so the Map is instant on relaunch.
    let locationIndex = PhotoLocationIndex()
    private let locationStore = PhotoLocationStore()
    private let locationCrawl = LocationCrawl()
    private var locationCrawlStarted = false

    /// The encrypted on-disk thumbnail cache, retained so Settings can report its size and clear it. It is the
    /// app's only on-disk media cache (previews live in a RAM cache; video bytes are backend-managed).
    private var thumbnailCache: ThumbnailCache?

    private var configuredUID: String?
    private var store: SessionKeychainStore?
    private var session: ProtonSession?
    private var loadTask: Task<Void, Never>?
    /// Monotonic id for the current load. Bumped whenever a load starts or the model tears down, so an
    /// off-main snapshot sort that finishes AFTER a newer load/teardown superseded it never publishes stale
    /// items. Belt-and-suspenders alongside `loadTask` cancellation — and makes the "newest load wins"
    /// invariant explicit if the load sequence is ever refactored to build snapshots concurrently.
    private var loadToken = 0
    private var firstContentGuard: Task<Void, Never>?
    private var backgroundActivityTask: Task<Void, Never>?

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

    /// Move the given items to Trash via the shared backend — a REAL, recoverable move (never a permanent
    /// delete), matching the only capability the backend exposes (`TrashProvider`). On success the items are
    /// dropped from the visible library; the call throws so the caller can surface a failure honestly.
    func trashItems(_ uids: Set<PhotoUID>) async throws {
        guard let backend, !uids.isEmpty else { return }
        try await backend.trash(Array(uids))
        snapshot = snapshot.removingItems(withUIDs: uids)   // order-preserving, re-indexed
    }

    /// Position of `uid` in the ordered timeline, or nil — O(1) via the snapshot index (viewer paging, map/
    /// grid open), replacing the previous O(n) `firstIndex`.
    func index(of uid: PhotoUID) -> Int? { snapshot.index(of: uid) }

    /// The chosen items in timeline order — O(k log k) from the snapshot index, for share/export of a
    /// selection, instead of an O(n) `filter` of the whole library on the main thread.
    func selectedItems(_ uids: Set<PhotoUID>) -> [PhotoItem] { snapshot.items(withUIDs: uids) }

    /// The on-disk size (bytes) of the encrypted thumbnail cache — the app's media-cache footprint, for Settings.
    /// Computed off the main actor (it sums file sizes on disk), so a large cache never stalls the UI.
    func cacheDiskSizeBytes() async -> Int64 {
        guard let cache = thumbnailCache else { return 0 }
        return await Task.detached { cache.diskSizeBytes() }.value
    }

    /// Clears the on-disk thumbnail cache, then restarts the crawl so the grid refills. Crash-safe with the
    /// grid/viewer active: the feed keeps its already-decoded RAM thumbnails (no broken rendering) and misses are
    /// re-downloaded. Only the app's own cache directory is touched — never anything outside it.
    func clearCache() async {
        guard let cache = thumbnailCache else { return }
        await cache.clear()
        if let feed = thumbnailFeed, !items.isEmpty {
            await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
        }
    }

    /// Retry after a failure — restarts the whole load for the current session.
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
                let pending = await feed.hasPendingThumbnailWork()
                guard let self, !Task.isCancelled else { return }
                if self.isBackgroundLoading != pending { self.isBackgroundLoading = pending }
                if !pending { break }
                try? await Task.sleep(for: .seconds(1))
            }
            self?.backgroundActivityTask = nil
        }
    }

    /// Lazily kicks off the background GPS crawl that fills the Map's location index — once per session, only
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

        // Newest first — recent photos are likelier geotagged, so pins appear fast.
        let uids = items.reversed().map(\.uid)
        let dates = Dictionary(items.map { ($0.uid, $0.captureTime) }, uniquingKeysWith: { first, _ in first })
        let index = locationIndex
        let store = locationStore
        let crawl = locationCrawl
        let feed = thumbnailFeed
        Task {
            // Give the thumbnail crawl a head start, then yield to it so the map crawl never stalls scrolling.
            try? await Task.sleep(for: .seconds(3))
            await crawl.start(
                uids: uids,
                captureDates: dates,
                location: { uid in
                    guard let metadata = try? await backend.metadata(for: uid), metadata.hasLocation,
                          let latitude = metadata.latitude, let longitude = metadata.longitude else { return nil }
                    return (latitude, longitude)
                },
                index: index,
                store: store,
                shouldYield: { await feed?.hasPendingThumbnailWork() ?? false }
            )
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
        configuredUID = nil
        session = nil
        backend = nil
        facade = nil
        snapshot = TimelineSnapshot()
        thumbnailFeed = nil
        thumbnailCache = nil
        loadState = .initial
        locationCrawlStarted = false
        locationIndex.replaceAll([])
    }

    private func start(session: ProtonSession, store: SessionKeychainStore) {
        loadToken &+= 1   // this load supersedes any older in-flight snapshot sort
        loadTask?.cancel()
        firstContentGuard?.cancel()
        firstContentGuard = nil   // must re-nil so armFirstContentGuardIfNeeded re-arms the safety net next load
        backgroundActivityTask?.cancel()
        backgroundActivityTask = nil
        isBackgroundLoading = false
        configuredUID = session.uid
        backend = nil
        facade = nil
        snapshot = TimelineSnapshot()
        thumbnailFeed = nil
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
                self.backend = backend
                self.thumbnailFeed = feed
                // The live feed's RAM tiers (UIImage wrappers + decoded core) respond to pressure tiers.
                UIKitMemoryPressureCoordinator.shared.attachFeed(feed)

                // Stale-while-revalidate: show the cached snapshot instantly (its count + a crawl seed), then
                // refresh from the server. The grid mounts under the loading overlay so it can report first
                // content, which lifts the overlay onto real thumbnails (never a blank grid).
                if let cached = await backend.cachedTimeline() {
                    try Task.checkCancellation()   // a newer session may have superseded us during the await
                    await applyItems(cached, cached: true)
                    await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
                }

                let refreshed = try await backend.loadTimeline()
                try Task.checkCancellation()
                await applyItems(refreshed, cached: false)
                await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
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
    private func applyItems(_ sections: [TimelineSection], cached: Bool) async {
        let token = loadToken
        let prepared = await Task.detached(priority: .userInitiated) {
            TimelineSnapshot(sections: sections)
        }.value
        // Publish only if THIS load is still the current one: not cancelled, and no newer load/teardown
        // bumped the token while we sorted off-main.
        guard !Task.isCancelled, token == loadToken else { return }
        snapshot = prepared
        apply(.inventoryResolved(count: prepared.count, cached: cached))
        armFirstContentGuardIfNeeded()
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
