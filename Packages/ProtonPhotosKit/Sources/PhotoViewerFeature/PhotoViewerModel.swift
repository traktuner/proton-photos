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
    /// The single AVPlayer used for video (streaming or downloaded). `nil` for images.
    public private(set) var player: AVPlayer?
    /// Explicit video lifecycle — the view shows progress / error from this.
    public private(set) var videoState: VideoViewerState = .idle
    /// Retains the streaming asset + its resource-loader delegate for as long as the player lives.
    private var streamingAsset: StreamingVideoAsset?
    private var statusObservation: NSKeyValueObservation?
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
        teardownPlayer()
        let item = current
        videoState = .idle
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

    /// Routes the settled item to the right media path:
    ///  • A *known* video (Videos tag / album, where `isVideo` is reliable) → range-streaming, so big
    ///    videos start almost immediately. Streaming failure falls back to a full download.
    ///  • Everything else → download the original and detect by content (`NSImage` decodes ⇒ image;
    ///    otherwise it's a video → AVPlayer). This is what fixes the reported bug: the main "All
    ///    Photos" timeline reports every item as `image/jpeg` (the SDK doesn't expose the type), so a
    ///    video there used to download, fail the image decode, and get stuck on a stalled %. The
    ///    image path is unchanged (no extra network probe), so browsing photos doesn't regress.
    private func resolveMedia(for item: PhotoItem) async {
        if item.isVideo, let streamer {
            videoState = .resolving
            log(item, localURLExists: false, assetPlayable: false, playerItemStatus: 0)
            do {
                let stream = try await streamer.makeStreamingAsset(for: item.uid)
                guard !Task.isCancelled, self.current == item else { return }
                startStreaming(stream, item: item)
                return
            } catch is VideoStreamError {
                videoState = .idle   // server says not a video after all — detect via download
            } catch {
                guard !Task.isCancelled, self.current == item else { return }
                await downloadOriginal(for: item, expecting: .unknown, streamingError: error.localizedDescription)
                return
            }
        }
        await downloadOriginal(for: item, expecting: .unknown, streamingError: nil)
    }

    private enum Expecting { case unknown, video }

    /// Downloads the original to a local file, reporting real progress, then renders it: a decodable
    /// image is shown sharp; anything else is treated as a video and handed to AVPlayer (with a
    /// sniffed extension so AVFoundation reliably opens the extensionless temp file).
    private func downloadOriginal(for item: PhotoItem, expecting: Expecting, streamingError: String?) async {
        isLoadingOriginal = true
        if expecting == .video { videoState = .downloading(0) }
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
                videoState = .idle
                Self.fullImageCache.setObject(full, forKey: Self.cacheKey(item.uid))
            } else {
                playLocalVideo(originalURL: url, item: item)
            }
        } catch is CancellationError {
            isLoadingOriginal = false
        } catch {
            isLoadingOriginal = false
            if expecting == .video {
                videoState = .failed(error.localizedDescription)
                log(item, state: .failed(error.localizedDescription),
                    localURLExists: false, assetPlayable: false, playerItemStatus: 2,
                    error: error.localizedDescription)
            }
            // Image case: keep showing the best interim image (thumbnail/preview).
        }
    }

    /// Pushes real download progress into the state (used by the `@Sendable` progress callback via a
    /// weak box, so the callback never captures the non-Sendable view model directly).
    private func updateDownloadProgress(_ p: Double, for item: PhotoItem) {
        guard current == item else { return }
        originalProgress = p
        if case .downloading = videoState { videoState = .downloading(p) }
    }

    // MARK: - Players

    private func startStreaming(_ stream: StreamingVideoAsset, item: PhotoItem) {
        streamingAsset = stream
        attachPlayer(AVPlayerItem(asset: stream.asset), item: item, isStreaming: true,
                     localURLExists: false, assetPlayable: stream.asset.isPlayable)
    }

    private func playLocalVideo(originalURL: URL, item: PhotoItem) {
        let playable = Self.fileWithVideoExtension(originalURL)
        let asset = AVURLAsset(url: playable)
        attachPlayer(AVPlayerItem(asset: asset), item: item, isStreaming: false,
                     localURLExists: FileManager.default.fileExists(atPath: playable.path),
                     assetPlayable: asset.isPlayable)
    }

    private func attachPlayer(_ playerItem: AVPlayerItem, item: PhotoItem, isStreaming: Bool,
                              localURLExists: Bool, assetPlayable: Bool) {
        isLoadingOriginal = false
        let player = AVPlayer(playerItem: playerItem)
        self.player = player
        videoState = .ready
        log(item, state: .ready, localURLExists: localURLExists, assetPlayable: assetPlayable,
            playerItemStatus: playerItem.status.rawValue)
        let ref = WeakViewerRef(self)
        statusObservation = playerItem.observe(\.status, options: [.new, .initial]) { observed, _ in
            let raw = observed.status.rawValue
            let err = observed.error?.localizedDescription
            Task { @MainActor in
                ref.model?.handlePlayerItemStatus(raw, error: err, item: item, isStreaming: isStreaming,
                                                  localURLExists: localURLExists, assetPlayable: assetPlayable)
            }
        }
        player.play()
    }

    private func handlePlayerItemStatus(_ raw: Int, error: String?, item: PhotoItem, isStreaming: Bool,
                                        localURLExists: Bool, assetPlayable: Bool) {
        guard self.current == item, self.player != nil else { return }
        guard let next = VideoPlayerItemStatus(rawValue: raw)?.nextState(error: error) else { return }
        switch next {
        case .playing:
            videoState = .playing
            player?.play()
            log(item, state: .playing, localURLExists: localURLExists, assetPlayable: assetPlayable, playerItemStatus: raw)
        case .failed(let message):
            log(item, state: .failed(message), localURLExists: localURLExists, assetPlayable: assetPlayable,
                playerItemStatus: raw, error: message)
            if isStreaming {
                // Streaming failed mid-flight → tear down and full-download the video instead.
                teardownPlayer()
                Task { await self.downloadOriginal(for: item, expecting: .video, streamingError: message) }
            } else {
                videoState = .failed(message)
            }
        default:
            break
        }
    }

    private func teardownPlayer() {
        statusObservation?.invalidate()
        statusObservation = nil
        player?.pause()
        player = nil
        streamingAsset = nil
    }

    private func log(_ item: PhotoItem, state: VideoViewerState? = nil, localURLExists: Bool,
                     assetPlayable: Bool, playerItemStatus: Int, error: String? = nil) {
        PhotoDiagnostics.shared.emit("VideoViewer", videoViewerLogFields(
            uid: item.uid,
            state: state ?? videoState,
            localURLExists: localURLExists,
            assetPlayable: assetPlayable,
            playerItemStatus: playerItemStatus,
            error: error
        ))
    }

    /// AVFoundation opens extensionless local files unreliably. Sniff the ISO-BMFF `ftyp` brand and
    /// hand back a sibling URL with the right extension (copying once), so playback is deterministic.
    private static func fileWithVideoExtension(_ url: URL) -> URL {
        guard url.pathExtension.isEmpty else { return url }
        let ext = sniffVideoExtension(url)
        let dest = url.appendingPathExtension(ext)
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.copyItem(at: url, to: dest)
        }
        return FileManager.default.fileExists(atPath: dest.path) ? dest : url
    }

    private static func sniffVideoExtension(_ url: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "mov" }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 12)) ?? Data()
        if head.count >= 12, let box = String(data: head.subdata(in: 4..<8), encoding: .ascii), box == "ftyp" {
            let brand = String(data: head.subdata(in: 8..<12), encoding: .ascii) ?? ""
            return brand.hasPrefix("qt") ? "mov" : "mp4"
        }
        return "mov"
    }
}

/// Sendable weak handle to the (MainActor, non-Sendable) view model, so the AVFoundation progress +
/// KVO `@Sendable` callbacks can route back to it without capturing it directly under Swift 6
/// concurrency. All access happens inside a `@MainActor` Task.
private final class WeakViewerRef: @unchecked Sendable {
    weak var model: PhotoViewerModel?
    init(_ model: PhotoViewerModel) { self.model = model }
}
