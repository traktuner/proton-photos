import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotosCore
import DesignSystem
import MediaCache
import TimelineFeature
import PhotoViewerFeature
import UploadFeature

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
    @State private var routeScrollPositions: [PhotoFilter: GridScrollAnchor] = [:]
    /// The placement target for the CURRENT route generation: a remembered photo anchor (restore) or nil
    /// (newest). Set synchronously when the route changes, BEFORE the async load, so the grid host has the
    /// correct target by the time the new sections arrive.
    @State private var routeInitialScrollAnchor: GridScrollAnchor? = nil
    @State private var searchText = ""
    @State private var committedSearchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?
    // Shared-element zoom transition (photo ↔ its grid cell).
    @State private var gridProxy = GridProxy()
    @State private var zoom: ZoomTransition?
    // Real height of the native window toolbar (its top safe-area inset). The viewer lays its media out
    // below this, so the open/close zoom must fly the photo into the SAME region to avoid a shrink/jump.
    @State private var topBarInset: CGFloat = 0
    // The grid's leading obstruction inset == the floating sidebar's overlap when it's open, else 0. Derived from
    // the KNOWN sidebar column width — SwiftUI coordinate spaces and preferences do NOT bridge across
    // NavigationSplitView's AppKit-hosted sidebar column, so the detail can't measure the overlap (its leading
    // safe-area inset reads 0 under a floating overlay sidebar). It changes only on a sidebar toggle (constant
    // during any window resize → no per-tick Metal re-layout).
    private var leadingObstructionInset: CGFloat { columnVisibility == .detailOnly ? 0 : sidebarWidth }
    // Selection + export.
    @State private var selectionMode = false
    @State private var selectedUIDs: Set<PhotoUID> = []
    @State private var isExporting = false
    @State private var pendingTrashItems: [PhotoItem] = []
    @State private var closeViewerAfterTrash = false
    @State private var confirmTrash = false
    // Favorites (read from server so iOS favorites show up; toggle writes back).
    @State private var favorites: Set<PhotoUID> = []
    @State private var uploadRefreshTask: Task<Void, Never>?
    @State private var uploadRefreshMessage: String?
    @State private var uploadRefreshBusy = false
    /// Whether the current banner message represents success (drives the icon/colour). Tracked
    /// explicitly so the banner never compares against localized message text.
    @State private var uploadRefreshSuccess = false
    private let feed: ThumbnailFeed
    private let aspects: AspectRegistry
    private let zoomOpenSpring = (response: 0.34, damping: 0.86)
    private let zoomCloseSpring = (response: 0.32, damping: 0.88)

    init(model: AppModel, facade: ProtonClientFacade) {
        self.model = model
        self.facade = facade
        self.backend = facade.backend
        self.uploadCoordinator = facade.uploadCoordinator
        let aspects = AspectRegistry()
        self.aspects = aspects
        // Use the SHARED, account-configured cache (AppModel.prepareBackend calls
        // OfflineLibraryManager.shared.configure(session:) before this view is built) so the encrypted
        // disk cache uses the durable per-account session-derived key and survives relaunch. A fresh
        // ThumbnailCache() here would stay on a per-process ephemeral key and re-crawl the whole library
        // every launch.
        let feed = ThumbnailFeed(cache: OfflineLibraryManager.shared.cache, loader: backend, aspects: aspects)
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
                    // user-resizable — an AppKit quirk we accept; min==ideal==max did not change it.)
                    .navigationSplitViewColumnWidth(sidebarWidth)
            } detail: {
                TimelineView(model: timelineModel, aspects: aspects, level: $level, proxy: gridProxy,
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
                .modifier(WindowToolbarChrome(isViewer: viewerModel != nil))
                // Always the real inset — do NOT flip to 0 when the viewer opens: the grid is covered by the
                // viewer anyway, and a flip would arm a spurious full-width sidebar scale that plays when you
                // close the viewer (and would move the cell the zoom transition flies from).
                .environment(\.gridLeadingEventInset, leadingObstructionInset)
                .onChange(of: searchText) { _, value in scheduleSearchCommit(value) }
            }
            .task { await loadAlbums() }
            .onAppear {
                attachOfflineManager()
                publishMetalGridLabData()
                if librarySettled { model.markLibraryReady() }
            }
            .onChange(of: librarySettled) { _, settled in
                if settled { model.markLibraryReady() }   // lift the launch veil once the grid is ready
            }
            .onChange(of: selection) { oldValue, newValue in
                // Remember where the user was in the route they're leaving (the grid still shows it at this
                // point, so the proxy reports the OLD route's anchor). Returning to that route re-pins it.
                if let anchor = gridProxy.currentScrollAnchor?() {
                    routeScrollPositions[oldValue] = anchor
                }
                // The new route opens at its remembered position, or at the newest end on first visit. Both the
                // target and the generation are set SYNCHRONOUSLY here — BEFORE the async `select(...)` that loads
                // the route — so the generation is already pending when the new sections (and the new data token)
                // arrive in the grid. The host owns the one-shot placement; we never scroll from here. (Not
                // `scrollToLatest`: that re-arms sticky bottom-pinning and would fight the user's first scroll.)
                routeInitialScrollAnchor = routeScrollPositions[newValue]
                routeScrollGeneration += 1
                Task { await timelineModel.select(newValue) }
            }
            .onChange(of: timelineModel.allItems.count) { _, count in
                OfflineLibraryManager.shared.liveAssetCount = count
                publishMetalGridLabData()
            }
            .onDisappear {
                searchDebounceTask?.cancel()
                searchDebounceTask = nil
            }
            .onChange(of: columnVisibility) { _, newValue in
                // The NATIVE split-view toggle drives columnVisibility — mirror it back into our open-state +
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

            // Hidden while a NON-interactive zoom (open/close spring) animates — the overlay stands in. During an
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
                // NOT `.opacity(0)` while dismissing — an alpha-0 NSView is non-hit-testable, so a fresh pinch would
                // leak to the grid behind (it would scroll/zoom) and never return to the scroll view (the image
                // "locks"). The viewer stays hit-testable and hides its OWN background + image while dismissing, so
                // the gesture always reaches its scroll view and the grid behind stays frozen.
            }

            // Shared-element zoom overlay: a single image morphing between the cell and fullscreen.
            if let zoom { zoomOverlay(zoom) }

            if isExporting {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("export.preparing")
                        .font(.callout.weight(.medium))
                }
                .padding(22)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }

            uploadRefreshBanner

        }
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
                .background(.regularMaterial, in: Capsule())
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
            // Full-window coords (this layer ignores the safe area, matching the window-space cell frames).
            // At progress 1 the photo is the media region BELOW the opaque top bar, identical to where the
            // viewer renders it — so handing off to the viewer causes no shrink/jump; at 0 it is the grid cell.
            let contentRect = CGRect(x: 0, y: topBarInset,
                                     width: geo.size.width, height: max(0, geo.size.height - topBarInset))
            let full = fitRect(z.image, in: contentRect)
            let p = max(0, min(1, z.progress))
            let frame = Self.lerpRect(z.cellFrame, full, p)
            ZStack {
                ViewerVisualConstants.backgroundColor.opacity(p)   // fades as the photo shrinks ⇒ the grid shows through
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

    private func openPhoto(_ item: PhotoItem, _ items: [PhotoItem]) {
        // Need the cell's on-screen frame and a thumbnail to fly; otherwise just open directly.
        guard let cell = gridProxy.windowFrameForItem?(item), let img = feed.memoryImage(for: item.uid) else {
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
        guard zoom == nil, let vm = viewerModel, let img = vm.image,
              let cell = gridProxy.windowFrameForItem?(vm.current) else { return }
        zoom = ZoomTransition(item: vm.current, image: img, cellFrame: cell, progress: 1, interactive: true)
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
                // Only a real close reveals the grid (a snap-back keeps the viewer) — repaint it then.
                if shouldClose { DispatchQueue.main.async { gridProxy.redrawOnReveal?() } }
            }
        }
    }

    private func closePhoto() {
        guard let vm = viewerModel else { return }
        let item = vm.current
        // Fly back to the photo's ACTUAL cell. If it scrolled off-screen (user navigated), close
        // instantly rather than centre-scrolling (which made it always shrink into the middle).
        logViewerToolbar(mode: "grid")
        guard let img = vm.image, let cell = gridProxy.windowFrameForItem?(item) else {
            viewerModel = nil
            DispatchQueue.main.async { gridProxy.redrawOnReveal?() }
            return
        }
        zoom = ZoomTransition(item: item, image: img, cellFrame: cell, progress: 1, interactive: false)
        DispatchQueue.main.async {
            withAnimation(.spring(response: zoomCloseSpring.response, dampingFraction: zoomCloseSpring.damping)) {
                zoom?.progress = 0
            } completion: {
                viewerModel = nil
                zoom = nil
                // The overlay is gone and the grid is uncovered — force one repaint (next runloop, after SwiftUI
                // removes the overlay) so it paints from its resident textures instead of showing the purged clear
                // surface until a stray relayout streams the tiles back top-to-bottom.
                DispatchQueue.main.async { gridProxy.redrawOnReveal?() }
            }
        }
    }

    private func makeViewer(_ item: PhotoItem, _ items: [PhotoItem]) -> PhotoViewerModel {
        let index = items.firstIndex(of: item) ?? 0
        return PhotoViewerModel(items: items, index: index, feed: feed, media: backend,
                                streamer: backend, metadataProvider: backend,
                                previewCache: OfflineLibraryManager.shared.previewCache)
    }

    /// Registers this window's thumbnail feed with the shared offline-cache manager, so the Settings
    /// scene can delete the cache and read status. The thumbnail crawl is mandatory grid infrastructure,
    /// independent of the Offline Photo Library toggle.
    private func attachOfflineManager() {
        let manager = OfflineLibraryManager.shared
        manager.attach(feed: feed, stats: backend)
        manager.liveAssetCount = timelineModel.allItems.count
    }

    /// Hands the live timeline sections + shared thumbnail feed to the (separate-window) Metal Grid Lab
    /// so it can render the REAL library. Read-only — does not touch the production grid.
    private func publishMetalGridLabData() {
        if case .loaded(let sections) = timelineModel.state {
            MetalGridLabBridge.shared.publish(sections: sections, feed: feed)
        }
    }

    /// Aspect-fit rect of `image` centred in `size` — the photo's fullscreen frame.
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

    /// True once the timeline has settled (loaded / empty / failed) — the signal that lifts the launch veil.
    private var librarySettled: Bool {
        if case .loading = timelineModel.state { return false }
        return true
    }

    private var title: String {
        switch selection {
        case .all: String(localized: "library.title")
        case .tag(let t): t.title
        case .album(_, let name): name
        case .trash: String(localized: "sidebar.recently_deleted")
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
                gridProxy.scrollToItem?(found)
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
        #if DEBUG
        print(line)
        #endif
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
        #if DEBUG
        print(line)
        #endif
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

    private func trashPhotos(_ items: [PhotoItem]) {
        let uids = items.map(\.uid)
        timelineModel.remove(Set(uids))          // optimistic removal from the grid
        favorites.subtract(uids)
        Task { try? await backend.trash(uids) }
    }

    private func restorePhotos(_ items: [PhotoItem]) {
        let uids = items.map(\.uid)
        timelineModel.remove(Set(uids))          // optimistic removal from the trash view
        Task { try? await backend.restore(uids) }
    }

    private var selectedItems: [PhotoItem] { timelineModel.allItems.filter { selectedUIDs.contains($0.uid) } }

    private func scheduleSearchCommit(_ value: String) {
        searchDebounceTask?.cancel()
        if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            committedSearchText = ""
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
                .background(.regularMaterial, in: Capsule())
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

                Button {
                    Task { await performExport([viewerModel.current]) }
                } label: {
                    Label("toolbar.download_original", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .disabled(isExporting)
                .help("toolbar.download_original")
                .accessibilityLabel("toolbar.download_original")

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
            // click opens. The toolbar is stable — the download (or restore) + trash actions are always
            // present and just enable when something is selected.
            ToolbarItemGroup(placement: .primaryAction) {
                uploadToolbarMenu
                if selection == .trash {
                    Button { restoreSelected() } label: {
                        if selectedUIDs.isEmpty {
                            Image(systemName: "arrow.uturn.backward")
                        } else {
                            Label("\(selectedUIDs.count)", systemImage: "arrow.uturn.backward")
                        }
                    }
                    .disabled(selectedUIDs.isEmpty)
                    .help("toolbar.restore_from_trash")
                    .accessibilityLabel(selectedUIDs.isEmpty ? "a11y.restore_selected_from_trash" : "a11y.restore_count_from_trash \(selectedUIDs.count)")
                } else {
                    Button { downloadSelected() } label: {
                        if selectedUIDs.isEmpty {
                            Image(systemName: "square.and.arrow.down")
                        } else {
                            Label("\(selectedUIDs.count)", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(selectedUIDs.isEmpty || isExporting)
                    .help(selectedUIDs.count > 1 ? "toolbar.download_count_photos_help \(selectedUIDs.count)" : "toolbar.download_original")
                    .accessibilityLabel(selectedUIDs.isEmpty ? "a11y.download_selected_originals" : "a11y.download_count_selected_originals \(selectedUIDs.count)")
                    Button { trashSelected() } label: {
                        Label("toolbar.move_selected_to_trash", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                        .disabled(selectedUIDs.isEmpty)
                        .help("toolbar.move_to_trash")
                        .accessibilityLabel("toolbar.move_selected_to_trash")
                }
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
                Menu {
                    Button("action.sign_out", role: .destructive) { model.signOut() }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
            }
        }
    }

    /// Apple-Photos-style aspect/square thumbnail toggle. Switches `gridContentMode` between
    /// aspectFitInsideSquare and squareFillCrop and pushes it to the grid coordinator — content fit ONLY, the
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
        .disabled(level >= 4)   // overview levels are square-only — the toggle is inert there
    }

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
        #if DEBUG
        print(line)
        #endif
    }

    // MARK: - Sidebar overlay

    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.22)) {
            sidebarOpen.toggle()
            columnVisibility = sidebarOpen ? .all : .detailOnly   // drive the native split view
        }
        SidebarPersistence.saveVisible(sidebarOpen)
        logSidebar(dragging: false)
    }

    private func logSidebar(dragging: Bool) {
        #if DEBUG
        let persisted = SidebarPersistence.resolvedWidth()
        print("[Sidebar] visible=\(sidebarOpen) width=\(Int(sidebarWidth)) dragging=\(dragging) persistedWidth=\(Int(persisted))")
        #endif
    }

    // MARK: - Download / export

    private func downloadSelected() {
        let items = timelineModel.allItems.filter { selectedUIDs.contains($0.uid) }
        guard !items.isEmpty, !isExporting else { return }
        Task { await performExport(items) }
    }

    /// Downloads original(s) only to explicit user-selected destinations. The app does not stage decrypted
    /// originals in its own temp/cache directories.
    @MainActor private func performExport(_ items: [PhotoItem]) async {
        isExporting = true
        defer { isExporting = false }
        do {
            if items.count == 1 {
                let item = items[0]
                let meta = try? await backend.metadata(for: item.uid)
                let name = meta?.filename ?? defaultName(item, ext: defaultExtension(item, metadata: meta))
                guard let dest = chooseSingleDestination(suggestedName: name) else { return }
                let data = try await backend.originalData(for: item.uid)
                try? FileManager.default.removeItem(at: dest)
                try data.write(to: dest, options: .atomic)
                NSWorkspace.shared.activateFileViewerSelecting([dest])
            } else {
                guard let folder = chooseExportFolder() else { return }
                var used = Set<String>()
                for item in items {
                    let meta = try? await backend.metadata(for: item.uid)
                    let base = meta?.filename ?? defaultName(item, ext: defaultExtension(item, metadata: meta))
                    let name = uniqueName(base, used: &used)
                    let dest = folder.appendingPathComponent(name)
                    let data = try await backend.originalData(for: item.uid)
                    try? FileManager.default.removeItem(at: dest)
                    try data.write(to: dest, options: .atomic)
                }
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            }
        } catch {
            DebugLog.log("export failed: \(error)")
        }
    }

    private func chooseSingleDestination(suggestedName: String) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func chooseExportFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "export.button")
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func defaultName(_ item: PhotoItem, ext: String) -> String {
        let e = ext.isEmpty ? "jpg" : ext
        return "\(item.uid.nodeID.prefix(8)).\(e)"
    }

    private func defaultExtension(_ item: PhotoItem, metadata: PhotoMetadata?) -> String {
        let mime = metadata?.mimeType ?? item.mediaType
        if mime.contains("png") { return "png" }
        if mime.contains("heic") || mime.contains("heif") { return "heic" }
        if mime.contains("quicktime") { return "mov" }
        if mime.hasPrefix("video/") { return "mp4" }
        return "jpg"
    }

    private func uniqueName(_ name: String, used: inout Set<String>) -> String {
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
/// masked to a vertical gradient — strongest frost at the very top, fading to fully clear below the toolbar
/// band. It never covers the sidebar (it is an overlay on the detail), never paints a flat opaque strip, and
/// never blocks pointer/scroll events. When the grid scrolls, the photos show through the fading edge.
private struct GridTopFrost: View {
    /// Total band height — the toolbar inset plus the fade region below it.
    let height: CGFloat

    var body: some View {
        // A LIGHT, UNIFORM frost across the toolbar band (no gradient) — held at full strength over the
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
            .opacity(0.5)                                        // lighter — a subtle frost, not a dark band
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

/// Window-toolbar chrome, the two distinct modes the app has:
///
/// • **Viewer** — a deliberately OPAQUE, warm bar that matches the photo-viewer media background, so the
///   viewer reads as a focused, distraction-free surface (Apple Photos does the same in its single-photo view).
///
/// • **Grid** — NOTHING is applied. The system renders its native macOS Liquid Glass toolbar, which samples
///   and adapts to the photos that scroll underneath it (the window is `fullSizeContentView` with a
///   transparent titlebar and the grid ignores the top safe area). That gives Apple's content-adaptive glass
///   refraction + scroll-edge blur for free — no painted strip, no fake `LinearGradient`/`Rectangle` overlay,
///   and no forced `.toolbarBackground` material (which would also paint an opaque band over the sidebar's
///   titlebar region and make the sidebar look boxed). Active/inactive vividness is left to the system.
private struct WindowToolbarChrome: ViewModifier {
    let isViewer: Bool

    func body(content: Content) -> some View {
        if isViewer {
            content
                .toolbarBackground(ViewerVisualConstants.backgroundColor, for: .windowToolbar)
                .toolbarBackground(.visible, for: .windowToolbar)
        } else {
            content   // native Liquid Glass — see the type doc above
        }
    }
}

/// Collapsible left sidebar — a native macOS sidebar `List` (Liquid-Glass vibrant material, native
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
            }
            if !albums.isEmpty {
                Section("sidebar.albums") {
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
