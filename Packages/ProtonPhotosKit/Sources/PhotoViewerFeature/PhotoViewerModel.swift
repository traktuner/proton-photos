import Foundation
import AppKit
import PhotosCore
import MediaCache

/// Drives the full-screen viewer with progressive quality (blur-up):
///  1. show the grid thumbnail instantly (blurred — it's small for full-screen),
///  2. swap to the larger preview when it arrives,
///  3. swap to the full original (sharp) once downloaded.
@MainActor
@Observable
public final class PhotoViewerModel {
    public private(set) var items: [PhotoItem]
    public private(set) var index: Int

    /// Best image available so far for the current item.
    public private(set) var image: NSImage?
    /// True once the original (full-res) is shown — the blur is removed.
    public private(set) var isSharp = false
    /// A video URL if the current item turned out to be a video/movie.
    public private(set) var videoURL: URL?

    private let feed: ThumbnailFeed
    private let media: FullMediaProvider
    private var loadTask: Task<Void, Never>?

    public init(items: [PhotoItem], index: Int, feed: ThumbnailFeed, media: FullMediaProvider) {
        self.items = items
        self.index = index
        self.feed = feed
        self.media = media
    }

    public var current: PhotoItem { items[index] }
    public var canGoNext: Bool { index < items.count - 1 }
    public var canGoPrevious: Bool { index > 0 }

    public func start() { loadCurrent() }

    public func next() {
        guard canGoNext else { return }
        index += 1
        loadCurrent()
    }

    public func previous() {
        guard canGoPrevious else { return }
        index -= 1
        loadCurrent()
    }

    private func loadCurrent() {
        loadTask?.cancel()
        let item = current
        image = nil
        isSharp = false
        videoURL = nil

        loadTask = Task { [feed, media] in
            // 1) Instant thumbnail (blurred backdrop while the original loads).
            if let thumb = await feed.image(for: item.uid), !Task.isCancelled, self.current == item {
                self.image = thumb
            }
            // 2) Larger preview for a crisper interim image.
            if let previewData = try? await media.preview(for: item.uid),
               let preview = NSImage(data: previewData), !Task.isCancelled, self.current == item {
                self.image = preview
            }
            // 3) Full original (image or video).
            do {
                let url = try await media.downloadOriginal(for: item.uid)
                guard !Task.isCancelled, self.current == item else { return }
                if Self.isVideo(url) {
                    self.videoURL = url
                } else if let full = NSImage(contentsOf: url) {
                    self.image = full
                    self.isSharp = true
                }
            } catch {
                // keep showing the best interim image
            }
        }
    }

    private static func isVideo(_ url: URL) -> Bool {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.conforms(to: .movie) || type.conforms(to: .video)
        }
        return ["mov", "mp4", "m4v", "avi"].contains(url.pathExtension.lowercased())
    }
}
