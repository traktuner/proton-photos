import DesignSystemCore
import Foundation
import PhotosCore
import ProtonDriveBackend
import SwiftUI
import TimelineCore
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
            uploadPreparationRow
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

    @ViewBuilder private var uploadPreparationRow: some View {
        let status = libraryModel.facade?.uploadCoordinator.preparationStatus ?? UploadPreparationStatus()
        HStack(spacing: 10) {
            Image(systemName: status.isRunning ? "arrow.trianglehead.2.clockwise" : "checkmark.shield")
                .foregroundStyle(status.isRunning ? ProtonColor.primary : ProtonColor.textWeak)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(uploadPreparationTitle(status))
                        .foregroundStyle(ProtonColor.textNorm)
                    Spacer()
                    if status.hasItems {
                        Text(String(localized: "settings.upload_check_progress \(status.resolved) \(status.total)"))
                            .font(.footnote)
                            .foregroundStyle(ProtonColor.textWeak)
                            .monospacedDigit()
                    }
                }
                if status.hasItems {
                    ProgressView(value: status.progressFraction)
                        .tint(ProtonColor.primary)
                    uploadPreparationDetail(status)
                } else {
                    Text(String(localized: "settings.upload_check_idle_help"))
                        .font(.footnote)
                        .foregroundStyle(ProtonColor.textWeak)
                }
            }
        }
    }

    private func uploadPreparationTitle(_ status: UploadPreparationStatus) -> String {
        if !status.hasItems { return String(localized: "settings.upload_check_idle") }
        return status.isRunning
            ? String(localized: "settings.upload_check_active")
            : String(localized: "settings.upload_check_done")
    }

    @ViewBuilder private func uploadPreparationDetail(_ status: UploadPreparationStatus) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if status.checking > 0 {
                Text(String(localized: "settings.upload_check_running \(status.checking)"))
            }
            if status.skippedDuplicates > 0 {
                Text(String(localized: "settings.upload_check_duplicates \(status.skippedDuplicates)"))
            }
            if status.needsAttention > 0 {
                Text(String(localized: "settings.upload_check_attention \(status.needsAttention)"))
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
