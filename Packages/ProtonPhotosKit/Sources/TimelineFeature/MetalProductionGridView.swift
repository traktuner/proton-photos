import SwiftUI
import AppKit
import Metal
import PhotosCore
import MediaCache

/// The production wrapper around `MetalGridScrollHost` — the Metal-backed library grid (the only timeline
/// grid). The canonical `SquareTileGridEngine` owns all geometry; this adds real-data binding, selection,
/// double-click viewer handoff, zoom-level changes, month labels, badges, and `GridProxy` wiring
/// (windowFrame / scrollToItem / scrollToLatest / zoom).
struct MetalProductionGridView: NSViewRepresentable {
    let sections: [TimelineSection]
    let allItems: [PhotoItem]
    let feed: ThumbnailFeed
    @Binding var level: Int
    let onOpen: (PhotoItem, [PhotoItem]) -> Void
    var proxy: GridProxy?
    var selectionMode: Bool = false
    var onSelectionChange: (Set<PhotoUID>) -> Void = { _ in }
    var favoriteUIDs: Set<PhotoUID> = []
    var media: FullMediaProvider?            // reserved for drag-to-Finder (deferred — see report)
    var metadataProvider: PhotoMetadataProvider?  // reserved for duration-text badge (deferred)

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let coord = context.coordinator
        guard let device = MTLCreateSystemDefaultDevice(),
              let host = MetalGridScrollHost(device: device, dataSource: MetalGridProductionAdapter.makeDataSource(sections: sections, feed: feed)) else {
            // Only reachable if Metal can't initialise on this machine (no GPU / shader build fails); emit a
            // diagnostic and return an empty view rather than crash.
            PhotoDiagnostics.shared.emit("MetalGridFallback", ["reason": "hostInitFailed"])
            return NSView()
        }
        host.coordinator.decorationsEnabled = true
        coord.host = host
        coord.allItems = allItems
        coord.onOpen = onOpen
        coord.onSelectionChange = onSelectionChange
        coord.dataToken = MetalGridProductionAdapter.dataToken(sections: sections)

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
        let coord = context.coordinator
        coord.allItems = allItems
        coord.onOpen = onOpen
        coord.onSelectionChange = onSelectionChange
        coord.interaction?.selectionMode = selectionMode
        coord.a11y?.items = allItems
        coord.a11y?.selected = host.coordinator.selectedUIDs

        let token = MetalGridProductionAdapter.dataToken(sections: sections)
        if token != coord.dataToken {
            coord.dataToken = token
            host.setDataSource(MetalGridProductionAdapter.makeDataSource(sections: sections, feed: feed))
            coord.header?.markers = MetalGridProductionAdapter.monthMarkers(sections: sections)
        }
        host.coordinator.setSelectionMode(selectionMode)
        host.coordinator.setFavorites(favoriteUIDs)
        if level != host.coordinator.level { host.animateToLevel(level) }
        wireProxy(host: host, levelBinding: $level)
        coord.header?.reposition()
    }

    private func wireProxy(host: MetalGridScrollHost, levelBinding: Binding<Int>) {
        let levelCount = host.coordinator.levelCount   // engine ladder (incl. the larger level 0)
        let stepIn = { levelBinding.wrappedValue = max(0, levelBinding.wrappedValue - 1) }
        let stepOut = { levelBinding.wrappedValue = min(levelCount - 1, levelBinding.wrappedValue + 1) }
        // The live trackpad pinch reports the settled level on release → keep the SwiftUI `level` in sync.
        host.onZoomCommit = { settled in levelBinding.wrappedValue = settled }
        guard let proxy else { return }
        proxy.windowFrameForItem = { [weak host] item in host?.windowFrame(forUID: item.uid) }
        proxy.scrollToItem = { [weak host] item in host?.scrollToItem(item.uid) }
        proxy.scrollToLatest = { [weak host] in host?.scrollToBottom() }
        proxy.zoomIn = stepIn
        proxy.zoomOut = stepOut
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
    }
}
