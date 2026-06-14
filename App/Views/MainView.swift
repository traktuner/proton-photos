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
    private let feed: ThumbnailFeed

    init(model: AppModel, backend: any PhotosBackend) {
        self.model = model
        self.backend = backend
        let feed = ThumbnailFeed(cache: ThumbnailCache(), loader: backend)
        self.feed = feed
        _timelineModel = State(initialValue: TimelineViewModel(repository: backend, feed: feed))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(ProtonColor.borderWeak)
            TimelineView(model: timelineModel) { item, items in
                let index = items.firstIndex(of: item) ?? 0
                viewerModel = PhotoViewerModel(items: items, index: index, feed: feed, media: backend)
            }
        }
        .background(ProtonColor.backgroundNorm)
        .overlay {
            if let viewerModel {
                PhotoViewerView(model: viewerModel) { self.viewerModel = nil }
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: viewerModel == nil)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Library")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(ProtonColor.textNorm)
            Spacer()
            Menu {
                Button("Sign out", role: .destructive) { model.signOut() }
            } label: {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(ProtonColor.textWeak)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }
}
