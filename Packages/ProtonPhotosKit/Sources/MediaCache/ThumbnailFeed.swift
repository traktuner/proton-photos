import Foundation
import AppKit
import ImageIO
import PhotosCore

/// Drives thumbnail loading for the whole library:
///  • a background prefetch that streams every thumbnail to disk as fast as the SDK allows,
///  • per-cell decode (downsampled, bounded in memory) for smooth scrolling.
///
/// Cells call `image(for:)`; the prefetch keeps the disk cache warm so most reads are instant.
public actor ThumbnailFeed {
    private let cache: ThumbnailCache
    private let loader: ThumbnailBatchLoader
    private let decoded = NSCache<NSString, NSImage>()
    private var inFlight: [PhotoUID: Task<NSImage?, Never>] = [:]
    private var prefetchTask: Task<Void, Never>?

    /// Ordered queue of thumbnails still to fetch. Workers pop from the front; `focus(_:)`
    /// prepends the on-screen window so scrolling instantly reprioritises that region.
    private var pending: [PhotoUID] = []
    private var workersRunning = false
    private nonisolated let concurrency: Int
    private nonisolated let batch: Int

    /// Pixel size we decode grid thumbnails to (≈ cell size × scale). Keeps memory + decode low.
    private let targetPixels: CGFloat

    public init(
        cache: ThumbnailCache,
        loader: ThumbnailBatchLoader,
        targetPixels: CGFloat = 320,
        concurrency: Int = 12,
        batch: Int = 40
    ) {
        self.cache = cache
        self.loader = loader
        self.targetPixels = targetPixels
        self.concurrency = concurrency
        self.batch = batch
        decoded.countLimit = 1500
    }

    /// Returns a decoded thumbnail, loading it on demand if the prefetch hasn't reached it yet.
    public func image(for uid: PhotoUID) async -> NSImage? {
        let key = Self.key(uid)
        if let img = decoded.object(forKey: key) { return img }

        if let data = await cache.data(for: uid), let img = Self.downsample(data, max: targetPixels) {
            decoded.setObject(img, forKey: key)
            return img
        }
        if let existing = inFlight[uid] { return await existing.value }

        let task = Task { () -> NSImage? in
            let box = ByteBox()
            await loader.loadThumbnails(for: [uid]) { loadedUID, data in
                if loadedUID == uid { box.set(data) }
            }
            guard let bytes = box.value else { return nil }
            await cache.store(bytes, for: uid)
            let img = Self.downsample(bytes, max: targetPixels)
            if let img { decoded.setObject(img, forKey: key) }
            return img
        }
        inFlight[uid] = task
        let result = await task.value
        inFlight[uid] = nil
        return result
    }

    /// Begin background download of every thumbnail to disk (sequential order).
    public func startPrefetch(_ uids: [PhotoUID]) {
        pending = uids
        startWorkers()
    }

    /// Reprioritise: move the on-screen window (and look-ahead) to the front of the queue, so a
    /// scroll jump fetches what the user is now looking at before continuing the sequential fill.
    public func focus(_ uids: [PhotoUID]) {
        let fresh = uids.filter { !cache.has($0) }
        guard !fresh.isEmpty else { return }
        pending.insert(contentsOf: fresh, at: 0)
        startWorkers()
    }

    public func stopPrefetch() {
        prefetchTask?.cancel()
        workersRunning = false
        pending.removeAll()
    }

    private func startWorkers() {
        guard !workersRunning else { return }
        workersRunning = true
        prefetchTask = Task { [weak self] in
            guard let self else { return }
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< self.concurrency {
                    group.addTask { await self.worker() }
                }
            }
            await self.markWorkersStopped()
        }
    }

    private func markWorkersStopped() { workersRunning = false }

    private func worker() async {
        while !Task.isCancelled {
            guard let chunk = takeBatch() else {
                if pending.isEmpty { return }       // nothing left
                try? await Task.sleep(for: .milliseconds(250))
                continue
            }
            await loader.loadThumbnails(for: chunk) { uid, data in
                Task { await self.cache.store(data, for: uid) }
            }
        }
    }

    private func takeBatch() -> [PhotoUID]? {
        var out: [PhotoUID] = []
        while !pending.isEmpty, out.count < batch {
            let uid = pending.removeFirst()
            if !cache.has(uid) { out.append(uid) }
        }
        return out.isEmpty ? nil : out
    }

    // MARK: - Decoding

    /// Downsample with ImageIO — decodes straight to the target size without materialising the
    /// full-size bitmap, which keeps scrolling smooth and memory flat.
    private static func downsample(_ data: Data, max: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return NSImage(data: data)
        }
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
