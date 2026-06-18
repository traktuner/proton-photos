import Foundation
import AppKit
import AVFoundation
import PhotosCore
import MediaCache

/// Drives the full-screen viewer with progressive quality (blur-up):
///  1. show the grid thumbnail instantly (blurred — it's small for full-screen),
///  2. swap to the larger preview when it arrives (disk-cached for offline),
///  3. swap to the full original (sharp) once downloaded.
///
/// Video (Deliverable 5) runs an explicit `VideoViewerState` machine instead of inferring "loading"
/// from a tangle of optionals: try range-streaming first (which also detects image-vs-video reliably
/// even though the main timeline reports every item as `image/jpeg`), observe `AVPlayerItem.status`,
/// and fall back to a full download if streaming setup fails. One `AVPlayer` for both paths, so the
/// view never re-creates the player on a redraw.
@MainActor
@Observable
public final class PhotoViewerModel {
    public private(set) var items: [PhotoItem]
    public private(set) var index: Int

    /// Best image available so far for the current item.
    public private(set) var image: NSImage?
    /// True once the original (full-res) is shown — the blur is removed.
    public private(set) var isSharp = false
    /// Owns the AVPlayer + the video state machine (streaming, watchdog, stall/buffer handling). The
    /// model decides *which* source to play; the controller decides *how it's going*.
    public let video = VideoPlaybackController()
    /// The single AVPlayer used for video (streaming or downloaded). `nil` for images.
    public var player: AVPlayer? { video.player }
    /// Explicit video lifecycle — the view shows progress / error from this.
    public var videoState: VideoViewerState { video.state }
    /// Download progress (0…1) of the full original — used to show a progress indicator for big
    /// downloads instead of an indefinite spinner.
    public private(set) var originalProgress: Double = 0
    public private(set) var isLoadingOriginal = false

    /// Whether the info panel is open, and the metadata for the current item (loaded lazily).
    public var showInfo = false
    public private(set) var metadata: PhotoMetadata?

    private let feed: ThumbnailFeed
    private let media: FullMediaProvider
    private let streamer: VideoStreamProvider?
    private let metadataProvider: PhotoMetadataProvider?
    private let previewCache: ThumbnailCache?
    private var loadTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?

    public init(items: [PhotoItem], index: Int, feed: ThumbnailFeed, media: FullMediaProvider,
                streamer: VideoStreamProvider? = nil, metadataProvider: PhotoMetadataProvider? = nil,
                previewCache: ThumbnailCache? = nil) {
        self.items = items
        self.index = index
        self.feed = feed
        self.media = media
        self.streamer = streamer
        self.metadataProvider = metadataProvider
        self.previewCache = previewCache
        // When a streaming attempt fails/times out, the controller asks us to full-download instead.
        video.onNeedsDownloadFallback = { [weak self] uid in
            guard let self, self.current.uid == uid else { return }
            let item = self.current
            Task { await self.downloadOriginal(for: item, expecting: .video) }
        }
    }

    public func toggleInfo() {
        showInfo.toggle()
        if showInfo { loadMetadata() }
    }

    /// Loads metadata for the current item (only while the panel is open). Cancels on navigation.
    private func loadMetadata() {
        metadataTask?.cancel()
        guard let metadataProvider else { return }
        let item = current
        metadata = nil
        metadataTask = Task { [metadataProvider] in
            let meta = try? await metadataProvider.metadata(for: item.uid)
            guard !Task.isCancelled, self.current == item else { return }
            self.metadata = meta
        }
    }

    public var current: PhotoItem { items[index] }
    public var canGoNext: Bool { index < items.count - 1 }
    public var canGoPrevious: Bool { index > 0 }

    public func start() { loadCurrent() }

    /// Called when the viewer closes: cancels any in-flight load and tears the player down so closing
    /// stops playback/audio immediately and cancels unnecessary streaming/download work.
    public func stop() {
        loadTask?.cancel()
        metadataTask?.cancel()
        video.teardown()
    }

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

    /// In-memory cache of already-loaded full-resolution images (shared across viewer instances) so
    /// reopening / re-navigating to a photo is instant and never re-shows the spinner.
    private static let fullImageCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>(); c.countLimit = 40; return c
    }()
    private static func cacheKey(_ uid: PhotoUID) -> NSString { "\(uid.volumeID)~\(uid.nodeID)" as NSString }

    private func loadCurrent() {
        loadTask?.cancel()
        video.reset()
        let item = current
        originalProgress = 0
        isLoadingOriginal = false
        if showInfo { loadMetadata() }   // keep the open panel in sync when navigating

        // Instant: if we already have the sharp original cached, show it — no spinner, no network.
        if let cached = Self.fullImageCache.object(forKey: Self.cacheKey(item.uid)) {
            image = cached
            isSharp = true
            return
        }
        // Otherwise show the thumbnail synchronously (so rapid arrow navigation always shows SOMETHING
        // immediately), and defer the heavy load so flicking past photos doesn't fire a network
        // storm — only the photo you actually land on loads its preview/original.
        image = feed.memoryImage(for: item.uid)
        isSharp = false

        loadTask = Task {
            try? await Task.sleep(for: .milliseconds(160))   // debounce: skip work for photos flicked past
            guard !Task.isCancelled, self.current == item else { return }

            if self.image == nil, let thumb = await self.feed.image(for: item.uid), self.current == item {
                self.image = thumb
            }
            // Larger preview for a crisper interim image (disk-cached for offline browsing).
            if let previewData = await self.loadPreview(item.uid),
               let preview = NSImage(data: previewData), !Task.isCancelled, self.current == item {
                self.image = preview
            }
            guard !Task.isCancelled, self.current == item else { return }

            await self.resolveMedia(for: item)
        }
    }

    /// Preview bytes, disk-cached: serves the offline `previews` derivative if present, else fetches
    /// and persists it. Keeps the viewer browseable offline and avoids re-downloading previews.
    private func loadPreview(_ uid: PhotoUID) async -> Data? {
        if let cache = previewCache, let data = cache.diskData(for: uid) { return data }
        guard let data = try? await media.preview(for: uid) else { return nil }
        previewCache?.storeToDisk(data, for: uid)
        return data
    }

    // MARK: - Media resolution (image vs video)

    /// Routes the settled item to the right media path. Whenever a streamer is available we try to
    /// resolve the item as a *stream first*, because `makeStreamingAsset` performs the real
    /// image-vs-video detection (a cheap link-metadata fetch that throws `.notAVideo` for images
    /// before any key work). This is the fix for the reported bug: the main "All Photos" timeline
    /// reports every item as `image/jpeg` (the SDK doesn't surface the type), so the old `if
    /// item.isVideo` gate never streamed those videos — it force-downloaded the whole file and then
    /// got stuck. Now real videos stream regardless of the timeline's lie, and images fall straight
    /// through to the (unchanged) image path.
    private func resolveMedia(for item: PhotoItem) async {
        guard let streamer else {
            await downloadOriginal(for: item, expecting: item.isVideo ? .video : .unknown)
            return
        }
        video.setResolving()
        logViewer(item, strategy: "resolving", kind: nil)
        do {
            let stream = try await streamer.makeStreamingAsset(for: item.uid)
            guard !Task.isCancelled, self.current == item else { return }
            isLoadingOriginal = false
            logViewer(item, strategy: "range", kind: .video)
            video.playStreaming(asset: stream.asset, retaining: stream, uid: item.uid)
        } catch is VideoStreamError {
            // Server MIME says it isn't a video → it's an image. Use the image path.
            guard !Task.isCancelled, self.current == item else { return }
            video.reset()
            logViewer(item, strategy: "image", kind: .image)
            await downloadOriginal(for: item, expecting: .image)
        } catch {
            // A real video (or unknown) whose stream setup failed → full-download fallback.
            guard !Task.isCancelled, self.current == item else { return }
            video.reset()
            await downloadOriginal(for: item, expecting: item.isVideo ? .video : .unknown)
        }
    }

    private enum Expecting { case unknown, image, video }

    /// Downloads the original to a local file, reporting real progress, then renders it: a decodable
    /// image is shown sharp; anything else is handed to the video controller (which sniffs/﻿wraps the
    /// extensionless temp file so AVFoundation opens it reliably).
    private func downloadOriginal(for item: PhotoItem, expecting: Expecting) async {
        isLoadingOriginal = true
        if expecting == .video { video.setDownloading(0) }
        let ref = WeakViewerRef(self)
        do {
            let url = try await media.downloadOriginal(for: item.uid) { p in
                Task { @MainActor in ref.model?.updateDownloadProgress(p, for: item) }
            }
            guard !Task.isCancelled, self.current == item else { return }
            isLoadingOriginal = false
            if expecting != .video, let full = NSImage(contentsOf: url) {
                image = full
                isSharp = true
                video.reset()
                Self.fullImageCache.setObject(full, forKey: Self.cacheKey(item.uid))
            } else {
                let playable = Self.fileWithVideoExtension(url)
                logViewer(item, strategy: "fullDownload", kind: .video)
                video.playLocalFile(url: playable, uid: item.uid)
            }
        } catch is CancellationError {
            isLoadingOriginal = false
        } catch {
            isLoadingOriginal = false
            if expecting == .video {
                video.fail(.classify(error), uid: item.uid)
                logViewer(item, strategy: "fullDownload", kind: .video)
            }
            // Image case: keep showing the best interim image (thumbnail/preview).
        }
    }

    /// Re-runs resolution for the current item (the "Retry" button in the failure overlay).
    public func retry() {
        guard current.isVideo || videoState.error != nil else { return }
        loadCurrent()
    }

    /// Pushes real download progress into the state (used by the `@Sendable` progress callback via a
    /// weak box, so the callback never captures the non-Sendable view model directly).
    private func updateDownloadProgress(_ p: Double, for item: PhotoItem) {
        guard current == item else { return }
        originalProgress = p
        if case .downloading = videoState { video.setDownloading(p) }
    }

    private func logViewer(_ item: PhotoItem, strategy: String, kind: MediaKind?) {
        PhotoDiagnostics.shared.emit("VideoViewer", videoViewerLogFields(
            uid: item.uid,
            mime: item.mediaType,
            detectedKind: kind,
            state: videoState,
            strategy: strategy,
            localURLExists: false,
            assetPlayable: player?.currentItem?.asset.isPlayable ?? false,
            playerItemStatus: player?.currentItem?.status.rawValue ?? 0,
            error: nil
        ))
    }

    /// AVFoundation opens extensionless local files unreliably. Sniff the ISO-BMFF `ftyp` brand and
    /// hand back a sibling URL with the right extension (copying once), so playback is deterministic.
    private static func fileWithVideoExtension(_ url: URL) -> URL {
        guard url.pathExtension.isEmpty else { return url }
        let head = (try? FileHandle(forReadingFrom: url))
            .flatMap { handle -> Data? in defer { try? handle.close() }; return try? handle.read(upToCount: 12) }
        let ext = head.flatMap(VideoContentSniffer.videoExtension(forHeader:)) ?? "mov"
        let dest = url.appendingPathExtension(ext)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        return FileManager.default.fileExists(atPath: dest.path) ? dest : url
    }
}

/// Sendable weak handle to the (MainActor, non-Sendable) view model, so the AVFoundation progress +
/// KVO `@Sendable` callbacks can route back to it without capturing it directly under Swift 6
/// concurrency. All access happens inside a `@MainActor` Task.
private final class WeakViewerRef: @unchecked Sendable {
    weak var model: PhotoViewerModel?
    init(_ model: PhotoViewerModel) { self.model = model }
}
