import DesignSystemCore
import PhotosCore
import SwiftUI
import TimelineUIKitFeature

/// The "All Photos" tab. The Metal grid mounts as soon as items + feed exist (even while loading) so it can
/// report first content; the loading/empty/error overlay sits on top and lifts only when the shared
/// `LibraryLoadState` says the grid is presentable — so the user never sees a blank grid first. While the
/// background crawl keeps filling the library after that, a small activity indicator sits on the nav-bar row.
///
/// A top-right "Select" button enters selection mode: tapping cells toggles them (blue check overlay), and a
/// native bottom action bar offers Share (native sheet over exported originals) and Move to Trash (real,
/// recoverable, confirmed) — both wired to shared backend capabilities, never faked.
struct MobileTimelineScreen: View {
    @EnvironmentObject private var model: MobileLibraryModel
    @State private var viewer: MobileViewerPresentation?
    @State private var selectionMode = false
    @State private var selected: Set<PhotoUID> = []
    @State private var sharePayload: MobileSharePayload?
    @State private var partialShare: MobilePartialShare?
    @State private var isExporting = false
    @State private var showTrashConfirm = false
    @State private var actionError: MobileSelectionError?

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
        // The background-crawl indicator lives on the nav-bar row, aligned top-left with the "Photos" title.
        if model.loadState.isContentReady, model.isBackgroundLoading, !selectionMode {
            ToolbarItem(placement: .topBarLeading) {
                ProgressView()
                    .controlSize(.small)
                    .tint(ProtonColor.primary)
                    .accessibilityLabel(String(localized: "loading.background_a11y"))
            }
        }
        if canSelect {
            ToolbarItem(placement: .topBarTrailing) {
                Button(selectionMode ? String(localized: "action.done") : String(localized: "action.select")) {
                    toggleSelectionMode()
                }
            }
        }
        // The library count sits on the right only while browsing (selection shows its own count in the bottom bar).
        if !selectionMode, let count = model.loadState.knownCount, count > 0 {
            ToolbarItem(placement: .topBarTrailing) {
                Text("\(count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(ProtonColor.textHint)
            }
        }
        if selectionMode {
            ToolbarItemGroup(placement: .bottomBar) { selectionActions }
        }
    }

    @ViewBuilder private var selectionActions: some View {
        Button {
            startShare()
        } label: {
            if isExporting {
                ProgressView()
            } else {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .disabled(selected.isEmpty || isExporting)
        .accessibilityLabel(String(localized: "selection.share_a11y"))

        Spacer()

        Text(selectionCountLabel)
            .font(.body)
            .foregroundStyle(ProtonColor.textNorm)
            .monospacedDigit()

        Spacer()

        Button(role: .destructive) {
            showTrashConfirm = true
        } label: {
            Image(systemName: "trash")
        }
        .disabled(selected.isEmpty || isExporting)
        .accessibilityLabel(String(localized: "selection.trash_a11y"))
    }

    private var selectionCountLabel: String {
        selected.isEmpty
            ? String(localized: "selection.select_items")
            : String(localized: "selection.count_selected \(selected.count)")
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
                    onFirstContentReady: { withAnimation(.spring(duration: 0.55)) { model.markFirstContentReady() } },
                    onOpenPhoto: open,
                    onToggleSelection: toggleSelection
                )
                .ignoresSafeArea(edges: .bottom)
            }

            overlay
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
        guard let index = model.items.firstIndex(of: item) else { return }
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

    private func startShare() {
        guard let backend = model.backend else { return }
        let chosen = model.items.filter { selected.contains($0.uid) }
        guard !chosen.isEmpty else { return }
        isExporting = true
        Task {
            let result = await MobileMediaExporter.exportOriginals(chosen, backend: backend)
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
