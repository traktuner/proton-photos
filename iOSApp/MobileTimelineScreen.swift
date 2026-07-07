import DesignSystemCore
import GridCore
import PhotosCore
import SwiftUI
import TimelineUIKitFeature
import UIKit

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
    @Environment(MobileViewerRouter.self) private var viewerRouter
    @State private var selectionMode = false
    @State private var selected: Set<PhotoUID> = []
    @State private var sharePayload: MobileSharePayload?
    @State private var partialShare: MobilePartialShare?
    @State private var isExporting = false
    @State private var showTrashConfirm = false
    @State private var actionError: MobileSelectionError?
    @State private var networkMonitor = NetworkMonitor.shared
    /// Frosted-bar height, read from the key window ONCE (init + onAppear) and cached - never read live
    /// during body evaluation, which cycles the layout under the safe-area-ignoring overlay.
    @State private var topFrostHeight: CGFloat = mobileTopBarFrostHeightDefault

    /// True while any selection action is running, so the other toolbar buttons disable together.
    private var selectionBusy: Bool { isExporting }

    private var canSelect: Bool { model.loadState.isContentReady && !model.items.isEmpty }
    private var titleActivityActive: Bool { model.loadState.isLoading || model.isBackgroundLoading }
    private var titleStatus: LibraryTitleStatus {
        if !networkMonitor.isOnline { return .offline }
        if networkMonitor.didRecentlyRestoreConnection { return .onlineRestored }
        return titleActivityActive ? .activity : .idle
    }
    private var titleStatusAccessibilityLabel: String {
        switch titleStatus {
        case .idle:
            ""
        case .activity:
            String(localized: "library.title_activity")
        case .offline:
            String(localized: "library.title_offline")
        case .onlineRestored:
            String(localized: "library.title_online_restored")
        }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "tab.photos"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .toolbar(selectionMode ? .hidden : .automatic, for: .tabBar)
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
        ToolbarItem(placement: .principal) {
            LibraryTitleStatusLabel(
                title: String(localized: "tab.photos"),
                status: titleStatus,
                accessibilityLabel: titleStatusAccessibilityLabel
            )
        }
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
                // Full-bleed under the inline nav bar so the native iOS 26 Liquid Glass bar floats over
                // the scrolling thumbnails (the grid host already insets its content by safeAreaInsets.top
                // so the first row still rests below the bar). Matches the map and the macOS grid.
                .ignoresSafeArea()
            }

            overlay
        }
        .overlay(alignment: .top) { TopFrostBar(height: topFrostHeight) }
        .onAppear { topFrostHeight = mobileTopBarFrostHeight() }
    }

    @ViewBuilder private var overlay: some View {
        if !networkMonitor.isOnline && model.items.isEmpty && (model.loadState.isLoading || model.loadState.failure != nil) {
            OfflineContentUnavailableView()
        } else if model.loadState.isLoading {
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

    /// Commit the result of a finger-drag selection - called ONCE when the drag ends, so a drag never rebuilds
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
                // Nothing could be prepared - surface the failure, never a silent no-op.
                actionError = MobileSelectionError(message: String(localized: "selection.share_failed"))
            } else if result.failed > 0 {
                // Some originals couldn't be downloaded - be honest about the partial share before proceeding,
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

/// Identifiable payload for the viewer sheet - the full item list plus the tapped index, so the viewer can page.
struct MobileViewerPresentation: Identifiable {
    let id = UUID()
    let index: Int
    let items: [PhotoItem]
}

/// App-wide viewer presentation state, owned ABOVE the size-class-adaptive shell. The shell swaps its whole
/// subtree when `horizontalSizeClass` flips (TabView ↔ NavigationSplitView) - e.g. simply ROTATING a
/// Max-size iPhone (portrait compact → landscape regular) - which destroys every screen's `@State`, so a
/// viewer presented from screen-local state was dismissed by the rotation itself. Screens write
/// `presentation`; the single `fullScreenCover` lives in `MobileMainTabView`, OUTSIDE the swap, so the open
/// viewer survives rotation and just re-lays-out.
@MainActor @Observable final class MobileViewerRouter {
    var presentation: MobileViewerPresentation?
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

/// A frosted-glass strip pinned behind the (inline) navigation bar.
///
/// Height of the frosted top bar on iOS: the status-bar / Dynamic Island inset (from the key window) plus
/// the standard inline navigation-bar height, so the shared `TopFrostBar` reliably covers the title area on
/// every device without depending on a SwiftUI geometry read that a full-bleed, safe-area-ignoring parent
/// would report as zero. (macOS passes its own toolbar inset; only the height source is per-platform.)
/// Constant `@State` seed. The real safe-area height is read from the key window in `.onAppear`;
/// doing that during view initialization can trigger a SwiftUI layout cycle under full-bleed overlays.
/// 91 = 47 (typical status bar) + 44 (navigation bar), matching `mobileTopBarFrostHeight()`'s fallback.
let mobileTopBarFrostHeightDefault: CGFloat = 91

func mobileTopBarFrostHeight() -> CGFloat {
    let topSafeArea = UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows)
        .first(where: \.isKeyWindow)?
        .safeAreaInsets.top ?? 47
    return topSafeArea + 44
}
