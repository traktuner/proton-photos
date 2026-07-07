import AlbumSyncCore
import PhotoLibraryBackupAdapter
import PhotosCore
import SwiftUI

/// Local-album → Proton-album sync over the SHARED cross-platform controller (same engine and
/// wording as macOS Settings > Backup). The screen shows ONLY the albums the user selected in the
/// picker sheet; removing a row stops syncing that album without touching Proton (the mapping
/// stays, so re-selecting reuses the same remote album).
struct MobileAlbumSyncScreen: View {
    @State var controller: AlbumSyncController
    @State private var showPicker = false

    var body: some View {
        List {
            if !controller.isAvailable {
                Text(String(localized: "settings.albumsync_unavailable"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                selectedSection
                if controller.isSyncing {
                    progressSection
                }
                if let message = controller.lastMessage {
                    Section {
                        Text(message)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle(String(localized: "settings.albumsync_title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showPicker = true
                } label: {
                    Label(String(localized: "settings.albumsync_add_albums"), systemImage: "plus")
                }
                .disabled(!controller.isAvailable)
            }
        }
        .sheet(isPresented: $showPicker) {
            MobileAlbumPickerSheet(controller: controller)
        }
        .confirmationDialog(
            String(localized: "settings.albumsync_conflict_title"),
            isPresented: conflictPresented,
            titleVisibility: .visible
        ) {
            if let conflict = controller.pendingConflict, conflict.existing.count == 1,
               let existing = conflict.existing.first {
                Button(String(localized: "settings.albumsync_use_existing")) {
                    controller.resolveConflict(useExisting: existing.id)
                }
            }
            Button(String(localized: "action.cancel"), role: .cancel) {
                controller.resolveConflict(useExisting: nil)
            }
        } message: {
            if let conflict = controller.pendingConflict {
                if conflict.existing.count > 1 {
                    Text(String(localized: "settings.albumsync_conflict_multiple"))
                } else {
                    Text(String(localized: "settings.albumsync_conflict_message \(conflict.album.title)"))
                }
            }
        }
    }

    // MARK: - Selected albums

    @ViewBuilder private var selectedSection: some View {
        Section {
            if controller.selectedAlbums.isEmpty {
                Button {
                    showPicker = true
                } label: {
                    Label(String(localized: "settings.albumsync_add_albums"), systemImage: "plus")
                }
            }
            ForEach(controller.selectedAlbums) { album in
                selectedRow(album)
            }
            if !controller.selectedAlbums.isEmpty {
                if controller.isSyncing {
                    Button(String(localized: "settings.albumsync_stop"), role: .destructive) {
                        controller.stopSync()
                    }
                } else {
                    Button(String(localized: "settings.albumsync_sync_all")) {
                        controller.syncSelected()
                    }
                }
            }
        } footer: {
            Text(String(localized: "settings.albumsync_explainer"))
        }
    }

    @ViewBuilder
    private func selectedRow(_ album: AlbumSyncController.SelectedAlbum) -> some View {
        let isActive = controller.isSyncing && controller.progress.localAlbumID == album.id
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let count = album.assetCount {
                        Text(String(localized: "settings.albumsync_photo_count \(count)"))
                    }
                    Text(isActive ? controller.progress.localizedTitle : album.localizedRowStatusDescription)
                        .foregroundStyle(stateColor(album, isActive: isActive))
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                ProgressView()
            } else if album.state == .needsDecision {
                Button(String(localized: "settings.albumsync_decide")) {
                    controller.presentConflict(albumID: album.id)
                }
                .buttonStyle(.borderless)
            } else {
                Button {
                    controller.removeFromSelection(album.id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(String(localized: "settings.albumsync_remove")))
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                controller.removeFromSelection(album.id)
            } label: {
                Label(String(localized: "settings.albumsync_remove"), systemImage: "xmark.circle")
            }
            .disabled(isActive)
        }
    }

    private func stateColor(_ album: AlbumSyncController.SelectedAlbum, isActive: Bool) -> Color {
        if isActive { return .secondary }
        if album.hasNeedsAttention { return .orange }
        switch album.state {
        case .missingLocally, .needsDecision: return .orange
        case .notSynced, .synced: return .secondary
        }
    }

    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(controller.progress.albumTitle)
                        .font(.footnote.weight(.medium))
                        .lineLimit(1)
                    Text(controller.progress.localizedTitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let detail = controller.progress.localizedDetail {
                    Text(detail)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ProgressView()
            }
        }
    }

    private var conflictPresented: Binding<Bool> {
        Binding(
            get: { controller.pendingConflict != nil },
            set: { presented in
                if !presented, controller.pendingConflict != nil {
                    controller.resolveConflict(useExisting: nil)
                }
            }
        )
    }
}

/// The album picker: every local album, searchable, multi-select with checkmarks. Confirming
/// applies the FULL selection (checked = synced), so adding and removing are both one visit.
/// Opening this sheet is the explicit user action that may trigger the photo-access prompt.
private struct MobileAlbumPickerSheet: View {
    @State var controller: AlbumSyncController
    @Environment(\.dismiss) private var dismiss

    @State private var draft: Set<String> = []
    @State private var searchText = ""
    @State private var didLoad = false

    private var filteredAlbums: [LocalAlbumSummary] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return controller.availableAlbums }
        return controller.availableAlbums.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if controller.isLoadingAlbums && !didLoad {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if controller.accessState == .denied || controller.accessState == .restricted {
                    ContentUnavailableView(
                        String(localized: "settings.photos_backup_denied"),
                        systemImage: "lock.rectangle.stack"
                    )
                } else if filteredAlbums.isEmpty {
                    ContentUnavailableView(
                        String(localized: "settings.albumsync_picker_empty"),
                        systemImage: "rectangle.stack"
                    )
                } else {
                    List(filteredAlbums) { album in
                        Button {
                            toggle(album.id)
                        } label: {
                            HStack {
                                Image(systemName: draft.contains(album.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(draft.contains(album.id) ? Color.accentColor : Color.secondary)
                                    .imageScale(.large)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(album.title)
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(String(localized: "settings.albumsync_photo_count \(album.assetCount)"))
                                        .font(.footnote.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(String(localized: "settings.albumsync_picker_title"))
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: String(localized: "settings.albumsync_picker_search"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "action.cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "settings.albumsync_picker_apply")) {
                        controller.applySelection(draft)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
                ToolbarItem(placement: .status) {
                    Text(String(localized: "settings.albumsync_picker_selected \(draft.count)"))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()   // the .status pill constrains width; keep the full text ("3 Alben"), not "3 Al…"
                }
            }
        }
        .task {
            await controller.loadAvailableAlbums()
            if !didLoad {
                draft = controller.selectedAlbumIDs
                didLoad = true
            }
        }
    }

    private func toggle(_ id: String) {
        if draft.contains(id) { draft.remove(id) } else { draft.insert(id) }
    }
}
