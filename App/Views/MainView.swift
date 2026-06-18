import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PhotosCore
import DesignSystem
import MediaCache
import TimelineFeature
import PhotoViewerFeature

struct MainView: View {
    let model: AppModel
    let backend: any PhotosBackend

    @State private var timelineModel: TimelineViewModel
    @State private var viewerModel: PhotoViewerModel?
    @State private var level: Int = 2          // 0 = most zoomed in … 5 = most zoomed out
    @State private var sidebarOpen: Bool
    @State private var sidebarWidth: CGFloat
    @State private var albums: [PhotoAlbum] = []
    @State private var selection: PhotoFilter = .all
    // Shared-element zoom transition (photo ↔ its grid cell).
    @State private var gridProxy = GridProxy()
    @State private var zoom: ZoomTransition?
    // Selection + export.
    @State private var selectionMode = false
    @State private var selectedUIDs: Set<PhotoUID> = []
    @State private var isExporting = false
    // Favorites (read from server so iOS favorites show up; toggle writes back).
    @State private var favorites: Set<PhotoUID> = []
    private let tuning = AnimationTuning.shared
    @Environment(\.openWindow) private var openWindow
    private let feed: ThumbnailFeed
    private let aspects: AspectRegistry

    init(model: AppModel, backend: any PhotosBackend) {
        self.model = model
        self.backend = backend
        let aspects = AspectRegistry()
        self.aspects = aspects
        let feed = ThumbnailFeed(cache: ThumbnailCache(), loader: backend, aspects: aspects)
        self.feed = feed
        _timelineModel = State(initialValue: TimelineViewModel(repository: backend, feed: feed, library: backend))
        _sidebarOpen = State(initialValue: SidebarPersistence.resolvedVisible())
        _sidebarWidth = State(initialValue: SidebarPersistence.resolvedWidth())
    }

    var body: some View {
        ZStack {
            NavigationStack {
                HStack(spacing: 0) {
                    SidebarView(albums: albums, selection: $selection)
                        .frame(width: sidebarWidth)
                        .opacity(sidebarOpen ? 1 : 0)
                        .frame(width: sidebarOpen ? sidebarWidth : 0, alignment: .leading)
                        .clipped()
                        .allowsHitTesting(sidebarOpen)
                    SidebarResizeHandle(width: $sidebarWidth) { dragging in
                        postGridResizeHint(reason: .sidebarDrag, phase: dragging ? "begin" : "end")
                        logSidebar(dragging: dragging)
                    }
                    .frame(width: sidebarOpen ? 8 : 0)
                    .opacity(sidebarOpen ? 1 : 0)
                    .allowsHitTesting(sidebarOpen)
                    TimelineView(model: timelineModel, aspects: aspects, level: $level, proxy: gridProxy,
                                 selectionMode: selectionMode, media: backend, favoriteUIDs: favorites,
                                 onSelectionChange: { selectedUIDs = $0 }) { item, items in
                        openPhoto(item, items)
                    }
                    .ignoresSafeArea(.container, edges: .top)   // photos scroll under the glass toolbar
                }
                .navigationTitle(title)
                .toolbar { toolbarContent }
                .toolbarBackground(.automatic, for: .windowToolbar)
            }
            .task { await loadAlbums() }
            .onAppear {
                openWindow(id: "anim-tuning")             // dev: live animation tuning panel
                attachOfflineManager()
            }
            .onChange(of: selection) { _, newValue in Task { await timelineModel.select(newValue) } }
            .onChange(of: timelineModel.allItems.count) { _, count in
                OfflineLibraryManager.shared.liveAssetCount = count
            }
            .onReceive(NotificationCenter.default.publisher(for: .protonPhotosToggleSidebar)) { _ in
                toggleSidebar()
            }

            // The viewer is hidden while a zoom transition is animating (the overlay stands in).
            if let viewerModel, zoom == nil {
                PhotoViewerView(model: viewerModel,
                                isFavorite: { favorites.contains($0) },
                                onToggleFavorite: toggleFavorite,
                                onTrash: { trashPhotos([$0]); closePhoto() }) { closePhoto() }
            }

            // Shared-element zoom overlay: a single image morphing between the cell and fullscreen.
            if let zoom { zoomOverlay(zoom) }

            if isExporting {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Preparing download…").font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                }
                .padding(22)
                .glassEffect(in: RoundedRectangle(cornerRadius: 16))
            }

        }
        .coordinateSpace(name: "root")
        .animation(.easeInOut(duration: 0.22), value: sidebarOpen)
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
            let full = fitRect(z.image, in: geo.size)
            let frame = z.expanded ? full : z.cellFrame
            ZStack {
                Color.black.opacity(z.expanded ? 1 : 0)
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
            return
        }
        zoom = ZoomTransition(item: item, image: img, cellFrame: cell, expanded: false)
        DispatchQueue.main.async {
            withAnimation(.spring(response: tuning.zoomOpenResponse, dampingFraction: tuning.zoomOpenDamping)) {
                zoom?.expanded = true
            } completion: {
                viewerModel = makeViewer(item, items)
                zoom = nil
            }
        }
    }

    private func closePhoto() {
        guard let vm = viewerModel else { return }
        let item = vm.current
        // Fly back to the photo's ACTUAL cell. If it scrolled off-screen (user navigated), close
        // instantly rather than centre-scrolling (which made it always shrink into the middle).
        guard let img = vm.image, let cell = gridProxy.windowFrameForItem?(item) else {
            viewerModel = nil
            return
        }
        zoom = ZoomTransition(item: item, image: img, cellFrame: cell, expanded: true)
        viewerModel = nil
        DispatchQueue.main.async {
            withAnimation(.spring(response: tuning.zoomCloseResponse, dampingFraction: tuning.zoomCloseDamping)) {
                zoom?.expanded = false
            } completion: {
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
    /// scene can toggle prefetch / delete the cache / read status. Applies the persisted toggle and
    /// gives the manager a hook to restart the library crawl when offline mode is re-enabled.
    private func attachOfflineManager() {
        let manager = OfflineLibraryManager.shared
        manager.attach(feed: feed, stats: backend)
        manager.liveAssetCount = timelineModel.allItems.count
        manager.restartPrefetch = { [feed, timelineModel] in
            Task { await feed.startPrefetch(timelineModel.allItems.map(\.uid)) }
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
        favorites = (try? await backend.favoriteUIDs()) ?? []
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
        selectionMode = false; selectedUIDs = []
        trashPhotos(items)
    }

    private func restoreSelected() {
        let items = selectedItems
        selectionMode = false; selectedUIDs = []
        restorePhotos(items)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button { toggleSidebar() } label: { Image(systemName: "sidebar.left") }
                .help("Toggle sidebar")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            if selectionMode {
                if selection == .trash {
                    Button { restoreSelected() } label: {
                        Label("\(selectedUIDs.count)", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(selectedUIDs.isEmpty)
                    .help("Restore from trash")
                } else {
                    Button { downloadSelected() } label: {
                        Label("\(selectedUIDs.count)", systemImage: "square.and.arrow.down")
                    }
                    .disabled(selectedUIDs.isEmpty || isExporting)
                    .help(selectedUIDs.count > 1 ? "Download \(selectedUIDs.count) originals as ZIP" : "Download original")
                    Button { trashSelected() } label: { Image(systemName: "trash") }
                        .disabled(selectedUIDs.isEmpty)
                        .help("Move to trash")
                }
                Button("Done") { selectionMode = false; selectedUIDs = [] }
            } else {
                Button { selectionMode = true } label: { Image(systemName: "checkmark.circle") }
                    .help("Select photos")
                Button { gridProxy.zoomOut?() } label: { Image(systemName: "minus") }
                    .help("Smaller thumbnails")
                    .disabled(level >= 5)
                Button { gridProxy.zoomIn?() } label: { Image(systemName: "plus") }
                    .help("Larger thumbnails")
                    .disabled(level <= 0)
                Menu {
                    Button("Sign out", role: .destructive) { model.signOut() }
                } label: {
                    Image(systemName: "person.crop.circle")
                }
            }
        }
    }

    private func toggleSidebar() {
        postGridResizeHint(reason: .sidebarToggle, phase: "begin")
        withAnimation(.easeInOut(duration: 0.22)) {
            sidebarOpen.toggle()
        }
        SidebarPersistence.saveVisible(sidebarOpen)
        logSidebar(dragging: false)
    }

    private func postGridResizeHint(reason: GridResizeTransitionReason, phase: String) {
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

    @MainActor private func performExport(_ items: [PhotoItem]) async {
        isExporting = true
        defer { isExporting = false }
        do {
            if items.count == 1 {
                let item = items[0]
                let src = try await backend.downloadOriginal(for: item.uid)
                let name = (try? await backend.metadata(for: item.uid))?.filename ?? defaultName(item, ext: src.pathExtension)
                saveSingle(src: src, suggestedName: name)
            } else {
                // Download every original into a temp folder, then zip the folder.
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("ProtonPhotos-\(UUID().uuidString)/Photos", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var used = Set<String>()
                for item in items {
                    let src = try await backend.downloadOriginal(for: item.uid)
                    let base = (try? await backend.metadata(for: item.uid))?.filename ?? defaultName(item, ext: src.pathExtension)
                    let name = uniqueName(base, used: &used)
                    try? FileManager.default.copyItem(at: src, to: folder.appendingPathComponent(name))
                }
                saveZip(of: folder)
            }
        } catch {
            DebugLog.log("export failed: \(error)")
        }
    }

    private func defaultName(_ item: PhotoItem, ext: String) -> String {
        let e = ext.isEmpty ? "jpg" : ext
        return "\(item.uid.nodeID.prefix(8)).\(e)"
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

    private func saveSingle(src: URL, suggestedName: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: src, to: dest)
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }

    private func saveZip(of folder: URL) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Photos.zip"
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        // NSFileCoordinator's .forUploading option zips the folder into a temporary archive.
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder, options: .forUploading, error: &coordError) { zipURL in
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: zipURL, to: dest)
        }
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }
}


/// Draggable divider between the sidebar and the grid (Deliverable 4). Updates the bound width live
/// (clamped to `SidebarMetrics`) and persists it on release. Shows the resize cursor on hover.
private struct SidebarResizeHandle: View {
    @Binding var width: CGFloat
    var onDraggingChanged: (Bool) -> Void = { _ in }
    @State private var dragStart: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 8)
            .overlay(Divider(), alignment: .center)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragStart ?? width
                        if dragStart == nil {
                            dragStart = base
                            onDraggingChanged(true)
                        }
                        width = SidebarMetrics.clamp(base + value.translation.width)
                    }
                    .onEnded { _ in
                        dragStart = nil
                        SidebarPersistence.saveWidth(width)
                        onDraggingChanged(false)
                    }
            )
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
