import SwiftUI
import Combine
import PhotosCore
import DesignSystem

/// Native macOS Settings window (ProtonPhotos → Einstellungen…). Two panes: Library/Offline (the
/// Offline Photo Library toggle + cache deletion) and Developer (the live cache-status surface).
struct SettingsView: View {
    var body: some View {
        TabView {
            LibrarySettingsTab()
                .tabItem { Label("settings.library_tab", systemImage: "photo.on.rectangle.angled") }
            CacheStatusTab()
                .tabItem { Label("settings.developer_tab", systemImage: "internaldrive") }
        }
        // Tall enough that the (now larger) Library tab fits without overflowing → no scroller appears. A scroller
        // only shows if a smaller screen genuinely can't fit the window.
        .frame(width: 520, height: 580)
    }
}

// MARK: - Library / Offline

private struct LibrarySettingsTab: View {
    @State private var offline = OfflineLibraryManager.shared
    @State private var account = AccountInfo.shared
    @AppStorage(AppSettingsKey.offlineOriginalsCapUnlimited) private var capUnlimited = AppSettingsDefault.offlineOriginalsCapUnlimited
    @AppStorage(AppSettingsKey.offlineOriginalsCapGB) private var capGB = AppSettingsDefault.offlineOriginalsCapGB
    @State private var confirmDelete = false
    @State private var confirmDisableOffline = false
    @State private var deleting = false
    @State private var cacheSize: Int64 = 0
    @State private var originalsSize: Int64 = 0

    var body: some View {
        Form {
            // Proton storage quota (from the account data we already fetch; shows last-known value offline).
            if let used = account.usedSpaceBytes, let max = account.maxSpaceBytes, max > 0 {
                Section {
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
                } header: {
                    Text("settings.storage_section")
                }
            }

            // 1) Offline master switch. E2EE is ALWAYS on (not a toggle); this only decides whether full
            //    originals are KEPT locally for instant/offline reopening.
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

            // 2) Originals cache budget - Unbounded or a slider-set cap (LRU purge of the oldest). Only meaningful
            //    while the offline library is on, so the whole section greys out otherwise.
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

            // 3) Master reset: wipes EVERYTHING on disk (incl. thumbnails) for the current account.
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

    /// Turning ON is immediate. Turning OFF must ALWAYS purge the originals (the OFF contract is "nothing kept");
    /// the `originalsSize` snapshot can lag (another window, or status not yet refreshed), so it only gates whether
    /// to confirm first - never whether to purge.
    private func setOffline(_ on: Bool) {
        if on { offline.setOfflineEnabled(true); return }
        if originalsSize > 0 {
            confirmDisableOffline = true   // the confirm action disables + purges
        } else {
            offline.setOfflineEnabled(false)
            Task { await offline.purgeOriginalsCache(); await refreshSize() }   // idempotent on empty
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

// MARK: - Developer / Cache status (Deliverable 3)

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
