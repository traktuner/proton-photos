import SwiftUI
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
    @State private var cellZoom: CGFloat = 1
    private let feed: ThumbnailFeed

    init(model: AppModel, backend: any PhotosBackend) {
        self.model = model
        self.backend = backend
        let feed = ThumbnailFeed(cache: ThumbnailCache(), loader: backend)
        self.feed = feed
        _timelineModel = State(initialValue: TimelineViewModel(repository: backend, feed: feed))
    }

    var body: some View {
        NavigationStack {
            TimelineView(model: timelineModel, cellZoom: $cellZoom) { item, items in
                let index = items.firstIndex(of: item) ?? 0
                viewerModel = PhotoViewerModel(items: items, index: index, feed: feed, media: backend)
            }
            .ignoresSafeArea(edges: .top)
            .navigationTitle("Library")
            .toolbar { toolbarContent }
        }
        .overlay {
            if let viewerModel {
                PhotoViewerView(model: viewerModel) { self.viewerModel = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewerModel == nil)
    }

    @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { adjustZoom(0.8) } label: { Image(systemName: "minus") }
                .help("Smaller thumbnails")
            Button { adjustZoom(1.25) } label: { Image(systemName: "plus") }
                .help("Larger thumbnails")
            Menu {
                Button("Sign out", role: .destructive) { model.signOut() }
            } label: {
                Image(systemName: "person.crop.circle")
            }
        }
    }

    private func adjustZoom(_ factor: CGFloat) {
        withAnimation(.smooth(duration: 0.3)) {
            cellZoom = min(max(cellZoom * factor, 0.55), 2.4)
        }
    }
}
