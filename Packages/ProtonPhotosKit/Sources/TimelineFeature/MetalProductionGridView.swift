import SwiftUI
import AppKit
import Metal
import PhotosCore
import MediaCache
import GridCore
import TimelineCore

/// Leading event-inset (in points) for the grid: while a translucent sidebar overlays the grid's leading
/// edge, the host declines hit-testing for `x < inset` so those events reach the sidebar. The grid still
/// renders + lays out full-width (photos animate behind the sidebar). Set by the shell; 0 by default.
public struct GridLeadingEventInsetKey: EnvironmentKey {
    public static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    var gridLeadingEventInset: CGFloat {
        get { self[GridLeadingEventInsetKey.self] }
        set { self[GridLeadingEventInsetKey.self] = newValue }
    }
}

/// The window's translucent toolbar height. The grid bakes it into the engine's top layout margin so the first
/// row rests below the toolbar instead of being tucked under it. Set by the shell; 0 by default.
public struct GridTopBarInsetKey: EnvironmentKey {
    public static let defaultValue: CGFloat = 0
}

public extension EnvironmentValues {
    var gridTopBarInset: CGFloat {
        get { self[GridTopBarInsetKey.self] }
        set { self[GridTopBarInsetKey.self] = newValue }
    }
}

/// The production wrapper around `MetalGridScrollHost` - the Metal-backed library grid (the only timeline
/// grid). The canonical `SquareTileGridEngine` owns all geometry; this adds real-data binding, selection,
/// double-click viewer handoff, zoom-level changes, month labels, badges, and `GridProxy` wiring
/// (windowFrame / scrollToItem / scrollToLatest / zoom).
struct MetalProductionGridView: NSViewRepresentable {
    @Environment(\.gridLeadingEventInset) private var leadingEventInset
    @Environment(\.gridTopBarInset) private var topBarInset
    let sections: [TimelineSection]
    let allItems: [PhotoItem]
    let feed: ThumbnailFeed
    @Binding var level: Int
    var routeScrollGeneration: Int = 0
    /// The target the next route placement should open at: a remembered photo anchor (returning to a
    /// previously-visited route), or `nil` to open at the newest end (first visit / launch). Set by the shell
    /// alongside `routeScrollGeneration`; consumed once per generation as the host's initial-viewport policy.
    var routeInitialScrollAnchor: GridScrollAnchor<PhotoUID>? = nil
    let gridProfile: GridLevelProfile
    let gridProfileResolver: TimelineGridProfileResolver?
    var gridFillOrder: GridFillOrder = .newestBottomTrailing
    let onOpen: (PhotoItem, [PhotoItem]) -> Void
    var proxy: GridProxy<PhotoUID>?
    var selectionMode: Bool = false
    var onSelectionChange: (Set<PhotoUID>) -> Void = { _ in }
    var favoriteUIDs: Set<PhotoUID> = []
    var media: FullMediaProvider?            // reserved for drag-to-Finder (deferred - see report)
    var metadataProvider: PhotoMetadataProvider?  // reserved for duration-text badge (deferred)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coord = context.coordinator
        guard let device = MTLCreateSystemDefaultDevice(),
              let host = MetalGridScrollHost(
                device: device,
                dataSource: MetalGridProductionAdapter.makeDataSource(sections: sections, feed: feed),
                gridProfile: gridProfile,
                fillOrder: gridFillOrder,
                gridProfileResolver: gridProfileResolver
              ) else {
            // Only reachable if Metal can't initialise on this machine (no GPU / shader build fails); emit a
            // diagnostic and return an empty view rather than crash.
            PhotoDiagnostics.shared.emit("MetalGridFallback", ["reason": "hostInitFailed"])
            return NSView()
        }
        host.coordinator.decorationsEnabled = true
        host.eventLeadingInset = leadingEventInset
        host.topBarInset = topBarInset
        coord.host = host
        coord.allItems = allItems
        coord.onOpen = onOpen
        coord.onSelectionChange = onSelectionChange
        coord.dataToken = MetalGridProductionAdapter.dataToken(sections: sections)
        // A freshly created host opens at its route's initial viewport. At launch (generation 0) the host's
        // default `stickToBottom` already opens at newest, so leave the generation untouched. When the host is
        // (re)created mid-session at a non-zero generation - e.g. returning to a large route after an empty/small
        // one destroyed the host - arm the one-shot policy so a REAL placement happens via the host's layout
        // path, then record the generation as satisfied by THAT placement. The shell sets `routeInitialScrollAnchor`
        // synchronously before the generation bumps, so it is already correct here. This couples "mark applied"
        // to a real placement: `makeNSView` never marks a generation applied without also installing the policy
        // that will place it, so host recreation can't swallow the route placement.
        if routeScrollGeneration != coord.appliedRouteScrollGeneration {
            host.requestInitialViewport(routeInitialViewport)
            coord.appliedRouteScrollGeneration = routeScrollGeneration
        }

        let selection = MetalGridSelectionController()
        let interaction = MetalGridInteractionController(coordinator: host.coordinator, selection: selection)
        interaction.selectionMode = selectionMode
        interaction.onOpen = { [weak coord] uid in
            guard let coord, let item = coord.allItems.first(where: { $0.uid == uid }) else { return }
            coord.onOpen?(item, coord.allItems)
        }
        selection.onChange = { [weak coord] set in
            coord?.host?.coordinator.setSelection(set)
            coord?.a11y?.selected = set
            coord?.onSelectionChange?(set)
        }
        coord.selection = selection
        coord.interaction = interaction
        host.onCellClick = { [weak coord] point, clickCount, modifiers in
            coord?.interaction?.handleClick(contentPoint: point, clickCount: clickCount, modifiers: modifiers)
        }
        host.onMarqueeBegan = { [weak coord] mods in
            coord?.interaction?.handleMarqueeBegan(additive: mods.contains(.shift))
        }
        host.onMarqueeChanged = { [weak coord] rect in
            coord?.interaction?.handleMarqueeChanged(contentRect: rect)
        }
        host.onMarqueeEnded = { [weak coord] in
            coord?.interaction?.handleMarqueeEnded()
        }

        let header = MetalGridHeaderRenderer(coordinator: host.coordinator)
        header.overlay.frame = host.bounds
        host.addSubview(header.overlay)                 // topmost, transparent to events
        header.markers = MetalGridProductionAdapter.monthMarkers(sections: sections)
        coord.header = header

        let a11y = MetalGridAccessibilityProvider(host: host, coordinator: host.coordinator)
        a11y.items = allItems
        a11y.onOpen = interaction.onOpen
        coord.a11y = a11y

        host.onViewportChanged = { [weak coord] in
            coord?.header?.reposition()
            coord?.a11y?.invalidate()
        }

        host.coordinator.setSelectionMode(selectionMode)
        host.coordinator.setFavorites(favoriteUIDs)
        wireProxy(host: host, levelBinding: $level)
        host.setLevel(level)
        MetalGridRuntime.logResolutionOnce()
        return host
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let host = nsView as? MetalGridScrollHost else { return }
        host.eventLeadingInset = leadingEventInset
        host.topBarInset = topBarInset
        host.updateFillOrder(gridFillOrder)
        host.updateGridProfileResolver(gridProfileResolver)
        let coord = context.coordinator
        coord.allItems = allItems
        coord.onOpen = onOpen
        coord.onSelectionChange = onSelectionChange
        coord.interaction?.selectionMode = selectionMode
        coord.a11y?.items = allItems
        coord.a11y?.selected = host.coordinator.selectedUIDs

        // A sidebar route switch bumps `routeScrollGeneration` SYNCHRONOUSLY (before the async `select(...)` that
        // loads the route), so by the time the new route's sections arrive (the data token changes) the
        // generation is already pending. The route's target - open at its remembered position or at the newest
        // end - is expressed as a one-shot initial-viewport POLICY installed ALONGSIDE the new data and consumed
        // by the host once layout geometry is valid (NOT an immediate scroll from here). The placement and the
        // generation-consume are coupled to the token change: because the generation is bumped before the data,
        // `routeChangePending` is already true when the new token lands - so the policy is installed exactly once
        // against the new data, regardless of how SwiftUI splits/coalesces the passes. An incremental data update
        // (token changes with no pending generation) installs `.preserve`, never yanking a scrolled-up user.
        let routeChangePending = routeScrollGeneration != coord.appliedRouteScrollGeneration
        let token = MetalGridProductionAdapter.dataToken(sections: sections)
        if token != coord.dataToken {
            coord.dataToken = token
            host.setDataSource(MetalGridProductionAdapter.makeDataSource(sections: sections, feed: feed),
                               initialViewport: routeChangePending ? routeInitialViewport : .preserve)
            coord.header?.markers = MetalGridProductionAdapter.monthMarkers(sections: sections)
            if routeChangePending { coord.appliedRouteScrollGeneration = routeScrollGeneration }
        }
        // NOTE: the generation is reconciled ONLY inside the token-change branch above. This is deliberate - it
        // is what makes the placement race-free (the generation is bumped before the load, so it is already
        // pending when the new token lands). It must NOT be advanced unconditionally: doing so would consume the
        // generation in the old-data pass, before the new token arrives, re-creating the very race this fixes.
        // The only residual is a rare leak if two consecutive routes share a `dataToken`
        // (hash(count, firstUID, lastUID)) - then the token never changes, the generation stays pending, and a
        // later incremental update re-pins the route's remembered anchor. It is benign (re-pins ≈ the user's
        // current spot) and self-heals on the next route switch.
        host.coordinator.setSelectionMode(selectionMode)
        host.coordinator.setFavorites(favoriteUIDs)
        // Honour a genuine external (+/- / keyboard / programmatic) level change, but IGNORE a stale `level`
        // binding value left over from a host-led pinch commit - re-driving it would re-anchor at the viewport
        // centre and jump a different photo under the cursor. See `LevelBindingReconciler`.
        host.reconcileLevelBinding(level)
        wireProxy(host: host, levelBinding: $level)
        coord.header?.reposition()
    }

    /// The host initial-viewport policy for the current route: restore a remembered photo anchor, or open at
    /// the newest end when there is none (first visit / launch).
    private var routeInitialViewport: GridInitialViewport {
        routeInitialScrollAnchor.map { .restore($0) }
            ?? (gridFillOrder == .newestBottomTrailing ? .newest : .oldest)
    }

    private func wireProxy(host: MetalGridScrollHost, levelBinding: Binding<Int>) {
        let levelCount = host.coordinator.levelCount   // engine ladder (incl. the larger level 0)
        let stepIn = { levelBinding.wrappedValue = max(0, levelBinding.wrappedValue - 1) }
        let stepOut = { levelBinding.wrappedValue = min(levelCount - 1, levelBinding.wrappedValue + 1) }
        // The live trackpad pinch reports the settled level on release → keep the SwiftUI `level` in sync.
        host.onZoomCommit = { settled in levelBinding.wrappedValue = settled }
        guard let proxy else { return }
        proxy.windowFrameForItem = { [weak host] uid in host?.windowFrame(forUID: uid) }
        proxy.scrollToItem = { [weak host] uid in host?.scrollToItem(uid) }
        proxy.scrollToFlatIndex = { [weak host] index in host?.scrollToFlatIndex(index) }
        proxy.scrollToLatest = { [weak host] in host?.scrollToBottom() }
        proxy.currentScrollAnchor = { [weak host] in host?.currentScrollAnchor() }   // read-only; shell remembers it per route
        proxy.zoomIn = stepIn
        proxy.zoomOut = stepOut
        // Grid → shell EVENT: first fully-drawn frame → forward to the shell (it holds the launch veil for this).
        host.coordinator.onFirstContentReady = { [weak proxy] in proxy?.onFirstContentReady?() }
        // Aspect/square toggle → the coordinator's content-mode preference (content fit only; no geometry change).
        proxy.toggleContentMode = { [weak host] in host?.coordinator.toggleContentMode() }
        proxy.setContentMode = { [weak host] mode in host?.coordinator.setPreferredNormalLevelContentMode(mode) }
        proxy.contentModeState = { [weak host] in
            guard let c = host?.coordinator else { return (.aspectFitInsideSquare, false) }
            return (c.preferredNormalLevelContentMode, c.aspectToggleAvailable)
        }
    }

    @MainActor final class Coordinator {
        weak var host: MetalGridScrollHost?
        var selection: MetalGridSelectionController?
        var interaction: MetalGridInteractionController?
        var header: MetalGridHeaderRenderer?
        var a11y: MetalGridAccessibilityProvider?
        var allItems: [PhotoItem] = []
        var onOpen: ((PhotoItem, [PhotoItem]) -> Void)?
        var onSelectionChange: ((Set<PhotoUID>) -> Void)?
        var dataToken = 0
        var appliedRouteScrollGeneration = 0
    }
}
