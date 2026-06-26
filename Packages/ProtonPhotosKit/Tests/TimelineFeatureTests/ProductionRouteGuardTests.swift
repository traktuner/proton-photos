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
        // all be gone — the accepted Phase-B effect path is the production default, with no flag of any kind.
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
        #expect(scanned > 0, "Guard scanned no files — repoRoot path is wrong: \(Self.repoRoot.path)")
    }

    @Test func gridFeedUsesSharedConfiguredCache() throws {
        let mainView = Self.repoRoot.appendingPathComponent("App/Views/MainView.swift")
        let text = try String(contentsOf: mainView, encoding: .utf8)
        // The grid feed must be built with the account-configured shared cache, never a throwaway instance.
        #expect(text.contains("ThumbnailFeed(cache: OfflineLibraryManager.shared.cache"))
        #expect(!text.contains("ThumbnailFeed(cache: ThumbnailCache()"))
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
        #expect(text.contains("geo.safeAreaInsets.leading"))             // obstruction-inset source (== sidebar width)
        #expect(text.contains("gridLeadingEventInset"))                  // inset threaded to the Metal grid host
        #expect(text.contains(".protonPhotosToggleSidebar"))             // ⌥⌘S receiver kept (the native toolbar toggle returns)
        #expect(!text.contains("ZStack(alignment: .topLeading)"))        // the hand-rolled overlay layout is gone
        #expect(!text.contains("SidebarPersistence.saveWidth"))          // no custom drag-resize handle (native resize)
        #expect(!text.contains("Label(\"Toggle sidebar\""))             // no duplicate / explicit toggle label
    }

    @Test func sidebarFilterChangesUseInitialViewportPolicy() throws {
        // A sidebar route switch opens the route via a ONE-SHOT INITIAL-VIEWPORT POLICY owned by the Metal grid
        // host — restoring the route's remembered scroll position, or opening at newest on first visit — NEVER an
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

        // The generation must be bumped SYNCHRONOUSLY, BEFORE the async `select(...)` load — this is the race fix
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
                    "the generation must be bumped BEFORE the async select(...) — gen-after-load reintroduces the token/generation race")
        }

        let timelineView = Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature/TimelineView.swift")
        let timelineText = try String(contentsOf: timelineView, encoding: .utf8)
        #expect(timelineText.contains("private let routeScrollGeneration: Int"))
        #expect(timelineText.contains("routeScrollGeneration: Int = 0"))
        #expect(timelineText.contains("routeScrollGeneration: routeScrollGeneration"))
        #expect(timelineText.contains("routeInitialScrollAnchor: routeInitialScrollAnchor"))   // memory threaded through
        #expect(timelineText.contains("MetalGridProductionAdapter.dateMarkers(sections: visibleSections, granularity: .month)"))
        #expect(timelineText.contains("if level >= 4, monthMarkers.count > 1"))
        #expect(timelineText.contains("TimelineDateScrubber(markers: monthMarkers)"))
        #expect(timelineText.contains("proxy?.scrollToFlatIndex?(marker.index)"))

        let productionView = Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalProductionGridView.swift")
        let productionText = try String(contentsOf: productionView, encoding: .utf8)
        #expect(productionText.contains("var routeScrollGeneration: Int = 0"))
        #expect(productionText.contains("appliedRouteScrollGeneration"))
        #expect(productionText.contains("proxy.scrollToFlatIndex"))
        // The route data-source switch installs the route's initial-viewport policy ALONGSIDE the new data,
        // gated on a pending route generation (else `.preserve` — incremental updates never re-place).
        #expect(productionText.contains("initialViewport: routeChangePending ? routeInitialViewport : .preserve"))
        // The rejected immediate-scroll route hook must be gone everywhere.
        #expect(!productionText.contains("showNewestOnceForRouteChange"))

        // `makeNSView` couples "mark generation applied" to arming a REAL placement, gated on a generation
        // mismatch — so host recreation installs a real placement rather than swallowing it. These are
        // UNCONDITIONAL (a refactor that drops the coupling must fail the guard, not silently skip it).
        let makeBody = try Self.body(of: productionText, from: "func makeNSView(context: Context) -> NSView {", to: "func updateNSView")
        #expect(makeBody.contains("host.requestInitialViewport(routeInitialViewport)"),
                "makeNSView must arm a real placement when it marks the generation applied")
        #expect(makeBody.contains("if routeScrollGeneration != coord.appliedRouteScrollGeneration"),
                "makeNSView must gate the placement+mark on a generation mismatch (never unconditional)")

        // Neither the makeNSView nor the updateNSView body may scroll the grid directly on a route change — the
        // host owns placement. (The proxy wiring of scrollToLatest/currentScrollAnchor lives in `wireProxy`, out
        // of these bodies.)
        let updateBody = try Self.body(of: productionText, from: "func updateNSView(_ nsView: NSView, context: Context) {", to: "private var routeInitialViewport")
        for (name, body) in [("makeNSView", makeBody), ("updateNSView", updateBody)] {
            #expect(!body.contains("scrollToBottom("), "\(name) must not scroll the grid directly")
            #expect(!body.contains("scrollToLatest?()"), "\(name) must not scroll the grid directly")
        }

        let host = Self.repoRoot.appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature/MetalGridScrollHost.swift")
        let hostText = try String(contentsOf: host, encoding: .utf8)
        // The host owns the pending initial-viewport state + the policy type (incl. `.restore`), `setDataSource`
        // takes the policy, and it exposes the read-only scroll offset the shell remembers per route.
        #expect(hostText.contains("enum GridInitialViewport"))
        #expect(hostText.contains("case restore(GridScrollAnchor)"))
        #expect(hostText.contains("struct GridScrollAnchor"))          // layout-invariant photo anchor (exact restore)
        #expect(hostText.contains("pendingInitialViewport"))
        #expect(hostText.contains("func setDataSource(_ source: MetalGridDataSource, initialViewport: GridInitialViewport"))
        #expect(hostText.contains("func currentScrollAnchor()"))
        #expect(hostText.contains("func scrollToFlatIndex(_ index: Int)"))
        #expect(hostText.contains("coordinator.cellContentRect(forFlatIndex: index)"))
        #expect(hostText.contains("coordinator.cellContentRect(forUID: anchor.uid)"))   // restore re-resolves the photo's current position
        #expect(!hostText.contains("func showNewestOnceForRouteChange"))
        // Unrelated hit-test inset invariants (kept stable by this change).
        #expect(hostText.contains("if point.x < eventLeadingInset"))
        #expect(!hostText.contains("convert(point, from: superview)"))

        // The pending policy is consumed from `applyContentSize`, only AFTER the geometry guard, and the clear is
        // gated on a valid window + clip height — so an invalid-geometry pass NEVER clears the policy early.
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
