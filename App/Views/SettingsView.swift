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
                .tabItem { Label("Mediathek", systemImage: "photo.on.rectangle.angled") }
            CacheStatusTab()
                .tabItem { Label("Entwickler", systemImage: "ladybug") }
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
                    Text("Offline-Mediathek")
                }
                Text("Vorschaubilder werden immer lokal verschlüsselt geladen, damit das Grid funktioniert. "
                   + "Dieser Schalter ist für zukünftige größere Offline-Derivate reserviert.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Mediathek / Offline")
            }

            Section {
                Toggle(isOn: $keepOriginals) { Text("Originale & Videos offline behalten") }
                    .disabled(true)
                Text("Demnächst. Aktuell werden Originale und Videos bei Bedarf gestreamt bzw. "
                   + "geladen und nicht dauerhaft gespeichert.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Zukünftig")
            }

            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Offline-Cache").font(.system(size: 12, weight: .medium))
                        Text(byteString(cacheSize))
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: {
                        if deleting { ProgressView().controlSize(.small) } else { Text("Offline-Cache löschen…") }
                    }
                    .disabled(deleting)
                }
                Text("Der verschlüsselte Thumbnail-/Preview-Cache bleibt beim Deaktivieren der Offline-Mediathek erhalten und wird nur "
                   + "über diese Schaltfläche gelöscht.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .task { await refreshSize() }
        .alert("Offline-Cache löschen?", isPresented: $confirmDelete) {
            Button("Abbrechen", role: .cancel) {}
            Button("Löschen", role: .destructive) { Task { await delete() } }
        } message: {
            Text("Vorschaubilder und Previews (\(byteString(cacheSize))) werden entfernt. "
               + "Metadaten und Originale sind nicht betroffen; Thumbnails werden bei Bedarf neu geladen.")
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
                row("Assets gesamt", "\(status.totalAssets)")
                row("Metadaten-Zeilen", "\(status.metadataRows)")
                row("Thumbnails auf Disk", "\(status.thumbnailsOnDisk)")
                row("Thumbnails fehlend", "\(status.thumbnailsMissing)")
                row("Disk-Abdeckung", percent(status.thumbnailCoverage))
            } header: { Text("Abdeckung") }

            Section {
                row("RAM dekodiert (≤)", "\(status.ramDecodedEstimate)")
                row("Prefetch-Warteschlange", "\(status.prefetchQueueDepth)")
                row("Aktive Prefetch-Jobs", "\(status.activePrefetchJobs)")
                row("Prefetch-Pause-Grund", status.prefetchPausedReason)
                row("Fehlgeschlagene Thumbnails", "\(status.failedThumbnailCount)")
            } header: { Text("Prefetch") }

            Section {
                row("Cache-Größe (Disk)", byteString(status.cacheSizeBytes))
                row("Preview-Cache (Disk)", byteString(status.previewCacheSizeBytes))
                row("Letzter Fehler", status.lastError ?? "—")
            } header: { Text("Speicher") }

            Section {
                Button { Task { await refresh() } } label: {
                    if refreshing { ProgressView().controlSize(.small) } else { Text("Aktualisieren") }
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
        HStack {
            Text(label).font(.system(size: 12))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
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
