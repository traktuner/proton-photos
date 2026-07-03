import DesignSystemCore
import PhotosCore
import SwiftUI
import TimelineUIKitFeature

/// The Collections tab: a generic, extensible hub over the shared `PhotoFilter` routes. It lists the
/// smart-filter categories that are backed by REAL backend capabilities (Favorites, Videos, Live Photos —
/// server-side `PhotoTag` filters), the user's Albums (`PhotoLibraryProvider.albums()`), and Trash — each
/// opening the same shared timeline grid filtered to that route. Adding a category is a new row, not a new
/// screen: everything flows through `PhotoFilter` + `backend.timeline(filter:)`.
///
/// Album CREATE / add-to-album are deliberately absent: the backend does not support them yet
/// (`AlbumCapabilities.canCreate/canAddPhotos == false`), so no affordance is shown that would fail.
struct MobileCollectionsScreen: View {
    @EnvironmentObject private var model: MobileLibraryModel
    @State private var albums: [PhotoAlbum] = []
    @State private var albumsPhase: Phase = .loading

    private enum Phase: Equatable { case loading, loaded, failed(String) }

    /// Smart categories backed by real, present capabilities in this repo (server-side `PhotoTag` filters). The
    /// titles + icons come from the shared `PhotoTag` (already localized), so no per-category strings live here.
    private let smartCategories: [PhotoTag] = [.favorites, .videos, .livePhotos]

    var body: some View {
        NavigationStack {
            List {
                Section(String(localized: "collections.section_library")) {
                    ForEach(smartCategories, id: \.rawValue) { tag in
                        NavigationLink {
                            MobileFilterGridScreen(title: tag.title, filter: .tag(tag))
                        } label: {
                            MobileCollectionRow(systemImage: tag.systemImage, title: tag.title)
                        }
                    }
                    NavigationLink {
                        MobileFilterGridScreen(title: String(localized: "collections.trash"), filter: .trash)
                    } label: {
                        MobileCollectionRow(systemImage: "trash", title: String(localized: "collections.trash"))
                    }
                }

                Section(String(localized: "collections.section_albums")) {
                    albumsSection
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(String(localized: "tab.collections"))
            .task(id: model.backend == nil) { await loadAlbums() }
            .refreshable { await loadAlbums() }
        }
    }

    @ViewBuilder private var albumsSection: some View {
        switch albumsPhase {
        case .loading where albums.isEmpty:
            HStack {
                ProgressView().controlSize(.small).tint(ProtonColor.primary)
                Text("collections.loading_albums").foregroundStyle(ProtonColor.textWeak)
            }
        case .failed(let message) where albums.isEmpty:
            VStack(alignment: .leading, spacing: 6) {
                Text("albums.load_failed").foregroundStyle(ProtonColor.textNorm)
                Text(message).font(.caption).foregroundStyle(ProtonColor.textWeak)
                Button(String(localized: "action.try_again")) { Task { await loadAlbums() } }
                    .font(.caption)
            }
        default:
            if albums.isEmpty {
                Text("collections.empty_albums").foregroundStyle(ProtonColor.textWeak)
            } else {
                ForEach(albums) { album in
                    NavigationLink {
                        MobileFilterGridScreen(title: album.title, filter: .album(id: album.id, title: album.title))
                    } label: {
                        MobileAlbumRow(album: album)
                    }
                }
            }
        }
    }

    private func loadAlbums() async {
        guard let backend = model.backend else { return }
        if albums.isEmpty { albumsPhase = .loading }
        do {
            albums = try await backend.albums()
            albumsPhase = .loaded
        } catch {
            albumsPhase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}

private struct MobileCollectionRow: View {
    let systemImage: String
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(ProtonColor.primary)
                .frame(width: 44, height: 44)
                .background(ProtonColor.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(ProtonColor.textNorm)
        }
        .padding(.vertical, 4)
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
                Text("albums.photo_count \(album.photoCount)")
                    .font(.caption)
                    .foregroundStyle(ProtonColor.textWeak)
            }
        }
        .padding(.vertical, 4)
    }
}

/// The shared timeline grid, filtered to ANY `PhotoFilter` route (smart tag, album, or trash), with the same
/// tap-to-open viewer as the main timeline. One screen serves every collection — the route is the only input.
private struct MobileFilterGridScreen: View {
    @EnvironmentObject private var model: MobileLibraryModel
    let title: String
    let filter: PhotoFilter

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
                ContentUnavailableView(
                    String(localized: "albums.detail_load_failed"),
                    systemImage: "exclamationmark.icloud",
                    description: Text(message)
                )
            case .loaded:
                if items.isEmpty {
                    ContentUnavailableView(String(localized: "collections.filter_empty"), systemImage: "photo.on.rectangle")
                } else if let feed = model.thumbnailFeed {
                    UIKitTimelineGrid(items: items, thumbnailFeed: feed, onOpenPhoto: open)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: filter) { await load() }
        .fullScreenCover(item: $viewer) { presentation in
            MobilePhotoViewer(items: presentation.items, startIndex: presentation.index, libraryModel: model)
        }
    }

    private func load() async {
        guard let backend = model.backend, filter.hasTimeline else { return }
        phase = .loading
        do {
            let sections = try await backend.timeline(filter: filter)
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
