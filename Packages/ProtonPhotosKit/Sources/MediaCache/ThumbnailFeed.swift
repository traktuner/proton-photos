import Foundation
import AppKit
import ImageIO
import PhotosCore

/// Loads thumbnails for the whole library with a single, bounded worker pool:
///  • on-screen cells call `requestPriority` + poll `cachedImage`, so what you're looking at is
///    fetched first (and a scroll jump instantly re-prioritises),
///  • the same workers fill the rest of the library sequentially in the background.
///
/// Crucially there is ONE bounded pool — visible cells do not each fire their own download, which
/// previously flooded the SDK and triggered rate-limiting/stalls.
public actor ThumbnailFeed {
    private nonisolated let cache: ThumbnailCache
    private nonisolated let loader: ThumbnailBatchLoader
    private nonisolated let aspects: AspectRegistry
    private let decoded = NSCache<NSString, NSImage>()
    private let targetPixels: CGFloat
    private nonisolated let concurrency: Int
    private nonisolated let batch: Int

    private var priority: [PhotoUID] = []           // requested by visible cells (newest first)
    private var prioritySet: Set<PhotoUID> = []
    private var sequential: [PhotoUID] = []         // background fill, in timeline order
    private var sequentialIndex = 0
    private var workersRunning = false
    private var workerTask: Task<Void, Never>?

    public init(
        cache: ThumbnailCache,
        loader: ThumbnailBatchLoader,
        aspects: AspectRegistry,
        targetPixels: CGFloat = 320,
        concurrency: Int = 10,
        batch: Int = 8
    ) {
        self.cache = cache
        self.loader = loader
        self.aspects = aspects
        self.targetPixels = targetPixels
        self.concurrency = concurrency
        self.batch = batch
        decoded.countLimit = 1500
    }

    // MARK: - Reads

    /// Cache-only lookup (decoded mem → disk → decode). Never triggers a network load.
    public func cachedImage(for uid: PhotoUID) -> NSImage? {
        let key = Self.key(uid)
        if let img = decoded.object(forKey: key) { return img }
        if let data = cache.diskData(for: uid), let img = Self.downsample(data, max: targetPixels) {
            decoded.setObject(img, forKey: key)
            aspects.record(uid, aspect: img.size.width / max(img.size.height, 1))
            return img
        }
        return nil
    }

    private func persist(_ data: Data, for uid: PhotoUID) { cache.storeToDisk(data, for: uid) }

    /// Visible cell asks for its thumbnail to be fetched soon. Cheap + idempotent.
    public func requestPriority(_ uid: PhotoUID) {
        guard !cache.has(uid), !prioritySet.contains(uid) else { return }
        priority.append(uid)
        prioritySet.insert(uid)
        if priority.count > 600 {                    // bound; drop oldest requests
            let dropCount = priority.count - 600
            for d in priority[0 ..< dropCount] { prioritySet.remove(d) }
            priority.removeFirst(dropCount)
        }
        startWorkers()
    }

    /// One-shot load for the viewer (cache-first, then a direct fetch).
    public func image(for uid: PhotoUID) async -> NSImage? {
        if let img = cachedImage(for: uid) { return img }
        let box = ByteBox()
        await loader.loadThumbnails(for: [uid]) { u, data in if u == uid { box.set(data) } }
        guard let data = box.value else { return nil }
        cache.storeToDisk(data, for: uid)
        let img = Self.downsample(data, max: targetPixels)
        if let img { decoded.setObject(img, forKey: Self.key(uid)) }
        return img
    }

    // MARK: - Prefetch

    public func startPrefetch(_ uids: [PhotoUID]) {
        sequential = uids
        sequentialIndex = 0
        startWorkers()
    }

    public func stopPrefetch() {
        workerTask?.cancel()
        workersRunning = false
        priority.removeAll(); prioritySet.removeAll(); sequential.removeAll()
    }

    private func startWorkers() {
        guard !workersRunning else { return }
        workersRunning = true
        workerTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< self.concurrency { group.addTask { await self.worker() } }
            }
            await self.workersStopped()
        }
    }

    private func workersStopped() { workersRunning = false }

    private func worker() async {
        while !Task.isCancelled {
            let chunk = takeBatch()
            if chunk.isEmpty {
                if priority.isEmpty && sequentialIndex >= sequential.count { return }
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            await Self.loadWithTimeout(chunk, loader: loader, cache: cache, seconds: 20)
        }
    }

    /// Run a batch download, but never let a slow/hung batch pin a worker: whichever finishes
    /// first (download or the timeout) wins, then the other is cancelled. Thumbnails that did
    /// arrive are already persisted via the callback; missing ones get retried later.
    private nonisolated static func loadWithTimeout(
        _ chunk: [PhotoUID],
        loader: ThumbnailBatchLoader,
        cache: ThumbnailCache,
        seconds: Double
    ) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await loader.loadThumbnails(for: chunk) { uid, data in
                    cache.storeToDisk(data, for: uid)
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
    }

    /// Priority requests first (newest visible wins), then the sequential background fill.
    private func takeBatch() -> [PhotoUID] {
        var out: [PhotoUID] = []
        while out.count < batch, let uid = priority.popLast() {
            prioritySet.remove(uid)
            if !cache.has(uid) { out.append(uid) }
        }
        while out.count < batch, sequentialIndex < sequential.count {
            let uid = sequential[sequentialIndex]
            sequentialIndex += 1
            if !cache.has(uid) && !out.contains(uid) { out.append(uid) }
        }
        return out
    }

    private func store(_ uid: PhotoUID, _ data: Data) {
        cache.storeToDisk(data, for: uid)
    }

    // MARK: - Decoding

    private static func downsample(_ data: Data, max: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return NSImage(data: data) }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSImage(data: data)
        }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    private static func key(_ uid: PhotoUID) -> NSString {
        "\(uid.volumeID)~\(uid.nodeID)" as NSString
    }
}

/// Thread-safe holder for collecting a thumbnail from the SDK's `@Sendable` callback.
private final class ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    func set(_ data: Data) { lock.withLock { bytes = data } }
    var value: Data? { lock.withLock { bytes } }
}
