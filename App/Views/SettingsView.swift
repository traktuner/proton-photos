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
                .tabItem { Label("settings.developer_tab", systemImage: "ladybug") }
        }
        .frame(width: 520, height: 460)
    }
}

// MARK: - Library / Offline

private struct LibrarySettingsTab: View {
    @State private var offline = OfflineLibraryManager.shared
    @AppStorage(AppSettingsKey.offlineOriginalsEnabled) private var keepOriginals = AppSettingsDefault.offlineOriginalsEnabled
    @State private var confirmDelete = false
    @State private var deleting = false
    @State private var cacheSize: Int64 = 0

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { offline.offlineEnabled },
                                     set: { offline.setOfflineEnabled($0) })) {
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
                Toggle(isOn: $keepOriginals) { Text("settings.keep_originals_toggle") }
                    .disabled(true)
                Text("settings.originals_offline_help")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("settings.future_section")
            }

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
    }

    private func refreshSize() async {
        let status = await OfflineLibraryManager.shared.refreshStatus()
        cacheSize = status.totalCacheSizeBytes
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
                row(String(localized: "settings.dev_last_error"), status.lastError ?? "—")
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
