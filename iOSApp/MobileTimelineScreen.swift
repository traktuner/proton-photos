import DesignSystemCore
import GridCore
import PhotosCore
import SwiftUI
import TimelineUIKitFeature

/// The main photos tab. The Metal grid mounts as soon as items and the feed exist; loading, empty and error
/// states stay as overlays driven by the shared `LibraryLoadState`.
struct MobileTimelineScreen: View {
    @Environment(MobileLibraryModel.self) private var model
    /// Whether the Photos tab is the active surface. Threaded into the grid so a hidden grid stops its
    /// render loop; defaults to true so previews/other embeds keep the grid live.
    var isActive: Bool = true
    /// Bumped by the tab shell when the already-active Fotos tab is retapped → the grid scrolls to the newest
    /// photos. A pass-through value only; the scroll math stays inside the grid host.
    var scrollToLatestSignal: Int = 0
    @State private var viewer: MobileViewerPresentation?
    @State private var selectionMode = false
    @State private var selected: Set<PhotoUID> = []
    @State private var sharePayload: MobileSharePayload?
    @State private var partialShare: MobilePartialShare?
    @State private var isExporting = false
    /// Non-nil while a save-to-Apple-Photos run is in flight; drives the centered progress overlay.
    @State private var saveProgress: MobileSaveProgress?
    @State private var showTrashConfirm = false
    @State private var actionError: MobileSelectionError?

    /// True while any selection action is running, so the other toolbar buttons disable together.
    private var selectionBusy: Bool { isExporting || saveProgress != nil }

    private var canSelect: Bool { model.loadState.isContentReady && !model.items.isEmpty }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "tab.photos"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .toolbar(selectionMode ? .hidden : .automatic, for: .tabBar)
        }
        .fullScreenCover(item: $viewer) { presentation in
            MobilePhotoViewer(
                items: presentation.items,
                startIndex: presentation.index,
                libraryModel: model
            )
        }
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
        if canSelect {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selectionMode ? String(localized: "action.done") : String(localized: "action.select")) {
                    toggleSelectionMode()
                }
            }
        }
        // Separate toolbar items keep the action buttons native while the center label stays unframed.
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
            ToolbarItem(placement: .bottomBar) {
                Button {
                    startSave()
                } label: {
                    Image(systemName: "square.and.arrow.down")
                }
                .disabled(selected.isEmpty || selectionBusy)
                .accessibilityLabel(String(localized: "selection.save_a11y"))
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

    /// Localized center text for the shared selection-toolbar policy.
    private var selectionCenterText: String? {
        switch SelectionToolbarText.centerLabel(selectedCount: selected.count) {
        case .prompt: return String(localized: "selection.select_items")
        case .hidden: return nil
        case let .count(count): return String(localized: "selection.count_selected \(count)")
        }
    }

    @ViewBuilder private var content: some View {
        ZStack(alignment: .topLeading) {
            ProtonColor.backgroundNorm.ignoresSafeArea()

            if let feed = model.thumbnailFeed, !model.items.isEmpty {
                UIKitTimelineGrid(
                    items: model.items,
                    thumbnailFeed: feed,
                    selectionMode: selectionMode,
                    selectedUIDs: selected,
                    isActive: isActive,
                    scrollToLatestSignal: scrollToLatestSignal,
                    onFirstContentReady: { withAnimation(.spring(duration: 0.55)) { model.markFirstContentReady() } },
                    onOpenPhoto: open,
                    onToggleSelection: toggleSelection,
                    onDragSelectionChanged: applyDragSelection
                )
                .ignoresSafeArea(edges: .bottom)
            }

            overlay
            savingOverlay
        }
    }

    /// Centered "Saving…" scrim while a save-to-Apple-Photos run is in flight, with an honest item count.
    @ViewBuilder private var savingOverlay: some View {
        if let progress = saveProgress {
            MobileSavingOverlay(progress: progress)
                .transition(.opacity)
        }
    }

    @ViewBuilder private var overlay: some View {
        if model.loadState.isLoading {
            MobileLibraryLoadingView(state: model.loadState)
                .transition(.opacity)
        } else if model.loadState.isEmpty {
            MobileEmptyLibraryView()
        } else if let failure = model.loadState.failure {
            MobileLibraryErrorView(message: failure.message, retryable: failure.retryable) {
                model.retry()
            }
        }
    }

    private func open(_ item: PhotoItem) {
        guard let index = model.index(of: item.uid) else { return }   // O(1), not an O(n) firstIndex scan
        viewer = MobileViewerPresentation(index: index, items: model.items)
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

    /// Commit the result of a finger-drag selection — called ONCE when the drag ends, so a drag never rebuilds
    /// the screen per frame (the grid host paints the in-progress selection itself).
    private func applyDragSelection(_ uids: Set<PhotoUID>) {
        selected = uids
    }

    private func startShare() {
        guard let backend = model.backend else { return }
        let chosen = model.selectedItems(selected)   // O(k log k) from the index, not an O(n) filter
        guard !chosen.isEmpty else { return }
        isExporting = true
        Task {
            let result = await MobileMediaExporter.exportOriginals(
                chosen, backend: backend, cache: model.originalsCache, cacheCapBytes: model.originalsCacheCapBytes
            )
            isExporting = false
            if result.urls.isEmpty {
                // Nothing could be prepared — surface the failure, never a silent no-op.
                actionError = MobileSelectionError(message: String(localized: "selection.share_failed"))
            } else if result.failed > 0 {
                // Some originals couldn't be downloaded — be honest about the partial share before proceeding,
                // rather than silently dropping them.
                partialShare = MobilePartialShare(urls: result.urls, failed: result.failed)
            } else {
                sharePayload = MobileSharePayload(urls: result.urls)
            }
        }
    }

    private func startSave() {
        guard let backend = model.backend else { return }
        let chosen = model.selectedItems(selected)   // O(k log k) from the index, not an O(n) filter
        guard !chosen.isEmpty else { return }
        saveProgress = MobileSaveProgress(completed: 0, total: chosen.count)
        Task {
            let prepared = await MobilePhotoLibrarySaver.prepare(
                backend: backend, cache: model.originalsCache, cacheCapBytes: model.originalsCacheCapBytes
            )
            guard case let .ready(session) = prepared else {
                saveProgress = nil
                // Denied/restricted Photos access — surface it, never a silent no-op.
                actionError = MobileSelectionError(message: String(localized: "selection.save_denied"))
                return
            }
            // The per-item loop runs on the main actor so the overlay count stays live; each item's
            // decrypt/download/PhotoKit write suspends off-main inside `session.save`.
            var tally = MobilePhotoLibrarySaver.Tally()
            for (offset, item) in chosen.enumerated() {
                tally.add(await session.save(item))
                saveProgress = MobileSaveProgress(completed: offset + 1, total: chosen.count)
            }
            session.cleanup()
            saveProgress = nil
            // Surface honestly: hard failures first, then a Live-Photo degrade note; full success is silent
            // (the overlay simply lifts).
            if tally.failed > 0 {
                actionError = MobileSelectionError(message: String(localized: "selection.save_failed \(tally.failed)"))
            } else if tally.livePhotoDegraded > 0 {
                actionError = MobileSelectionError(message: String(localized: "selection.save_live_degraded \(tally.livePhotoDegraded)"))
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
}

/// Identifiable payload for the viewer sheet — the full item list plus the tapped index, so the viewer can page.
struct MobileViewerPresentation: Identifiable {
    let id = UUID()
    let index: Int
    let items: [PhotoItem]
}

/// A localized, user-facing failure for a selection action (share/trash), surfaced honestly via an alert.
struct MobileSelectionError: Identifiable {
    let id = UUID()
    let message: String
}

/// A share where some originals could not be downloaded: the successfully-exported URLs plus how many were
/// dropped, so the user is told before the (partial) share proceeds.
struct MobilePartialShare: Identifiable {
    let id = UUID()
    let urls: [URL]
    let failed: Int
}

/// Progress of an in-flight save-to-Apple-Photos run, driving the centered overlay.
struct MobileSaveProgress: Equatable {
    var completed: Int
    var total: Int
}

/// Centered "Saving…" scrim shown while saving selected originals into Apple Photos. Mirrors the app's loading
/// HUD idiom (a large tinted `ProgressView` + label over an ultra-thin material) with an honest item count.
private struct MobileSavingOverlay: View {
    let progress: MobileSaveProgress

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
                .tint(ProtonColor.primary)
            Text(String(localized: "selection.saving"))
                .font(.headline)
                .foregroundStyle(ProtonColor.textNorm)
            if progress.total > 0 {
                Text(String(localized: "selection.saving_progress \(progress.completed) \(progress.total)"))
                    .font(.subheadline)
                    .foregroundStyle(ProtonColor.textWeak)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Rectangle().fill(.ultraThinMaterial).ignoresSafeArea() }
        .accessibilityElement(children: .combine)
    }
}
