import MediaByteCache
import PhotosCore
import SwiftUI
import UIKit

/// Identifiable payload for the share sheet: the on-disk file URLs exported from the selection.
struct MobileSharePayload: Identifiable {
    let id = UUID()
    let urls: [URL]
}

/// Exports the selected media's ORIGINAL files to on-disk temp URLs for a native share sheet.
///
/// It shares real files, never thumbnails: each item's original bytes come from the shared
/// `FullMediaProvider` (`backend.originalData`), are written to a temp file with the correct extension, and the
/// URLs are handed to `UIActivityViewController`. Items whose download fails are skipped (the share proceeds
/// with whatever succeeded); if none succeed the caller surfaces the failure honestly. Photos and videos are
/// handled uniformly. Download concurrency is bounded so a multi-video selection never spikes memory.
enum MobileMediaExporter {
    /// The dedicated temp subfolder for share exports, cleared before each run so stale files never pile up.
    private static var exportDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ShareExports", isDirectory: true)
    }

    /// The result of an export run: the successfully-written file URLs and how many items could NOT be
    /// downloaded, so the caller can be honest about a partial share instead of silently dropping items.
    struct ExportResult {
        let urls: [URL]
        let failed: Int
    }

    static func exportOriginals(
        _ items: [PhotoItem],
        backend: any FullMediaProvider & PhotoMetadataProvider,
        cache: ThumbnailCache?,
        cacheCapBytes: Int64
    ) async -> ExportResult {
        guard !items.isEmpty else { return ExportResult(urls: [], failed: 0) }
        let directory = exportDirectory
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Cache-first byte retrieval: a just-viewed / previously-shared original is reused from the encrypted
        // originals cache instead of being re-downloaded. On a miss we SEED the cache (`.persisting`): the iOS
        // viewer displays a bounded preview rather than the full original, so on iOS it is the share/export path
        // that most often warms the originals cache — and every subsequent share/open then avoids the network.
        // Bytes only ever live in the AES-GCM cache, never as app-owned plaintext.
        let policy: OriginalsCachePolicy = cache != nil ? .persisting(capBytes: cacheCapBytes) : .readOnly
        let provider = EncryptedOriginalProvider(media: backend, cache: cache, policy: policy)
        // Shared, thread-safe uniquer: two selected photos can legitimately carry the SAME original Proton
        // name (e.g. two `IMG_0001.HEIC` from different folders), so the concurrent tasks reserve a unique
        // on-disk name before writing — mirroring macOS `uniqueName` — instead of silently overwriting.
        let names = ExportNames()

        let maxConcurrent = 4
        var exported: [URL] = []
        var failed = 0
        var index = 0
        // Bounded task group: at most `maxConcurrent` downloads in flight so a big video selection can't spike RAM.
        await withTaskGroup(of: URL?.self) { group in
            func addNext() {
                guard index < items.count else { return }
                let item = items[index]
                index += 1
                group.addTask { await export(item, provider: provider, backend: backend, names: names, into: directory) }
            }
            for _ in 0 ..< min(maxConcurrent, items.count) { addNext() }
            for await url in group {
                if let url { exported.append(url) } else { failed += 1 }
                addNext()
            }
        }
        return ExportResult(urls: exported, failed: failed)
    }

    private static func export(
        _ item: PhotoItem,
        provider: EncryptedOriginalProvider,
        backend: any PhotoMetadataProvider,
        names: ExportNames,
        into directory: URL
    ) async -> URL? {
        do {
            let data = try await provider.originalData(for: item.uid)
            // The real decrypted Proton link name is authoritative — an `IMG_1234.HEIC` must stay
            // `IMG_1234.HEIC`, never a re-invented `ProductBrand-…`. Look it up like macOS does; a metadata
            // failure degrades to the generated fallback rather than failing the whole export.
            let meta = try? await backend.metadata(for: item.uid)
            // Extension only matters when the real name lacks one: derive it from the ACTUAL bytes (the SDK
            // stamps `image/jpeg` on every image — the reason a HEIC used to be saved as `.jpg`), with the
            // real link MIME as a secondary signal.
            let ext = OriginalFileNaming.resolvedExtension(
                filename: meta?.filename, mimeType: meta?.mimeType, header: data,
                fallbackMediaType: item.mediaType, isVideo: item.isVideo
            )
            let desired = OriginalFileNaming.exportFilename(
                metadataFilename: meta?.filename, fallbackBase: fallbackBase(for: item), ext: ext
            )
            let url = directory.appendingPathComponent(await names.unique(desired))
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// The generated last-resort base name (no extension), used ONLY when no real Proton filename is
    /// available: the brand plus capture date plus a node-id suffix so two photos from the same second
    /// never collide before the uniquer even runs.
    static func fallbackBase(for item: PhotoItem) -> String {
        let stamp = Self.stampFormatter.string(from: item.captureTime)
        let suffix = String(item.uid.nodeID.suffix(6))
        return "\(ProductBrand.displayName)-\(stamp)-\(suffix)"
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

/// Serialises on-disk name assignment across the concurrent export/save tasks so two files that resolve to
/// the same original name (a real collision, e.g. two `IMG_0001.HEIC`) get `IMG_0001 2.HEIC` etc. instead of
/// clobbering each other's temp URL. Case-insensitive to match the (typically case-insensitive) filesystem.
/// Mirrors macOS `MainView.uniqueName`.
actor ExportNames {
    private var used: Set<String> = []

    func unique(_ name: String) -> String {
        if reserve(name) { return name }
        let ns = name as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if reserve(candidate) { return candidate }
            n += 1
        }
    }

    /// Records `name` and returns true if it was free; false if already taken.
    private func reserve(_ name: String) -> Bool {
        used.insert(name.lowercased()).inserted
    }
}

/// Thin SwiftUI wrapper over `UIActivityViewController` — the native iOS share sheet — over exported file URLs.
struct MobileActivityView: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
