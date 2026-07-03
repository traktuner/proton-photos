import DesignSystemCore
import PhotosCore
import SwiftUI
import TimelineUIKitFeature

/// The "All Photos" tab. The Metal grid mounts as soon as items + feed exist (even while loading) so it can
/// report first content; the loading/empty/error overlay sits on top and lifts only when the shared
/// `LibraryLoadState` says the grid is presentable — so the user never sees a blank grid first. While the
/// background crawl keeps filling the library after that, the loading spinner flies to the top-left and
/// stays there as a small persistent indicator.
struct MobileTimelineScreen: View {
    @EnvironmentObject private var model: MobileLibraryModel
    @State private var viewer: MobileViewerPresentation?
    @Namespace private var loadingIndicatorNamespace

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(String(localized: "tab.photos"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    if let count = model.loadState.knownCount, count > 0 {
                        ToolbarItem(placement: .topBarTrailing) {
                            Text("\(count)")
                                .font(.footnote.monospacedDigit())
                                .foregroundStyle(ProtonColor.textHint)
                        }
                    }
                }
        }
        .fullScreenCover(item: $viewer) { presentation in
            MobilePhotoViewer(
                items: presentation.items,
                startIndex: presentation.index,
                libraryModel: model
            )
        }
    }

    @ViewBuilder private var content: some View {
        ZStack(alignment: .topLeading) {
            ProtonColor.backgroundNorm.ignoresSafeArea()

            if let feed = model.thumbnailFeed, !model.items.isEmpty {
                UIKitTimelineGrid(
                    items: model.items,
                    thumbnailFeed: feed,
                    onFirstContentReady: { withAnimation(.spring(duration: 0.55)) { model.markFirstContentReady() } },
                    onOpenPhoto: open
                )
                .ignoresSafeArea(edges: .bottom)
            }

            overlay

            if model.loadState.isContentReady, model.isBackgroundLoading {
                MobileBackgroundLoadingIndicator(namespace: loadingIndicatorNamespace)
                    .transition(.opacity)
            }
        }
        .animation(.spring(duration: 0.55), value: model.isBackgroundLoading)
    }

    @ViewBuilder private var overlay: some View {
        if model.loadState.isLoading {
            MobileLibraryLoadingView(state: model.loadState, spinnerNamespace: loadingIndicatorNamespace)
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
}

/// The small persistent top-left activity chip shown while the background crawl is still filling the
/// library. Shares its geometry id with the full-screen loading spinner, so lifting the overlay reads as
/// the spinner flying into the corner.
private struct MobileBackgroundLoadingIndicator: View {
    let namespace: Namespace.ID

    var body: some View {
        ProgressView()
            .controlSize(.small)
            .tint(ProtonColor.primary)
            .matchedGeometryEffect(id: MobileLibraryLoadingView.spinnerGeometryID, in: namespace)
            .padding(10)
            .background(.ultraThinMaterial, in: Circle())
            .padding(.top, 10)
            .padding(.leading, 14)
            .accessibilityLabel(String(localized: "loading.background_a11y"))
    }
}

/// Identifiable payload for the viewer sheet — the full item list plus the tapped index, so the viewer can page.
struct MobileViewerPresentation: Identifiable {
    let id = UUID()
    let index: Int
    let items: [PhotoItem]
}
