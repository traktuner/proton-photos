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
    @State private var columnVisibility: NavigationSplitViewVisibility
    @State private var albums: [PhotoAlbum] = []
    @State private var selection: PhotoFilter = .all
    @State private var searchText = ""
    // Shared-element zoom transition (photo ↔ its grid cell).
    @State private var gridProxy = GridProxy()
    @State private var zoom: ZoomTransition?
    // Real height of the native window toolbar (its top safe-area inset). The viewer lays its media out
    // below this, so the open/close zoom must fly the photo into the SAME region to avoid a shrink/jump.
    @State private var topBarInset: CGFloat = 0
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
            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(albums: albums, selection: $selection)
                    .navigationSplitViewColumnWidth(
                        min: SidebarMetrics.minWidth,
                        ideal: sidebarWidth,
                        max: SidebarMetrics.maxWidth
                    )
            } detail: {
                TimelineView(model: timelineModel, aspects: aspects, level: $level, proxy: gridProxy,
                             searchText: searchText,
                             selectionMode: selectionMode, media: backend, metadataProvider: backend, favoriteUIDs: favorites,
                             onSelectionChange: { selectedUIDs = $0 }) { item, items in
                    openPhoto(item, items)
                }
                .ignoresSafeArea(.container, edges: .top)   // photos scroll under the glass toolbar
                .navigationTitle(viewerModel == nil ? title : "")
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search \(title)")
                .toolbar { toolbarContent }
                // Viewer: opaque, warm top bar matching the media background. Grid: default glass material
                // that appears as photos scroll under it.
                .toolbarBackground(viewerModel != nil
                                   ? AnyShapeStyle(ViewerVisualConstants.backgroundColor)
                                   : AnyShapeStyle(.bar),
                                   for: .windowToolbar)
                .toolbarBackground(viewerModel != nil ? .visible : .automatic, for: .windowToolbar)
            }
            .overlay(alignment: .top) {
                if viewerModel == nil {
                    gridToolbarGlassFade
                }
            }
            .task { await loadAlbums() }
            .onAppear {
                attachOfflineManager()
                publishMetalGridLabData()
            }
            .onChange(of: selection) { _, newValue in
                Task {
                    await timelineModel.select(newValue)
                    if newValue == .all {
                        DispatchQueue.main.async {
                            gridProxy.scrollToLatest?()
                        }
                    }
                }
            }
            .onChange(of: timelineModel.allItems.count) { _, count in
                OfflineLibraryManager.shared.liveAssetCount = count
                publishMetalGridLabData()
            }
            .onChange(of: columnVisibility) { _, newValue in
                syncSidebarVisibility(from: newValue)
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

            // The viewer is hidden while a zoom transition is animating (the overlay stands in).
            if let viewerModel, zoom == nil {
                PhotoViewerView(model: viewerModel,
                                isFavorite: { favorites.contains($0) },
                                onToggleFavorite: toggleFavorite,
                                onTrash: { requestTrash([$0], closeViewer: true) }) { closePhoto() }
            }

            // Shared-element zoom overlay: a single image morphing between the cell and fullscreen.
            if let zoom { zoomOverlay(zoom) }

            if isExporting {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    Text("Preparing…")
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
            Button("Move to Trash", role: .destructive) {
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
            Button("Cancel", role: .cancel) {
                pendingTrashItems = []
                closeViewerAfterTrash = false
            }
        } message: {
            Text(trashConfirmationMessage)
        }
    }

    private var gridToolbarGlassFade: some View {
        GeometryReader { geo in
            let height = max(84, geo.safeAreaInsets.top + 34)
            VStack(spacing: 0) {
                Rectangle()
                    .fill(.bar)
                    .frame(height: height)
                    .mask(
                        LinearGradient(stops: [
                            .init(color: .black, location: 0),
                            .init(color: .black, location: 0.50),
                            .init(color: .clear, location: 1)
                        ], startPoint: .top, endPoint: .bottom)
                    )
                Spacer(minLength: 0)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
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
                        Image(systemName: uploadRefreshMessage == "Uploaded" || uploadRefreshMessage == "Library refreshed" ? "checkmark.circle.fill" : "exclamationmark.circle")
                            .foregroundStyle(uploadRefreshMessage == "Uploaded" || uploadRefreshMessage == "Library refreshed" ? .green : .secondary)
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
        var expanded: Bool
    }

    @ViewBuilder private func zoomOverlay(_ z: ZoomTransition) -> some View {
        GeometryReader { geo in
            // Full-window coords (this layer ignores the safe area, matching the window-space cell frames).
            // The expanded target is the media region BELOW the opaque top bar, identical to where the
            // viewer will render the photo — so handing off to the viewer causes no shrink/jump.
            let contentRect = CGRect(x: 0, y: topBarInset,
                                     width: geo.size.width, height: max(0, geo.size.height - topBarInset))
            let full = fitRect(z.image, in: contentRect)
            let frame = z.expanded ? full : z.cellFrame
            ZStack {
                ViewerVisualConstants.backgroundColor.opacity(z.expanded ? 1 : 0)
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

    private func openPhoto(_ item: PhotoItem, _ items: [PhotoItem]) {
        // Need the cell's on-screen frame and a thumbnail to fly; otherwise just open directly.
        guard let cell = gridProxy.windowFrameForItem?(item), let img = feed.memoryImage(for: item.uid) else {
            viewerModel = makeViewer(item, items)
            logViewerToolbar(mode: "viewer")
            return
        }
        zoom = ZoomTransition(item: item, image: img, cellFrame: cell, expanded: false)
        DispatchQueue.main.async {
            withAnimation(.spring(response: zoomOpenSpring.response, dampingFraction: zoomOpenSpring.damping)) {
                zoom?.expanded = true
            } completion: {
                viewerModel = makeViewer(item, items)
                logViewerToolbar(mode: "viewer")
                zoom = nil
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
            return
        }
        zoom = ZoomTransition(item: item, image: img, cellFrame: cell, expanded: true)
        DispatchQueue.main.async {
            withAnimation(.spring(response: zoomCloseSpring.response, dampingFraction: zoomCloseSpring.damping)) {
                zoom?.expanded = false
            } completion: {
                viewerModel = nil
                zoom = nil
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

    private var title: String {
        switch selection {
        case .all: "Library"
        case .tag(let t): t.title
        case .album(_, let name): name
        case .trash: "Recently Deleted"
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
        panel.message = "Choose photos or videos to upload"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        uploadCoordinator.chooseDestination(files: panel.urls)
    }

    private func presentUploadFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder to upload (media is discovered recursively)"
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        uploadCoordinator.chooseDestination(folder: folder)
    }

    private func scheduleUploadRefresh(_ event: UploadCompletedEvent) {
        uploadRefreshTask?.cancel()
        uploadRefreshTask = Task { await runUploadRefresh(event) }
    }

    @MainActor private func runUploadRefresh(_ event: UploadCompletedEvent) async {
        uploadRefreshBusy = true
        uploadRefreshMessage = "Upload complete, refreshing library…"
        let schedule = TimelineRefreshRetrySchedule.uploadDefault.delays
        for (attempt, delay) in schedule.enumerated() {
            guard !Task.isCancelled else { return }
            if delay > .zero {
                uploadRefreshMessage = "Upload complete, waiting for library refresh…"
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
                uploadRefreshMessage = "Uploaded"
                gridProxy.scrollToItem?(found)
                clearUploadRefreshMessage(after: .seconds(2))
                return
            }
        }
        uploadRefreshBusy = false
        uploadRefreshMessage = "Upload completed, but the library has not indexed it yet. Use Refresh Library."
    }

    private func refreshLibraryManually() {
        Task { await performManualLibraryRefresh() }
    }

    @MainActor private func performManualLibraryRefresh() async {
        uploadRefreshBusy = true
        uploadRefreshMessage = "Refreshing library…"
        let result = await timelineModel.refreshLibrary()
        OfflineLibraryManager.shared.liveAssetCount = timelineModel.allItems.count
        await loadAlbums()
        logUploadRefresh(uploadedNode: "-", attempt: 0, result: result)
        uploadRefreshBusy = false
        uploadRefreshMessage = result.errorMessage == nil ? "Library refreshed" : "Library refresh failed"
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
        pendingTrashItems.count == 1 ? "Move photo to Trash?" : "Move \(pendingTrashItems.count) photos to Trash?"
    }

    private var trashConfirmationMessage: String {
        pendingTrashItems.count == 1
            ? "The photo will move to Recently Deleted."
            : "The selected photos will move to Recently Deleted."
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if let viewerModel {
            ToolbarItem(placement: .navigation) {
                Button { closePhoto() } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .help("Back to library")
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
                    Label("Info", systemImage: viewerModel.showInfo ? "info.circle.fill" : "info.circle")
                        .labelStyle(.iconOnly)
                }
                .help("Info")
                .accessibilityLabel("Info")

                Button {
                    Task { await performExport([viewerModel.current]) }
                } label: {
                    Label("Download original", systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly)
                }
                .disabled(isExporting)
                .help("Download original")
                .accessibilityLabel("Download original")

                Button { toggleFavorite(viewerModel.current.uid) } label: {
                    Label(favorites.contains(viewerModel.current.uid) ? "Remove favorite" : "Favorite",
                          systemImage: favorites.contains(viewerModel.current.uid) ? "heart.fill" : "heart")
                        .labelStyle(.iconOnly)
                }
                .help(favorites.contains(viewerModel.current.uid) ? "Remove favorite" : "Favorite")
                .accessibilityLabel(favorites.contains(viewerModel.current.uid) ? "Remove favorite" : "Favorite")

                Button { onTrashViewerItem(viewerModel.current) } label: {
                    Label("Move to trash", systemImage: "trash")
                        .labelStyle(.iconOnly)
                }
                .help("Move to trash")
                .accessibilityLabel("Move to trash")
            }
        } else {
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
                    .help("Restore from trash")
                    .accessibilityLabel(selectedUIDs.isEmpty ? "Restore selected from trash" : "Restore \(selectedUIDs.count) selected from trash")
                } else {
                    Button { downloadSelected() } label: {
                        if selectedUIDs.isEmpty {
                            Image(systemName: "square.and.arrow.down")
                        } else {
                            Label("\(selectedUIDs.count)", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(selectedUIDs.isEmpty || isExporting)
                    .help(selectedUIDs.count > 1 ? "Download \(selectedUIDs.count) photos to a folder" : "Download original")
                    .accessibilityLabel(selectedUIDs.isEmpty ? "Download selected originals" : "Download \(selectedUIDs.count) selected originals")
                    Button { trashSelected() } label: {
                        Label("Move selected to trash", systemImage: "trash")
                            .labelStyle(.iconOnly)
                    }
                        .disabled(selectedUIDs.isEmpty)
                        .help("Move to trash")
                        .accessibilityLabel("Move selected to trash")
                }
                ControlGroup {
                    Button { gridProxy.zoomOut?() } label: {
                        Label("Smaller thumbnails", systemImage: "minus")
                            .labelStyle(.iconOnly)
                    }
                        .help("Smaller thumbnails")
                        .disabled(level >= 5)
                        .accessibilityLabel("Smaller thumbnails")
                    Button { gridProxy.zoomIn?() } label: {
                        Label("Larger thumbnails", systemImage: "plus")
                            .labelStyle(.iconOnly)
                    }
                        .help("Larger thumbnails")
                        .disabled(level <= 0)
                        .accessibilityLabel("Larger thumbnails")
                }
                aspectSquareToggleButton
                Menu {
                    Button("Sign out", role: .destructive) { model.signOut() }
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
            Button("Upload Photos…") { performUploadUIAction("uploadPhotos", trigger: .toolbar) }
                .disabled(!uploadCoordinator.uploadCapabilities.canUpload)
            Button("Upload Folder…") { performUploadUIAction("uploadFolder", trigger: .toolbar) }
                .disabled(!uploadCoordinator.uploadCapabilities.canUpload)
            Divider()
            Button("Show Uploads") { performUploadUIAction("showQueue", trigger: .toolbar) }
        } label: {
            Label("Upload", systemImage: "tray.and.arrow.up")
        }
        .help("Upload photos or a folder")
        .accessibilityLabel("Upload")
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

    private func toggleSidebar() {
        let targetVisible = !sidebarOpen
        postGridResizeHint(reason: .sidebarToggle, phase: "begin")
        withAnimation(.easeInOut(duration: 0.22)) {
            sidebarOpen = targetVisible
            columnVisibility = targetVisible ? .all : .detailOnly
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            postGridResizeHint(reason: .sidebarToggle, phase: "end")
        }
        SidebarPersistence.saveVisible(targetVisible)
        logSidebar(dragging: false)
    }

    private func syncSidebarVisibility(from visibility: NavigationSplitViewVisibility) {
        let visible = visibility != .detailOnly
        guard visible != sidebarOpen else { return }
        postGridResizeHint(reason: .sidebarToggle, phase: "begin")
        sidebarOpen = visible
        SidebarPersistence.saveVisible(visible)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            postGridResizeHint(reason: .sidebarToggle, phase: "end")
        }
        logSidebar(dragging: false)
    }

    private func postGridResizeHint(reason: GridResizeReason, phase: String) {
        NotificationCenter.default.post(
            name: .protonPhotosGridResizeHint,
            object: nil,
            userInfo: ["reason": reason.rawValue, "phase": phase]
        )
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
        panel.prompt = "Export"
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


/// Collapsible left sidebar — a native macOS sidebar `List` (Liquid-Glass vibrant material, native
/// selection): Proton smart filters (tags) on top, user albums below.
private struct SidebarView: View {
    let albums: [PhotoAlbum]
    @Binding var selection: PhotoFilter

    var body: some View {
        List(selection: Binding(get: { selection }, set: { if let v = $0 { selection = v } })) {
            Section {
                Label("All Photos", systemImage: "photo.on.rectangle.angled")
                    .tag(PhotoFilter.all)
                ForEach(PhotoTag.allCases, id: \.self) { tag in
                    Label(tag.title, systemImage: tag.systemImage)
                        .tag(PhotoFilter.tag(tag))
                }
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { album in
                        Label(album.title, systemImage: "rectangle.stack")
                            .tag(PhotoFilter.album(id: album.id, title: album.title))
                    }
                }
            }
            Section {
                Label("Recently Deleted", systemImage: "trash")
                    .tag(PhotoFilter.trash)
            }
        }
        .listStyle(.sidebar)
    }
}
