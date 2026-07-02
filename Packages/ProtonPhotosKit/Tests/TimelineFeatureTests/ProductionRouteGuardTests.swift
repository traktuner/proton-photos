import Foundation
import Testing

/// Static source guards: removed/insecure production routes must not reappear, and the grid feed must use the
/// shared account-configured cache. Scans App/ + the package Sources/ (NOT Tests/, which holds these literals).
@Suite("Production route guards")
struct ProductionRouteGuardTests {
    /// `<repo>/Packages/ProtonPhotosKit/Tests/TimelineFeatureTests/ProductionRouteGuardTests.swift` → `<repo>`.
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TimelineFeatureTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // ProtonPhotosKit
            .deletingLastPathComponent()   // Packages
            .deletingLastPathComponent()   // <repo>
    }

    private func swiftFiles(under dir: URL) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    @Test func noRemovedProductionRoutesRemain() {
        // The spike tuning UI, the rejected focusRow crossfade flag, AND the single-lattice gating flag must
        // all be gone - the accepted Phase-B effect path is the production default, with no flag of any kind.
        let forbidden = ["anim-tuning", "TuningView", "AnimationTuning",
                         "MetalGrid.focusRowTransition", "MetalGridFocusRowTransitionFlag",
                         "MetalGrid.singleLatticeTransition", "MetalGridSingleLatticeTransitionFlag"]
        let roots = [Self.repoRoot.appendingPathComponent("App"),
                     Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources")]
        var scanned = 0
        for root in roots {
            for file in swiftFiles(under: root) {
                scanned += 1
                let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                for token in forbidden {
                    #expect(!text.contains(token), "Forbidden production route '\(token)' found in \(file.path)")
                }
            }
        }
        #expect(scanned > 0, "Guard scanned no files - repoRoot path is wrong: \(Self.repoRoot.path)")
    }

    @Test func gridFeedUsesSharedConfiguredCache() throws {
        let mainView = Self.repoRoot.appendingPathComponent("App/Views/MainView.swift")
        let text = try String(contentsOf: mainView, encoding: .utf8)
        // The grid feed must be built with the account-configured shared cache, never a throwaway instance.
        #expect(text.contains("ThumbnailFeed(cache: OfflineLibraryManager.shared.cache"))
        #expect(!text.contains("ThumbnailFeed(cache: ThumbnailCache()"))
    }

    @Test func appAccountDataCacheIsEncryptedAndCleared() throws {
        let accountCache = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Drive/AccountDataCache.swift"), encoding: .utf8)
        #expect(accountCache.contains("AES.GCM.seal"), "account cache must seal raw account JSON before writing")
        #expect(accountCache.contains("AES.GCM.open"), "account cache must authenticate/decrypt before use")
        #expect(accountCache.contains("HKDF<SHA256>.deriveKey"), "account cache key must be derived, not raw-used")
        #expect(accountCache.contains("keyPassword"), "account cache must be bound to the unlocked Proton secret")
        #expect(accountCache.contains("uid"), "account cache must be account-scoped")

        let driveSession = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Drive/DriveSession.swift"), encoding: .utf8)
        #expect(driveSession.contains("AccountDataCache.save(users: uData, addresses: aData, uid: current.uid, keyPassword: current.keyPassword)"))
        #expect(driveSession.contains("AccountDataCache.load(uid: current.uid, keyPassword: current.keyPassword)"))

        let bridge = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Drive/DriveSDKBridge.swift"), encoding: .utf8)
        #expect(bridge.contains("driveSession.cachedAccountData()"),
                "offline cold start must use only the encrypted account cache fallback")

        let appModel = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/AppModel.swift"), encoding: .utf8)
        #expect(appModel.contains("AccountDataCache.clear(uid: session.uid)"),
                "sign-out must clear encrypted account cache blobs")
    }

    @Test func sdkSecretCacheIsInMemoryOnly() throws {
        let bridge = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Drive/DriveSDKBridge.swift"), encoding: .utf8)
        #expect(bridge.contains("\"secrets.sqlite\"") && bridge.contains("\"secrets.sqlite-wal\"") && bridge.contains("\"secrets.sqlite-shm\""),
                "startup must purge legacy SDK plaintext secret-cache files")
        let config = try Self.body(of: bridge, from: "let config = ProtonDriveClientConfiguration(", to: "self.photosClient = try await ProtonPhotosClient(")
        #expect(config.contains("entityCachePath:"), "non-secret entity cache may stay on disk")
        #expect(!config.contains("secretCachePath:"), "SDK decrypted key material must not be persisted via secretCachePath")
        #expect(!config.contains("secretCacheEncryptionKey:"), "do not claim encrypted SDK secret persistence until the native core actually honors it")
    }

    @Test func viewerOriginalsCacheIsReadBeforeNetworkAndPurgedBySettings() throws {
        let mainView = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Views/MainView.swift"), encoding: .utf8)
        #expect(mainView.contains("originalsCache: offline.originalsCache"))
        #expect(mainView.contains("cacheOriginals: offline.offlineEnabled"))
        #expect(mainView.contains("originalsCapBytes: offline.originalsCapBytes"))

        let viewer = try String(contentsOf: Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotoViewerFeature/PhotoViewerModel.swift"), encoding: .utf8)
        #expect(viewer.contains("oc.diskData(for: uid)"), "viewer must check encrypted originals cache before download")
        #expect(viewer.contains("oc.storeToDisk(data, for: uid)"), "viewer must persist downloaded originals when enabled")
        #expect(viewer.contains("oc.enforceByteCap(cap)"), "viewer must enforce the originals LRU budget after writes")
        let originalsRead = viewer.range(of: "if let oc = self.originalsCache")
        let thumbnailFallback = viewer.range(of: "if self.image == nil, let thumb = await self.feed.image")
        #expect(originalsRead != nil, "viewer must have an originals-cache read block")
        #expect(thumbnailFallback != nil, "viewer must still have the thumbnail fallback")
        if let o = originalsRead, let t = thumbnailFallback {
            #expect(o.upperBound <= t.lowerBound, "originals cache must be consulted before preview/thumbnail/network work")
        }
        let originalsReadBody = try Self.body(of: viewer, from: "if let oc = self.originalsCache", to: "if self.image == nil, let thumb = await self.feed.image")
        #expect(originalsReadBody.contains("return"), "originals cache hit must skip the network path")

        let offline = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Offline/OfflineLibraryManager.swift"), encoding: .utf8)
        #expect(offline.contains("originalsCache.clearAndForgetKey()"), "sign-out purge must include originals")
        #expect(offline.contains("func purgeOriginalsCache() async"), "turning offline off must have an originals-only purge")
        #expect(offline.contains("await originalsCache.clear()"))
    }

    @Test func viewerNeverPersistsDecryptedMotionVideoTempFiles() throws {
        let viewer = try String(contentsOf: Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotoViewerFeature/PhotoViewerModel.swift"), encoding: .utf8)
        #expect(!viewer.contains("temporaryDirectory"), "Live Photo motion must not write decrypted video bytes to /tmp")
        #expect(!viewer.contains("proton-motion-"), "Live Photo motion must not synthesize plaintext local movie files")
        #expect(!viewer.contains("AVPlayer(url:"), "Viewer playback must not rely on decrypted local temp files")
        #expect(viewer.contains("plaintext local motion-video files are forbidden by the local E2EE contract"))
    }

    @Test func videoBlockCacheStoreDoesNotWalkWholeTreePerBlock() throws {
        let cache = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Drive/Streaming/VideoByteRangeCache.swift"), encoding: .utf8)
        let storeBody = try Self.body(of: cache, from: "func store(uid: PhotoUID, block: Int, encrypted: Data) {", to: "    /// Clears the whole video block cache")
        #expect(storeBody.contains("sizeOnDiskLocked()"), "store must initialize from the cached size tracker")
        #expect(storeBody.contains("enforceBudgetLocked(keep:"), "store must enforce budget from the cached size tracker")
        #expect(!storeBody.contains("directorySize(root)"), "store must not rescan the full video cache tree for every block")

        let budgetBody = try Self.body(of: cache, from: "private func enforceBudgetLocked(keep: String) {", to: "private func sizeOnDiskLocked()")
        #expect(budgetBody.contains("var total = sizeOnDiskLocked()"), "budget enforcement must consume the running size tracker")
    }

    @Test func burstProviderMaterializesHiddenSeriesMembers() throws {
        let bridge = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Drive/DriveSDKBridge.swift"), encoding: .utf8)
        let body = try Self.body(of: bridge, from: "func burstGroup(containing uid: PhotoUID) async throws -> [PhotoItem] {", to: "    // MARK: - VideoStreamProvider")
        #expect(body.contains("Self.syntheticBurstMember("),
                "Proton exposes series as one visible timeline photo plus hidden RelatedPhotos; the viewer must materialize those hidden members")
        #expect(!body.contains("return memberIDs.compactMap"),
                "Do not collapse a real Proton series to only members already present in the normal timeline")
        #expect(bridge.contains("private static func syntheticBurstMember("),
                "UID-backed synthetic members let thumbnail/preview/original loading use the existing provider path")
    }

    @Test func mainViewUsesNativeSplitViewChrome() throws {
        let mainView = Self.repoRoot.appendingPathComponent("App/Views/MainView.swift")
        let text = try String(contentsOf: mainView, encoding: .utf8)
        // The library shell is a NATIVE NavigationSplitView: the floating sidebar overlays the detail, whose
        // MTKView renders FULL-WIDTH under it (`.ignoresSafeArea(.container, edges: [..., .leading])`). The grid
        // is laid out only in the unobscured area via a LEADING OBSTRUCTION INSET driven by the detail's leading
        // safe-area inset. The hand-rolled overlay ZStack + the custom drag-resize handle are gone (native
        // resize + the native toolbar toggle replace them). The invariants:
        #expect(text.contains("NavigationSplitView("))                   // native split view shell
        #expect(text.contains(".navigationSplitViewColumnWidth("))       // native column-width policy
        #expect(text.contains(".searchable(text: $searchText"))          // search on the detail toolbar
        #expect(text.contains("@State private var committedSearchText")) // UI input is debounced before filtering
        #expect(text.contains("Task.sleep(for: .milliseconds(280))"))
        #expect(text.contains("searchText: committedSearchText"))
        #expect(text.contains(".ignoresSafeArea(.container"))            // detail extends under the floating sidebar
        // The obstruction inset is derived from the KNOWN sidebar width gated on columnVisibility - SwiftUI
        // coordinate spaces / preferences don't bridge across NavigationSplitView's AppKit sidebar, so it can't be
        // measured. It must NOT wrap the grid in a GeometryReader (the per-tick resize throttle).
        #expect(text.contains("columnVisibility == .detailOnly ? 0 : sidebarWidth"))  // obstruction-inset source
        #expect(text.contains("gridLeadingEventInset"))                  // inset threaded to the Metal grid host
        #expect(text.contains(".protonPhotosToggleSidebar"))             // ⌥⌘S receiver kept (the native toolbar toggle returns)
        #expect(!text.contains("ZStack(alignment: .topLeading)"))        // the hand-rolled overlay layout is gone
        #expect(!text.contains("SidebarPersistence.saveWidth"))          // no custom drag-resize handle (native resize)
        #expect(!text.contains("Label(\"Toggle sidebar\""))             // no duplicate / explicit toggle label
    }

    @Test func liquidGlassChromeUsesNativeContracts() throws {
        let app = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/ProtonPhotosApp.swift"), encoding: .utf8)
        #expect(app.contains(".windowToolbarStyle(.unified)"), "window chrome should stay on the native unified toolbar")
        #expect(app.contains(".launchVeil(active: model.isPreparing)"), "startup must use the native launch veil instead of a black loading screen")
        #expect(!app.contains(".preferredColorScheme(.dark)"), "the app must not globally lock native Liquid Glass to dark mode")

        let mainView = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Views/MainView.swift"), encoding: .utf8)
        #expect(mainView.contains("GridTopFrost("), "Metal-backed grid needs the measured within-window frost bridge")
        #expect(mainView.contains("NSVisualEffectView()"), "toolbar frost must use public AppKit material, not painted rectangles")
        #expect(mainView.contains("view.blendingMode = .withinWindow"), "frost must sample the Metal grid inside the window")
        #expect(mainView.contains("view.state = .followsWindowActiveState"), "active/inactive toolbar vividness must remain system-driven")
        #expect(mainView.contains(".searchable(text: $searchText"), "search must remain a native toolbar search field")
        #expect(mainView.contains(".confirmationDialog(trashConfirmationTitle"), "destructive trash actions need a native confirmation dialog")
        #expect(!mainView.contains(".toolbarBackground("), "custom toolbar backgrounds box the sidebar and fight Liquid Glass")
        #expect(!mainView.contains("gridToolbarGlassFade"), "old hand-painted toolbar gradient must not return")
        #expect(!mainView.contains("SidebarResizeHandle"), "the custom sidebar resize handle must not return")

        let colors = try String(contentsOf: Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/DesignSystemCore/ProtonColors.swift"), encoding: .utf8)
        #expect(colors.contains("Color(nsColor: .windowBackgroundColor)"), "neutral backgrounds should stay semantic")
        #expect(colors.contains("public static let textNorm = Color.primary"), "foreground neutrals should stay semantic")

        let components = try String(contentsOf: Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/DesignSystemCore/ProtonComponents.swift"), encoding: .utf8)
        #expect(!components.contains("struct ProtonPrimaryButtonStyle"), "dead custom button style must not return")
        #expect(!components.contains("struct ProtonSpinner"), "dead custom spinner must not return")

        let timeline = try String(contentsOf: Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature/TimelineView.swift"), encoding: .utf8)
        #expect(timeline.contains("ContentUnavailableView"), "grid empty/error/search states should use native unavailable views")

        let uploadQueue = try String(contentsOf: Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/UploadFeature/UploadQueuePanel.swift"), encoding: .utf8)
        #expect(uploadQueue.contains("ContentUnavailableView"), "upload queue empty state should use native unavailable view")
        #expect(!uploadQueue.contains(".background(.regularMaterial)"), "popover content must not stack a second material over native popover glass")
    }

    @Test func albumsSidebarAndEmptyRoutesStayExplicit() throws {
        let mainView = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Views/MainView.swift"), encoding: .utf8)
        let sidebar = try Self.body(of: mainView, from: "private struct SidebarView: View", to: ".scrollContentBackground(.hidden)")
        #expect(sidebar.contains("Section(\"sidebar.albums\")"),
                "the Albums section must stay visible even before the account has albums")
        #expect(sidebar.contains("if albums.isEmpty"))
        #expect(sidebar.contains("Label(\"sidebar.no_albums\", systemImage: \"tray\")"))
        #expect(sidebar.contains(".disabled(true)"), "the empty-albums row is information, not a fake route")
        #expect(!sidebar.contains("if !albums.isEmpty"),
                "hiding the whole Albums section makes 'no albums' indistinguishable from a broken album fetch")

        let appStrings = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Localizable.xcstrings"), encoding: .utf8)
        #expect(appStrings.contains("\"sidebar.no_albums\""))

        let timeline = try String(contentsOf: Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature/TimelineView.swift"), encoding: .utf8)
        #expect(timeline.contains("private var emptyStateCopy"))
        #expect(timeline.contains("switch model.filter"))
        #expect(timeline.contains("empty.album_title"))
        #expect(timeline.contains("empty.filter_title"))
        #expect(timeline.contains("empty.trash_title"))

        let packageStrings = try String(contentsOf: Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotosCore/Resources/Localizable.xcstrings"), encoding: .utf8)
        for key in ["empty.album_title", "empty.album_description", "empty.filter_title %@", "empty.filter_description", "empty.trash_title", "empty.trash_description"] {
            #expect(packageStrings.contains("\"\(key)\""), "missing package localization key \(key)")
        }
    }

    @Test func motionSidebarFilterTracksProtonSdkPhotoTag() throws {
        let domain = try String(contentsOf: Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/PhotosCore/PhotoLibrary.swift"), encoding: .utf8)
        #expect(domain.contains("case motionPhotos = 4"),
                "Motion must remain aligned with Proton's server-side motionPhoto tag")
        #expect(domain.contains("case .motionPhotos: L10n.string(\"tag.motion\")"))

        let sdk = try String(contentsOf: Self.repoRoot.appendingPathComponent("Vendor/sdk-swift/Sources/Generated/proton.drive.sdk.pb.swift"), encoding: .utf8)
        #expect(sdk.contains("case motionPhoto // = 4"),
                "the vendored SDK must expose Proton_Drive_Sdk_PhotoTag.motionPhoto")

        let bridge = try String(contentsOf: Self.repoRoot.appendingPathComponent("App/Drive/DriveSDKBridge.swift"), encoding: .utf8)
        #expect(bridge.contains("fetchPhotosList(volumeID: root.volumeID, tag: tag.rawValue)"),
                "sidebar smart filters must query Proton by the server tag raw value")
    }

    @Test func sidebarFilterChangesUseInitialViewportPolicy() throws {
        // A sidebar route switch opens the route via a ONE-SHOT INITIAL-VIEWPORT POLICY owned by the Metal grid
        // host - restoring the route's remembered scroll position, or opening at newest on first visit - NEVER an
        // immediate / external / virtual scroll correction. These static guards pin that architecture (and the
        // gen-before-load ordering that makes it race-free) so the rejected immediate-scroll pattern cannot return.
        let mainView = Self.repoRoot.appendingPathComponent("App/Views/MainView.swift")
        let mainText = try String(contentsOf: mainView, encoding: .utf8)
        #expect(mainText.contains("@State private var routeScrollGeneration"))
        #expect(mainText.contains("routeScrollGeneration += 1"))
        #expect(mainText.contains("routeScrollGeneration: routeScrollGeneration"))
        // Per-route scroll-position memory: capture on leave, restore on return, threaded to the grid.
        #expect(mainText.contains("routeScrollPositions"))
        #expect(mainText.contains("currentScrollAnchor"))
        #expect(mainText.contains("routeInitialScrollAnchor: routeInitialScrollAnchor"))
        // MainView must NOT scroll-correct routes itself: no direct scrollToLatest, no per-route special-casing.
        #expect(!mainText.contains("gridProxy.scrollToLatest?()"))
        #expect(!mainText.contains("if newValue =="))
        #expect(!mainText.contains("switch newValue"))

        // The generation must be bumped SYNCHRONOUSLY, BEFORE the async `select(...)` load - this is the race fix
        // (the new data token must never arrive before the generation is pending). Pin the ordering inside the
        // route-change handler.
        let onChangeBody = try Self.body(of: mainText, from: ".onChange(of: selection)", to: ".onChange(of: timelineModel.allItems.count)")
        #expect(onChangeBody.contains("routeScrollPositions[oldValue]"))
        #expect(onChangeBody.contains("routeInitialScrollAnchor = routeScrollPositions[newValue]"))
        let genBump = onChangeBody.range(of: "routeScrollGeneration += 1")
        let asyncSelect = onChangeBody.range(of: "await timelineModel.select(newValue)")
        #expect(genBump != nil, "the route-change handler must bump the generation")
        #expect(asyncSelect != nil, "the route-change handler must load the new route")
        if let g = genBump, let s = asyncSelect {
            #expect(g.upperBound <= s.lowerBound,
                    "the generation must be bumped BEFORE the async select(...) - gen-after-load reintroduces the token/generation race")
        }

        let timelineView = Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature/TimelineView.swift")
        let timelineText = try String(contentsOf: timelineView, encoding: .utf8)
        #expect(timelineText.contains("private let routeScrollGeneration: Int"))
        #expect(timelineText.contains("routeScrollGeneration: Int = 0"))
        #expect(timelineText.contains("routeScrollGeneration: routeScrollGeneration"))
        #expect(timelineText.contains("routeInitialScrollAnchor: routeInitialScrollAnchor"))   // memory threaded through
        #expect(timelineText.contains("let showsMonthLabels = gridProfile.showsMonthLabels(level: level)"))
        #expect(timelineText.contains("includeMonthMarkers: showsMonthLabels"))
        #expect(timelineText.contains("if showsMonthLabels, visibleContent.monthMarkers.count > 1"))
        #expect(timelineText.contains("TimelineDateScrubber(markers: visibleContent.monthMarkers)"))
        #expect(timelineText.contains("proxy?.scrollToFlatIndex?(marker.index)"))

        let timelineViewModel = Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature/TimelineViewModel.swift")
        let timelineViewModelText = try String(contentsOf: timelineViewModel, encoding: .utf8)
        // Month markers are derived from the visible route's already-flattened items (the `items:` overload
        // avoids a second flatten; one-pass boundary detection replaces per-item Calendar.dateComponents).
        #expect(timelineViewModelText.contains("MetalGridProductionAdapter.dateMarkers(items: visibleItems, granularity: .month)"))

        let productionView = Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalProductionGridView.swift")
        let productionText = try String(contentsOf: productionView, encoding: .utf8)
        #expect(productionText.contains("var routeScrollGeneration: Int = 0"))
        #expect(productionText.contains("appliedRouteScrollGeneration"))
        #expect(productionText.contains("proxy.scrollToFlatIndex"))
        // The route data-source switch installs the route's initial-viewport policy ALONGSIDE the new data,
        // gated on a pending route generation (else `.preserve` - incremental updates never re-place).
        #expect(productionText.contains("initialViewport: routeChangePending ? routeInitialViewport : .preserve"))
        // The rejected immediate-scroll route hook must be gone everywhere.
        #expect(!productionText.contains("showNewestOnceForRouteChange"))

        // `makeNSView` couples "mark generation applied" to arming a REAL placement, gated on a generation
        // mismatch - so host recreation installs a real placement rather than swallowing it. These are
        // UNCONDITIONAL (a refactor that drops the coupling must fail the guard, not silently skip it).
        let makeBody = try Self.body(of: productionText, from: "func makeNSView(context: Context) -> NSView {", to: "func updateNSView")
        #expect(makeBody.contains("host.requestInitialViewport(routeInitialViewport)"),
                "makeNSView must arm a real placement when it marks the generation applied")
        #expect(makeBody.contains("if routeScrollGeneration != coord.appliedRouteScrollGeneration"),
                "makeNSView must gate the placement+mark on a generation mismatch (never unconditional)")

        // Neither the makeNSView nor the updateNSView body may scroll the grid directly on a route change - the
        // host owns placement. (The proxy wiring of scrollToLatest/currentScrollAnchor lives in `wireProxy`, out
        // of these bodies.)
        let updateBody = try Self.body(of: productionText, from: "func updateNSView(_ nsView: NSView, context: Context) {", to: "private var routeInitialViewport")
        for (name, body) in [("makeNSView", makeBody), ("updateNSView", updateBody)] {
            #expect(!body.contains("scrollToBottom("), "\(name) must not scroll the grid directly")
            #expect(!body.contains("scrollToLatest?()"), "\(name) must not scroll the grid directly")
        }

        let host = Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridScrollHost.swift")
        let hostText = try String(contentsOf: host, encoding: .utf8)
        let anchor = Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/GridCore/GridScrollAnchor.swift")
        let anchorText = try String(contentsOf: anchor, encoding: .utf8)
        // The host owns the pending initial-viewport state + the policy type (incl. `.restore`), `setDataSource`
        // takes the policy, and it exposes the read-only scroll offset the shell remembers per route.
        #expect(hostText.contains("enum GridInitialViewport"))
        #expect(hostText.contains("case restore(GridScrollAnchor<PhotoUID>)"))
        #expect(anchorText.contains("struct GridScrollAnchor<ItemID")) // layout-invariant generic item anchor
        #expect(!hostText.contains("struct GridScrollAnchor"))
        #expect(hostText.contains("pendingInitialViewport"))
        #expect(hostText.contains("func setDataSource(_ source: MetalGridDataSource, initialViewport: GridInitialViewport"))
        #expect(hostText.contains("func currentScrollAnchor()"))
        #expect(hostText.contains("func scrollToFlatIndex(_ index: Int)"))
        #expect(hostText.contains("coordinator.cellContentRect(forFlatIndex: index)"))
        #expect(hostText.contains("coordinator.cellContentRect(forUID: anchor.itemID)")) // restore re-resolves the photo's current position
        #expect(!hostText.contains("func showNewestOnceForRouteChange"))
        // Unrelated hit-test inset invariants (kept stable by this change).
        #expect(hostText.contains("if point.x < eventLeadingInset"))
        #expect(!hostText.contains("convert(point, from: superview)"))

        // The pending policy is consumed from `applyContentSize`, only AFTER the geometry guard, and the clear is
        // gated on a valid window + clip height - so an invalid-geometry pass NEVER clears the policy early.
        let applyBody = try Self.body(of: hostText, from: "private func applyContentSize(_ size: CGSize) {", to: "private func placeForInitialViewport")
        #expect(applyBody.contains("pendingInitialViewport != .preserve"))
        #expect(applyBody.contains("placeForInitialViewport(pendingInitialViewport, clipHeight: clipH)"))
        #expect(applyBody.contains("window != nil"))
        #expect(applyBody.contains("clipH > 0"))
        let guardRange = applyBody.range(of: "guard width > 1, size.height > 0 else { return }")
        let clearRange = applyBody.range(of: "pendingInitialViewport = .preserve")
        #expect(guardRange != nil, "applyContentSize must early-return on invalid geometry before touching the policy")
        #expect(clearRange != nil, "applyContentSize must clear the policy after consuming it")
        if let g = guardRange, let c = clearRange {
            #expect(g.upperBound <= c.lowerBound, "the geometry guard must precede the policy clear (no early clear)")
        }

        // Route placement must NOT re-arm sticky pinning or call the sticky bottom API.
        let placeBody = try Self.body(of: hostText, from: "private func placeForInitialViewport(_ policy: GridInitialViewport, clipHeight: CGFloat) {", to: "func requestInitialViewport")
        #expect(placeBody.contains("stickToBottom = false"))
        #expect(placeBody.contains("scrollLockOrigin = nil"))
        #expect(placeBody.contains("lastMagnifyEventTime = 0"))
        #expect(!placeBody.contains("stickToBottom = true"))
        #expect(!placeBody.contains("scrollToBottom()"))
    }

    private enum GuardError: Error { case markerNotFound }

    /// The source slice from the first occurrence of `from` up to (excluding) the next occurrence of `to`.
    private static func body(of text: String, from: String, to: String) throws -> String {
        guard let start = text.range(of: from) else {
            Issue.record("Start marker not found: \(from)")
            throw GuardError.markerNotFound
        }
        guard let end = text[start.upperBound...].range(of: to) else {
            Issue.record("End marker not found: \(to)")
            throw GuardError.markerNotFound
        }
        return String(text[start.lowerBound..<end.lowerBound])
    }
}
