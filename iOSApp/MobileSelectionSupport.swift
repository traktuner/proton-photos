import PhotosCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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

    static func exportOriginals(_ items: [PhotoItem], backend: any FullMediaProvider) async -> ExportResult {
        guard !items.isEmpty else { return ExportResult(urls: [], failed: 0) }
        let directory = exportDirectory
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

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
                group.addTask { await export(item, backend: backend, into: directory) }
            }
            for _ in 0 ..< min(maxConcurrent, items.count) { addNext() }
            for await url in group {
                if let url { exported.append(url) } else { failed += 1 }
                addNext()
            }
        }
        return ExportResult(urls: exported, failed: failed)
    }

    private static func export(_ item: PhotoItem, backend: any FullMediaProvider, into directory: URL) async -> URL? {
        do {
            let data = try await backend.originalData(for: item.uid)
            let url = directory.appendingPathComponent(filename(for: item))
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// A recipient-friendly filename: the capture date plus the correct extension for the media type.
    private static func filename(for item: PhotoItem) -> String {
        let ext = UTType(mimeType: item.mediaType)?.preferredFilenameExtension
            ?? (item.isVideo ? "mov" : "jpg")
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
