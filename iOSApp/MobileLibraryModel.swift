import Foundation
import MediaByteCache
import MediaCacheCore
import MediaCacheUIKitAdapter
import MediaLocationCore
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
@MainActor
final class MobileLibraryModel: ObservableObject {
    /// The single source of truth for the onboarding/loading UI. Shared, tested policy — see `LibraryLoadState`.
    @Published private(set) var loadState: LibraryLoadState = .initial
    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var thumbnailFeed: UIKitThumbnailFeed?

    /// The shared backend, exposed so the Albums / Map / Viewer tabs can reuse it without re-building anything.
    private(set) var backend: (any PhotosBackend)?
    private(set) var facade: ProtonClientFacade?

    /// Whole-library GPS index for the Map tab (shared MediaLocationCore). Persisted encrypted at rest with the
    /// same per-account key as the media caches, so the Map is instant on relaunch.
    let locationIndex = PhotoLocationIndex()
    private let locationStore = PhotoLocationStore()
    private let locationCrawl = LocationCrawl()
    private var locationCrawlStarted = false

    private var configuredUID: String?
    private var store: SessionKeychainStore?
    private var session: ProtonSession?
    private var loadTask: Task<Void, Never>?
    private var firstContentGuard: Task<Void, Never>?

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
        loadTask?.cancel()
        firstContentGuard?.cancel()
        configuredUID = nil
        session = nil
        backend = nil
        facade = nil
        items = []
        thumbnailFeed = nil
        loadState = .initial
        locationCrawlStarted = false
        locationIndex.replaceAll([])
    }

    private func start(session: ProtonSession, store: SessionKeychainStore) {
        loadTask?.cancel()
        firstContentGuard?.cancel()
        configuredUID = session.uid
        backend = nil
        facade = nil
        items = []
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

                // Stale-while-revalidate: show the cached snapshot instantly (its count + a crawl seed), then
                // refresh from the server. The grid mounts under the loading overlay so it can report first
                // content, which lifts the overlay onto real thumbnails (never a blank grid).
                if let cached = await backend.cachedTimeline() {
                    applyItems(cached, cached: true)
                    await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
                }

                let refreshed = try await backend.loadTimeline()
                try Task.checkCancellation()
                applyItems(refreshed, cached: false)
                await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
            } catch is CancellationError {
                // A newer session/configuration replaced this task.
            } catch {
                apply(.failed(message: Self.message(for: error), retryable: true))
            }
        }
    }

    private func applyItems(_ sections: [TimelineSection], cached: Bool) {
        items = sections.flatMap(\.items).sorted(by: TimelineOrder.areInIncreasingOrder)
        apply(.inventoryResolved(count: items.count, cached: cached))
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
            if case .loadingContent = self.loadState { self.apply(.firstContentReady) }
        }
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
