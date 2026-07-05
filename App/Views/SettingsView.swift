import SwiftUI
import Combine
import AlbumSyncCore
import PhotoLibraryBackupAdapter
import PhotosCore
import DesignSystem
import ProtonDriveBackend
import UploadCore

/// Native macOS Settings window (Proton Photos -> Einstellungen...).
struct SettingsView: View {
    let uploadCoordinator: UploadCoordinator?
    let backup: FolderBackupController?
    let photoBackup: PhotoLibraryBackupController?
    let albumSync: AlbumSyncController?
    let signOut: () -> Void

    var body: some View {
        TabView {
            AccountSettingsTab(signOut: signOut)
                .tabItem { Label("settings.account_tab", systemImage: "person.crop.circle") }
            LibrarySettingsTab()
                .tabItem { Label("settings.library_tab", systemImage: "photo.on.rectangle.angled") }
            if let backup {
                BackupSettingsTab(backup: backup, photoBackup: photoBackup, albumSync: albumSync, uploadCoordinator: uploadCoordinator)
                    .tabItem { Label("settings.backup_tab", systemImage: "arrow.triangle.2.circlepath.icloud") }
            }
            CacheStatusTab()
                .tabItem { Label("settings.diagnostics_tab", systemImage: "internaldrive") }
        }
        .frame(width: 520, height: 520)
    }
}

// MARK: - Folder backup

private struct BackupSettingsTab: View {
    @State var backup: FolderBackupController
    let photoBackup: PhotoLibraryBackupController?
    let albumSync: AlbumSyncController?
    let uploadCoordinator: UploadCoordinator?

    var body: some View {
        Form {
            if let photoBackup {
                Section {
                    PhotoLibraryBackupSection(controller: photoBackup)
                } header: {
                    Text("settings.photos_backup_section")
                }
            }
            if let albumSync {
                Section {
                    AlbumSyncSection(controller: albumSync)
                } header: {
                    Text("settings.albumsync_section")
                }
            }
            Section {
                if backup.folders.isEmpty {
                    Text("settings.backup_no_folders")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(backup.folders) { folder in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folder.displayPath)
                                .font(.system(size: 12))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            if folder.needsRenewal {
                                Text("settings.backup_folder_stale")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.orange)
                            }
                        }
                        Spacer()
                        Button(role: .destructive) { backup.removeFolder(folder.id) } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .disabled(backup.isSyncing)
                    }
                }
                Button("settings.backup_add_folder") { pickFolder() }
                    .disabled(backup.isSyncing)
            } header: {
                Text("settings.backup_folders_section")
            }

            Section {
                if !backup.isAvailable {
                    Text("settings.backup_unavailable")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    folderSyncStatus
                }
            } header: {
                Text("settings.backup_status_section")
            }

            // The manual upload queue's pre-upload check lives here too: it is backup work
            // ("is this already safe?"), not a generic library concern.
            Section {
                BackupStatusSummaryRow(
                    status: BackupStatus(manualUploadCheck: uploadCoordinator?.preparationStatus ?? UploadPreparationStatus())
                )
            } header: {
                Text("settings.backup_uploads_section")
            }
        }
        .formStyle(.grouped)
    }

    /// Status header, honest progress, and count rows - all wording comes from the shared
    /// Core `BackupStatus` model, so macOS and iOS can never drift apart.
    @ViewBuilder
    private var folderSyncStatus: some View {
        let status = backup.status
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(status.localizedTitle)
                    .font(.system(size: 12, weight: .medium))
                if let detail = status.localizedDetail {
                    Text(detail)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if backup.isSyncing {
                Button("settings.backup_stop") { backup.stopSync() }
            } else {
                Button("settings.backup_sync_now") { backup.syncNow() }
                    .disabled(backup.folders.isEmpty)
            }
        }
        if status.isActive || status.phase == .paused {
            if let fraction = status.fractionCompleted {
                ProgressView(value: fraction)
            } else {
                ProgressView()  // indeterminate: totals unknown (scanning) - no fake progress
            }
            if let name = status.currentItemName {
                Text(name)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        if let total = status.totalConsidered, total > 0 {
            VStack(alignment: .leading, spacing: 3) {
                Text("settings.backup_backed_up \(status.backedUp) \(total)")
                if status.skippedRemoteDeletions > 0 {
                    Text("settings.backup_row_skipped_deleted \(status.skippedRemoteDeletions)")
                }
                if status.sourceMissing > 0 {
                    Text("settings.backup_row_source_missing \(status.sourceMissing)")
                }
                if status.waitingRetry > 0 {
                    Text("settings.backup_row_blocked \(status.waitingRetry)")
                }
                if status.failed > 0 {
                    Text("settings.backup_row_failed \(status.failed)")
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(.secondary)
        }
        if let message = backup.lastMessage {
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = NSLocalizedString("settings.backup_add_folder_prompt", comment: "folder picker confirm button")
        if panel.runModal() == .OK, let url = panel.url {
            backup.addFolder(url)
        }
    }
}

// MARK: - Account

private struct AccountSettingsTab: View {
    let signOut: () -> Void

    @State private var account = AccountInfo.shared

    var body: some View {
        Form {
            Section {
                if let used = account.usedSpaceBytes, let max = account.maxSpaceBytes, max > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("settings.storage_used").font(.system(size: 12, weight: .medium))
                            Spacer()
                            Text("\(byteString(used)) / \(byteString(max))")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: Double(min(used, max)), total: Double(max))
                    }
                } else {
                    Text("settings.storage_unavailable")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("settings.storage_section")
            }

            Section {
                Button("action.sign_out", role: .destructive, action: signOut)
                Text("settings.sign_out_help")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("settings.account_section")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Library / Cache

private struct LibrarySettingsTab: View {
    @State private var offline = OfflineLibraryManager.shared
    @AppStorage(AppSettingsKey.offlineOriginalsCapUnlimited) private var capUnlimited = AppSettingsDefault.offlineOriginalsCapUnlimited
    @AppStorage(AppSettingsKey.offlineOriginalsCapGB) private var capGB = AppSettingsDefault.offlineOriginalsCapGB
    @State private var confirmDelete = false
    @State private var confirmDisableOffline = false
    @State private var deleting = false
    @State private var cacheSize: Int64 = 0
    @State private var originalsSize: Int64 = 0

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { offline.offlineEnabled }, set: { setOffline($0) })) {
                    Text("settings.offline_library_toggle")
                }
                Text("settings.offline_library_help")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("settings.library_offline_section")
            }

            Section {
                Picker("settings.cache_limit_section", selection: $capUnlimited) {
                    Text("settings.cache_limit_bounded").tag(false)
                    Text("settings.cache_limit_unlimited").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: capUnlimited) { _, _ in applyCap() }

                if !capUnlimited {
                    HStack {
                        Slider(value: $capGB, in: 1...50, step: 1) { editing in if !editing { applyCap() } }
                        Text("\(Int(capGB)) GB")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
                Text("settings.cache_limit_help")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("settings.cache_limit_section")
            }
            .disabled(!offline.offlineEnabled)

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("settings.offline_cache_label").font(.system(size: 12, weight: .medium))
                        Text(byteString(cacheSize))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: {
                        if deleting { ProgressView().controlSize(.small) } else { Text("settings.delete_offline_cache_button") }
                    }
                    .disabled(deleting)
                }
                Text("settings.cache_deletion_help")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("settings.storage_section")
            }
        }
        .formStyle(.grouped)
        .task { await refreshSize() }
        .confirmationDialog("alert.delete_offline_cache_title", isPresented: $confirmDelete) {
            Button("action.cancel", role: .cancel) {}
            Button("action.delete", role: .destructive) { Task { await delete() } }
        } message: {
            Text("alert.delete_offline_cache_message \(byteString(cacheSize))")
        }
        .confirmationDialog("settings.disable_offline_title", isPresented: $confirmDisableOffline) {
            Button("action.cancel", role: .cancel) {}
            Button("settings.disable_offline_confirm", role: .destructive) {
                offline.setOfflineEnabled(false)
                Task { await offline.purgeOriginalsCache(); await refreshSize() }
            }
        } message: {
            Text("settings.disable_offline_message \(byteString(originalsSize))")
        }
    }

    private func setOffline(_ on: Bool) {
        if on { offline.setOfflineEnabled(true); return }
        if originalsSize > 0 {
            confirmDisableOffline = true
        } else {
            offline.setOfflineEnabled(false)
            Task { await offline.purgeOriginalsCache(); await refreshSize() }
        }
    }

    private func applyCap() {
        offline.setOriginalsCap(unlimited: capUnlimited, gigabytes: capGB)
        Task { await refreshSize() }
    }

    private func refreshSize() async {
        let status = await OfflineLibraryManager.shared.refreshStatus()
        cacheSize = status.totalCacheSizeBytes
        originalsSize = status.originalsCacheSizeBytes
    }

    private func delete() async {
        deleting = true
        await OfflineLibraryManager.shared.deleteOfflineCache()
        await refreshSize()
        deleting = false
    }
}

/// Photos-library backup controls over the SHARED cross-platform controller. Presentation only:
/// consent copy before any permission request, honest permission states, shared status wording.
private struct PhotoLibraryBackupSection: View {
    @State var controller: PhotoLibraryBackupController

    var body: some View {
        if !controller.isAvailable {
            Text("settings.backup_unavailable")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else if !controller.isEnabled {
            Text("settings.photos_backup_explainer")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                if controller.accessState == .denied || controller.accessState == .restricted {
                    Text("settings.photos_backup_denied")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("settings.photos_backup_enable") {
                    Task { await controller.enableBackup() }
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(controller.status.localizedTitle)
                        .font(.system(size: 12, weight: .medium))
                    if let detail = controller.status.localizedDetail {
                        Text(detail)
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if controller.isSyncing {
                    Button("settings.backup_stop") { controller.stopSync() }
                } else {
                    Button("settings.backup_sync_now") { controller.syncNow() }
                }
            }
            if controller.status.isActive || controller.status.phase == .paused {
                if let fraction = controller.status.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                if let name = controller.status.currentItemName {
                    Text(name)
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            if let total = controller.status.totalConsidered, total > 0 {
                Text("settings.backup_backed_up \(controller.status.backedUp) \(total)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                if controller.status.failed > 0 {
                    Text("settings.backup_row_failed \(controller.status.failed)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.orange)
                }
            }
            if controller.accessState == .limited {
                Text("settings.photos_backup_limited")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if let message = controller.lastMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("settings.photos_backup_disable") { controller.disableBackup() }
                    .controlSize(.small)
            }
        }
    }
}

/// Local-album → Proton-album sync over the SHARED cross-platform controller. Presentation only:
/// Settings shows ONLY the albums the user selected in the picker sheet; each row carries its
/// shared-wording state and a remove control (removal never touches Proton - the mapping stays,
/// so re-selecting reuses the same album). Same-name conflicts are resolved by the user, never by
/// guessing.
private struct AlbumSyncSection: View {
    @State var controller: AlbumSyncController
    @State private var showPicker = false

    var body: some View {
        if !controller.isAvailable {
            Text("settings.backup_unavailable")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            if controller.selectedAlbums.isEmpty {
                Text("settings.albumsync_explainer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(controller.selectedAlbums) { album in
                selectedRow(album)
            }
            if controller.isSyncing {
                syncProgress
            }
            if controller.accessState == .denied || controller.accessState == .restricted {
                Text("settings.photos_backup_denied")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
            if let message = controller.lastMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button {
                    showPicker = true
                } label: {
                    Label("settings.albumsync_add_albums", systemImage: "plus")
                }
                Spacer()
                if controller.isSyncing {
                    Button("settings.backup_stop") { controller.stopSync() }
                } else {
                    Button("settings.albumsync_sync_all") { controller.syncSelected() }
                        .disabled(controller.selectedAlbums.isEmpty)
                }
            }
            .sheet(isPresented: $showPicker) {
                AlbumPickerSheet(controller: controller)
            }
            .confirmationDialog(
                "settings.albumsync_conflict_title",
                isPresented: conflictPresented,
                titleVisibility: .visible
            ) {
                if let conflict = controller.pendingConflict, conflict.existing.count == 1,
                   let existing = conflict.existing.first {
                    Button("settings.albumsync_use_existing") {
                        controller.resolveConflict(useExisting: existing.id)
                    }
                }
                Button("action.cancel", role: .cancel) {
                    controller.resolveConflict(useExisting: nil)
                }
            } message: {
                if let conflict = controller.pendingConflict {
                    if conflict.existing.count > 1 {
                        Text("settings.albumsync_conflict_multiple")
                    } else {
                        Text("settings.albumsync_conflict_message \(conflict.album.title)")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func selectedRow(_ album: AlbumSyncController.SelectedAlbum) -> some View {
        let isActive = controller.isSyncing && controller.progress.localAlbumID == album.id
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(album.title)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    if let count = album.assetCount {
                        Text("settings.albumsync_photo_count \(count)")
                    }
                    Text(isActive ? controller.progress.localizedTitle : album.localizedStateDescription)
                        .foregroundStyle(rowStateColor(album, isActive: isActive))
                    if album.needsAttentionCount > 0, !isActive {
                        Text("settings.albumsync_row_attention \(album.needsAttentionCount)")
                            .foregroundStyle(.orange)
                    }
                }
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
            if isActive {
                ProgressView()
                    .controlSize(.small)
            } else if album.state == .needsDecision {
                Button("settings.albumsync_decide") { controller.presentConflict(albumID: album.id) }
                    .controlSize(.small)
            }
            Button {
                controller.removeFromSelection(album.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(isActive)
            .help(String(localized: "settings.albumsync_remove"))
            .accessibilityLabel(Text("settings.albumsync_remove"))
        }
    }

    private func rowStateColor(_ album: AlbumSyncController.SelectedAlbum, isActive: Bool) -> Color {
        if isActive { return .secondary }
        switch album.state {
        case .missingLocally, .needsDecision: return .orange
        case .notSynced, .synced: return .secondary
        }
    }

    private var syncProgress: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let detail = controller.progress.localizedDetail {
                Text(detail)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView()
                .controlSize(.small)
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

/// The album picker: every local album, searchable, multi-select. Confirming applies the FULL
/// selection (checked = synced), so adding and removing are both one visit. Opening this sheet is
/// the explicit user action that may trigger the system photo-access prompt.
private struct AlbumPickerSheet: View {
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
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("settings.albumsync_picker_title")
                    .font(.headline)
                TextField("settings.albumsync_picker_search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
            }
            .padding()

            Divider()

            if controller.isLoadingAlbums && !didLoad {
                Spacer()
                ProgressView()
                Spacer()
            } else if controller.accessState == .denied || controller.accessState == .restricted {
                Spacer()
                Text("settings.photos_backup_denied")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .padding()
                Spacer()
            } else if filteredAlbums.isEmpty {
                Spacer()
                Text("settings.albumsync_picker_empty")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()
                Spacer()
            } else {
                List(filteredAlbums) { album in
                    Toggle(isOn: draftBinding(album.id)) {
                        HStack {
                            Text(album.title)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Text("settings.albumsync_photo_count \(album.assetCount)")
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Text("settings.albumsync_picker_selected \(draft.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("action.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("settings.albumsync_picker_apply") {
                    controller.applySelection(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 420, height: 480)
        .task {
            await controller.loadAvailableAlbums()
            if !didLoad {
                draft = controller.selectedAlbumIDs
                didLoad = true
            }
        }
    }

    private func draftBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { draft.contains(id) },
            set: { checked in
                if checked { draft.insert(id) } else { draft.remove(id) }
            }
        )
    }
}

/// Compact status row over the shared Core `BackupStatus` model (used for the manual upload
/// queue's pre-upload check). Idle is explanatory text only; a standalone "Ready" row is not
/// useful for this section.
private struct BackupStatusSummaryRow: View {
    let status: BackupStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsStatusHeader {
                HStack(alignment: .firstTextBaseline) {
                    Label(status.localizedTitle, systemImage: status.isActive ? "arrow.trianglehead.2.clockwise" : "checkmark.shield")
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    if total > 0 {
                        Text(String(localized: "settings.upload_check_progress \(status.checked) \(total)"))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let total = status.totalConsidered, total > 0 {
                if let fraction = status.fractionCompleted {
                    ProgressView(value: fraction)
                } else {
                    ProgressView()
                }
                VStack(alignment: .leading, spacing: 2) {
                    if status.alreadyBackedUp > 0 {
                        Text("settings.upload_check_duplicates \(status.alreadyBackedUp)")
                    }
                    if status.needsAttentionCount > 0 {
                        Text("settings.upload_check_attention \(status.needsAttentionCount)")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            } else {
                Text("settings.upload_check_idle_help")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var total: Int {
        status.totalConsidered ?? 0
    }

    private var showsStatusHeader: Bool {
        status.isActive || total > 0 || status.needsAttentionCount > 0
    }
}

// MARK: - Diagnostics

private struct CacheStatusTab: View {
    @State private var status = OfflineCacheStatus()
    @State private var refreshing = false
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                row(String(localized: "settings.dev_total_assets"), "\(status.totalAssets)")
                row(String(localized: "settings.dev_metadata_rows"), "\(status.metadataRows)")
                row(String(localized: "settings.dev_thumbnails_on_disk"), "\(status.thumbnailsOnDisk)")
                row(String(localized: "settings.dev_thumbnails_missing"), "\(status.thumbnailsMissing)")
                row(String(localized: "settings.dev_disk_coverage"), percent(status.thumbnailCoverage))
            } header: { Text("settings.coverage_section") }

            Section {
                row(String(localized: "settings.dev_ram_decoded"), "\(status.ramDecodedEstimate)")
                row(String(localized: "settings.dev_prefetch_queue"), "\(status.prefetchQueueDepth)")
                row(String(localized: "settings.dev_active_prefetch"), "\(status.activePrefetchJobs)")
                row(String(localized: "settings.dev_prefetch_pause_reason"), status.prefetchPausedReason)
                row(String(localized: "settings.dev_failed_thumbnails"), "\(status.failedThumbnailCount)")
            } header: { Text("settings.prefetch_section") }

            Section {
                row(String(localized: "settings.dev_cache_size_disk"), byteString(status.cacheSizeBytes))
                row(String(localized: "settings.dev_preview_cache_disk"), byteString(status.previewCacheSizeBytes))
                row(String(localized: "settings.dev_originals_cache_disk"), byteString(status.originalsCacheSizeBytes))
                row(String(localized: "settings.dev_last_error"), status.lastError ?? "-")
            } header: { Text("settings.storage_section") }

            Section {
                Button { Task { await refresh() } } label: {
                    if refreshing { ProgressView().controlSize(.small) } else { Text("action.refresh") }
                }
            }
        }
        .formStyle(.grouped)
        .task { await refresh() }
        .onReceive(timer) { _ in Task { await refresh() } }
    }

    private func refresh() async {
        refreshing = true
        status = await OfflineLibraryManager.shared.refreshStatus()
        refreshing = false
    }

    private func row(_ label: String, _ value: String) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func percent(_ fraction: Double) -> String {
        String(format: "%.1f %%", fraction * 100)
    }
}

private func byteString(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
}
