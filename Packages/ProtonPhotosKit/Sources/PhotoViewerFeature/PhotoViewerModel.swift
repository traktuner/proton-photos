import Foundation
import AppKit
import AVFoundation
import PhotosCore
import MediaCache

/// Drives the full-screen viewer with progressive quality (blur-up):
///  1. show the grid thumbnail instantly (blurred — it's small for full-screen),
///  2. swap to the larger preview when it arrives (disk-cached for offline),
    ///  3. swap to the full original (sharp) once decrypted into RAM.
///
/// Video (Deliverable 5) runs an explicit `VideoViewerState` machine instead of inferring "loading"
/// from a tangle of optionals: try range-streaming first (which also detects image-vs-video reliably
/// even though the main timeline reports every item as `image/jpeg`), observe `AVPlayerItem.status`,
    /// Streaming is the only video path: falling back to a decrypted local temp file is forbidden by the
    /// app-wide local E2EE rule. One `AVPlayer` is retained for the streaming path, so the view never
    /// re-creates the player on a redraw.
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

    // MARK: Live Photo motion clip
    // A SEPARATE, muted player for the paired motion video — preloaded the moment a Live Photo opens so hovering
    // the LIVE badge (or a force-click) plays it with NO delay, NO controls overlay, and NO black load gap. The
    // view crossfades this over the still (the "ghost" effect). Distinct from `video` (which is for real videos).
    public private(set) var motionPlayer: AVPlayer?
    /// True while the motion clip is playing — the view crossfades the motion layer in/out on this.
    public private(set) var isMotionPlaying = false
    private var motionLocalFileURL: URL?              // temp file backing the local-file motion player; deleted on teardown
    private var motionTask: Task<Void, Never>?
    private var motionEndObserver: NSObjectProtocol?

    /// Whether the info panel is open, and the metadata for the current item (loaded lazily).
    public var showInfo = false
    public private(set) var metadata: PhotoMetadata?

    /// Reverse-geocoded place/POI name for the current item's GPS, if any — drives the viewer top-bar
    /// "named location" headline. Resolved lazily (debounced) so flicking past photos doesn't geocode.
    public private(set) var placeName: String?

    private let feed: ThumbnailFeed
    private let media: FullMediaProvider
    private let streamer: VideoStreamProvider?
    private let metadataProvider: PhotoMetadataProvider?
    private let previewCache: ThumbnailCache?
    /// Encrypted disk cache for full-resolution ORIGINALS (offline library). Read before any download so a cached
    /// original is shown instantly even after relaunch; written after a successful load when `cacheOriginals` is
    /// on, then trimmed to `originalsCapBytes` (LRU). `nil` disables it entirely.
    private let originalsCache: ThumbnailCache?
    /// Whether to PERSIST newly-downloaded originals (the Offline Photo Library master switch). Reads always try
    /// the disk cache regardless — purging on disable is what removes them.
    private let cacheOriginals: Bool
    private let originalsCapBytes: Int64?
    private var loadTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var placeTask: Task<Void, Never>?

    public init(items: [PhotoItem], index: Int, feed: ThumbnailFeed, media: FullMediaProvider,
                streamer: VideoStreamProvider? = nil, metadataProvider: PhotoMetadataProvider? = nil,
                previewCache: ThumbnailCache? = nil, originalsCache: ThumbnailCache? = nil,
                cacheOriginals: Bool = false, originalsCapBytes: Int64? = nil) {
        self.items = items
        self.index = index
        self.feed = feed
        self.media = media
        self.streamer = streamer
        self.metadataProvider = metadataProvider
        self.previewCache = previewCache
        self.originalsCache = originalsCache
        self.cacheOriginals = cacheOriginals
        self.originalsCapBytes = originalsCapBytes
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

    /// Resolves the GPS → place-name headline for `item`. Debounced so rapid arrow navigation doesn't
    /// fire a metadata fetch + geocode for every photo flicked past; reuses already-loaded metadata when
    /// the info panel is open. Geocoded names are cached per coordinate in `PlaceNameResolver`.
    private func resolvePlaceName(for item: PhotoItem) {
        placeTask?.cancel()
        placeName = nil
        guard let metadataProvider else { return }
        placeTask = Task { [metadataProvider] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, self.current == item else { return }
            let meta: PhotoMetadata?
            if let loaded = self.metadata, self.current == item {
                meta = loaded
            } else {
                meta = try? await metadataProvider.metadata(for: item.uid)
            }
            guard !Task.isCancelled, self.current == item,
                  let meta, meta.hasLocation, let lat = meta.latitude, let lon = meta.longitude else { return }
            let name = await PlaceNameResolver.shared.placeName(latitude: lat, longitude: lon)
            guard !Task.isCancelled, self.current == item else { return }
            self.placeName = name
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
        placeTask?.cancel()
        video.teardown()
        teardownMotion()
    }

    // MARK: - Live Photo motion playback

    /// Live-Photo MOTION playback, re-enabled via a FULLY-DOWNLOADED LOCAL-FILE player (see `prepareMotion`).
    /// The previous STREAMING player attached a custom `AVAssetResourceLoader` on its own `DispatchQueue` — the
    /// likely trigger for the process-wide Swift-6.2 executor corruption (#76804) that crashed even Apple's own
    /// SwiftUI/AppKit frameworks (`_ButtonGesture` action dispatch) after a Live Photo was opened. A local-file
    /// `AVPlayer` has NO such custom loader/queue. If this STILL corrupts the executor (a crash on a button tap
    /// after opening a Live Photo), set it back to `false` — AVPlayer is then incompatible until the toolchain
    /// ships the #76804 fix (Xcode 26.2 line).
    static let livePhotoMotionPlaybackEnabled = true

    /// Preloads the paired motion clip — FULL download + decrypt to a local temp file, then a LOCAL-FILE
    /// `AVPlayer` (no streaming, no custom resource-loader queue). Hover/force-click are no-ops until
    /// `motionPlayer` is set (i.e. the clip finished downloading). No-op for non-Live items.
    private func prepareMotion(for item: PhotoItem) {
        teardownMotion()
        guard Self.livePhotoMotionPlaybackEnabled,
              item.isLivePhoto, let motionUID = item.relatedVideoUID else { return }
        // Inherits the model's `@MainActor` context, so the `@Observable` writes after the nonisolated download
        // land back on main (same pattern as `loadTask`).
        motionTask = Task {
            guard let data = try? await media.originalData(for: motionUID),
                  !Task.isCancelled, self.current == item else { return }
            // Play a LOCAL FILE — NOT the custom `protonvideo://` streaming asset. Write the decrypted bytes to a
            // unique temp file (cleaned up in `teardownMotion`).
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("proton-motion-\(motionUID.nodeID).mov")
            guard (try? data.write(to: url, options: .atomic)) != nil, !Task.isCancelled, self.current == item else { return }
            let player = AVPlayer(url: url)
            player.isMuted = true                                   // silent ghost preview (matches Apple's hover)
            player.actionAtItemEnd = .pause
            player.automaticallyWaitsToMinimizeStalling = false
            self.motionLocalFileURL = url
            self.motionPlayer = player
            // Preroll only once the item is ready (preroll throws otherwise); a local file is ready near-instantly.
            if let pi = player.currentItem {
                var tries = 0
                while pi.status == .unknown, !Task.isCancelled, tries < 50 {
                    try? await Task.sleep(for: .milliseconds(20)); tries += 1
                }
                if pi.status == .readyToPlay, !Task.isCancelled { player.preroll(atRate: 1) { _ in } }
            }
        }
    }

    /// Plays the motion clip ONCE from the start (hover the LIVE badge or force-click). Idempotent while playing.
    public func playMotion() {
        guard let player = motionPlayer, !isMotionPlaying else { return }
        isMotionPlaying = true
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        let ref = WeakViewerRef(self)
        motionEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: player.currentItem, queue: .main
        ) { _ in Task { @MainActor in ref.model?.stopMotion() } }
    }

    /// Stops the motion clip and crossfades back to the still (hover-out, or auto at end-of-clip).
    public func stopMotion() {
        guard isMotionPlaying else { return }
        isMotionPlaying = false
        motionPlayer?.pause()
        motionPlayer?.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        if let obs = motionEndObserver { NotificationCenter.default.removeObserver(obs); motionEndObserver = nil }
    }

    private func teardownMotion() {
        motionTask?.cancel(); motionTask = nil
        if let obs = motionEndObserver { NotificationCenter.default.removeObserver(obs); motionEndObserver = nil }
        motionPlayer?.pause()
        isMotionPlaying = false
        motionPlayer = nil
        if let url = motionLocalFileURL { try? FileManager.default.removeItem(at: url); motionLocalFileURL = nil }
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
        resolvePlaceName(for: item)      // top-bar POI headline (debounced; skips photos flicked past)
        prepareMotion(for: item)         // preload the Live Photo motion clip so hover/force-click is instant

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

            // Cached full original on disk (offline library) → show the SHARP image instantly and skip the
            // preview + download entirely. The disk read + AES-GCM decrypt + decode run OFF the main actor (the
            // blob can be tens of MB); only the assignment hops back. Instant even after relaunch / offline.
            if let oc = self.originalsCache {
                let uid = item.uid
                let cached = await Task.detached { oc.diskData(for: uid).flatMap { NSImage(data: $0) } }.value
                if let full = cached {
                    guard !Task.isCancelled, self.current == item else { return }
                    self.image = full
                    self.isSharp = true
                    oc.touch(uid)   // mark recently-used so the LRU cap keeps it
                    Self.fullImageCache.setObject(full, forKey: Self.cacheKey(uid))
                    return
                }
            }

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
            await loadOriginalBytes(for: item, expecting: item.isVideo ? .video : .unknown)
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
            await loadOriginalBytes(for: item, expecting: .image)
        } catch {
            // A real video (or unknown) whose stream setup failed stays failed rather than writing a
            // decrypted full-video temp file.
            guard !Task.isCancelled, self.current == item else { return }
            video.reset()
            if item.isVideo {
                video.fail(VideoPlaybackError.classify(error), uid: item.uid)
            } else {
                await loadOriginalBytes(for: item, expecting: .unknown)
            }
        }
    }

    private enum Expecting { case unknown, image, video }

    /// Decrypts the original into RAM, reporting real progress, then renders it if it is an image. Videos are
    /// never written to a decrypted local temp file; they must use the range-streaming path.
    private func loadOriginalBytes(for item: PhotoItem, expecting: Expecting) async {
        isLoadingOriginal = true
        if expecting == .video { video.setDownloading(0) }
        let ref = WeakViewerRef(self)
        do {
            let data = try await media.originalData(for: item.uid) { p in
                Task { @MainActor in ref.model?.updateDownloadProgress(p, for: item) }
            }
            guard !Task.isCancelled, self.current == item else { return }
            isLoadingOriginal = false
            if expecting != .video, let full = NSImage(data: data) {
                image = full
                isSharp = true
                video.reset()
                Self.fullImageCache.setObject(full, forKey: Self.cacheKey(item.uid))
                // Persist the original to the encrypted offline cache (off the main actor), then trim to the LRU
                // budget. Gated on the Offline Photo Library switch; the read path above always tries the cache.
                if cacheOriginals, let oc = originalsCache {
                    let uid = item.uid
                    let cap = originalsCapBytes
                    Task.detached { oc.storeToDisk(data, for: uid); if let cap { oc.enforceByteCap(cap) } }
                }
            } else {
                video.fail(.streamURLUnavailable, uid: item.uid)
                logViewer(item, strategy: "streamRequired", kind: .video)
            }
        } catch is CancellationError {
            isLoadingOriginal = false
        } catch {
            isLoadingOriginal = false
            if expecting == .video {
                video.fail(.classify(error), uid: item.uid)
                logViewer(item, strategy: "streamRequired", kind: .video)
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
            assetPlayable: player?.currentItem?.status == .readyToPlay,
            playerItemStatus: player?.currentItem?.status.rawValue ?? 0,
            error: nil
        ))
    }
}

/// Sendable weak handle to the (MainActor, non-Sendable) view model, so the AVFoundation progress +
/// KVO `@Sendable` callbacks can route back to it without capturing it directly under Swift 6
/// concurrency. All access happens inside a `@MainActor` Task.
private final class WeakViewerRef: @unchecked Sendable {
    weak var model: PhotoViewerModel?
    init(_ model: PhotoViewerModel) { self.model = model }
}
