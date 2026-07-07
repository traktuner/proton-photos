import DesignSystemCore
import PhotosCore
import SwiftUI
import TimelineUIKitFeature

/// The Collections tab: a generic, extensible hub over the shared `PhotoFilter` routes. It lists the
/// smart-filter categories that are backed by REAL backend capabilities (Favorites, Videos, Live Photos -
/// server-side `PhotoTag` filters), the user's Albums (`PhotoLibraryProvider.albums()`), and Trash - each
/// opening the same shared timeline grid filtered to that route. Adding a category is a new row, not a new
/// screen: everything flows through `PhotoFilter` + `backend.timeline(filter:)`.
///
/// Album CREATE / add-to-album are deliberately absent: the backend does not support them yet
/// (`AlbumCapabilities.canCreate/canAddPhotos == false`), so no affordance is shown that would fail.
struct MobileCollectionsScreen: View {
    /// `@Environment` over the `@Observable` model: Collections reads only `backend`/`thumbnailFeed`, so a
    /// timeline snapshot change no longer re-renders this list.
    @Environment(MobileLibraryModel.self) private var model
    @State private var albums: [PhotoAlbum] = []
    @State private var albumsPhase: Phase = .loading

    private enum Phase: Equatable { case loading, loaded, failed(String) }
    private struct AlbumsReloadKey: Equatable {
        var backendReady: Bool
        var revision: Int
    }

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
            .navigationBarTitleDisplayMode(.inline)
            .task(id: AlbumsReloadKey(backendReady: model.backend != nil, revision: model.albumCatalogRevision)) {
                await loadAlbums()
            }
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
                Text("collections.empty_albums \(ProductBrand.displayName)").foregroundStyle(ProtonColor.textWeak)
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
/// tap-to-open viewer as the main timeline. One screen serves every collection - the route is the only input.
private struct MobileFilterGridScreen: View {
    @Environment(MobileLibraryModel.self) private var model
    let title: String
    let filter: PhotoFilter

    @Environment(MobileViewerRouter.self) private var viewerRouter
    @State private var snapshot = TimelineSnapshot()
    @State private var phase: Phase = .loading
    @State private var confirmEmptyTrash = false
    @State private var actionError: String?

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
                if snapshot.isEmpty {
                    ContentUnavailableView(String(localized: "collections.filter_empty"), systemImage: "photo.on.rectangle")
                } else if let feed = model.thumbnailFeed {
                    UIKitTimelineGrid(items: snapshot.items, thumbnailFeed: feed, fillOrder: .topLeading, onOpenPhoto: open)
                        .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if filter == .trash {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(role: .destructive) {
                        confirmEmptyTrash = true
                    } label: {
                        Image(systemName: "trash.slash")
                    }
                    .disabled(snapshot.isEmpty || phase != .loaded)
                    .accessibilityLabel(String(localized: "trash.empty_button"))
                }
            }
        }
        .confirmationDialog(String(localized: "trash.empty_title"), isPresented: $confirmEmptyTrash) {
            Button(String(localized: "trash.empty_confirm"), role: .destructive) {
                Task { await emptyTrash() }
            }
            Button(String(localized: "action.cancel"), role: .cancel) {}
        } message: {
            Text(String(localized: "trash.empty_message"))
        }
        .alert(String(localized: "trash.empty_failed_title"), isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        )) {
            Button(String(localized: "action.ok"), role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .task(id: filter) { await load() }
    }

    private func load() async {
        guard let backend = model.backend, filter.hasTimeline else { return }
        phase = .loading
        do {
            let sections = try await backend.timeline(filter: filter)
            // Flatten + sort OFF the main actor, exactly like the main timeline, so opening a large album
            // never hitches the push transition.
            let prepared = await Task.detached(priority: .userInitiated) {
                TimelineSnapshot(sections: sections)
            }.value
            guard !Task.isCancelled else { return }
            snapshot = prepared
            phase = .loaded
        } catch {
            phase = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    private func open(_ item: PhotoItem) {
        guard let index = snapshot.index(of: item.uid) else { return }   // O(1)
        viewerRouter.presentation = MobileViewerPresentation(index: index, items: snapshot.items)
    }

    @MainActor private func emptyTrash() async {
        guard filter == .trash, !snapshot.isEmpty else { return }
        do {
            try await model.emptyTrash()
            snapshot = TimelineSnapshot()
            phase = .loaded
        } catch {
            actionError = String(localized: "trash.empty_failed_message")
        }
    }
}
