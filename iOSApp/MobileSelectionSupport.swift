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
        backend: any FullMediaProvider,
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
                group.addTask { await export(item, provider: provider, into: directory) }
            }
            for _ in 0 ..< min(maxConcurrent, items.count) { addNext() }
            for await url in group {
                if let url { exported.append(url) } else { failed += 1 }
                addNext()
            }
        }
        return ExportResult(urls: exported, failed: failed)
    }

    private static func export(_ item: PhotoItem, provider: EncryptedOriginalProvider, into directory: URL) async -> URL? {
        do {
            let data = try await provider.originalData(for: item.uid)
            // Derive the extension from the ACTUAL bytes, not the timeline `mediaType` (which the SDK
            // stamps as `image/jpeg` on every image — the reason a HEIC used to be saved as `.jpg`).
            let ext = OriginalFileNaming.resolvedExtension(
                filename: nil, mimeType: item.mediaType, header: data,
                fallbackMediaType: item.mediaType, isVideo: item.isVideo
            )
            let url = directory.appendingPathComponent(filename(for: item, ext: ext))
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// A recipient-friendly filename: the capture date plus the resolved original extension.
    private static func filename(for item: PhotoItem, ext: String) -> String {
        let stamp = Self.stampFormatter.string(from: item.captureTime)
        // Keep the node id suffix so two photos from the same second never collide on disk.
        let suffix = String(item.uid.nodeID.suffix(6))
        return "\(ProductBrand.displayName)-\(stamp)-\(suffix).\(ext)"
    }

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

/// Thin SwiftUI wrapper over `UIActivityViewController` — the native iOS share sheet — over exported file URLs.
struct MobileActivityView: UIViewControllerRepresentable {
    let urls: [URL]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
