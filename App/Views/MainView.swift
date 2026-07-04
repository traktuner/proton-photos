import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotosCore
import DesignSystem
import MediaCache
import GridCore
import TimelineFeature
import PhotoViewerFeature
import UploadCore
import UploadFeature
import MapFeature
import ProtonDriveBackend

struct MainView: View {
    let model: AppModel
    let facade: ProtonClientFacade
    let backend: any PhotosBackend
    @Bindable var uploadCoordinator: UploadCoordinator

    @State private var timelineModel: TimelineViewModel
    @State private var viewerModel: PhotoViewerModel?
    @State private var level: Int = 3          // 0 = most zoomed in (largest, ~3 cols) … 5 = densest overview
    // Aspect/square thumbnail toggle preference (normal levels L0–L3). Pushed to the grid coordinator; the
    // overview levels (L4–L5) force squareFillCrop regardless. Toggling changes content fit ONLY, never layout.
    // Initial default = aspectFitInsideSquare (matches the coordinator's default).
    @State private var gridContentMode: TileContentDisplayMode = .aspectFitInsideSquare
    @State private var sidebarOpen: Bool
    @State private var sidebarWidth: CGFloat
    @State private var columnVisibility: NavigationSplitViewVisibility   // native sidebar show/hide
    @State private var albums: [PhotoAlbum] = []
    @State private var selection: PhotoFilter = .all
    @State private var routeScrollGeneration = 0
    /// Per-route scroll-position memory: leaving a route stores a layout-invariant photo anchor here; returning
    /// re-pins it (so the route reopens exactly where the user was, even across zoom/resize). `nil` for a route
    /// never visited → opens at newest.
    @State private var routeScrollPositions: [PhotoFilter: GridScrollAnchor<PhotoUID>] = [:]
    /// The placement target for the CURRENT route generation: a remembered photo anchor (restore) or nil
    /// (newest). Set synchronously when the route changes, BEFORE the async load, so the grid host has the
    /// correct target by the time the new sections arrive.
    @State private var routeInitialScrollAnchor: GridScrollAnchor<PhotoUID>? = nil
    @State private var searchText = ""
    @State private var committedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    // Shared-element zoom transition (photo ↔ its grid cell).
    @State private var gridProxy = GridProxy<PhotoUID>()
    @State private var veilTimeout: Task<Void, Never>?
    @State private var zoom: ZoomTransition?
    // Real height of the native window toolbar (its top safe-area inset). The viewer lays its media out
    // below this, so the open/close zoom must fly the photo into the SAME region to avoid a shrink/jump.
    @State private var topBarInset: CGFloat = 0
    @State private var networkMonitor = NetworkMonitor.shared
    // The grid's leading obstruction inset == the floating sidebar's overlap when it's open, else 0. Derived from
    // the KNOWN sidebar column width - SwiftUI coordinate spaces and preferences do NOT bridge across
    // NavigationSplitView's AppKit-hosted sidebar column, so the detail can't measure the overlap (its leading
    // safe-area inset reads 0 under a floating overlay sidebar). It changes only on a sidebar toggle (constant
    // during any window resize → no per-tick Metal re-layout).
    private var leadingObstructionInset: CGFloat { columnVisibility == .detailOnly ? 0 : sidebarWidth }
    // Selection + export.
    @State private var selectionMode = false
    @State private var selectedUIDs: Set<PhotoUID> = []
    @State private var isExporting = false
    /// 0…1 download progress for the top-bar ring (blended across all selected items).
    @State private var exportFraction: Double = 0
    /// The running export, so the progress menu can cancel it mid-download (partial ZIP is discarded).
    @State private var exportTask: Task<Void, Never>?
    @State private var confirmLargeExport = false
    @State private var pendingExportItems: [PhotoItem] = []
    @State private var pendingExportZipName: String?
    /// Above this many selected items, downloading a ZIP asks for confirmation first.
    private let largeExportThreshold = 50
    @State private var pendingTrashItems: [PhotoItem] = []
    @State private var closeViewerAfterTrash = false
    @State private var confirmTrash = false
    /// Set when a trash/restore API call fails AFTER the optimistic grid removal - the items are
    /// reloaded and the failure surfaced, never silently swallowed (the photo would look deleted while
    /// the server still has it outside the trash).
    @State private var trashActionFailureMessage: String?
    // Favorites (read from server so iOS favorites show up; toggle writes back).
    @State private var favorites: Set<PhotoUID> = []
    @State private var uploadRefreshTask: Task<Void, Never>?
    @State private var uploadRefreshMessage: String?
    @State private var uploadRefreshBusy = false
    /// Whether the current banner message represents success (drives the icon/colour). Tracked
    /// explicitly so the banner never compares against localized message text.
    @State private var uploadRefreshSuccess = false
    private let feed: ThumbnailFeed
    private let zoomOpenSpring = (response: 0.34, damping: 0.86)
    private let zoomCloseSpring = (response: 0.32, damping: 0.88)

    init(model: AppModel, facade: ProtonClientFacade) {
        self.model = model
        self.facade = facade
        self.backend = facade.backend
        self.uploadCoordinator = facade.uploadCoordinator
        // Learned thumbnail dimensions persist into the library metadata DB (photos.w/h) through the
        // backend bridge - batched by the coalescer, so decode callbacks never touch the DB directly.
        let dimensions = PhotoDimensionCoalescer(store: backend)
        // Use the SHARED, account-configured cache (AppModel.prepareBackend calls
        // OfflineLibraryManager.shared.configure(session:) before this view is built) so the encrypted
        // disk cache uses the durable per-account session-derived key and survives relaunch. A fresh
        // ThumbnailCache() here would stay on a per-process ephemeral key and re-crawl the whole library
        // every launch.
        let feed = ThumbnailFeed(cache: OfflineLibraryManager.shared.cache, loader: backend, dimensions: dimensions)
        self.feed = feed
        _timelineModel = State(initialValue: TimelineViewModel(repository: backend, feed: feed, library: backend))
        let sidebarVisible = SidebarPersistence.resolvedVisible()
        let width = SidebarPersistence.resolvedWidth()
        _sidebarOpen = State(initialValue: sidebarVisible)
        _sidebarWidth = State(initialValue: width)
        _columnVisibility = State(initialValue: sidebarVisible ? .all : .detailOnly)
    }

    var body: some View {
        ZStack {
            // NATIVE shell: NavigationSplitView gives the macOS-26 floating Liquid-Glass sidebar (native title,
            // toggle, glass to the top corner) for free. The detail's Metal grid extends UNDER the floating
            // sidebar via `.ignoresSafeArea(.container, edges: [.top, .leading])`, while its content is laid out
            // only in the unobscured area (the leading-obstruction inset = the detail's leading safe-area inset).
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(albums: albums, selection: $selection)
                    // Fixed width. (The OS still draws a resize cursor on the divider even though the column is not
                    // user-resizable - an AppKit quirk we accept; min==ideal==max did not change it.)
                    .navigationSplitViewColumnWidth(sidebarWidth)
            } detail: {
                TimelineView(model: timelineModel, level: $level, proxy: gridProxy,
                             routeScrollGeneration: routeScrollGeneration,
                             routeInitialScrollAnchor: routeInitialScrollAnchor,
                             searchText: committedSearchText,
                             selectionMode: selectionMode, media: backend, metadataProvider: backend, favoriteUIDs: favorites,
                             onSelectionChange: { selectedUIDs = $0 }) { item, items in
                    openPhoto(item, items)
                }
                .ignoresSafeArea(.container, edges: [.top, .leading])   // MTKView renders full-width under the floating sidebar
                .overlay(alignment: .top) {
                    if viewerModel == nil {
                        GridTopFrost(height: topBarInset + 12)
                    }
                }
                .navigationTitle(viewerModel == nil ? title : "")
                .searchable(text: $searchText, placement: .toolbar, prompt: Text("search.prompt \(title)"))
                .toolbar { toolbarContent }
                // Native Liquid Glass everywhere: no `.toolbarBackground` style is registered, so both the grid
                // and the viewer use the system glass bar (registering any style here would replace the adaptive
                // glass with a flat fill AND box the sidebar titlebar - see git history / the removed WindowToolbarChrome).
                // Always the real inset - do NOT flip to 0 when the viewer opens: the grid is covered by the
                // viewer anyway, and a flip would arm a spurious full-width sidebar scale that plays when you
                // close the viewer (and would move the cell the zoom transition flies from).
                .environment(\.gridLeadingEventInset, leadingObstructionInset)
                .environment(\.gridTopBarInset, topBarInset)   // first grid row rests below the translucent toolbar
                .onChange(of: searchText) { _, value in scheduleSearchCommit(value) }
            }
            .task { await loadAlbums() }
            .onAppear {
                attachOfflineManager()
                // Register the live feed's RAM caches with the memory governor (idempotent by identity,
                // so SwiftUI re-creating this view never double-registers or leaks a stale feed).
                AppMemoryPressureCoordinator.shared.attachFeed(timelineModel.feed)
                // The grid calls this once the first on-screen frame is fully drawn → lift the veil then.
                gridProxy.onFirstContentReady = { [weak model] in model?.markLibraryReady() }
                evaluateVeilLift()
            }
            .onChange(of: librarySettled) { _, _ in evaluateVeilLift() }
            .onChange(of: selection) { oldValue, newValue in
                // Switching sidebar route while a photo/video is open: close the viewer INSTANTLY so the new tab's
                // grid (or Map) just shows. No zoom-back-to-cell - the photo's cell usually isn't in the new
                // route, and the expectation is simply "tab switches, photo closes."
                if viewerModel != nil {
                    zoom = nil
                    viewerModel = nil
                }
                // Remember where the user was in the route they're leaving (the grid still shows it at this
                // point, so the proxy reports the OLD route's anchor). Returning to that route re-pins it.
                if let anchor = gridProxy.currentScrollAnchor?() {
                    routeScrollPositions[oldValue] = anchor
                }
                // Non-timeline routes (for example the Map overlay) keep the last grid route underneath.
                guard newValue.hasTimeline else { return }
                // The new route opens at its remembered position, or at the newest end on first visit. Both the
                // target and the generation are set SYNCHRONOUSLY here - BEFORE the async `select(...)` that loads
                // the route - so the generation is already pending when the new sections (and the new data token)
                // arrive in the grid. The host owns the one-shot placement; we never scroll from here. (Not
                // `scrollToLatest`: that re-arms sticky bottom-pinning and would fight the user's first scroll.)
                routeInitialScrollAnchor = routeScrollPositions[newValue]
                routeScrollGeneration += 1
                Task { await timelineModel.select(newValue) }
            }
            .onChange(of: timelineModel.allItems.count) { _, count in
                OfflineLibraryManager.shared.liveAssetCount = count
                // Kick off the low-priority GPS crawl (once) so the Map's location index fills in behind the
                // thumbnail crawl.
                OfflineLibraryManager.shared.startLocationCrawl(items: timelineModel.allItems, metadata: backend)
            }
            .onDisappear {
                searchDebounceTask?.cancel()
                searchDebounceTask = nil
            }
            .onChange(of: columnVisibility) { _, newValue in
                // The NATIVE split-view toggle drives columnVisibility - mirror it back into our open-state +
                // persistence (the ⌥⌘S path goes through toggleSidebar() which sets both).
                let visible = newValue != .detailOnly
                guard visible != sidebarOpen else { return }
                sidebarOpen = visible
                SidebarPersistence.saveVisible(visible)
            }
            .onReceive(NotificationCenter.default.publisher(for: .protonPhotosToggleSidebar)) { _ in
                toggleSidebar()
            }
            .task { await uploadCoordinator.start() }
            .onReceive(NotificationCenter.default.publisher(for: .protonPhotosUploadPhotos)) { notification in
                performUploadUIAction("uploadPhotos", trigger: uploadTrigger(from: notification))
            }
            .onReceive(NotificationCenter.default.publisher(for: .protonPhotosUploadFolder)) { notification in
                performUploadUIAction("uploadFolder", trigger: uploadTrigger(from: notification))
            }
            .onReceive(NotificationCenter.default.publisher(for: .protonPhotosShowUploadQueue)) { notification in
                performUploadUIAction("showQueue", trigger: uploadTrigger(from: notification))
            }
            .onReceive(NotificationCenter.default.publisher(for: .protonPhotosRefreshLibrary)) { _ in
                refreshLibraryManually()
            }
            .onChange(of: uploadCoordinator.completedUploadRevision) { _, _ in
                guard let completed = uploadCoordinator.latestCompletedUpload else { return }
                scheduleUploadRefresh(completed)
            }
            .sheet(isPresented: $uploadCoordinator.isDestinationSheetPresented) {
                UploadDestinationSheet(coordinator: uploadCoordinator)
            }

            // Library Map route: a MapKit map of every geotagged photo, inset beside the floating sidebar like
            // the viewer. Sits OVER the grid (which still holds the last route underneath) and UNDER the viewer,
            // so tapping a pin opens the photo viewer on top.
            if selection == .map {
                LibraryMapScreen(index: OfflineLibraryManager.shared.locationIndex,
                                 thumbnail: { feed.memoryImage(for: $0) },
                                 onSelectPhoto: { openPhotoByUID($0) })
                    .overlay { mapEmptyStateOverlay }
                    .padding(.leading, leadingObstructionInset)
                    .animation(.easeInOut(duration: 0.3), value: leadingObstructionInset)
                    .ignoresSafeArea()
            }

            // Hidden while a NON-interactive zoom (open/close spring) animates - the overlay stands in. During an
            // INTERACTIVE pinch-dismiss it stays mounted but INVISIBLE, so the pinch gesture keeps delivering while
            // the overlay shows the live shrink-into-the-cell.
            if let viewerModel, zoom == nil || zoom?.interactive == true {
                PhotoViewerView(model: viewerModel,
                                isFavorite: { favorites.contains($0) },
                                onToggleFavorite: toggleFavorite,
                                onTrash: { requestTrash([$0], closeViewer: true) },
                                onClose: { closePhoto() },
                                onPinchDismissBegan: beginInteractiveDismiss,
                                onPinchDismissChanged: updateInteractiveDismiss,
                                onPinchDismissEnded: { endInteractiveDismiss(shouldClose: $0) },
                                isDismissing: zoom?.interactive == true)
                    // Inset by the floating sidebar's width so it stays visible BESIDE the viewer (and the native
                    // toggle actually shows/hides it) instead of being covered. 0 when collapsed ⇒ full-width viewer.
                    // Matches the zoom overlay's `contentRect` inset, so the open/close hand-off has no jump.
                    .padding(.leading, leadingObstructionInset)
                    .animation(.easeInOut(duration: 0.3), value: leadingObstructionInset)   // slide with the sidebar toggle
                // NOT `.opacity(0)` while dismissing - an alpha-0 NSView is non-hit-testable, so a fresh pinch would
                // leak to the grid behind (it would scroll/zoom) and never return to the scroll view (the image
                // "locks"). The viewer stays hit-testable and hides its OWN background + image while dismissing, so
                // the gesture always reaches its scroll view and the grid behind stays frozen.
            }

            // Shared-element zoom overlay: a single image morphing between the cell and fullscreen.
            if let zoom { zoomOverlay(zoom) }

            uploadRefreshBanner

            if !networkMonitor.isOnline {
                offlineIndicator
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: networkMonitor.isOnline)
        .background(
            // Reads the real top safe-area inset (= native toolbar height) so the zoom transition and the
            // viewer agree on exactly where the media sits below the opaque top bar.
            GeometryReader { geo in
                Color.clear
                    .onAppear { topBarInset = geo.safeAreaInsets.top }
                    .onChange(of: geo.safeAreaInsets.top) { _, new in topBarInset = new }
            }
        )
        .coordinateSpace(name: "root")
        .animation(.easeInOut(duration: 0.22), value: sidebarOpen)
        .popover(isPresented: $uploadCoordinator.isQueueVisible, arrowEdge: .top) {
            UploadQueuePanel(coordinator: uploadCoordinator)
        }
        .confirmationDialog(trashConfirmationTitle, isPresented: $confirmTrash) {
            Button("alert.move_to_trash", role: .destructive) {
                let items = pendingTrashItems
                let shouldClose = closeViewerAfterTrash
                pendingTrashItems = []
                closeViewerAfterTrash = false
                trashPhotos(items)
                if shouldClose {
                    closePhoto()
                } else {
                    selectionMode = false
                    selectedUIDs = []
                }
            }
            Button("action.cancel", role: .cancel) {
                pendingTrashItems = []
                closeViewerAfterTrash = false
            }
        } message: {
            Text(trashConfirmationMessage)
        }
        .confirmationDialog("export.confirm_many_title", isPresented: $confirmLargeExport) {
            Button("export.confirm_many_button") {
                let items = pendingExportItems
                let zipName = pendingExportZipName
                pendingExportItems = []
                pendingExportZipName = nil
                startExport(items, zipSuggestedName: zipName)
            }
            Button("action.cancel", role: .cancel) {
                pendingExportItems = []
                pendingExportZipName = nil
            }
        } message: {
            Text("export.confirm_many_message \(pendingExportItems.count)")
        }
        .alert("alert.trash_action_failed_title", isPresented: Binding(
            get: { trashActionFailureMessage != nil },
            set: { if !$0 { trashActionFailureMessage = nil } }
        )) {
            Button("action.ok", role: .cancel) { trashActionFailureMessage = nil }
        } message: {
            Text(trashActionFailureMessage ?? "")
        }
    }

    /// Native upload menu - a system toolbar `Menu` gets the OS Liquid Glass pill for free.
    private var uploadToolbarMenu: some View {
        Menu {
            Button("menu.upload_photos") { performUploadUIAction("uploadPhotos", trigger: .toolbar) }
                .disabled(!uploadCoordinator.uploadCapabilities.canUpload)
            Button("menu.upload_folder") { performUploadUIAction("uploadFolder", trigger: .toolbar) }
                .disabled(!uploadCoordinator.uploadCapabilities.canUpload)
            Divider()
            Button("menu.show_uploads") { performUploadUIAction("showQueue", trigger: .toolbar) }
        } label: {
            Label("toolbar.upload", systemImage: "tray.and.arrow.up")
        }
        .help("toolbar.upload_menu_help")
        .accessibilityLabel("toolbar.upload")
    }

    /// The download trigger - or, while a download runs, the native progress indicator (so the icon is REPLACED,
    /// never duplicated: one download at a time). In Trash the same slot is the Restore action.
    @ViewBuilder private var downloadActionItem: some View {
        if isExporting {
            exportProgressIndicator
            exportCancelButton
        } else if selection == .trash {
            Button { restoreSelected() } label: {
                if selectedUIDs.isEmpty { Image(systemName: "arrow.uturn.backward") }
                else { Label("\(selectedUIDs.count)", systemImage: "arrow.uturn.backward") }
            }
            .disabled(selectedUIDs.isEmpty)
            .help("toolbar.restore_from_trash")
            .accessibilityLabel(selectedUIDs.isEmpty ? "a11y.restore_selected_from_trash" : "a11y.restore_count_from_trash \(selectedUIDs.count)")
        } else {
            Button { downloadSelected() } label: {
                if selectedUIDs.isEmpty { Image(systemName: "square.and.arrow.down") }
                else { Label("\(selectedUIDs.count)", systemImage: "square.and.arrow.down") }
            }
            .disabled(selectedUIDs.isEmpty)
            .help(selectedUIDs.count > 1 ? "toolbar.download_count_photos_help \(selectedUIDs.count)" : "toolbar.download_original")
            .accessibilityLabel(selectedUIDs.isEmpty ? "a11y.download_selected_originals" : "a11y.download_count_selected_originals \(selectedUIDs.count)")
        }
    }

    /// While a download runs: the SYSTEM's native determinate progress indicator (a custom coloured ring can't
    /// render inside a system toolbar control - the toolbar standardises item content - so this is the
    /// Liquid-Glass-native indicator). Paired with `exportCancelButton` so the two sit together and the pill is a
    /// normal two-item width (a lone tiny indicator made the pill a sliver). Cancel is a real LEFT-click button -
    /// right-click only opens the OS toolbar's own "Icon & Text / Icon Only" customization menu.
    private var exportProgressIndicator: some View {
        let pct = Int((exportFraction * 100).rounded())
        return ProgressView(value: max(0.001, min(1, exportFraction)))
            .progressViewStyle(.circular)
            .controlSize(.regular)
            .help("export.progress_percent \(pct)")
            .accessibilityLabel("export.progress_percent \(pct)")
    }

    private var exportCancelButton: some View {
        Button { cancelExport() } label: {
            Label("export.cancel", systemImage: "xmark")
                .labelStyle(.iconOnly)
        }
        .help("export.cancel")
        .accessibilityLabel("export.cancel")
    }

    /// Subtle bottom pill shown only while the device has no network - so cached browsing reads as a deliberate
    /// offline state, and a failed upload/favorite/video has an obvious reason.
    private var offlineIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
            Text("status.offline")
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(in: Capsule())   // native Liquid Glass (was .ultraThinMaterial)
    }

    @ViewBuilder private var uploadRefreshBanner: some View {
        if let uploadRefreshMessage {
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    if uploadRefreshBusy {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: uploadRefreshSuccess ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(uploadRefreshSuccess ? .green : .secondary)
                    }
                    Text(uploadRefreshMessage)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(in: Capsule())   // native Liquid Glass (was .regularMaterial)
                .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                .padding(.bottom, 20)
            }
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: - Zoom transition

    private struct ZoomTransition: Equatable {
        let item: PhotoItem
        let image: NSImage
        var cellFrame: CGRect
        var progress: CGFloat    // 1 = fullscreen, 0 = collapsed into the grid cell
        var interactive: Bool    // true = pinch-driven (the viewer is kept alive, invisible, behind this overlay)
    }

    @ViewBuilder private func zoomOverlay(_ z: ZoomTransition) -> some View {
        GeometryReader { geo in
            // Window coords (this layer ignores the safe area, matching the window-space cell frames). The
            // media region sits BELOW the opaque top bar AND to the trailing side of the floating sidebar
            // (the leading-obstruction inset) - identical to where the inset viewer renders it, so handing
            // off to the viewer causes no shrink/jump; at progress 0 it is the grid cell.
            let contentRect = CGRect(x: leadingObstructionInset, y: topBarInset,
                                     width: max(0, geo.size.width - leadingObstructionInset),
                                     height: max(0, geo.size.height - topBarInset))
            let full = fitRect(z.image, in: contentRect)
            let p = max(0, min(1, z.progress))
            let frame = Self.lerpRect(z.cellFrame, full, p)
            ZStack {
                ViewerVisualConstants.backgroundColor.opacity(p)   // fades as the photo shrinks ⇒ the grid shows through
                    .padding(.leading, leadingObstructionInset)    // cover only the detail area, never the floating sidebar
                Image(nsImage: z.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private static func lerpRect(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
        CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
               width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    /// Open the viewer for a photo identified only by uid (a Map pin tap). Looks it up in the currently loaded
    /// library list and opens directly (no cell-zoom - the grid cell is behind the map / may be off-screen).
    private func openPhotoByUID(_ uid: PhotoUID) {
        guard let item = timelineModel.allItems.first(where: { $0.uid == uid }) else { return }
        openPhoto(item, timelineModel.allItems)
    }

    private func openPhoto(_ item: PhotoItem, _ items: [PhotoItem]) {
        // Need the cell's on-screen frame and a thumbnail to fly; otherwise just open directly.
        guard let cell = gridProxy.windowFrameForItem?(item.uid), let img = feed.memoryImage(for: item.uid) else {
            viewerModel = makeViewer(item, items)
            logViewerToolbar(mode: "viewer")
            return
        }
        zoom = ZoomTransition(item: item, image: img, cellFrame: cell, progress: 0, interactive: false)
        DispatchQueue.main.async {
            withAnimation(.spring(response: zoomOpenSpring.response, dampingFraction: zoomOpenSpring.damping)) {
                zoom?.progress = 1
            } completion: {
                viewerModel = makeViewer(item, items)
                logViewerToolbar(mode: "viewer")
                zoom = nil
            }
        }
    }

    // MARK: Interactive pinch-to-dismiss (drives the shared zoom overlay LIVE from the viewer's pinch)

    /// Pinch-out at fit-scale began: hand the LIVE dismiss to the shared zoom overlay so the photo shrinks toward
    /// its EXACT grid cell while the grid fades back in behind it. The viewer is kept alive (rendered invisible) so
    /// its in-progress pinch gesture keeps delivering. Falls back to the spring close if the cell scrolled off-screen.
    private func beginInteractiveDismiss() {
        // A fresh pinch-out may OVERRIDE a stranded interactive dismiss - e.g. the video player loaded mid-pinch and
        // swapped the content view out from under the previous gesture, leaving the overlay half-collapsed. Only a
        // NON-interactive open/close spring is left undisturbed; otherwise the pinch always takes over and resolves
        // the close (the user's "pinch out should overrule whatever is happening" requirement).
        if let z = zoom, !z.interactive { return }
        guard let vm = viewerModel, let img = vm.image,
              let target = viewerReturnTarget(for: vm) else { return }
        zoom = ZoomTransition(item: target.item, image: img, cellFrame: target.cell, progress: 1, interactive: true)
    }

    /// Live pinch progress: 1 = fullscreen, 0 = collapsed into the cell.
    private func updateInteractiveDismiss(_ progress: CGFloat) {
        guard zoom?.interactive == true else { return }
        zoom?.progress = max(0, min(1, progress))
    }

    /// Fingers up: commit the close (fly the rest of the way into the cell) or spring back to fullscreen.
    private func endInteractiveDismiss(shouldClose: Bool) {
        guard zoom?.interactive == true else { return }
        zoom?.interactive = false   // gesture is over ⇒ the viewer may now fully hide
        if shouldClose { logViewerToolbar(mode: "grid") }
        DispatchQueue.main.async {
            withAnimation(.spring(response: zoomCloseSpring.response, dampingFraction: zoomCloseSpring.damping)) {
                zoom?.progress = shouldClose ? 0 : 1
            } completion: {
                if shouldClose { viewerModel = nil }
                zoom = nil
            }
        }
    }

    private func closePhoto() {
        guard let vm = viewerModel else { return }
        // Fly back to the photo's ACTUAL cell. If it scrolled off-screen (user navigated), close
        // instantly rather than centre-scrolling (which made it always shrink into the middle).
        logViewerToolbar(mode: "grid")
        guard let img = vm.image, let target = viewerReturnTarget(for: vm) else {
            viewerModel = nil
            return
        }
        zoom = ZoomTransition(item: target.item, image: img, cellFrame: target.cell, progress: 1, interactive: false)
        DispatchQueue.main.async {
            withAnimation(.spring(response: zoomCloseSpring.response, dampingFraction: zoomCloseSpring.damping)) {
                zoom?.progress = 0
            } completion: {
                viewerModel = nil
                zoom = nil
            }
        }
    }

    private func viewerReturnTarget(for vm: PhotoViewerModel) -> (item: PhotoItem, cell: CGRect)? {
        for item in vm.gridReturnCandidates {
            if let cell = gridProxy.windowFrameForItem?(item.uid) { return (item, cell) }
        }
        return nil
    }

    private func makeViewer(_ item: PhotoItem, _ items: [PhotoItem]) -> PhotoViewerModel {
        let index = items.firstIndex(of: item) ?? 0
        let offline = OfflineLibraryManager.shared
        return PhotoViewerModel(items: items, index: index, feed: feed, media: backend,
                                streamer: backend, metadataProvider: backend,
                                burstProvider: backend,
                                previewCache: offline.previewCache,
                                originalsCache: offline.originalsCache,
                                cacheOriginals: offline.offlineEnabled,
                                originalsCapBytes: offline.originalsCapBytes)
    }

    /// Registers this window's thumbnail feed with the shared offline-cache manager, so the Settings
    /// scene can delete the cache and read status. The thumbnail crawl is mandatory grid infrastructure,
    /// independent of the Offline Photo Library toggle.
    private func attachOfflineManager() {
        let manager = OfflineLibraryManager.shared
        manager.attach(feed: feed, stats: backend)
        manager.liveAssetCount = timelineModel.allItems.count
    }

    /// Aspect-fit rect of `image` centred in `size` - the photo's fullscreen frame.
    private func fitRect(_ image: NSImage, in size: CGSize) -> CGRect {
        let ia = image.size.width / max(image.size.height, 1)
        let ra = size.width / max(size.height, 1)
        var w = size.width, h = size.height
        if ia > ra { h = w / ia } else { w = h * ia }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    /// Aspect-fit rect of `image` centred within an arbitrary `rect` (used to fit inside the media region
    /// below the top bar, not the whole window).
    private func fitRect(_ image: NSImage, in rect: CGRect) -> CGRect {
        let fitted = fitRect(image, in: rect.size)
        return fitted.offsetBy(dx: rect.minX, dy: rect.minY)
    }

    // MARK: - Chrome

    /// True once the timeline has settled (loaded / empty / failed) - the signal that lifts the launch veil.
    private var librarySettled: Bool {
        if case .loading = timelineModel.state { return false }
        return true
    }

    /// Lift the launch veil only once the VISIBLE thumbnails are actually drawn (the grid fires
    /// `onFirstContentReady` → `markLibraryReady`), not merely when the library LIST loads - so it never reveals
    /// blank cells. An empty/failed library has nothing to draw, so it lifts at once. A safety timeout guarantees
    /// the veil can never stick: a cell that somehow never becomes resident must not pin it forever.
    private func evaluateVeilLift() {
        guard librarySettled else { return }
        if timelineModel.allItems.isEmpty { model.markLibraryReady(); return }
        guard veilTimeout == nil else { return }
        veilTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            // If the grid never reported first content in time, the veil lifts here onto a still-filling grid.
            // Trace it once (grep `[FirstContent]`) so a cold-start log distinguishes a natural ready from this
            // fallback; skip the trace when content already became ready so the log stays truthful.
            if !model.libraryReady {
                PhotoDiagnostics.shared.emit("FirstContent", ["event": "veilTimeout", "phase": "coldStart"])
            }
            model.markLibraryReady()
        }
    }

    private var title: String {
        switch selection {
        case .all: String(localized: "library.title")
        case .tag(let t): t.title
        case .album(_, let name): name
        case .trash: String(localized: "sidebar.recently_deleted")
        case .map: "Map"
        }
    }

    private func loadAlbums() async {
        albums = (try? await backend.albums()) ?? []
        uploadCoordinator.albums = albums          // feed the upload destination picker
        favorites = (try? await backend.favoriteUIDs()) ?? []
    }

    // MARK: - Upload

    private func performUploadUIAction(_ action: String, trigger: UploadUITrigger) {
        logUploadUI(action: action, trigger: trigger)
        switch action {
        case "uploadPhotos":
            presentUploadPhotos()
        case "uploadFolder":
            presentUploadFolder()
        case "showQueue":
            uploadCoordinator.isQueueVisible = true
        default:
            break
        }
    }

    private func presentUploadPhotos() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .movie]
        panel.message = String(localized: "upload.choose_photos_message")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        uploadCoordinator.chooseDestination(files: panel.urls)
    }

    private func presentUploadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = String(localized: "upload.choose_folder_message")
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        uploadCoordinator.chooseDestination(folder: folder)
    }

    private func scheduleUploadRefresh(_ event: UploadCompletedEvent) {
        uploadRefreshTask?.cancel()
        uploadRefreshTask = Task { await runUploadRefresh(event) }
    }

    @MainActor private func runUploadRefresh(_ event: UploadCompletedEvent) async {
        uploadRefreshBusy = true
        uploadRefreshSuccess = false
        uploadRefreshMessage = String(localized: "upload.refreshing_after_upload")
        let schedule = TimelineRefreshRetrySchedule.uploadDefault.delays
        for (attempt, delay) in schedule.enumerated() {
            guard !Task.isCancelled else { return }
            if delay > .zero {
                uploadRefreshMessage = String(localized: "upload.waiting_for_refresh")
                try? await Task.sleep(for: delay)
            }
            let result = await timelineModel.refreshAfterUpload(uploadedUID: event.uploadedUID)
            OfflineLibraryManager.shared.liveAssetCount = timelineModel.allItems.count
            if event.destination.usesAlbum {
                await loadAlbums()
            }
            logUploadRefresh(upload: event, attempt: attempt, result: result)
            if let found = result.foundItem {
                uploadRefreshBusy = false
                uploadRefreshSuccess = true
                uploadRefreshMessage = String(localized: "upload.uploaded")
                gridProxy.scrollToItem?(found.uid)
                clearUploadRefreshMessage(after: .seconds(2))
                return
            }
        }
        uploadRefreshBusy = false
        uploadRefreshSuccess = false
        uploadRefreshMessage = String(localized: "upload.not_yet_indexed")
    }

    private func refreshLibraryManually() {
        Task { await performManualLibraryRefresh() }
    }

    @MainActor private func performManualLibraryRefresh() async {
        uploadRefreshBusy = true
        uploadRefreshSuccess = false
        uploadRefreshMessage = String(localized: "library.refreshing")
        let result = await timelineModel.refreshLibrary()
        OfflineLibraryManager.shared.liveAssetCount = timelineModel.allItems.count
        await loadAlbums()
        logUploadRefresh(uploadedNode: "-", attempt: 0, result: result)
        uploadRefreshBusy = false
        uploadRefreshSuccess = result.errorMessage == nil
        uploadRefreshMessage = result.errorMessage == nil ? String(localized: "library.refreshed") : String(localized: "library.refresh_failed")
        clearUploadRefreshMessage(after: .seconds(2))
    }

    private func clearUploadRefreshMessage(after delay: Duration) {
        Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !uploadRefreshBusy else { return }
            uploadRefreshMessage = nil
        }
    }

    private func logUploadUI(action: String, trigger: UploadUITrigger) {
        let line = "[UploadUI] action=\(action) trigger=\(trigger.rawValue)"
        DebugLog.log(line)
    }

    private func logUploadRefresh(upload: UploadCompletedEvent, attempt: Int, result: TimelineRefreshResult) {
        logUploadRefresh(uploadedNode: upload.uploadedUID.nodeID, attempt: attempt, result: result)
    }

    private func logUploadRefresh(uploadedNode: String, attempt: Int, result: TimelineRefreshResult) {
        let line = """
        [UploadRefresh] uploadedNode=\(uploadedNode) attempt=\(attempt) found=\(result.found) \
        timelineCountBefore=\(result.timelineCountBefore) timelineCountAfter=\(result.timelineCountAfter) \
        filter=\(result.filterDescription) elapsedMs=\(Int(result.elapsedMs)) error=\(result.errorMessage ?? "-")
        """
        DebugLog.log(line)
    }

    /// Honest Map empty state over the bare world map, mirroring the iOS states: "scanning" while the
    /// GPS crawl runs, "no geotagged photos" only once it completed empty, a real-failure state when
    /// every probe failed, and the generic hint before the crawl starts. Shares `PhotoLocationIndex`
    /// scan progress with iOS - the states can't drift.
    @ViewBuilder private var mapEmptyStateOverlay: some View {
        let index = OfflineLibraryManager.shared.locationIndex
        if index.coordinates.isEmpty {
            switch index.scanProgress.phase {
            case .scanning:
                ContentUnavailableView {
                    Label("map.scanning_title", systemImage: "location.magnifyingglass")
                } description: {
                    Text("map.scanning_message \(index.scanProgress.scanned) \(index.scanProgress.total)")
                }
            case .failed:
                ContentUnavailableView {
                    Label("map.scan_failed_title", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("map.scan_failed_message")
                }
            case .completed:
                ContentUnavailableView {
                    Label("map.empty_title", systemImage: "mappin.slash")
                } description: {
                    Text("map.no_places_found_message")
                }
            case .idle:
                ContentUnavailableView {
                    Label("map.empty_title", systemImage: "mappin.slash")
                } description: {
                    Text("map.empty_message")
                }
            }
        }
    }

    // MARK: - Favorites / trash

    private func toggleFavorite(_ uid: PhotoUID) {
        let nowFavorite = !favorites.contains(uid)
        if nowFavorite { favorites.insert(uid) } else { favorites.remove(uid) }   // optimistic
        Task {
            do { try await backend.setFavorite(uid, nowFavorite) }
            catch { if nowFavorite { favorites.remove(uid) } else { favorites.insert(uid) } }   // revert on failure
        }
    }

    /// Whether EVERY selected photo is already a favorite - drives the batch heart's filled/empty state and the
    /// toggle direction, so it's ONE button (mirroring the viewer's single-photo heart), never a separate
    /// favorite + unfavorite pair.
    private var selectedAllFavorited: Bool {
        !selectedUIDs.isEmpty && selectedUIDs.allSatisfy { favorites.contains($0) }
    }

    /// Batch favorite TOGGLE: if every selected photo is already favorited, un-favorites them all; otherwise
    /// favorites the ones that aren't yet. Optimistic, reverts per item; keeps the selection so the result shows.
    private func favoriteSelected() {
        let target = !selectedAllFavorited
        let uids = selectedUIDs.filter { favorites.contains($0) != target }
        guard !uids.isEmpty else { return }
        if target { favorites.formUnion(uids) } else { favorites.subtract(uids) }   // optimistic
        Task {
            for uid in uids {
                do { try await backend.setFavorite(uid, target) }
                catch { if target { favorites.remove(uid) } else { favorites.insert(uid) } }   // revert just this one
            }
        }
    }

    /// Sets the single selected photo as the current album's cover (direct REST), then refreshes the album list
    /// so the sidebar cover updates. Keeps the selection (non-destructive).
    private func setSelectedAsAlbumCover(albumID: String) {
        guard selectedUIDs.count == 1, let uid = selectedUIDs.first else { return }
        Task {
            try? await facade.albums.setAlbumCover(albumID: albumID, photoUID: uid)
            await loadAlbums()
        }
    }

    private func trashPhotos(_ items: [PhotoItem]) {
        let uids = items.map(\.uid)
        timelineModel.remove(Set(uids))          // optimistic removal from the grid
        favorites.subtract(uids)
        Task {
            do {
                try await backend.trash(uids)
            } catch {
                // Honest failure: the server still has the photos outside the trash. Reload the current
                // route so they reappear, and tell the user - a swallowed error here looks like a
                // successful delete that never shows up in Recently Deleted.
                DebugLog.log("trash: FAILED n=\(uids.count) - \(error)")
                await timelineModel.retry()
                trashActionFailureMessage = String(localized: "alert.trash_failed_message")
            }
        }
    }

    private func restorePhotos(_ items: [PhotoItem]) {
        let uids = items.map(\.uid)
        timelineModel.remove(Set(uids))          // optimistic removal from the trash view
        Task {
            do {
                try await backend.restore(uids)
            } catch {
                DebugLog.log("restore: FAILED n=\(uids.count) - \(error)")
                await timelineModel.retry()
                trashActionFailureMessage = String(localized: "alert.restore_failed_message")
            }
        }
    }

    private var selectedItems: [PhotoItem] { timelineModel.allItems.filter { selectedUIDs.contains($0.uid) } }

    private func scheduleSearchCommit(_ value: String) {
        searchDebounceTask?.cancel()
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            committedSearchText = ""
            // Clearing the search restores the FULL timeline - land at the newest (bottom-right), the grid's home,
            // not the preserved filtered-view offset (which reads as the oldest, top). Re-arm the one-shot
            // initial-viewport placement with a nil anchor (⇒ `.newest`); the host applies it when the full data lands.
            routeInitialScrollAnchor = nil
            routeScrollGeneration += 1
            searchDebounceTask = nil
            return
        }
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            committedSearchText = value
            searchDebounceTask = nil
        }
    }

    private func trashSelected() {
        let items = selectedItems
        requestTrash(items, closeViewer: false)
    }

    private func restoreSelected() {
        let items = selectedItems
        selectionMode = false; selectedUIDs = []
        restorePhotos(items)
    }

    private func requestTrash(_ items: [PhotoItem], closeViewer: Bool) {
        guard !items.isEmpty else { return }
        pendingTrashItems = items
        closeViewerAfterTrash = closeViewer
        confirmTrash = true
    }

    private var trashConfirmationTitle: String {
        pendingTrashItems.count == 1
            ? String(localized: "alert.trash_confirmation_title_one")
            : String(localized: "alert.trash_confirmation_title_other \(pendingTrashItems.count)")
    }

    private var trashConfirmationMessage: String {
        pendingTrashItems.count == 1
            ? String(localized: "alert.trash_confirmation_message_one")
            : String(localized: "alert.trash_confirmation_message_other")
    }

    /// Small native progress indicator next to the upload button during the library's FIRST warm-up, while the
    /// thumbnail cache builds; it whooshes away once warm and is not re-shown this session (see
    /// `OfflineLibraryManager.isPreparingLibrary`). The exact percent lives on the tooltip / VoiceOver.
    ///
    /// Deliberately the SAME control as `exportProgressIndicator` (the download progress) - a determinate
    /// `.circular` `ProgressView` at `.controlSize(.regular)` - so the two read identically and the pill sizes
    /// itself the same proven way. No glyph, no label. No manual `.glassEffect`: the toolbar glass is system-owned.
    private var libraryPreparePill: some View {
        let pct = Int(OfflineLibraryManager.shared.cachePreparePercent.rounded())
        // Wrapped in a Button so it gets the SAME round, padded toolbar pill as the aspect-toggle button (a bare
        // view gets a tight content-hugging pill instead). The action is a deliberate no-op - it's a status
        // indicator, not a control - but it must stay HIT-TESTABLE, otherwise the hover tooltip (the live percent)
        // never fires (`.allowsHitTesting(false)` would suppress hover, and `.disabled` would dim the pie).
        return Button(action: {}) {
            ProgressView(value: max(0.001, min(1, OfflineLibraryManager.shared.cachePreparePercent / 100)))
                .progressViewStyle(.circular)
                .controlSize(.small)
        }
        .help(Text(verbatim: "Mediathek wird geladen … \(pct)%"))
        .accessibilityLabel(Text(verbatim: "Mediathek wird geladen, \(pct) Prozent"))
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if let viewerModel {
            ToolbarItem(placement: .navigation) {
                Button { closePhoto() } label: {
                    Label("toolbar.back", systemImage: "chevron.left")
                }
                .help("toolbar.back_to_library")
            }
            // Apple-Photos centered two-line metadata in a pill: location/POI (or date) over the
            // secondary line, both inside a capsule padded comfortably larger than the text.
            ToolbarItem(placement: .principal) {
                let t = viewerTitle(viewerModel)
                VStack(spacing: 1) {
                    Text(t.line1)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(t.line2)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .multilineTextAlignment(.center)
                .fixedSize()
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                // No manual `.glassEffect` here: this is a `.principal` toolbar item and the system toolbar OWNS
                // the Liquid-Glass background. A manual Capsule glass rendered a DOUBLE pill (inner manual capsule
                // inside the outer system pill). The system supplies the single glass background.
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { viewerModel.toggleInfo() }
                } label: {
                    Label("toolbar.info", systemImage: viewerModel.showInfo ? "info.circle.fill" : "info.circle")
                        .labelStyle(.iconOnly)
                }
                .help("toolbar.info")
                .accessibilityLabel("toolbar.info")

                if isExporting {
                    exportProgressIndicator   // the download icon is replaced by the native progress while exporting
                    exportCancelButton
                } else {
                    let downloadTitle = viewerModel.hasBurstFilmstrip ? "toolbar.download_burst_zip" : "toolbar.download_original"
                    Button {
                        downloadViewerSelection(viewerModel)
                    } label: {
                        Label(LocalizedStringKey(downloadTitle), systemImage: "square.and.arrow.down")
                            .labelStyle(.iconOnly)
                    }
                    .help(LocalizedStringKey(downloadTitle))
                    .accessibilityLabel(LocalizedStringKey(downloadTitle))
                    .disabled(!viewerModel.canDownloadCurrentSelection)
                }

                Button { toggleFavorite(viewerModel.current.uid) } label: {
                    Label(favorites.contains(viewerModel.current.uid) ? "toolbar.remove_favorite" : "toolbar.favorite",
                          systemImage: favorites.contains(viewerModel.current.uid) ? "heart.fill" : "heart")
                        .labelStyle(.iconOnly)
                }
                .help(favorites.contains(viewerModel.current.uid) ? "toolbar.remove_favorite" : "toolbar.favorite")
                .accessibilityLabel(favorites.contains(viewerModel.current.uid) ? "toolbar.remove_favorite" : "toolbar.favorite")

                Button { onTrashViewerItem(viewerModel.current) } label: {
                    Label("toolbar.move_to_trash", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .help("toolbar.move_to_trash")
                .accessibilityLabel("toolbar.move_to_trash")
            }
        } else {
            // The sidebar toggle is the NATIVE NavigationSplitView one (it returns automatically + moves with the
            // sidebar). The ⌥⌘S command still posts `.protonPhotosToggleSidebar` → `toggleSidebar()`.
            // No explicit "select mode": click / ⌘-click / ⇧-click / drag-marquee select directly, double
            // click opens. The toolbar is stable - the download (or restore) + trash actions are always
            // present and just enable when something is selected.
            // Library-preparing pill - its OWN glass pill, right before the upload group. A single determinate
            // progress indicator (the SAME control as the download progress); the system supplies its glass.
            // The trailing `ToolbarSpacer(.fixed)` splits this off as a SEPARATE pill from the upload group.
            if OfflineLibraryManager.shared.isPreparingLibrary {
                ToolbarItem(placement: .primaryAction) { libraryPreparePill }
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            // Pill 1 - upload + download belong together (`ToolbarSpacer` splits the system glass into a SEPARATE
            // pill from the selection actions; the toolbar manages its own glass, so this native split is the only
            // reliable way to get distinct pills).
            ToolbarItemGroup(placement: .primaryAction) {
                uploadToolbarMenu
                downloadActionItem
            }
            // Pill 2 - selection actions (trash / favorite / album cover). Omitted entirely in Trash (only Restore
            // applies there, and it lives in the download slot of pill 1).
            if selection != .trash {
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { trashSelected() } label: {
                        Label("toolbar.move_selected_to_trash", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                        .disabled(selectedUIDs.isEmpty)
                        .help("toolbar.move_to_trash")
                        .accessibilityLabel("toolbar.move_selected_to_trash")
                    Button { favoriteSelected() } label: {
                        Label(selectedAllFavorited ? "toolbar.remove_favorite" : "toolbar.favorite_selected",
                              systemImage: selectedAllFavorited ? "heart.fill" : "heart")
                            .labelStyle(.iconOnly)
                    }
                        .disabled(selectedUIDs.isEmpty)
                        .help(selectedAllFavorited ? "toolbar.remove_favorite" : "toolbar.favorite_selected")
                        .accessibilityLabel(selectedAllFavorited ? "toolbar.remove_favorite" : "toolbar.favorite_selected")
                    if case .album(let albumID, _) = selection {
                        Button { setSelectedAsAlbumCover(albumID: albumID) } label: {
                            Label("toolbar.set_album_cover", systemImage: "rectangle.badge.checkmark")
                                .labelStyle(.iconOnly)
                        }
                            .disabled(selectedUIDs.count != 1)
                            .help("toolbar.set_album_cover")
                            .accessibilityLabel("toolbar.set_album_cover")
                    }
                }
            }
            // Pill 3 - zoom + aspect view controls.
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                ControlGroup {
                    Button { gridProxy.zoomOut?() } label: {
                        Label("toolbar.smaller_thumbnails", systemImage: "minus")
                            .labelStyle(.iconOnly)
                    }
                        .help("toolbar.smaller_thumbnails")
                        .disabled(level >= 5)
                        .accessibilityLabel("toolbar.smaller_thumbnails")
                    Button { gridProxy.zoomIn?() } label: {
                        Label("toolbar.larger_thumbnails", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                        .help("toolbar.larger_thumbnails")
                        .disabled(level <= 0)
                        .accessibilityLabel("toolbar.larger_thumbnails")
                }
                aspectSquareToggleButton
            }
        }
    }

    /// Apple-Photos-style aspect/square thumbnail toggle. Switches `gridContentMode` between
    /// aspectFitInsideSquare and squareFillCrop and pushes it to the grid coordinator - content fit ONLY, the
    /// square slot geometry never changes. Disabled on the dense overview levels (L4–L5, square-only). The
    /// glyph is an SF Symbol (or an in-app vector fallback) resolved by `AspectSquareToggleModel`; no raster.
    private var aspectSquareToggleButton: some View {
        Button {
            gridContentMode = AspectSquareToggleModel.toggled(gridContentMode)
            gridProxy.setContentMode?(gridContentMode)
        } label: {
            Image(nsImage: AspectSquareToggleModel.image(for: gridContentMode))
        }
        .help(AspectSquareToggleModel.accessibilityLabel(for: gridContentMode))
        .accessibilityLabel(AspectSquareToggleModel.accessibilityLabel(for: gridContentMode))
        .disabled(level >= 4)   // overview levels are square-only - the toggle is inert there
    }


    private func onTrashViewerItem(_ item: PhotoItem) {
        requestTrash([item], closeViewer: true)
    }

    /// Center-title metadata for the viewer top bar. `placeName` is the reverse-geocoded POI/location
    /// headline (nil until resolved or when the photo has no GPS); the filename fallback is best-effort
    /// (only populated while the Info panel is open).
    private func viewerTitle(_ vm: PhotoViewerModel) -> ViewerTitle {
        ViewerTitleFormatter.make(
            captureDate: vm.current.captureTime,
            index: vm.index,
            total: vm.items.count,
            locationName: vm.placeName,
            filename: vm.metadata?.filename
        )
    }

    /// Proof line for the spec: the Library/sidebar toggle is suppressed in viewer mode and restored in
    /// grid mode (the toolbar content is conditional on `viewerModel != nil`).
    private func logViewerToolbar(mode: String) {
        let line = "[ViewerToolbar] mode=\(mode) sidebarToggleVisible=\(mode == "grid")"
        DebugLog.log(line)
    }

    // MARK: - Sidebar overlay

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.22)) {
            sidebarOpen.toggle()
            columnVisibility = sidebarOpen ? .all : .detailOnly   // drive the native split view
        }
        SidebarPersistence.saveVisible(sidebarOpen)
    }

    // MARK: - Download / export

    private struct ExportRequest {
        let items: [PhotoItem]
        let zipSuggestedName: String?
    }

    private func downloadSelected() {
        let items = timelineModel.allItems.filter { selectedUIDs.contains($0.uid) }
        guard !items.isEmpty, !isExporting else { return }
        Task { @MainActor in
            let request = await makeExportRequest(for: items, preferredSeriesNameSource: items.count == 1 ? items[0] : nil)
            startOrConfirmExport(request)
        }
    }

    private func downloadViewerSelection(_ viewerModel: PhotoViewerModel) {
        let items = viewerModel.exportItemsForDownload
        guard !items.isEmpty, !isExporting else { return }
        Task { @MainActor in
            let request = await makeExportRequest(for: items, preferredSeriesNameSource: viewerModel.baseCurrent)
            startOrConfirmExport(request)
        }
    }

    private func startOrConfirmExport(_ request: ExportRequest) {
        guard !request.items.isEmpty, !isExporting else { return }
        if request.items.count > largeExportThreshold {
            pendingExportItems = request.items
            pendingExportZipName = request.zipSuggestedName
            confirmLargeExport = true     // confirm large multi-downloads before zipping
        } else {
            startExport(request.items, zipSuggestedName: request.zipSuggestedName)
        }
    }

    /// Expands a selected Proton burst/series title photo into all known members before export. This keeps the
    /// grid toolbar and viewer toolbar on the same E2EE-safe export path; only the item list and suggested ZIP
    /// filename are prepared here.
    @MainActor private func makeExportRequest(for sourceItems: [PhotoItem],
                                              preferredSeriesNameSource: PhotoItem?) async -> ExportRequest {
        var expanded: [PhotoItem] = []
        var seen = Set<PhotoUID>()
        var expandedSingleSeries = false

        func appendUnique(_ item: PhotoItem) {
            guard seen.insert(item.uid).inserted else { return }
            expanded.append(item)
        }

        let memberIDSet = Set((preferredSeriesNameSource?.burstMemberIDs ?? []).map {
            PhotoUID(volumeID: preferredSeriesNameSource?.uid.volumeID ?? "", nodeID: $0)
        })
        let sourceUIDSet = Set(sourceItems.map(\.uid))
        let alreadyExpandedPreferredSeries = sourceItems.count > 1
            && preferredSeriesNameSource?.isBurstCandidate == true
            && !memberIDSet.isEmpty
            && sourceUIDSet.isSubset(of: memberIDSet)

        if alreadyExpandedPreferredSeries {
            sourceItems.forEach(appendUnique)
            expandedSingleSeries = true
        } else {
            for item in sourceItems {
                if item.isBurstCandidate,
                   let group = try? await backend.burstGroup(containing: item.uid),
                   group.count > 1 {
                    group.forEach(appendUnique)
                    expandedSingleSeries = true
                } else {
                    appendUnique(item)
                }
            }
        }

        let zipName: String?
        if expandedSingleSeries, expanded.count > 1, let source = preferredSeriesNameSource ?? sourceItems.first {
            zipName = await suggestedSeriesZipName(for: source)
        } else {
            zipName = nil
        }
        return ExportRequest(items: expanded, zipSuggestedName: zipName)
    }

    @MainActor private func suggestedSeriesZipName(for item: PhotoItem) async -> String {
        let meta = try? await backend.metadata(for: item.uid)
        let fallback = Self.defaultName(item, ext: Self.defaultExtension(item, metadata: meta))
        let filename = meta?.filename?.isEmpty == false ? meta?.filename : fallback
        let stem = URL(fileURLWithPath: filename ?? fallback).deletingPathExtension().lastPathComponent
        let safeStem = stem.isEmpty ? "ProtonPhotos" : stem
        return "\(safeStem)-\(String(localized: "export.series_zip_suffix")).zip"
    }

    /// Single entry point for launching an export, so the toolbar ring's menu has one task to cancel.
    private func startExport(_ items: [PhotoItem], zipSuggestedName: String? = nil) {
        exportTask?.cancel()
        exportTask = Task { await performExport(items, zipSuggestedName: zipSuggestedName) }
    }

    /// Cancels the running download (from the toolbar ring's menu). `performExport` discards any partial ZIP.
    private func cancelExport() { exportTask?.cancel() }

    /// Downloads original(s) only to explicit user-selected destinations. The app does not stage decrypted
    /// originals in its own temp/cache directories.
    /// MainActor ORCHESTRATION only: panels, progress state, Finder reveal, alerts. The heavy lifting
    /// (CRC-32, AES-GCM decrypt of cached originals, file writes) runs OFF the main actor in the `nonisolated`
    /// workers below, so a large export never freezes the UI and Cancel reacts instantly (the user's "im
    /// Hintergrund, nicht Vordergrund" requirement).
    @MainActor private func performExport(_ items: [PhotoItem], zipSuggestedName: String?) async {
        let backend = self.backend
        let cache = OfflineLibraryManager.shared.originalsCache
        // Captures self only to push 0…1 onto the @State ring; the closure itself runs on the main actor.
        let onProgress: @Sendable (Double) -> Void = { p in Task { @MainActor in self.exportFraction = p } }

        // Resolve the destination FIRST - the progress pill must appear only when the download actually begins,
        // never while the Save panel is open (otherwise a blank pill sits there until the user picks a location).
        let single = items.count == 1
        let dest: URL
        if single {
            let item = items[0]
            let meta = try? await backend.metadata(for: item.uid)
            let name = meta?.filename ?? Self.defaultName(item, ext: Self.defaultExtension(item, metadata: meta))
            guard let chosen = chooseSingleDestination(suggestedName: name) else { return }
            dest = chosen
        } else {
            // Multi-select → ONE streaming ZIP, written straight to the user's chosen file (no app-temp staging →
            // respects the E2EE "originals only at the chosen destination" rule; no size cap → bounded only by
            // free disk via the live guard in the worker).
            guard let chosen = chooseZipDestination(suggestedName: zipSuggestedName) else { return }
            dest = chosen
        }

        // Download begins now → grow the glass progress pill (animated), and tear it down (animated) when done.
        exportFraction = 0
        withAnimation(.smooth(duration: 0.35)) { isExporting = true }
        defer { withAnimation(.smooth(duration: 0.3)) { isExporting = false }; exportTask = nil }

        do {
            if single {
                try await Self.writeSingleExport(item: items[0], dest: dest, backend: backend, cache: cache, onProgress: onProgress)
            } else {
                try await Self.writeZipExport(items: items, dest: dest, backend: backend, cache: cache, onProgress: onProgress)
            }
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch is CancellationError {
            // User cancelled from the ring popover; the worker's `defer` already discarded any partial output.
        } catch ExportError.lowDisk {
            let alert = NSAlert()
            alert.messageText = String(localized: "export.low_disk_title")
            alert.informativeText = String(localized: "export.low_disk_message")
            alert.runModal()
        } catch {
            DebugLog.log("export failed: \(error)")
        }
    }

    /// Off-main single-file export: fetch decrypted bytes (cache or download), then write atomically. `nonisolated`
    /// ⇒ runs on the generic executor, so the decrypt/write never block the main thread.
    nonisolated private static func writeSingleExport(item: PhotoItem, dest: URL, backend: any PhotosBackend,
                                                      cache: ThumbnailCache, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let data = try await fetchOriginal(item: item, backend: backend, cache: cache, onProgress: onProgress)
        try Task.checkCancellation()                 // cancelled mid-download → don't write a partial file
        try? FileManager.default.removeItem(at: dest)
        try data.write(to: dest, options: .atomic)
    }

    /// Off-main streaming ZIP export. A `defer` guarantees that ANY non-success exit (cancel, low-disk, or a
    /// failed download) aborts the writer and deletes the partial `.zip` - there is never a half-written archive
    /// left behind, and the cancel is honoured between files without touching the main thread.
    nonisolated private static func writeZipExport(items: [PhotoItem], dest: URL, backend: any PhotosBackend,
                                                   cache: ThumbnailCache, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let total = Double(items.count)
        let destDir = dest.deletingLastPathComponent()
        let safetyMargin: Int64 = 256 * 1024 * 1024   // headroom (incl. the central directory)
        let writer = try ZipStreamWriter(url: dest)
        var success = false
        defer { if !success { writer.abort(); try? FileManager.default.removeItem(at: dest) } }
        var used = Set<String>()
        for (i, item) in items.enumerated() {
            try Task.checkCancellation()
            let meta = try? await backend.metadata(for: item.uid)
            let base = meta?.filename ?? defaultName(item, ext: defaultExtension(item, metadata: meta))
            let name = uniqueName(base, used: &used)
            // Blend each file's own download progress into the overall ring (smooth, not per-item jumps).
            let data = try await fetchOriginal(item: item, backend: backend, cache: cache,
                                               onProgress: { p in onProgress((Double(i) + p) / total) })
            try Task.checkCancellation()
            if let free = freeBytes(at: destDir), free < Int64(data.count) + safetyMargin { throw ExportError.lowDisk }
            try writer.addFile(name: name, data: data)
            onProgress(Double(i + 1) / total)
        }
        try writer.finish()
        success = true
    }

    /// Decrypted original bytes - REUSES the offline cache (already-viewed/offline originals) so a big export
    /// doesn't re-download what's already local; otherwise a fresh decrypt+download (reporting progress).
    /// `nonisolated` + the actor's `nonisolated diskData` ⇒ the AES-GCM decrypt happens off the main thread.
    nonisolated private static func fetchOriginal(item: PhotoItem, backend: any PhotosBackend, cache: ThumbnailCache,
                                                  onProgress: @escaping @Sendable (Double) -> Void) async throws -> Data {
        // Shared cache-first retrieval (one implementation across iOS + macOS). `.readOnly`: export reuses
        // whatever the viewer cached and bumps LRU on a hit, but never itself grows the offline cache.
        try await EncryptedOriginalProvider(media: backend, cache: cache, policy: .readOnly)
            .originalData(for: item.uid, onProgress: onProgress)
    }

    private func chooseZipDestination(suggestedName: String? = nil) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName ?? "ProtonPhotos Export.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    nonisolated private static func freeBytes(at dir: URL) -> Int64? {
        (try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?.volumeAvailableCapacityForImportantUsage
    }

    private enum ExportError: Error { case lowDisk }

    private func chooseSingleDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }


    nonisolated private static func defaultName(_ item: PhotoItem, ext: String) -> String {
        let e = ext.isEmpty ? "jpg" : ext
        return "\(item.uid.nodeID.prefix(8)).\(e)"
    }

    nonisolated private static func defaultExtension(_ item: PhotoItem, metadata: PhotoMetadata?) -> String {
        // Shared resolver: real Proton filename → trustworthy MIME → timeline mediaType fallback.
        // (No `header:` here — the suggested name is chosen before the download begins; macOS's
        // primary name source remains `metadata.filename`, so this is behaviour-preserving.)
        OriginalFileNaming.resolvedExtension(
            filename: metadata?.filename, mimeType: metadata?.mimeType, header: nil,
            fallbackMediaType: item.mediaType, isVideo: item.isVideo
        )
    }

    nonisolated private static func uniqueName(_ name: String, used: inout Set<String>) -> String {
        guard used.contains(name) else { used.insert(name); return name }
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var i = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem) \(i)" : "\(stem) \(i).\(ext)"
            if !used.contains(candidate) { used.insert(candidate); return candidate }
            i += 1
        }
    }

}


/// Apple-Photos-style top-bar frost over the grid: a public within-window `NSVisualEffectView` (which DOES
/// blur the Metal grid behind it, unlike the native toolbar glass, which can't sample a `CAMetalLayer`),
/// masked to a vertical gradient - strongest frost at the very top, fading to fully clear below the toolbar
/// band. It never covers the sidebar (it is an overlay on the detail), never paints a flat opaque strip, and
/// never blocks pointer/scroll events. When the grid scrolls, the photos show through the fading edge.
private struct GridTopFrost: View {
    /// Total band height - the toolbar inset plus the fade region below it.
    let height: CGFloat

    var body: some View {
        // A LIGHT, UNIFORM frost across the toolbar band (no gradient) - held at full strength over the
        // toolbar height, with only a soft fade at the very bottom edge so it doesn't read as a hard strip.
        // Lighter overall (reduced opacity) so the photos show through as a subtle frosted contrast.
        WithinWindowBlur(material: .headerView)
            .frame(height: max(48, height))
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0.00),   // uniform frost…
                        .init(color: .black, location: 0.80),   // …held across the toolbar
                        .init(color: .clear, location: 1.00),   // soft bottom edge only
                    ],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .opacity(0.5)                                        // lighter - a subtle frost, not a dark band
            .frame(maxWidth: .infinity, alignment: .top)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
    }
}

/// Minimal public-AppKit bridge: a within-window vibrancy view whose material adapts to the content (and to
/// active/inactive window state) on its own. Used only as the frosted material for `GridTopFrost`; the
/// gradient shape is applied by SwiftUI's `.mask` so there is no AppKit coordinate-flip to reason about.
private struct WithinWindowBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .headerView

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow    // sample + blur the photos rendered behind it in this window
        view.material = material
        view.state = .followsWindowActiveState   // system-driven active/inactive vividness
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}

/// Collapsible left sidebar - a native macOS sidebar `List` (Liquid-Glass vibrant material, native
/// selection): Proton smart filters (tags) on top, user albums below.
private struct SidebarView: View {
    let albums: [PhotoAlbum]
    @Binding var selection: PhotoFilter

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let v = $0 { selection = v } })) {
            Section {
                Label("sidebar.all_photos", systemImage: "photo.on.rectangle.angled")
                    .tag(PhotoFilter.all)
                ForEach(PhotoTag.allCases, id: \.self) { tag in
                    Label(tag.title, systemImage: tag.systemImage)
                        .tag(PhotoFilter.tag(tag))
                }
                Label("Map", systemImage: "map")
                    .tag(PhotoFilter.map)
            }
            Section("sidebar.albums") {
                if albums.isEmpty {
                    Label("sidebar.no_albums", systemImage: "tray")
                        .foregroundStyle(.secondary)
                        .disabled(true)
                } else {
                    ForEach(albums) { album in
                        Label(album.title, systemImage: "rectangle.stack")
                            .tag(PhotoFilter.album(id: album.id, title: album.title))
                    }
                }
            }
            Section {
                Label("sidebar.recently_deleted", systemImage: "trash")
                    .tag(PhotoFilter.trash)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)   // let the within-window glass (and the grid behind it) show through
    }
}
