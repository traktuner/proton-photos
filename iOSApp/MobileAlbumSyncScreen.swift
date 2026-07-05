import AlbumSyncCore
import PhotoLibraryBackupAdapter
import PhotosCore
import SwiftUI

/// Local-album → Proton-album sync over the SHARED cross-platform controller (same engine and
/// wording as macOS Settings > Backup). Presentation only: album list, per-album sync state from
/// the persisted mapping, honest phase wording, and the same-name conflict resolved by the user.
struct MobileAlbumSyncScreen: View {
    @State var controller: AlbumSyncController

    var body: some View {
        List {
            if !controller.isAvailable {
                Text(String(localized: "settings.albumsync_unavailable"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                albumsSection
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
        // Opening this screen is the explicit user action that may trigger the photo-access prompt.
        .task { await controller.refreshAlbums() }
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
            if let conflict = controller.pendingConflict, conflict.existing.count > 1 {
                Text(String(localized: "settings.albumsync_conflict_multiple"))
            } else {
                Text(String(localized: "settings.albumsync_conflict_message"))
            }
        }
    }

    @ViewBuilder private var albumsSection: some View {
        Section {
            if controller.accessState == .denied || controller.accessState == .restricted {
                Text(String(localized: "settings.photos_backup_denied"))
                    .font(.footnote)
                    .foregroundStyle(.orange)
            } else if controller.localAlbums.isEmpty {
                Text(String(localized: "settings.albumsync_no_albums"))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(controller.localAlbums) { album in
                albumRow(album)
            }
        } footer: {
            Text(String(localized: "settings.albumsync_explainer"))
        }
    }

    private func albumRow(_ album: LocalAlbumSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(String(localized: "settings.albumsync_photo_count \(album.assetCount)"))
                    if let synced = controller.mapping(for: album)?.lastSyncedAt {
                        Text(String(localized: "settings.albumsync_last_synced \(synced.formatted(.relative(presentation: .named)))"))
                    }
                }
                .font(.footnote.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
            if controller.isSyncing, controller.progress.localAlbumID == album.id {
                Button(String(localized: "settings.albumsync_stop")) { controller.stopSync() }
                    .buttonStyle(.borderless)
            } else {
                Button(String(localized: "settings.albumsync_sync")) { controller.startSync(album: album) }
                    .buttonStyle(.borderless)
                    .disabled(controller.isSyncing)
            }
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
