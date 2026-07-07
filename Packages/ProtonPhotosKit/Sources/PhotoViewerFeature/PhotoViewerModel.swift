import Foundation
import AppKit
import AVFoundation
import PhotosCore
import MediaCache
import PhotoViewerCore

/// Drives the full-screen viewer with progressive quality (thumbnail → preview → original):
///  1. show the grid thumbnail instantly (soft - small image scaled up for full-screen),
///  2. swap to the larger preview when it arrives (disk-cached for offline),
///  3. crossfade to the full original (sharp) once decrypted into RAM.
///
/// Video playback uses an explicit `VideoViewerState` machine instead of inferring "loading" from a tangle
/// of optionals. Streaming is the only video path: falling back to a decrypted local temp file is forbidden
/// by the local E2EE rule. One `AVPlayer` is retained for the streaming path, so the view never re-creates
/// the player on a redraw.
@MainActor
@Observable
public final class PhotoViewerModel {
    public private(set) var items: [PhotoItem]
    public private(set) var index: Int

    /// Best image available so far for the current item.
    public private(set) var image: NSImage?
    /// True once the original (full-res) is shown - drives the crossfade reveal from the interim image.
    public private(set) var isSharp = false
    /// Owns the AVPlayer + the video state machine (streaming, watchdog, stall/buffer handling). The
    /// model decides *which* source to play; the controller decides *how it's going*.
    public let video: VideoPlaybackController
    /// The single AVPlayer used for video (streaming or downloaded). `nil` for images.
    public var player: AVPlayer? { video.player }
    /// Explicit video lifecycle - the view shows progress / error from this.
    public var videoState: VideoViewerState { video.state }
    /// Download progress (0…1) of the full original - used to show a progress indicator for big
    /// downloads instead of an indefinite spinner.
    public private(set) var originalProgress: Double = 0
    public private(set) var isLoadingOriginal = false

    // MARK: Live Photo motion clip
    /// The paired Live Photo motion clip's shared controller (single AVPlayer + play/stop state). The same
    /// controller drives the iOS viewer, so motion behavior - E2EE preload, instant playback, crossfade - is not
    /// forked per platform. See `LivePhotoMotionController`.
    public let motion = LivePhotoMotionController()
    /// The motion clip's player once fully preloaded, else nil (still loading / not a Live Photo / disabled).
    public var motionPlayer: AVPlayer? { motion.player }
    /// True while the motion clip is playing - the view crossfades the motion layer in/out on this.
    public var isMotionPlaying: Bool { motion.isPlaying }

    /// Whether the info panel is open, and the metadata for the current item (loaded lazily).
    public var showInfo = false
    public private(set) var metadata: PhotoMetadata?

    /// Reverse-geocoded place/POI name for the current item's GPS, if any - drives the viewer top-bar
    /// "named location" headline. Resolved lazily (debounced) so flicking past photos doesn't geocode.
    public private(set) var placeName: String?

    private let feed: ThumbnailFeed
    private let media: FullMediaProvider
    private let streamer: VideoStreamProvider?
    private let metadataProvider: PhotoMetadataProvider?
    private let placeNameResolver: (any PlaceNameResolving)?
    private let burstProvider: BurstGroupProvider?
    private let previewCache: ThumbnailCache?
    /// Encrypted disk cache for full-resolution ORIGINALS (offline library). Read before any download so a cached
    /// original is shown instantly even after relaunch; written after a successful load when `cacheOriginals` is
    /// on, then trimmed to `originalsCapBytes` (LRU). `nil` disables it entirely.
    private let originalsCache: ThumbnailCache?
    /// Whether to PERSIST newly-downloaded originals (the Offline Photo Library master switch). Reads always try
    /// the disk cache regardless - purging on disable is what removes them.
    private let cacheOriginals: Bool
    private let originalsCapBytes: Int64?
    private var loadTask: Task<Void, Never>?
    private var metadataTask: Task<Void, Never>?
    private var placeTask: Task<Void, Never>?
    private var burstTask: Task<Void, Never>?
    private var burstSelection = BurstSelectionModel()

    public var burstItems: [PhotoItem] { burstSelection.items }
    public var burstIndex: Int? { burstSelection.selectedIndex }
    public var isLoadingBurst: Bool { burstSelection.isLoading }
    public var burstLoadFailed: Bool { burstSelection.loadFailed }

    public init(items: [PhotoItem], index: Int, feed: ThumbnailFeed, media: FullMediaProvider,
                streamer: VideoStreamProvider? = nil, metadataProvider: PhotoMetadataProvider? = nil,
                placeNameResolver: (any PlaceNameResolving)? = nil,
                burstProvider: BurstGroupProvider? = nil,
                previewCache: ThumbnailCache? = nil, originalsCache: ThumbnailCache? = nil,
                cacheOriginals: Bool = false, originalsCapBytes: Int64? = nil) {
        self.items = items
        self.index = index
        self.feed = feed
        self.media = media
        self.streamer = streamer
        self.metadataProvider = metadataProvider
        self.placeNameResolver = placeNameResolver
        self.burstProvider = burstProvider
        self.previewCache = previewCache
        self.originalsCache = originalsCache
        self.cacheOriginals = cacheOriginals
        self.originalsCapBytes = originalsCapBytes
        self.video = VideoPlaybackController { event in
            PhotoDiagnostics.shared.emit(event.name, event.fields, throttleSeconds: event.throttleSeconds)
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
            guard !Task.isCancelled, self.isDisplaying(item) else { return }
            self.metadata = meta
        }
    }

    /// Resolves the GPS → place-name headline for `item`. Debounced so rapid arrow navigation doesn't
    /// fire a metadata fetch + geocode for every photo flicked past; reuses already-loaded metadata when
    /// the info panel is open. Geocoding is injected by the app/platform layer.
    private func resolvePlaceName(for item: PhotoItem) {
        placeTask?.cancel()
        placeName = nil
        guard let metadataProvider, let placeNameResolver else { return }
        placeTask = Task { [metadataProvider] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, self.isDisplaying(item) else { return }
            let meta: PhotoMetadata?
            if let loaded = self.metadata, self.isDisplaying(item) {
                meta = loaded
            } else {
                meta = try? await metadataProvider.metadata(for: item.uid)
            }
            guard !Task.isCancelled, self.isDisplaying(item),
                  let meta, meta.hasLocation, let lat = meta.latitude, let lon = meta.longitude else { return }
            let name = await placeNameResolver.placeName(latitude: lat, longitude: lon)
            guard !Task.isCancelled, self.isDisplaying(item) else { return }
            self.placeName = name
        }
    }

    public var baseCurrent: PhotoItem { items[index] }
    public var current: PhotoItem {
        burstSelection.current(fallback: baseCurrent)
    }
    public var canGoNext: Bool { index < items.count - 1 }
    public var canGoPrevious: Bool { index > 0 }
    public var canNavigateNext: Bool {
        burstSelection.canMoveNext || canGoNext
    }
    public var canNavigatePrevious: Bool {
        burstSelection.canMovePrevious || canGoPrevious
    }
    public var thumbnailFeed: ThumbnailFeed { feed }
    public var hasBurstFilmstrip: Bool { burstSelection.hasFilmstrip }
    public var exportItemsForDownload: [PhotoItem] {
        burstSelection.exportItems(current: current)
    }
    public var canDownloadCurrentSelection: Bool {
        !isLoadingBurst && !exportItemsForDownload.isEmpty
    }
    public var gridReturnCandidates: [PhotoItem] {
        burstSelection.gridReturnCandidates(current: current, base: baseCurrent)
    }
    private func isDisplaying(_ item: PhotoItem) -> Bool { current.uid == item.uid }
    private func isBaseCurrent(_ item: PhotoItem) -> Bool { baseCurrent.uid == item.uid }

    public func start() { loadCurrent() }

    /// Called when the viewer closes: cancels any in-flight load and tears the player down so closing
    /// stops playback/audio immediately and cancels unnecessary streaming/download work.
    public func stop() {
        loadTask?.cancel()
        burstTask?.cancel()
        metadataTask?.cancel()
        placeTask?.cancel()
        video.teardown()
        motion.teardown()
    }

    // MARK: - Live Photo motion playback

    /// Plays the paired motion clip (with sound) - both the LIVE-badge HOVER and the FORCE-CLICK call this. All
    /// the E2EE-safe preload/playback logic lives in the shared `LivePhotoMotionController`.
    public func playMotion() { motion.play() }

    /// Stops the motion clip and crossfades back to the still (hover-out, or auto at end-of-clip).
    public func stopMotion() { motion.stop() }

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

    /// Contextual keyboard/button navigation. A visible burst/series filmstrip is a nested selection, so
    /// left/right first move through series members; at the series edges they fall through to the adjacent
    /// library item, matching keyboard accessibility expectations for an active sub-selection.
    public func nextInContext() {
        if let selected = burstSelection.selectNext() {
            loadDisplayedItem(selected)
            return
        }
        next()
    }

    public func previousInContext() {
        if let selected = burstSelection.selectPrevious() {
            loadDisplayedItem(selected)
            return
        }
        previous()
    }

    public func selectBurstIndex(_ newIndex: Int) {
        guard let selected = burstSelection.selectIndex(newIndex) else { return }
        loadDisplayedItem(selected)
    }

    /// In-memory cache of already-loaded full-resolution images (shared across viewer instances) so
    /// reopening / re-navigating to a photo is instant and never re-shows the spinner.
    private static let fullImageCacheCountLimit = 8
    private static let fullImageCacheByteLimit = 512 * 1024 * 1024
    private static let fullImageCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = fullImageCacheCountLimit
        c.totalCostLimit = fullImageCacheByteLimit
        return c
    }()
    private static func cacheKey(_ uid: PhotoUID) -> NSString { "\(uid.volumeID)~\(uid.nodeID)" as NSString }

    private static func cacheFullImage(_ image: NSImage, for uid: PhotoUID) {
        fullImageCache.setObject(image, forKey: cacheKey(uid), cost: decodedImageCost(image))
    }

    /// Governor-driven memory-pressure response for the shared full-resolution viewer cache - the
    /// single most jetsam-prone RAM consumer. `scale` lowers the cost limit; `purge` drops every held
    /// decode now (a revisit re-decodes from disk/network - never a crash). Static + thread-safe
    /// NSCache, callable from the governor without touching a viewer instance.
    public static func applyMemoryPressure(scale: Double, purge: Bool) {
        let clamped = min(1, max(0, scale))
        fullImageCache.totalCostLimit = max(1, Int(Double(fullImageCacheByteLimit) * clamped))
        if purge { fullImageCache.removeAllObjects() }
    }

    private static func decodedImageCost(_ image: NSImage) -> Int {
        let representationCost = image.representations.map { rep -> Int in
            if let bitmap = rep as? NSBitmapImageRep, bitmap.bytesPerRow > 0, bitmap.pixelsHigh > 0 {
                return bitmap.bytesPerRow * bitmap.pixelsHigh
            }
            guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return 0 }
            return rep.pixelsWide * rep.pixelsHigh * 4
        }.max() ?? 0
        let fallbackCost = Int(max(1, image.size.width) * max(1, image.size.height) * 4)
        return max(1, representationCost, fallbackCost)
    }

    /// Wraps the Core `CGImage` decode as AppKit image. The heavy ImageIO decode still runs off the main actor.
    private nonisolated static func decodeFullImage(_ data: Data) -> NSImage? {
        guard let cg = PhotoPerformanceSignposts.viewer.interval("viewer.decode", {
            ViewerFullImageDecoder.decodeCGImage(data)
        }) else { return NSImage(data: data) }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private nonisolated static func decodePreviewImage(_ data: Data) -> NSImage? {
        guard let cg = ViewerFullImageDecoder.decodeCGImage(data) else { return NSImage(data: data) }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private func loadCurrent() {
        burstTask?.cancel()
        burstSelection.reset()
        let item = baseCurrent
        burstSelection.seedKnownGroup(for: item, libraryItems: items)
        loadDisplayedItem(item)
        loadBurstGroupIfNeeded(for: item)
    }

    private func loadDisplayedItem(_ item: PhotoItem) {
        loadTask?.cancel()
        video.reset()
        originalProgress = 0
        isLoadingOriginal = false
        if showInfo { loadMetadata() }   // keep the open panel in sync when navigating
        resolvePlaceName(for: item)      // top-bar POI headline (debounced; skips photos flicked past)
        // Preload the Live Photo motion clip so hover/force-click plays instantly - only while `item` stays current.
        motion.prepare(for: item, streamer: streamer) { [weak self] in self?.isDisplaying(item) ?? false }

        // Instant: if we already have the sharp original cached, show it - no spinner, no network.
        if let cached = Self.fullImageCache.object(forKey: Self.cacheKey(item.uid)) {
            image = cached
            isSharp = true
            return
        }
        // Otherwise show the thumbnail synchronously (so rapid arrow navigation always shows SOMETHING
        // immediately), and defer the heavy load so flicking past photos doesn't fire a network
        // storm - only the photo you actually land on loads its preview/original.
        image = feed.memoryImage(for: item.uid)
        isSharp = false

        loadTask = Task {
            try? await Task.sleep(for: .milliseconds(160))   // debounce: skip work for photos flicked past
            guard !Task.isCancelled, self.isDisplaying(item) else { return }

            // Cached full original on disk (offline library) → show the SHARP image instantly and skip the
            // preview + download entirely. The disk read + AES-GCM decrypt + decode run OFF the main actor (the
            // blob can be tens of MB); only the assignment hops back. Instant even after relaunch / offline.
            if let oc = self.originalsCache {
                let uid = item.uid
                let cached = await Task.detached { oc.diskData(for: uid).flatMap { Self.decodeFullImage($0) } }.value
                if let full = cached {
                    guard !Task.isCancelled, self.isDisplaying(item) else { return }
                    self.image = full
                    self.isSharp = true
                    oc.touch(uid)   // mark recently-used so the LRU cap keeps it
                    Self.cacheFullImage(full, for: uid)
                    return
                }
            }

            if self.image == nil, let thumb = await self.feed.image(for: item.uid), self.isDisplaying(item) {
                self.image = thumb
            }
            // Larger preview for a crisper interim image (disk-cached for offline browsing).
            if let preview = await self.loadPreviewImage(item.uid), !Task.isCancelled, self.isDisplaying(item) {
                self.image = preview
            }
            guard !Task.isCancelled, self.isDisplaying(item) else { return }

            await self.resolveMedia(for: item)
        }
    }

    private func loadBurstGroupIfNeeded(for item: PhotoItem) {
        guard let burstProvider, burstSelection.beginLoadingIfCandidate(item) else { return }
        burstTask = Task { [burstProvider] in
            do {
                let group = try await burstProvider.burstGroup(containing: item.uid)
                guard !Task.isCancelled, self.isBaseCurrent(item) else { return }
                self.burstSelection.applyLoadedGroup(group, containing: item)
            } catch {
                guard !Task.isCancelled, self.isBaseCurrent(item) else { return }
                self.burstSelection.failLoading()
            }
        }
    }

    /// Preview bytes, disk-cached: serves the offline `previews` derivative if present, else fetches
    /// and persists it. Keeps the viewer browseable offline and avoids re-downloading previews.
    private func loadPreviewImage(_ uid: PhotoUID) async -> NSImage? {
        if let cache = previewCache {
            let cached = await Task.detached(priority: .userInitiated) {
                cache.diskData(for: uid).flatMap { Self.decodePreviewImage($0) }
            }.value
            if let cached { return cached }
        }
        guard let data = try? await media.preview(for: uid) else { return nil }
        let preview = await Task.detached(priority: .userInitiated) {
            Self.decodePreviewImage(data)
        }.value
        if let previewCache {
            Task.detached(priority: .utility) {
                previewCache.storeToDisk(data, for: uid)
            }
        }
        return preview
    }

    // MARK: - Media resolution (image vs video)

    /// Routes the settled item to the right media path. Whenever a streamer is available we try to
    /// resolve the item as a *stream first*, because `makeStreamingAsset` performs the real
    /// image-vs-video detection (a cheap link-metadata fetch that throws `.notAVideo` for images
    /// before any key work). This is the fix for the reported bug: the main "All Photos" timeline
    /// reports every item as `image/jpeg` (the SDK doesn't surface the type), so the old `if
    /// item.isVideo` gate never streamed those videos - it force-downloaded the whole file and then
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
            guard !Task.isCancelled, self.isDisplaying(item) else { return }
            isLoadingOriginal = false
            logViewer(item, strategy: "range", kind: .video)
            video.playStreaming(asset: stream.asset, retaining: stream, uid: item.uid)
        } catch is VideoStreamError {
            // Server MIME says it isn't a video → it's an image. Use the image path.
            guard !Task.isCancelled, self.isDisplaying(item) else { return }
            video.reset()
            logViewer(item, strategy: "image", kind: .image)
            await loadOriginalBytes(for: item, expecting: .image)
        } catch {
            // A real video (or unknown) whose stream setup failed stays failed rather than writing a
            // decrypted full-video temp file.
            guard !Task.isCancelled, self.isDisplaying(item) else { return }
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
            guard !Task.isCancelled, self.isDisplaying(item) else { return }
            isLoadingOriginal = false
            // Decode the full original OFF the main actor so a large photo never rasterizes on the UI thread.
            let full = expecting != .video
                ? await Task.detached(priority: .userInitiated) { Self.decodeFullImage(data) }.value
                : nil
            guard !Task.isCancelled, self.isDisplaying(item) else { return }
            if let full {
                image = full
                isSharp = true
                video.reset()
                Self.cacheFullImage(full, for: item.uid)
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
        loadDisplayedItem(current)
    }

    /// Pushes real download progress into the state (used by the `@Sendable` progress callback via a
    /// weak box, so the callback never captures the non-Sendable view model directly).
    private func updateDownloadProgress(_ p: Double, for item: PhotoItem) {
        guard current.uid == item.uid else { return }
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
