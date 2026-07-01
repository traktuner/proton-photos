import Foundation
import CoreGraphics
import SQLite3
import Testing
import PhotosCore
import MediaCache
@testable import TimelineFeature

/// Tests for the engineering/infrastructure pass: settings persistence, window-frame validation,
/// sidebar metrics, the video state machine, thumbnail priority ordering, prefetch pause reasons,
/// and the timeline DB query plan.
@Suite("App infrastructure")
struct AppInfrastructureTests {

    // MARK: Deliverable 1 — settings persistence

    @Test func offlineToggleAndSidebarWidthPersist() {
        let suite = "tests-settings-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        // Default registers ON; the persisted value survives a round-trip.
        defaults.register(defaults: [AppSettingsKey.offlineLibraryEnabled: AppSettingsDefault.offlineLibraryEnabled])
        #expect(defaults.bool(forKey: AppSettingsKey.offlineLibraryEnabled) == true)
        defaults.set(false, forKey: AppSettingsKey.offlineLibraryEnabled)
        #expect(defaults.bool(forKey: AppSettingsKey.offlineLibraryEnabled) == false)

        // Sidebar width persists and resolves through the clamp.
        defaults.set(300.0, forKey: AppSettingsKey.sidebarWidth)
        #expect(SidebarMetrics.resolved(stored: CGFloat(defaults.double(forKey: AppSettingsKey.sidebarWidth))) == 300)
    }

    // MARK: Deliverable 4 — sidebar metrics

    @Test func sidebarClampAndResolve() {
        #expect(SidebarMetrics.clamp(10) == SidebarMetrics.minWidth)
        #expect(SidebarMetrics.clamp(9999) == SidebarMetrics.maxWidth)
        #expect(SidebarMetrics.clamp(250) == 250)
        #expect(SidebarMetrics.resolved(stored: 0) == SidebarMetrics.defaultWidth)   // unset key
        #expect(SidebarMetrics.resolved(stored: 5000) == SidebarMetrics.maxWidth)    // clamped
        #expect(SidebarMetrics.resolved(stored: 200) == 200)
    }

    @Test func sidebarWidthClampTest() {
        #expect(SidebarMetrics.clamp(SidebarMetrics.minWidth - 100) == SidebarMetrics.minWidth)
        #expect(SidebarMetrics.clamp(SidebarMetrics.maxWidth + 100) == SidebarMetrics.maxWidth)
        #expect(SidebarMetrics.clamp(320) == 320)
    }

    @Test func sidebarPersistenceTest() {
        let suite = "tests-sidebar-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(SidebarPersistence.resolvedVisible(defaults: defaults))
        SidebarPersistence.saveVisible(false, defaults: defaults)
        #expect(!SidebarPersistence.resolvedVisible(defaults: defaults))
        SidebarPersistence.saveVisible(true, defaults: defaults)
        #expect(SidebarPersistence.resolvedVisible(defaults: defaults))

        SidebarPersistence.saveWidth(10, defaults: defaults)
        #expect(SidebarPersistence.resolvedWidth(defaults: defaults) == SidebarMetrics.minWidth)
        SidebarPersistence.saveWidth(320, defaults: defaults)
        #expect(SidebarPersistence.resolvedWidth(defaults: defaults) == 320)
    }

    @Test func sidebarToggleAnimationStateTest() {
        let width: CGFloat = 260
        #expect(SidebarMetrics.effectiveWidth(visible: true, width: width) == width)
        #expect(SidebarMetrics.effectiveWidth(visible: false, width: width) == 0)
        #expect(SidebarMetrics.effectiveWidth(visible: true, width: 9_000) == SidebarMetrics.maxWidth)
    }

    // MARK: Deliverable 6 — window frame validation

    @Test func windowFrameStaysOnScreen() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let fallback = CGSize(width: 1080, height: 720)

        // Reachable frame is returned unchanged.
        let onScreen = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(WindowFramePolicy.validate(onScreen, screens: [screen], fallbackSize: fallback) == onScreen)

        // A frame on a vanished display is re-centred (keeping its size) onto the primary screen.
        let offScreen = CGRect(x: 6000, y: 6000, width: 800, height: 600)
        let recovered = WindowFramePolicy.validate(offScreen, screens: [screen], fallbackSize: fallback)
        #expect(recovered.size == offScreen.size)
        #expect(WindowFramePolicy.isSufficientlyVisible(recovered, on: [screen]))

        // No screens → fallback size at origin (headless/test).
        let headless = WindowFramePolicy.validate(.zero, screens: [], fallbackSize: fallback)
        #expect(headless.size == fallback)

        // Empty saved frame with screens → centred fallback size, on screen.
        let firstRun = WindowFramePolicy.validate(.zero, screens: [screen], fallbackSize: fallback)
        #expect(firstRun.size == fallback)
        #expect(WindowFramePolicy.isSufficientlyVisible(firstRun, on: [screen]))
    }

    @Test func windowFramePersistenceNotBrokenTest() {
        let suite = "tests-window-frame-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let finalFrame = CGRect(x: 80, y: 90, width: 1_100, height: 740)
        defaults.set(NSStringFromRect(finalFrame), forKey: AppSettingsKey.mainWindowFrame)
        let restored = WindowFramePolicy.validate(
            NSRectFromString(defaults.string(forKey: AppSettingsKey.mainWindowFrame) ?? ""),
            screens: [CGRect(x: 0, y: 0, width: 1_920, height: 1_080)],
            fallbackSize: CGSize(width: 1_080, height: 720)
        )
        #expect(restored == finalFrame)
    }

    // MARK: Deliverable 3 — cache status math

    @Test func cacheCoverageMath() {
        var status = OfflineCacheStatus()
        #expect(status.thumbnailCoverage == 1)               // no assets yet
        status.totalAssets = 200
        status.thumbnailsOnDisk = 50
        #expect(abs(status.thumbnailCoverage - 0.25) < 1e-9)
        status.cacheSizeBytes = 10
        status.previewCacheSizeBytes = 7
        #expect(status.totalCacheSizeBytes == 17)
    }

    // MARK: Deliverable 5 — video state machine

    @Test func videoStateMachineTransitions() {
        #expect(VideoPlayerItemStatus.readyToPlay.nextState(error: nil) == .playing)
        #expect(VideoPlayerItemStatus.failed.nextState(error: .decryptionFailed) == .failed(.decryptionFailed))
        #expect(VideoPlayerItemStatus.unknown.nextState(error: nil) == nil)   // keep current state

        #expect(VideoViewerState.downloading(0.42).progress == 0.42)
        #expect(VideoViewerState.playing.progress == 1)
        #expect(VideoViewerState.resolving.isBusy)
        #expect(VideoViewerState.downloading(0.1).isBusy)
        #expect(VideoViewerState.buffering(nil).isBusy)
        #expect(!VideoViewerState.playing.isBusy)                       // no infinite spinner once playing
        #expect(!VideoViewerState.failed(.timedOut).isBusy)            // …or once failed
        #expect(VideoViewerState.failed(.networkUnavailable).errorMessage == VideoPlaybackError.networkUnavailable.userMessage)
        #expect(VideoViewerState.ready.errorMessage == nil)
    }

    @Test func videoLogFieldsContract() {
        let fields = videoViewerLogFields(
            uid: PhotoUID(volumeID: "v", nodeID: "n"),
            state: .downloading(0.5),
            localURLExists: true,
            assetPlayable: false,
            playerItemStatus: 0,
            error: nil
        )
        #expect(fields["uid"] == "v~n")
        #expect(fields["state"] == "downloading")
        #expect(fields["progress"] == "0.50")
        #expect(fields["localURLExists"] == "true")
        #expect(fields["assetPlayable"] == "false")
        #expect(fields["playerItemStatus"] == "0")
        #expect(fields["error"] == "none")
    }

    // MARK: Deliverable 2 — prefetch priority + pause

    @Test func thumbnailPriorityIsOrdered() {
        // Visible work outranks every background tier; idle crawl is last.
        let order: [ThumbnailPriority] = [
            .visibleNow, .zoomAnchorAndFocusRow, .likelyZoomOutTargetCoverage,
            .nearViewportScrollAhead, .idleLibraryCrawl,
        ]
        for (a, b) in zip(order, order.dropFirst()) { #expect(a < b) }
        #expect(order.min() == .visibleNow)
        #expect(order.max() == .idleLibraryCrawl)
    }

    @Test func prefetchPauseReasons() async {
        let namespace = "tests-pause-\(UUID().uuidString)"
        let root = timelineFeatureTestCacheRoot("pause")
        let aspects = await MainActor.run { AspectRegistry(namespace: namespace, rootDirectory: root) }
        let feed = ThumbnailFeed(cache: ThumbnailCache(namespace: namespace, rootDirectory: root),
                                 loader: StubThumbnailLoader(), aspects: aspects,
                                 concurrency: 1, batch: 1)
        await feed.startPrefetch([PhotoUID(volumeID: "v", nodeID: "a")])

        await feed.setUserInteractionActive(true)
        var status = await feed.prefetchStatus()
        #expect(status.paused)
        #expect(status.pausedReason == "interaction")    // paused during scroll/pinch

        await feed.setUserInteractionActive(false)
        await feed.pausePrefetch()
        status = await feed.prefetchStatus()
        #expect(status.pausedReason == "manual")

        await feed.resumePrefetch()
        await feed.setPrefetchEnabled(false)
        status = await feed.prefetchStatus()
        #expect(!status.enabled)
        #expect(status.pausedReason == "disabled")        // offline toggle off
    }

    // MARK: Deliverable (DB) — timeline query plan

    /// Mirrors the schema + indexes of `DriveSDKBridge.PhotoTimelineStore`. Asserts the ordered
    /// timeline scan rides the `t` index (no temp b-tree sort) and the UID lookup is an index search,
    /// not a full table scan.
    @Test func timelineQueryPlanUsesIndexes() throws {
        var db: OpaquePointer?
        #expect(sqlite3_open(":memory:", &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        exec(db, """
        CREATE TABLE photos(
          node TEXT PRIMARY KEY, vol TEXT, t REAL, mime TEXT, live INTEGER, relvid TEXT,
          tags TEXT DEFAULT '', burst TEXT DEFAULT ''
        );
        """)
        exec(db, "CREATE INDEX idx_photos_t ON photos(t ASC);")
        exec(db, "CREATE INDEX idx_photos_vol_node ON photos(vol, node);")

        let orderPlan = queryPlan(db, "SELECT node, vol, t, mime, live, relvid, tags, burst FROM photos ORDER BY t ASC;")
        #expect(orderPlan.contains("idx_photos_t"))
        #expect(!orderPlan.uppercased().contains("TEMP B-TREE"))   // index satisfies the ORDER BY

        let lookupPlan = queryPlan(db, "SELECT t FROM photos WHERE vol = 'x' AND node = 'y';")
        #expect(lookupPlan.uppercased().contains("SEARCH"))        // index search, not full SCAN
        #expect(!lookupPlan.uppercased().contains("SCAN PHOTOS"))
    }

    @Test func aspectRegistryUsesInjectedRootAndPersistsThere() async throws {
        let namespace = "tests-aspects-\(UUID().uuidString)"
        let root = timelineFeatureTestCacheRoot("aspects")
        let uid = PhotoUID(volumeID: "vol", nodeID: "aspect")
        let productionURL = AspectRegistry.storageURL(namespace: namespace)
        try? FileManager.default.removeItem(at: productionURL)

        let registry = await MainActor.run { AspectRegistry(namespace: namespace, rootDirectory: root) }
        registry.record(uid, aspect: 1.5)
        try await Task.sleep(for: .milliseconds(180))

        let reloaded = await MainActor.run { AspectRegistry(namespace: namespace, rootDirectory: root) }
        let aspect = await MainActor.run { reloaded.aspect(for: uid) }
        #expect(abs(aspect - 1.5) < 0.0001)
        #expect(FileManager.default.fileExists(atPath: AspectRegistry.storageURL(namespace: namespace, rootDirectory: root).path))
        #expect(!FileManager.default.fileExists(atPath: productionURL.path))
    }

    @Test func aspectRegistryDefaultPathContractStaysInProtonPhotosCaches() {
        let namespace = "tests-default-path-\(UUID().uuidString)"
        let expected = AspectRegistry.defaultRootDirectory().appendingPathComponent("\(namespace).json")
        #expect(AspectRegistry.storageURL(namespace: namespace) == expected)
    }

    @Test func metalGridStatsFrameSurfacesRenderAndUploadCounters() {
        let stats = MetalGridStats.frame(
            visibleCount: 7,
            overscanCount: 3,
            realCount: 5,
            cellCount: 8,
            textureUploads: 2,
            textureUploadBytes: 4_096,
            textureUploadMs: 1.25,
            evictions: 1,
            residentBytes: 8_192,
            drawCalls: 6,
            textureBinds: 7,
            instanceCount: 5,
            gpuDrawMs: 0.75
        )
        #expect(stats.visibleItems == 7)
        #expect(stats.overscanItems == 3)
        #expect(stats.realTextureItems == 5)
        #expect(stats.placeholderItems == 3)
        #expect(stats.textureUploads == 2)
        #expect(stats.textureUploadBytes == 4_096)
        #expect(stats.textureUploadMs == 1.25)
        #expect(stats.evictions == 1)
        #expect(stats.memoryEstimateBytes == 8_192)
        #expect(stats.cacheHits == 5)
        #expect(stats.cacheMisses == 3)
        #expect(stats.drawCalls == 6)
        #expect(stats.textureBinds == 7)
        #expect(stats.instanceCount == 5)
        #expect(stats.gpuDrawMs == 0.75)
    }

    // MARK: - SQLite helpers

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        #expect(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func queryPlan(_ db: OpaquePointer?, _ sql: String) -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + sql, -1, &stmt, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(stmt) }
        var lines: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let detail = sqlite3_column_text(stmt, 3) { lines.append(String(cString: detail)) }
        }
        return lines.joined(separator: " | ")
    }
}

private actor StubThumbnailLoader: ThumbnailBatchLoader {
    func loadThumbnails(for uids: [PhotoUID], onLoaded: @Sendable @escaping (PhotoUID, Data) -> Void) async {}
}
