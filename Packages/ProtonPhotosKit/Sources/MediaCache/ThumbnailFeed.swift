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
    private nonisolated(unsafe) let decoded = NSCache<NSString, NSImage>()  // NSCache is thread-safe
    private nonisolated let diskPresence = DiskPresenceCache()
    private let targetPixels: CGFloat
    private nonisolated let concurrency: Int
    private nonisolated let batch: Int

    private var priority: [PhotoUID] = []           // requested by visible cells (newest first)
    private var priorityByUID: [PhotoUID: ThumbnailPriority] = [:]
    private var sequential: [PhotoUID] = []         // background fill, in timeline order
    private var sequentialIndex = 0
    private var workersRunning = false
    private var workerTask: Task<Void, Never>?
    private var interactionActive = false
    private var decodeInFlight = 0
    private var downloadInFlight = 0
    private var lastErrors: [String] = []
    private var prefetchEnabled = true
    private var prefetchPaused = false
    private var checkpointKey: String?
    private var prefetchCompleted = 0
    private var prefetchFailed = 0
    private var prefetchDiskHit = 0
    private var prefetchDownloadStarted = 0
    private var prefetchDownloadCompleted = 0
    private var prefetchDecodeStarted = 0
    private var prefetchDecodeCompleted = 0

    // Background-crawl yield (app-level starvation mitigation — see PROTONPHOTOS_… security report). The
    // sequential crawl shares one rate-limit gate + URLSession with visible thumbnail loads, so a heavy
    // crawl can trip a 429 that stalls what's on screen. We therefore PAUSE the sequential crawl (never the
    // priority queue) while there is recent visible demand or just after a rate-limited/empty batch.
    private let clock: @Sendable () -> Date
    private var lastDemandAt: Date?            // last non-idle (visible/near-viewport) thumbnail request
    private var crawlBackoffUntil: Date?       // sequential crawl suspended until this instant after a 429/empty batch
    private nonisolated let visibleQuietWindow: TimeInterval = 0.25
    private nonisolated let crawlBackoffSeconds: TimeInterval = 5

    public init(
        cache: ThumbnailCache,
        loader: ThumbnailBatchLoader,
        aspects: AspectRegistry,
        targetPixels: CGFloat = 320,
        concurrency: Int = 10,
        batch: Int = 8,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.cache = cache
        self.loader = loader
        self.aspects = aspects
        self.targetPixels = targetPixels
        self.concurrency = concurrency
        self.batch = batch
        self.clock = clock
        decoded.countLimit = 1500
    }

    // MARK: - Reads

    /// Cache-only lookup (decoded mem → disk → decode). Never triggers a network load.
    public func cachedImage(for uid: PhotoUID) -> NSImage? {
        let key = Self.key(uid)
        if let img = decoded.object(forKey: key) {
            PhotoDiagnostics.shared.increment("thumb.ramDecodedHit")
            return img
        }
        PhotoDiagnostics.shared.increment("thumb.ramDecodeMiss")
        PhotoDiagnostics.shared.recordDiskReadDuringPinch()
        if let data = cache.diskData(for: uid) {
            diskPresence.set(uid, present: true)
            PhotoDiagnostics.shared.increment("thumb.diskCacheHit")
            guard let img = decode(data, for: uid) else { return nil }
            decoded.setObject(img, forKey: key)
            aspects.record(uid, aspect: img.size.width / max(img.size.height, 1))
            return img
        }
        diskPresence.set(uid, present: false)
        PhotoDiagnostics.shared.increment("thumb.diskCacheMiss")
        return nil
    }

    /// Synchronous in-memory lookup (decoded NSCache only — no actor hop, no disk). Lets a cell show
    /// an already-decoded thumbnail INSTANTLY without flickering to blank during a live re-justify.
    public nonisolated func memoryImage(for uid: PhotoUID) -> NSImage? {
        decoded.object(forKey: Self.key(uid))
    }

    public nonisolated func knownDiskThumbnailPresent(for uid: PhotoUID) -> Bool? {
        diskPresence.value(for: uid)
    }

    private func persist(_ data: Data, for uid: PhotoUID) { cache.storeToDisk(data, for: uid) }

    public func cacheState(for request: ThumbnailRequest, gpuTextureResident: Bool = false) -> ThumbnailCacheTierState {
        let diskThumbnail = cache.has(request.uid)
        diskPresence.set(request.uid, present: diskThumbnail)
        return ThumbnailCacheTierState(
            knownInTimeline: true,
            diskThumbnail: diskThumbnail,
            ramDecoded: decoded.object(forKey: Self.key(request.uid)) != nil,
            gpuTexture: gpuTextureResident
        )
    }

    public func thumbnailHealth(for uids: [PhotoUID], gpuResident: Set<PhotoUID> = []) -> ThumbnailHealthSnapshot {
        var real = 0
        var disk = 0
        var missingDisk = 0
        var gpuHit = 0
        var gpuMiss = 0
        for uid in uids {
            if decoded.object(forKey: Self.key(uid)) != nil { real += 1 }
            if cache.has(uid) {
                diskPresence.set(uid, present: true)
                disk += 1
            } else {
                diskPresence.set(uid, present: false)
                missingDisk += 1
            }
            if gpuResident.contains(uid) { gpuHit += 1 } else { gpuMiss += 1 }
        }
        return ThumbnailHealthSnapshot(
            visibleCellCount: uids.count,
            realThumbnailCount: real,
            missingDiskCount: missingDisk,
            missingNetworkCount: missingDisk,
            decodeInFlightCount: decodeInFlight,
            downloadInFlightCount: downloadInFlight,
            diskCacheHitCount: disk,
            ramDecodedHitCount: real,
            gpuTextureHitCount: gpuHit,
            gpuTextureMissCount: gpuMiss
        )
    }

    /// Visible cell asks for its thumbnail to be fetched soon. Cheap + idempotent.
    public func requestPriority(_ uid: PhotoUID, priority requestedPriority: ThumbnailPriority = .visibleNow) {
        // Any non-idle request is live visible demand: mark it so the sequential crawl yields the shared
        // rate-limit budget to on-screen work (it resumes `visibleQuietWindow` after demand goes quiet).
        if requestedPriority != .idleLibraryCrawl { lastDemandAt = clock() }
        PhotoDiagnostics.shared.recordDiskPresenceCheckDuringPinch()
        let diskHit = cache.hasUsableDiskData(uid)   // skip the network ONLY for a decryptable blob
        diskPresence.set(uid, present: diskHit)
        guard !diskHit else {
            PhotoDiagnostics.shared.increment("thumb.diskCacheHit")
            return
        }
        PhotoDiagnostics.shared.increment("thumb.diskCacheMiss")
        if let existing = priorityByUID[uid] {
            if requestedPriority < existing {
                priorityByUID[uid] = requestedPriority
                PhotoDiagnostics.shared.increment("thumb.priorityUpgrade")
            }
            return
        }
        priority.append(uid)
        priorityByUID[uid] = requestedPriority
        if priority.count > 600 {                    // bound; drop oldest requests
            let dropCount = priority.count - 600
            for d in priority[0 ..< dropCount] { priorityByUID.removeValue(forKey: d) }
            priority.removeFirst(dropCount)
        }
        startWorkers()
    }

    /// Force a bounded set of thumbnails into the *decoded* in-memory cache so a synchronous
    /// `memoryImage(for:)` will hit. `requestPriority`/`cachedImage` are not enough for the zoom
    /// overlay: a thumbnail can be on disk yet absent from RAM (so the overlay treats it as missing),
    /// and `requestPriority` deliberately skips anything already on disk (`cache.has`) — it only drives
    /// *network* fetches, never disk→RAM decode. This fills that gap.
    ///
    /// For each uid: count it if already decoded; else read+downsample the disk thumbnail into the
    /// decoded cache; else queue a network priority fetch (non-blocking). The decode runs on the actor
    /// (like `cachedImage`), never on the main thread, and is bounded by `limit` so it can't stall the
    /// pinch's priority traffic for long.
    public func warmDecoded(
        _ requests: [ThumbnailRequest],
        priority requestedPriority: ThumbnailPriority,
        limit: Int
    ) async -> WarmDecodedResult {
        let targets = Array(requests.prefix(max(0, limit)))
        var alreadyDecoded = 0, decodedFromDisk = 0, queuedNetwork = 0, missing = 0, mainThreadDecodeCount = 0
        for request in targets {
            let uid = request.uid
            let key = Self.key(uid)
            if decoded.object(forKey: key) != nil {
                PhotoDiagnostics.shared.increment("thumb.ramDecodedHit")
                alreadyDecoded += 1
                continue
            }
            PhotoDiagnostics.shared.increment("thumb.ramDecodeMiss")
            PhotoDiagnostics.shared.recordDiskReadDuringPinch()
            if let data = cache.diskData(for: uid) {
                diskPresence.set(uid, present: true)
                PhotoDiagnostics.shared.increment("thumb.diskCacheHit")
                let img = decode(data, for: uid)
                guard let img else {
                    missing += 1
                    continue
                }
                decoded.setObject(img, forKey: key)
                aspects.record(uid, aspect: img.size.width / max(img.size.height, 1))
                decodedFromDisk += 1
            } else if cache.hasUsableDiskData(uid) {
                diskPresence.set(uid, present: true)
                PhotoDiagnostics.shared.increment("thumb.diskCacheHit")
                missing += 1   // on disk but undecodable (corrupt/partial) — rare (diskData already drops it)
            } else {
                diskPresence.set(uid, present: false)
                PhotoDiagnostics.shared.increment("thumb.diskCacheMiss")
                requestPriority(uid, priority: requestedPriority)   // not on disk yet; queue network, do not block pinch
                queuedNetwork += 1
            }
        }
        let result = WarmDecodedResult(
            requested: targets.count,
            alreadyDecoded: alreadyDecoded,
            decodedFromDisk: decodedFromDisk,
            queuedNetwork: queuedNetwork,
            missing: missing,
            mainThreadDecodeCount: mainThreadDecodeCount
        )
        return result
    }

    public func warmDecoded(_ uids: [PhotoUID], limit: Int = 160) async -> WarmDecodedResult {
        await warmDecoded(
            uids.map { ThumbnailRequest(uid: $0, pixelSize: Int(targetPixels)) },
            priority: .zoomAnchorAndFocusRow,
            limit: limit
        )
    }

    public func warmTextures(
        _ requests: [ThumbnailRequest],
        priority requestedPriority: ThumbnailPriority,
        limit: Int
    ) async -> WarmTextureResult {
        let decodedResult = await warmDecoded(requests, priority: requestedPriority, limit: limit)
        return WarmTextureResult(
            requested: decodedResult.requested,
            alreadyResident: 0,
            decodedWarmed: decodedResult.alreadyDecoded + decodedResult.decodedFromDisk,
            uploadQueued: 0,
            missing: decodedResult.queuedNetwork + decodedResult.missing
        )
    }

    /// One-shot load for the viewer (cache-first, then a direct fetch).
    public func image(for uid: PhotoUID) async -> NSImage? {
        if let img = cachedImage(for: uid) { return img }
        let box = ByteBox()
        PhotoDiagnostics.shared.recordNetworkRequestDuringPinch()
        await loader.loadThumbnails(for: [uid]) { u, data in if u == uid { box.set(data) } }
        guard let data = box.value else { return nil }
        cache.storeToDisk(data, for: uid)
        let img = decode(data, for: uid)
        if let img { decoded.setObject(img, forKey: Self.key(uid)) }
        return img
    }

    // MARK: - Prefetch

    public func startPrefetch(_ uids: [PhotoUID]) {
        guard prefetchEnabled else { return }
        sequential = uids
        checkpointKey = Self.checkpointKey(for: uids)
        sequentialIndex = checkpointKey.flatMap { UserDefaults.standard.object(forKey: $0) as? Int } ?? 0
        sequentialIndex = min(max(sequentialIndex, 0), sequential.count)
        startWorkers()
    }

    public func stopPrefetch() {
        workerTask?.cancel()
        workersRunning = false
        priority.removeAll(); priorityByUID.removeAll(); sequential.removeAll()
    }

    public func setPrefetchEnabled(_ enabled: Bool) {
        prefetchEnabled = enabled
        if !enabled { stopPrefetch() }
    }

    public func pausePrefetch() {
        prefetchPaused = true
    }

    public func resumePrefetch() {
        prefetchPaused = false
        startWorkers()
    }

    public func setUserInteractionActive(_ active: Bool) {
        interactionActive = active
    }

    public struct PrefetchStatus: Sendable, Equatable {
        public let enabled: Bool
        public let paused: Bool
        public let diskThumbnailCoveragePercent: Double
        public let currentQueueLength: Int
        public let downloadsInFlight: Int
        public let decodesInFlight: Int
        public let lastErrors: [String]
        public let cacheSizeBytes: Int64
        public let diskFileCount: Int
        public let activeJobs: Int
        public let completed: Int
        public let failed: Int
        public let diskHit: Int
        public let downloadStarted: Int
        public let downloadCompleted: Int
        public let decodeStarted: Int
        public let decodeCompleted: Int
        public let pausedReason: String
    }

    public func prefetchStatus() -> PrefetchStatus {
        let coverage = cache.diskCoverage(for: sequential)
        let pausedReason: String
        if !prefetchEnabled {
            pausedReason = "disabled"
        } else if prefetchPaused {
            pausedReason = "manual"
        } else if interactionActive {
            pausedReason = "interaction"
        } else {
            pausedReason = "none"
        }
        return PrefetchStatus(
            enabled: prefetchEnabled,
            paused: prefetchPaused || interactionActive,
            diskThumbnailCoveragePercent: coverage.percent,
            currentQueueLength: priority.count + max(0, sequential.count - sequentialIndex),
            downloadsInFlight: downloadInFlight,
            decodesInFlight: decodeInFlight,
            lastErrors: lastErrors,
            cacheSizeBytes: cache.diskSizeBytes(),
            diskFileCount: cache.diskFileCount(),
            activeJobs: downloadInFlight + decodeInFlight,
            completed: prefetchCompleted,
            failed: prefetchFailed,
            diskHit: prefetchDiskHit,
            downloadStarted: prefetchDownloadStarted,
            downloadCompleted: prefetchDownloadCompleted,
            decodeStarted: prefetchDecodeStarted,
            decodeCompleted: prefetchDecodeCompleted,
            pausedReason: pausedReason
        )
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

    private func workersStopped() {
        workersRunning = false
        // Close a lost-wakeup window: `startWorkers()` reaches `workersStopped()` via an `await`
        // suspension, so a `requestPriority`/`startPrefetch` that enqueued work during the task-group
        // teardown would have seen `workersRunning == true` and skipped starting a worker. Re-check and
        // relaunch so the last-requested thumbnail is never stranded. (Workers only return when the queues
        // are drained, so this restarts strictly when new work arrived in the gap — no spin.)
        if !priority.isEmpty || sequentialIndex < sequential.count { startWorkers() }
    }

    private func worker() async {
        while !Task.isCancelled {
            let chunk = takeBatch()
            if chunk.isEmpty {
                if priority.isEmpty && sequentialIndex >= sequential.count { return }
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            downloadInFlight += chunk.count
            prefetchDownloadStarted += chunk.count
            PhotoDiagnostics.shared.recordNetworkRequestDuringPinch()
            let completed = await Self.loadWithTimeout(chunk, loader: loader, cache: cache, diskPresence: diskPresence, seconds: 20)
            downloadInFlight = max(0, downloadInFlight - chunk.count)
            prefetchCompleted += completed
            prefetchDownloadCompleted += completed
            let failed = max(0, chunk.count - completed)
            prefetchFailed += failed
            if completed == 0, !chunk.isEmpty {
                recordError("thumbnail fetch returned 0/\(chunk.count) (network or rate-limit)")
                // Likely rate-limited: back the sequential crawl off so it stops compounding the 429 and
                // hurting visible loads. Priority/visible work continues (takeBatch drains it regardless).
                crawlBackoffUntil = clock().addingTimeInterval(crawlBackoffSeconds)
            }
            if let checkpointKey, sequentialIndex > 0 {
                UserDefaults.standard.set(sequentialIndex, forKey: checkpointKey)
            }
            emitPrefetchSummary()
        }
    }

    /// Run a batch download, but never let a slow/hung batch pin a worker: whichever finishes
    /// first (download or the timeout) wins, then the other is cancelled. Thumbnails that did
    /// arrive are already persisted via the callback; missing ones get retried later.
    private nonisolated static func loadWithTimeout(
        _ chunk: [PhotoUID],
        loader: ThumbnailBatchLoader,
        cache: ThumbnailCache,
        diskPresence: DiskPresenceCache,
        seconds: Double
    ) async -> Int {
        let counter = IntBox()
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await loader.loadThumbnails(for: chunk) { uid, data in
                    cache.storeToDisk(data, for: uid)
                    diskPresence.set(uid, present: true)
                    counter.increment()
                }
            }
            group.addTask { try? await Task.sleep(for: .seconds(seconds)) }
            await group.next()
            group.cancelAll()
        }
        return counter.value
    }

    /// Priority requests first (newest visible wins), then the sequential background fill.
    private func takeBatch() -> [PhotoUID] {
        var out: [PhotoUID] = []
        while out.count < batch, !priority.isEmpty {
            let bestIndex = priority.indices.min {
                let lhs = priorityByUID[priority[$0]] ?? .idleLibraryCrawl
                let rhs = priorityByUID[priority[$1]] ?? .idleLibraryCrawl
                if lhs != rhs { return lhs < rhs }
                return $0 > $1
            } ?? priority.index(before: priority.endIndex)
            let uid = priority.remove(at: bestIndex)
            priorityByUID.removeValue(forKey: uid)
            PhotoDiagnostics.shared.recordDiskPresenceCheckDuringPinch()
            let diskHit = cache.hasUsableDiskData(uid)   // decryptable-only → corrupt blobs still refetch
            diskPresence.set(uid, present: diskHit)
            if !diskHit { out.append(uid) } else { prefetchDiskHit += 1 }
        }
        // Sequential background fill ONLY when the crawl isn't paused/disabled, there's no recent visible
        // demand, and we're not in a post-429 backoff. The priority queue above is ALWAYS served — visible
        // fetches are never gated here.
        let now = clock()
        let recentDemand = lastDemandAt.map { now.timeIntervalSince($0) < visibleQuietWindow } ?? false
        let backingOff = crawlBackoffUntil.map { now < $0 } ?? false
        guard !interactionActive, !prefetchPaused, prefetchEnabled, !recentDemand, !backingOff else { return out }
        while out.count < batch, sequentialIndex < sequential.count {
            let uid = sequential[sequentialIndex]
            sequentialIndex += 1
            let diskHit = cache.hasUsableDiskData(uid)   // decryptable-only → corrupt blobs still refetch
            diskPresence.set(uid, present: diskHit)
            if !diskHit && !out.contains(uid) {
                out.append(uid)
            } else {
                prefetchDiskHit += 1
            }
        }
        return out
    }

    private func store(_ uid: PhotoUID, _ data: Data) {
        cache.storeToDisk(data, for: uid)
    }

    // MARK: - Decoding

    private func decode(_ data: Data, for uid: PhotoUID) -> NSImage? {
        prefetchDecodeStarted += 1
        decodeInFlight += 1
        PhotoDiagnostics.shared.recordDecodeStarted(queueDepth: decodeInFlight)
        let start = Date()
        let image = Self.downsample(data, max: targetPixels)
        let durationMs = Date().timeIntervalSince(start) * 1000
        decodeInFlight = max(0, decodeInFlight - 1)
        if let image {
            prefetchDecodeCompleted += 1
            PhotoDiagnostics.shared.recordDecodeCompleted(durationMs: durationMs, queueDepth: decodeInFlight)
            return image
        }
        PhotoDiagnostics.shared.increment("thumb.diskDecodeFailed")
        PhotoDiagnostics.shared.recordDecodeFailed(queueDepth: decodeInFlight)
        recordError("decode failed for \(Self.key(uid))")
        return nil
    }

    /// Keeps the most recent cache errors for the Developer/Cache status surface (last one shown).
    private func recordError(_ message: String) {
        lastErrors.append(message)
        if lastErrors.count > 10 { lastErrors.removeFirst(lastErrors.count - 10) }
    }

    private func emitPrefetchSummary() {
        let pausedReason: String
        if !prefetchEnabled {
            pausedReason = "disabled"
        } else if prefetchPaused {
            pausedReason = "manual"
        } else if interactionActive {
            pausedReason = "interaction"
        } else {
            pausedReason = "none"
        }
        PhotoDiagnostics.shared.emit("ThumbPrefetch", [
            "enabled": "\(prefetchEnabled)",
            "queueDepth": "\(priority.count + max(0, sequential.count - sequentialIndex))",
            "activeJobs": "\(downloadInFlight + decodeInFlight)",
            "completed": "\(prefetchCompleted)",
            "failed": "\(prefetchFailed)",
            "diskHit": "\(prefetchDiskHit)",
            "downloadStarted": "\(prefetchDownloadStarted)",
            "downloadCompleted": "\(prefetchDownloadCompleted)",
            "decodeStarted": "\(prefetchDecodeStarted)",
            "decodeCompleted": "\(prefetchDecodeCompleted)",
            "pausedReason": pausedReason,
        ], throttleSeconds: 1.0)
    }

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

    private static func checkpointKey(for uids: [PhotoUID]) -> String {
        let first = uids.first.map { "\($0.volumeID)~\($0.nodeID)" } ?? "empty"
        let last = uids.last.map { "\($0.volumeID)~\($0.nodeID)" } ?? "empty"
        let raw = "\(uids.count)-\(first)-\(last)"
        let cleaned = raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : "_" }.joined()
        return "ProtonPhotos.thumbnailPrefetch." + String(cleaned.prefix(180))
    }
}

/// Thread-safe holder for collecting a thumbnail from the SDK's `@Sendable` callback.
private final class ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?
    func set(_ data: Data) { lock.withLock { bytes = data } }
    var value: Data? { lock.withLock { bytes } }
}

private final class IntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private final class DiskPresenceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]

    func set(_ uid: PhotoUID, present: Bool) {
        lock.withLock { values[Self.key(uid)] = present }
    }

    func value(for uid: PhotoUID) -> Bool? {
        lock.withLock { values[Self.key(uid)] }
    }

    private static func key(_ uid: PhotoUID) -> String {
        "\(uid.volumeID)~\(uid.nodeID)"
    }
}
