import DesignSystemCore
import PhotosCore
import SwiftUI
import TimelineUIKitFeature

/// Albums tab. Always visible with a polished empty state; when albums exist it lists them and opens a detail
/// grid. Album data comes from the shared backend (`PhotoLibraryProvider.albums()` / `timeline(filter:)`).
struct MobileAlbumsScreen: View {
    @EnvironmentObject private var model: MobileLibraryModel
    @State private var albums: [PhotoAlbum] = []
    @State private var phase: Phase = .loading

    private enum Phase: Equatable { case loading, loaded, failed(String) }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Albums")
                .task(id: model.backend == nil) { await load() }
                .refreshable { await load() }
        }
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading where albums.isEmpty:
            ProgressView().controlSize(.large).tint(ProtonColor.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message) where albums.isEmpty:
            ContentUnavailableView {
                Label("Couldn't load albums", systemImage: "exclamationmark.icloud")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
                    .tint(ProtonColor.primary)
            }
        default:
            if albums.isEmpty {
                ContentUnavailableView {
                    Label("No albums", systemImage: "rectangle.stack")
                } description: {
                    Text("Albums you create in Proton Photos will appear here.")
                }
            } else {
                List(albums) { album in
                    NavigationLink {
                        MobileAlbumDetailScreen(album: album)
                    } label: {
                        MobileAlbumRow(album: album)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        if albums.isEmpty { phase = .loading }
        do {
            albums = try await backend.albums()
            phase = .loaded
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

private struct MobileAlbumRow: View {
    let album: PhotoAlbum

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "rectangle.stack.fill")
                .font(.title3)
                .foregroundStyle(ProtonColor.primary)
                .frame(width: 44, height: 44)
                .background(ProtonColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ProtonColor.textNorm)
                Text("^[\(album.photoCount) photo](inflect: true)")
                    .font(.caption)
                    .foregroundStyle(ProtonColor.textWeak)
            }
        }
        .padding(.vertical, 4)
    }
}

/// Album detail — the shared timeline grid, filtered to the album, with the same tap-to-open viewer.
private struct MobileAlbumDetailScreen: View {
    @EnvironmentObject private var model: MobileLibraryModel
    let album: PhotoAlbum

    @State private var items: [PhotoItem] = []
    @State private var phase: Phase = .loading
    @State private var viewer: MobileViewerPresentation?

    private enum Phase: Equatable { case loading, loaded, failed(String) }

    var body: some View {
        ZStack {
            ProtonColor.backgroundNorm.ignoresSafeArea()

            switch phase {
            case .loading:
                ProgressView().controlSize(.large).tint(ProtonColor.primary)
            case .failed(let message):
                ContentUnavailableView("Couldn't load album", systemImage: "exclamationmark.icloud", description: Text(message))
            case .loaded:
                if items.isEmpty {
                    ContentUnavailableView("Empty album", systemImage: "rectangle.stack")
                } else if let feed = model.thumbnailFeed {
                    UIKitTimelineGrid(items: items, thumbnailFeed: feed, onOpenPhoto: open)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .navigationTitle(album.title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: album.id) { await load() }
        .fullScreenCover(item: $viewer) { presentation in
            MobilePhotoViewer(items: presentation.items, startIndex: presentation.index, libraryModel: model)
        }
    }

    private func load() async {
        guard let backend = model.backend else { return }
        phase = .loading
        do {
            let sections = try await backend.timeline(filter: .album(id: album.id, title: album.title))
            items = sections.flatMap(\.items).sorted(by: TimelineOrder.areInIncreasingOrder)
            phase = .loaded
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func open(_ item: PhotoItem) {
        guard let index = items.firstIndex(of: item) else { return }
        viewer = MobileViewerPresentation(index: index, items: items)
    }
}
