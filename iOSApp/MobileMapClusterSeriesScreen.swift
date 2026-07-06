import CoreLocation
import DesignSystemCore
import GridCore
import PhotoViewerCore
import PhotosCore
import SwiftUI
import TimelineUIKitFeature

/// Pushed when a map cluster is tapped. Lists every member photo in the shared UIKit timeline grid, with the
/// same selection toolbar (share / trash), hidden tab bar, and viewer routing as the main Photos tab. The
/// navigation title reverse-geocodes from the cluster's center coordinate so the user sees a real place name.
struct MobileMapClusterSeriesScreen: View {
    let uids: [PhotoUID]
    let coordinate: CLLocationCoordinate2D

    @Environment(MobileLibraryModel.self) private var model
    @Environment(MobileViewerRouter.self) private var viewerRouter
    @State private var selectionMode = false
    @State private var selected: Set<PhotoUID> = []
    @State private var sharePayload: MobileSharePayload?
    @State private var partialShare: MobilePartialShare?
    @State private var isExporting = false
    @State private var showTrashConfirm = false
    @State private var actionError: MobileSelectionError?
    @State private var placeName: String?

    private var selectionBusy: Bool { isExporting }

    private var clusterItems: [PhotoItem] { model.selectedItems(Set(uids)) }

    var body: some View {
        content
            .navigationTitle(placeName ?? String(localized: "map.cluster_title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .toolbar(selectionMode ? .hidden : .automatic, for: .tabBar)
            .task { await resolvePlaceName() }
            .sheet(item: $sharePayload) { payload in
                MobileActivityView(urls: payload.urls)
            }
            .confirmationDialog(
                String(localized: "selection.share_partial_title"),
                isPresented: Binding(get: { partialShare != nil }, set: { if !$0 { partialShare = nil } }),
                titleVisibility: .visible,
                presenting: partialShare
            ) { info in
                Button(String(localized: "selection.share_partial_proceed")) {
                    sharePayload = MobileSharePayload(urls: info.urls)
                }
                Button(String(localized: "action.cancel"), role: .cancel) {}
            } message: { info in
                Text(String(localized: "selection.share_partial_message \(info.failed)"))
            }
            .confirmationDialog(
                String(localized: "selection.trash_title"),
                isPresented: $showTrashConfirm,
                titleVisibility: .visible
            ) {
                Button(String(localized: "selection.trash_confirm"), role: .destructive) { performTrash() }
                Button(String(localized: "action.cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "selection.trash_message"))
            }
            .alert(
                actionError?.message ?? "",
                isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
            ) {
                Button(String(localized: "action.ok"), role: .cancel) {}
            }
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        if !clusterItems.isEmpty {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selectionMode ? String(localized: "action.done") : String(localized: "action.select")) {
                    toggleSelectionMode()
                }
            }
        }
        if selectionMode {
            ToolbarItem(placement: .bottomBar) {
                Button {
                    startShare()
                } label: {
                    if isExporting {
                        ProgressView()
                    } else {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                .disabled(selected.isEmpty || selectionBusy)
                .accessibilityLabel(String(localized: "selection.share_a11y"))
            }
            ToolbarSpacer(.flexible, placement: .bottomBar)
            if let centerText = selectionCenterText {
                ToolbarItem(placement: .bottomBar) {
                    Text(centerText)
                        .font(.body)
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .fixedSize()
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
            }
            ToolbarItem(placement: .bottomBar) {
                Button(role: .destructive) {
                    showTrashConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(selected.isEmpty || selectionBusy)
                .accessibilityLabel(String(localized: "selection.trash_a11y"))
            }
        }
    }

    private var selectionCenterText: String? {
        switch SelectionToolbarText.centerLabel(selectedCount: selected.count) {
        case .prompt: return String(localized: "selection.select_items")
        case .hidden: return nil
        case let .count(count): return String(localized: "selection.count_selected \(count)")
        }
    }

    @ViewBuilder private var content: some View {
        ZStack {
            ProtonColor.backgroundNorm.ignoresSafeArea()

            if let feed = model.thumbnailFeed, !clusterItems.isEmpty {
                UIKitTimelineGrid(
                    items: clusterItems,
                    thumbnailFeed: feed,
                    selectionMode: selectionMode,
                    selectedUIDs: selected,
                    isActive: true,
                    onOpenPhoto: open,
                    onToggleSelection: toggleSelection,
                    onDragSelectionChanged: applyDragSelection
                )
                .ignoresSafeArea(edges: .bottom)
            } else {
                ContentUnavailableView {
                    Label("map.empty_title", systemImage: "photo.on.rectangle")
                } description: {
                    Text("map.no_places_found_message")
                }
            }
        }
    }

    private func open(_ item: PhotoItem) {
        guard let index = model.index(of: item.uid) else { return }
        viewerRouter.presentation = MobileViewerPresentation(index: index, items: model.items)
    }

    private func toggleSelectionMode() {
        withAnimation(.easeInOut(duration: 0.2)) {
            selectionMode.toggle()
            if !selectionMode { selected.removeAll() }
        }
    }

    private func toggleSelection(_ item: PhotoItem) {
        if selected.contains(item.uid) { selected.remove(item.uid) } else { selected.insert(item.uid) }
    }

    private func applyDragSelection(_ uids: Set<PhotoUID>) {
        selected = uids
    }

    private func startShare() {
        guard let backend = model.backend else { return }
        let chosen = model.selectedItems(selected)
        guard !chosen.isEmpty else { return }
        isExporting = true
        Task {
            let result = await MobileMediaExporter.exportOriginals(
                chosen, backend: backend, cache: model.originalsCache, cacheCapBytes: model.originalsCacheCapBytes
            )
            isExporting = false
            if result.urls.isEmpty {
                actionError = MobileSelectionError(message: String(localized: "selection.share_failed"))
            } else if result.failed > 0 {
                partialShare = MobilePartialShare(urls: result.urls, failed: result.failed)
            } else {
                sharePayload = MobileSharePayload(urls: result.urls)
            }
        }
    }

    private func performTrash() {
        let uids = selected
        guard !uids.isEmpty else { return }
        Task {
            do {
                try await model.trashItems(uids)
                withAnimation(.easeInOut(duration: 0.2)) {
                    selected.removeAll()
                    selectionMode = false
                }
            } catch {
                actionError = MobileSelectionError(message: String(localized: "selection.trash_failed"))
            }
        }
    }

    private func resolvePlaceName() async {
        let name = await PlaceNameResolver.shared.placeName(latitude: coordinate.latitude, longitude: coordinate.longitude)
        placeName = name
    }
}
