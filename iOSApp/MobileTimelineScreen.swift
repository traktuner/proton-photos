import DesignSystemCore
import PhotosCore
import SwiftUI
import TimelineUIKitFeature

/// The "All Photos" tab. The Metal grid mounts as soon as items + feed exist (even while loading) so it can
/// report first content; the loading/empty/error overlay sits on top and lifts only when the shared
/// `LibraryLoadState` says the grid is presentable — so the user never sees a blank grid first.
struct MobileTimelineScreen: View {
    @EnvironmentObject private var model: MobileLibraryModel
    @State private var viewer: MobileViewerPresentation?

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Photos")
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
        ZStack {
            ProtonColor.backgroundNorm.ignoresSafeArea()

            if let feed = model.thumbnailFeed, !model.items.isEmpty {
                UIKitTimelineGrid(
                    items: model.items,
                    thumbnailFeed: feed,
                    onFirstContentReady: { model.markFirstContentReady() },
                    onOpenPhoto: open
                )
                .ignoresSafeArea(edges: .bottom)
            }

            overlay
        }
    }

    @ViewBuilder private var overlay: some View {
        if model.loadState.isLoading {
            MobileLibraryLoadingView(state: model.loadState)
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

/// Identifiable payload for the viewer sheet — the full item list plus the tapped index, so the viewer can page.
struct MobileViewerPresentation: Identifiable {
    let id = UUID()
    let index: Int
    let items: [PhotoItem]
}
