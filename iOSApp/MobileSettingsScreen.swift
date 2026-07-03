import DesignSystemCore
import Foundation
import PhotosCore
import ProtonDriveBackend
import SwiftUI
import TimelineCore

/// Account, library status, cache and sign-out settings for the mobile app.
struct MobileSettingsScreen: View {
    @EnvironmentObject private var sessionModel: MobileSessionModel
    @EnvironmentObject private var libraryModel: MobileLibraryModel
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
                            Text("\(byteString(used)) / \(byteString(max))")
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
                libraryStatusRow(title: String(localized: "settings.library_still_loading"), detail: nil)
            }
        }
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

    private func clearCache() {
        isClearingCache = true
        Task {
            await libraryModel.clearCache()
            await refreshCacheSize()
            isClearingCache = false
        }
    }
}
