import DesignSystemCore
import Foundation
import PhotoLibraryBackupAdapter
import Photos
import PhotosUI
import PhotosCore
import ProtonDriveBackend
import SwiftUI
import TimelineCore
import UIKit
import UploadCore

/// Account, library status, cache and sign-out settings for the mobile app.
struct MobileSettingsScreen: View {
    @EnvironmentObject private var sessionModel: MobileSessionModel
    /// `@Environment` over the `@Observable` model: Settings reads only `loadState`/`isBackgroundLoading`, so
    /// it is NOT re-rendered when a large timeline `snapshot` is published — the core menu-smoothness fix.
    @Environment(MobileLibraryModel.self) private var libraryModel
    /// Shared Proton account info populated by the backend's account-data cache.
    @State private var account = AccountInfo.shared

    @State private var cacheSize: Int64 = 0
    @State private var isClearingCache = false
    @State private var confirmSignOut = false
    @State private var confirmClearCache = false

    var body: some View {
        NavigationStack {
            List {
                accountSection
                librarySection
                backupSection
                cacheSection
                signOutSection
                brandFooter
            }
            .navigationTitle(String(localized: "tab.settings"))
            .task { await refreshCacheSize() }
            .task(id: libraryModel.isBackgroundLoading) {
                await refreshCacheSizeWhilePreviewsLoad()
            }
            .alert(
                String(localized: "settings.sign_out_confirm \(ProductBrand.displayName)"),
                isPresented: $confirmSignOut
            ) {
                Button(String(localized: "action.sign_out"), role: .destructive) { sessionModel.signOut() }
                Button(String(localized: "action.cancel"), role: .cancel) {}
            }
            .alert(
                String(localized: "settings.clear_cache_title"),
                isPresented: $confirmClearCache
            ) {
                Button(String(localized: "settings.clear_cache"), role: .destructive) { clearCache() }
                Button(String(localized: "action.cancel"), role: .cancel) {}
            } message: {
                Text(String(localized: "settings.clear_cache_message"))
            }
        }
    }

    // MARK: - Sections

    /// Account identity and storage quota when the backend has decoded them.
    @ViewBuilder private var accountSection: some View {
        if account.primaryEmail != nil || (account.usedSpaceBytes != nil && account.maxSpaceBytes != nil) {
            Section(String(localized: "settings.section_account")) {
                if let email = account.primaryEmail {
                    LabeledContent(String(localized: "settings.account_email")) {
                        Text(email).foregroundStyle(ProtonColor.textWeak)
                    }
                }
                if let used = account.usedSpaceBytes, let max = account.maxSpaceBytes, max > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent(String(localized: "settings.storage")) {
                            Text(String(localized: "settings.storage_usage \(byteString(used)) \(byteString(max))"))
                                .monospacedDigit()
                                .foregroundStyle(ProtonColor.textWeak)
                        }
                        ProgressView(value: Double(min(used, max)), total: Double(max))
                            .tint(ProtonColor.primary)
                    }
                }
            }
        }
    }

    /// Library total and current loading phase. `LibraryLoadState` intentionally exposes no fabricated percentage.
    @ViewBuilder private var librarySection: some View {
        Section(String(localized: "settings.section_library")) {
            if let count = libraryModel.loadState.knownCount, libraryModel.loadState.hasSettled {
                Text(String(localized: "settings.photo_count \(count)"))
                    .monospacedDigit()
            }
            if libraryModel.loadState.isLoading {
                libraryStatusRow(
                    title: String(localized: "settings.library_loading"),
                    detail: libraryModel.loadState.knownCount.map { String(localized: "loading.preparing_count \($0)") }
                )
            } else if libraryModel.isBackgroundLoading {
                libraryStatusRow(
                    title: String(localized: "settings.library_still_loading"),
                    detail: previewLoadingDetail
                )
            }
        }
    }

    /// Backup state lives in its own section, mirroring the macOS Backup tab. Rows are driven by
    /// the shared Core `BackupStatus` model - same phases and wording on every platform.
    @ViewBuilder private var backupSection: some View {
        Section {
            if let photoBackup = libraryModel.photoBackup {
                MobilePhotoBackupRows(controller: photoBackup)
            }
            if let albumSync = libraryModel.albumSync {
                NavigationLink {
                    MobileAlbumSyncScreen(controller: albumSync)
                } label: {
                    Label(String(localized: "settings.albumsync_row"), systemImage: "rectangle.stack.badge.plus")
                }
            }
            backupStatusRow
        } header: {
            Text(String(localized: "settings.section_backup"))
        } footer: {
            if libraryModel.photoBackup?.isEnabled == true {
                Text(String(localized: "settings.photos_backup_background_note"))
            }
        }
    }

    private var previewLoadingDetail: String? {
        let remaining = libraryModel.previewLoadStatus.remaining
        guard remaining > 0 else { return nil }
        return String(localized: "settings.previews_remaining \(remaining)")
    }

    private func libraryStatusRow(title: String, detail: String?) -> some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(ProtonColor.primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(ProtonColor.textNorm)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(ProtonColor.textWeak)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
            }
        }
    }

    @ViewBuilder private var backupStatusRow: some View {
        let status = BackupStatus(
            manualUploadCheck: libraryModel.facade?.uploadCoordinator.preparationStatus ?? UploadPreparationStatus()
        )
        let total = status.totalConsidered ?? 0
        if status.isActive || total > 0 || status.needsAttentionCount > 0 {
            HStack(spacing: 10) {
                Image(systemName: status.isActive ? "arrow.trianglehead.2.clockwise" : "checkmark.shield")
                    .foregroundStyle(status.isActive ? ProtonColor.primary : ProtonColor.textWeak)
                    .frame(width: 18)
                    .spinsWhileActive(status.isActive)
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(status.localizedTitle)
                            .foregroundStyle(ProtonColor.textNorm)
                        Spacer()
                        if total > 0 {
                            Text(String(localized: "settings.upload_check_progress \(status.checked) \(total)"))
                                .font(.footnote)
                                .foregroundStyle(ProtonColor.textWeak)
                                .monospacedDigit()
                        }
                    }
                    if total > 0 {
                        if let fraction = status.fractionCompleted {
                            ProgressView(value: fraction)
                                .tint(ProtonColor.primary)
                        } else {
                            ProgressView()
                                .tint(ProtonColor.primary)
                        }
                        backupStatusDetail(status)
                    } else if status.needsAttentionCount > 0 {
                        backupStatusDetail(status)
                    }
                }
            }
        } else {
            Text(String(localized: "settings.upload_check_idle_help"))
                .font(.footnote)
                .foregroundStyle(ProtonColor.textWeak)
        }
    }

    @ViewBuilder private func backupStatusDetail(_ status: BackupStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if status.alreadyBackedUp > 0 {
                Text(String(localized: "settings.upload_check_duplicates \(status.alreadyBackedUp)"))
            }
            if status.needsAttentionCount > 0 {
                Text(String(localized: "settings.upload_check_attention \(status.needsAttentionCount)"))
            }
        }
        .font(.footnote)
        .foregroundStyle(ProtonColor.textWeak)
        .monospacedDigit()
    }

    /// On-disk encrypted thumbnail-cache size and clear action.
    @ViewBuilder private var cacheSection: some View {
        Section(String(localized: "settings.section_cache")) {
            LabeledContent(String(localized: "settings.cache_size")) {
                Text(byteString(cacheSize))
                    .monospacedDigit()
                    .foregroundStyle(ProtonColor.textWeak)
            }
            Button(role: .destructive) {
                confirmClearCache = true
            } label: {
                HStack {
                    Text(String(localized: "settings.clear_cache"))
                    Spacer()
                    if isClearingCache { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isClearingCache)
        }
    }

    @ViewBuilder private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                confirmSignOut = true
            } label: {
                Label(String(localized: "action.sign_out"), systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    @ViewBuilder private var brandFooter: some View {
        Section {
            EmptyView()
        } footer: {
            HStack {
                Spacer()
                VStack(spacing: 8) {
                    MobileBrandLogo(height: 28)
                    Text(ProductBrand.displayName)
                        .font(.footnote)
                        .foregroundStyle(ProtonColor.textHint)
                }
                Spacer()
            }
            .padding(.top, 12)
        }
    }

    // MARK: - Actions

    private func byteString(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func refreshCacheSize() async {
        cacheSize = await libraryModel.cacheDiskSizeBytes()
    }

    private func refreshCacheSizeWhilePreviewsLoad() async {
        guard libraryModel.isBackgroundLoading else { return }
        while !Task.isCancelled, libraryModel.isBackgroundLoading {
            try? await Task.sleep(for: .seconds(3))
            await refreshCacheSize()
        }
    }

    private func clearCache() {
        isClearingCache = true
        Task {
            await libraryModel.clearCache()
            await refreshCacheSize()
            isClearingCache = false
        }
    }
}

// MARK: - Photos library backup (shared cross-platform controller, native mobile presentation)

/// Enable/permission/progress rows for Photos-library backup. All state, counts, and wording come
/// from the shared `PhotoLibraryBackupController` + `BackupStatus`; this view is layout only.
private struct MobilePhotoBackupRows: View {
    @State var controller: PhotoLibraryBackupController

    var body: some View {
        if !controller.isAvailable {
            Text(String(localized: "settings.photos_backup_unavailable"))
                .font(.footnote)
                .foregroundStyle(ProtonColor.textWeak)
        } else if !controller.isEnabled {
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "settings.photos_backup_explainer"))
                    .font(.footnote)
                    .foregroundStyle(ProtonColor.textWeak)
                if controller.accessState == .denied || controller.accessState == .restricted {
                    Text(String(localized: "settings.photos_backup_denied"))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    Button(String(localized: "settings.photos_backup_open_settings")) {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } else {
                    Button(String(localized: "settings.photos_backup_enable")) {
                        Task { await controller.enableBackup() }
                    }
                    .foregroundStyle(ProtonColor.primary)
                }
            }
        } else {
            enabledStatusRows
        }
    }

    @ViewBuilder private var enabledStatusRows: some View {
        let status = controller.status

        HStack(alignment: .top, spacing: 10) {
            Image(systemName: status.isActive ? "arrow.trianglehead.2.clockwise" : "checkmark.shield")
                .foregroundStyle(status.isActive ? ProtonColor.primary : ProtonColor.textWeak)
                .frame(width: 18, height: 22, alignment: .center)
                .spinsWhileActive(status.isActive)

            VStack(alignment: .leading, spacing: 4) {
                Text(status.localizedTitle)
                    .foregroundStyle(ProtonColor.textNorm)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.opacity)

                statusDetail(status)
                statusProgressSlot(status)

                if status.failed > 0 {
                    Text(String(localized: "settings.upload_check_attention \(status.failed)"))
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if controller.isSyncing {
                Button(String(localized: "settings.photos_backup_pause")) { controller.stopSync() }
                    .font(.footnote)
            } else {
                Button(String(localized: "settings.photos_backup_sync_now")) { controller.syncNow() }
                    .font(.footnote)
            }
        }

        if controller.accessState == .limited {
            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "settings.photos_backup_limited"))
                    .font(.footnote)
                    .foregroundStyle(ProtonColor.textWeak)
                Button(String(localized: "settings.photos_backup_manage_selection")) {
                    presentLimitedLibraryPicker()
                }
                .font(.footnote)
            }
        }

        Button(String(localized: "settings.photos_backup_disable"), role: .destructive) {
            controller.disableBackup()
        }
        .font(.footnote)
    }

    private func statusDetail(_ status: BackupStatus) -> some View {
        let detail = status.localizedDetail ?? " "
        return Text(detail)
            .font(.footnote)
            .foregroundStyle(ProtonColor.textWeak)
            .monospacedDigit()
            .lineLimit(1)
            .opacity(status.localizedDetail == nil ? 0 : 1)
            .accessibilityHidden(status.localizedDetail == nil)
            .frame(minHeight: 18, alignment: .leading)
            .contentTransition(.opacity)
    }

    @ViewBuilder private func statusProgressSlot(_ status: BackupStatus) -> some View {
        if (status.isActive || status.phase == .paused), let fraction = status.fractionCompleted {
            ProgressView(value: fraction)
                .tint(ProtonColor.primary)
                .frame(height: 4)
        } else {
            Color.clear.frame(height: 4)
        }
    }

    /// The system's limited-library selection UI (iOS/iPadOS only - the picker is UIKit-hosted,
    /// which is exactly why this call lives in the app layer, not the shared adapter).
    private func presentLimitedLibraryPicker() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let root = scenes.first?.keyWindow?.rootViewController else { return }
        var presenter = root
        while let presented = presenter.presentedViewController { presenter = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: presenter)
    }
}
