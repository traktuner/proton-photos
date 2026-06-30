import Foundation
import MediaByteCache
import MediaDecodingCore
import PhotosCore

public struct ThumbnailFeedCoreConfiguration: Sendable, Equatable {
    public let targetPixels: CGFloat
    public let downloadConcurrencyLimit: Int
    public let initialDownloadConcurrency: Int
    public let minimumDownloadConcurrency: Int
    public let batchSize: Int
    public let decodedMemoryBudgetBytes: Int
    public let maxConcurrentDecodes: Int
    public let priorityQueueLimit: Int
    public let sequentialScanLimit: Int
    public let visibleQuietWindow: TimeInterval
    public let crawlBackoffSeconds: TimeInterval
    public let downloadTimeoutSeconds: Double

    public init(
        targetPixels: CGFloat = 320,
        downloadConcurrencyLimit: Int = 4,
        initialDownloadConcurrency: Int? = nil,
        minimumDownloadConcurrency: Int = 1,
        batchSize: Int = 8,
        decodedMemoryBudgetBytes: Int = 128 * 1024 * 1024,
        maxConcurrentDecodes: Int = 2,
        priorityQueueLimit: Int = 600,
        sequentialScanLimit: Int = 128,
        visibleQuietWindow: TimeInterval = 0.25,
        crawlBackoffSeconds: TimeInterval = 5,
        downloadTimeoutSeconds: Double = 20
    ) {
        let downloadLimit = max(1, downloadConcurrencyLimit)
        let minimum = min(max(1, minimumDownloadConcurrency), downloadLimit)
        let initial = initialDownloadConcurrency ?? max(minimum, downloadLimit / 2)
        self.targetPixels = max(1, targetPixels)
        self.downloadConcurrencyLimit = downloadLimit
        self.initialDownloadConcurrency = min(max(minimum, initial), downloadLimit)
        self.minimumDownloadConcurrency = minimum
        self.batchSize = max(1, batchSize)
        self.decodedMemoryBudgetBytes = max(1, decodedMemoryBudgetBytes)
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
        self.priorityQueueLimit = max(1, priorityQueueLimit)
        self.sequentialScanLimit = max(1, sequentialScanLimit)
        self.visibleQuietWindow = max(0, visibleQuietWindow)
        self.crawlBackoffSeconds = max(0, crawlBackoffSeconds)
        self.downloadTimeoutSeconds = max(0.1, downloadTimeoutSeconds)
    }
}

/// Universal thumbnail pipeline core.
///
/// Owns platform-independent feed behavior: disk/network decisions, priority ordering, background crawl,
/// adaptive download concurrency, decoded `CGImage` residency, and diagnostics. Platform targets adapt
/// `DecodedThumbnail` to their presentation image type outside this module.
public actor ThumbnailFeedCore {
    private nonisolated let cache: ThumbnailCache
    private nonisolated let loader: ThumbnailBatchLoader
    private nonisolated let onDecoded: @Sendable (PhotoUID, DecodedThumbnail) -> Void
    private nonisolated(unsafe) let decoded = NSCache<NSString, DecodedThumbnailBox>()
    private nonisolated let diskPresence = DiskPresenceCache()
    private nonisolated let configuration: ThumbnailFeedCoreConfiguration

    private var priority: [PhotoUID] = []
    private var priorityByUID: [PhotoUID: ThumbnailPriority] = [:]
    private var sequential: [PhotoUID] = []
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
    private var lastRepassPercent = -1.0
    private var targetConcurrency = 2
    private var activeDownloaders = 0
    private var aimdSuccessStreak = 0

    private let clock: @Sendable () -> Date
    private var lastDemandAt: Date?
    private var crawlBackoffUntil: Date?

    public init(
        cache: ThumbnailCache,
        loader: ThumbnailBatchLoader,
        configuration: ThumbnailFeedCoreConfiguration = ThumbnailFeedCoreConfiguration(),
        clock: @escaping @Sendable () -> Date = { Date() },
        onDecoded: @escaping @Sendable (PhotoUID, DecodedThumbnail) -> Void = { _, _ in }
    ) {
        self.cache = cache
        self.loader = loader
        self.configuration = configuration
        self.clock = clock
        self.onDecoded = onDecoded
        decoded.totalCostLimit = configuration.decodedMemoryBudgetBytes
        targetConcurrency = configuration.initialDownloadConcurrency
    }

    public func cachedDecoded(for uid: PhotoUID) -> DecodedThumbnail? {
        let key = Self.key(uid)
        if let cached = decoded.object(forKey: key)?.value {
            PhotoDiagnostics.shared.increment("thumb.ramDecodedHit")
            return cached
        }
        PhotoDiagnostics.shared.increment("thumb.ramDecodeMiss")
        PhotoDiagnostics.shared.recordDiskReadDuringPinch()
        if let data = cache.diskData(for: uid) {
            diskPresence.set(uid, present: true)
            PhotoDiagnostics.shared.increment("thumb.diskCacheHit")
            guard let image = decode(data, for: uid) else { return nil }
            storeDecoded(image, for: uid)
            return image
        }
        diskPresence.set(uid, present: false)
        PhotoDiagnostics.shared.increment("thumb.diskCacheMiss")
        return nil
    }

    public nonisolated func memoryDecoded(for uid: PhotoUID) -> DecodedThumbnail? {
        decoded.object(forKey: Self.key(uid))?.value
    }

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

    public func requestPriority(_ uid: PhotoUID, priority requestedPriority: ThumbnailPriority = .visibleNow) {
        if requestedPriority != .idleLibraryCrawl { lastDemandAt = clock() }
        PhotoDiagnostics.shared.recordDiskPresenceCheckDuringPinch()
        let diskHit = cache.hasUsableDiskData(uid)
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
        if priority.count > configuration.priorityQueueLimit {
            let dropCount = priority.count - configuration.priorityQueueLimit
            for uid in priority[0 ..< dropCount] { priorityByUID.removeValue(forKey: uid) }
            priority.removeFirst(dropCount)
        }
        startWorkers()
    }

    public func hasRecentVisibleDemand(within: TimeInterval = 2.0) -> Bool {
        guard let last = lastDemandAt else { return false }
        return clock().timeIntervalSince(last) < within
    }

    public func hasPendingThumbnailWork() -> Bool {
        guard prefetchEnabled else { return false }
        return !priority.isEmpty || sequentialIndex < sequential.count
    }

    public func warmDecoded(
        _ requests: [ThumbnailRequest],
        priority requestedPriority: ThumbnailPriority,
        limit: Int
    ) async -> WarmDecodedResult {
        let targets = Array(requests.prefix(max(0, limit)))
        lastDemandAt = clock()
        var alreadyDecoded = 0
        var decodedFromDisk = 0
        var queuedNetwork = 0
        var missing = 0
        let mainThreadDecodeCount = 0
        var needDecode: [PhotoUID] = []
        needDecode.reserveCapacity(targets.count)
        for request in targets {
            if decoded.object(forKey: Self.key(request.uid)) != nil {
                PhotoDiagnostics.shared.increment("thumb.ramDecodedHit")
                alreadyDecoded += 1
            } else {
                needDecode.append(request.uid)
            }
        }
        if !needDecode.isEmpty {
            let cache = self.cache
            let maxPixels = configuration.targetPixels
            let lanes = max(1, min(needDecode.count, configuration.maxConcurrentDecodes))
            let outcomes = await withTaskGroup(of: DecodedTile.self) { group -> [DecodedTile] in
                var iterator = needDecode.makeIterator()
                func addNext() {
                    guard let uid = iterator.next() else { return }
                    group.addTask {
                        guard let data = cache.diskData(for: uid) else {
                            return DecodedTile(uid: uid, decoded: nil, diskHadData: false, durationMs: 0)
                        }
                        let start = Date()
                        let decoded = ThumbnailImageDecoder.downsample(data, maxPixelSize: maxPixels)
                        return DecodedTile(
                            uid: uid,
                            decoded: decoded,
                            diskHadData: true,
                            durationMs: Date().timeIntervalSince(start) * 1000
                        )
                    }
                }
                for _ in 0 ..< lanes { addNext() }
                var results: [DecodedTile] = []
                results.reserveCapacity(needDecode.count)
                for await tile in group {
                    results.append(tile)
                    addNext()
                }
                return results
            }
            for tile in outcomes {
                PhotoDiagnostics.shared.increment("thumb.ramDecodeMiss")
                if tile.diskHadData {
                    diskPresence.set(tile.uid, present: true)
                    PhotoDiagnostics.shared.increment("thumb.diskCacheHit")
                    prefetchDecodeStarted += 1
                    PhotoDiagnostics.shared.recordDecodeStarted(queueDepth: 0)
                    if let image = tile.decoded {
                        storeDecoded(image, for: tile.uid)
                        prefetchDecodeCompleted += 1
                        PhotoDiagnostics.shared.recordDecodeCompleted(durationMs: tile.durationMs, queueDepth: 0)
                        decodedFromDisk += 1
                    } else {
                        missing += 1
                        PhotoDiagnostics.shared.increment("thumb.diskDecodeFailed")
                        PhotoDiagnostics.shared.recordDecodeFailed(queueDepth: 0)
                        recordError("decode failed for \(Self.key(tile.uid))")
                    }
                } else if cache.hasUsableDiskData(tile.uid) {
                    diskPresence.set(tile.uid, present: true)
                    PhotoDiagnostics.shared.increment("thumb.diskCacheHit")
                    missing += 1
                } else {
                    diskPresence.set(tile.uid, present: false)
                    PhotoDiagnostics.shared.increment("thumb.diskCacheMiss")
                    requestPriority(tile.uid, priority: requestedPriority)
                    queuedNetwork += 1
                }
            }
        }
        return WarmDecodedResult(
            requested: targets.count,
            alreadyDecoded: alreadyDecoded,
            decodedFromDisk: decodedFromDisk,
            queuedNetwork: queuedNetwork,
            missing: missing,
            mainThreadDecodeCount: mainThreadDecodeCount
        )
    }

    public func warmDecoded(_ uids: [PhotoUID], limit: Int = 160) async -> WarmDecodedResult {
        await warmDecoded(
            uids.map { ThumbnailRequest(uid: $0, pixelSize: Int(configuration.targetPixels)) },
            priority: .zoomAnchorAndFocusRow,
            limit: limit
        )
    }

    public func decoded(for uid: PhotoUID) async -> DecodedThumbnail? {
        if let image = cachedDecoded(for: uid) { return image }
        let box = ByteBox()
        PhotoDiagnostics.shared.recordNetworkRequestDuringPinch()
        await loader.loadThumbnails(for: [uid]) { loadedUID, data in
            if loadedUID == uid { box.set(data) }
        }
        guard let data = box.value else { return nil }
        cache.storeToDisk(data, for: uid)
        guard let image = decode(data, for: uid) else { return nil }
        storeDecoded(image, for: uid)
        return image
    }

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
        priority.removeAll()
        priorityByUID.removeAll()
        sequential.removeAll()
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
        public let diskThumbnailCoverageFraction: Double
        public let diskThumbnailTotal: Int
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
            diskThumbnailCoverageFraction: coverage.percent,
            diskThumbnailTotal: coverage.total,
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
                for _ in 0 ..< self.configuration.downloadConcurrencyLimit {
                    group.addTask { await self.worker() }
                }
            }
            await self.workersStopped()
        }
    }

    private func workersStopped() {
        workersRunning = false
        if !priority.isEmpty || sequentialIndex < sequential.count { startWorkers() }
    }

    private func worker() async {
        while !Task.isCancelled {
            let chunk = takeBatch()
            if chunk.isEmpty {
                if priority.isEmpty && sequentialIndex >= sequential.count {
                    let percent = cache.diskCoverage(for: sequential).percent
                    if percent < 99.5, percent > lastRepassPercent + 0.01 {
                        lastRepassPercent = percent
                        sequentialIndex = 0
                        try? await Task.sleep(for: .seconds(2))
                        continue
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(150))
                continue
            }
            while activeDownloaders >= targetConcurrency, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(60))
            }
            if Task.isCancelled { return }
            activeDownloaders += 1
            downloadInFlight += chunk.count
            prefetchDownloadStarted += chunk.count
            PhotoDiagnostics.shared.recordNetworkRequestDuringPinch()
            let completed = await Self.loadWithTimeout(
                chunk,
                loader: loader,
                cache: cache,
                diskPresence: diskPresence,
                seconds: configuration.downloadTimeoutSeconds
            )
            activeDownloaders = max(0, activeDownloaders - 1)
            downloadInFlight = max(0, downloadInFlight - chunk.count)
            prefetchCompleted += completed
            prefetchDownloadCompleted += completed
            let failed = max(0, chunk.count - completed)
            prefetchFailed += failed
            if completed == 0, !chunk.isEmpty {
                recordError("thumbnail fetch returned 0/\(chunk.count) (network or rate-limit)")
                crawlBackoffUntil = clock().addingTimeInterval(configuration.crawlBackoffSeconds)
                targetConcurrency = max(configuration.minimumDownloadConcurrency, targetConcurrency / 2)
                aimdSuccessStreak = 0
            } else if completed > 0 {
                aimdSuccessStreak += 1
                if aimdSuccessStreak >= 4 {
                    aimdSuccessStreak = 0
                    targetConcurrency = min(configuration.downloadConcurrencyLimit, targetConcurrency + 1)
                }
            }
            if let checkpointKey, sequentialIndex > 0 {
                UserDefaults.standard.set(sequentialIndex, forKey: checkpointKey)
            }
            emitPrefetchSummary()
        }
    }

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

    private func takeBatch() -> [PhotoUID] {
        var out: [PhotoUID] = []
        while out.count < configuration.batchSize, !priority.isEmpty {
            let bestIndex = priority.indices.min {
                let lhs = priorityByUID[priority[$0]] ?? .idleLibraryCrawl
                let rhs = priorityByUID[priority[$1]] ?? .idleLibraryCrawl
                if lhs != rhs { return lhs < rhs }
                return $0 > $1
            } ?? priority.index(before: priority.endIndex)
            let uid = priority.remove(at: bestIndex)
            priorityByUID.removeValue(forKey: uid)
            PhotoDiagnostics.shared.recordDiskPresenceCheckDuringPinch()
            let diskHit = cache.has(uid)
            diskPresence.set(uid, present: diskHit)
            if !diskHit {
                out.append(uid)
            } else {
                prefetchDiskHit += 1
            }
        }

        let now = clock()
        let recentDemand = lastDemandAt.map { now.timeIntervalSince($0) < configuration.visibleQuietWindow } ?? false
        let backingOff = crawlBackoffUntil.map { now < $0 } ?? false
        guard !interactionActive, !prefetchPaused, prefetchEnabled, !recentDemand, !backingOff else { return out }

        var scannedThisCall = 0
        while out.count < configuration.batchSize,
              sequentialIndex < sequential.count,
              scannedThisCall < configuration.sequentialScanLimit {
            scannedThisCall += 1
            let uid = sequential[sequentialIndex]
            sequentialIndex += 1
            let diskHit = cache.has(uid)
            diskPresence.set(uid, present: diskHit)
            if !diskHit && !out.contains(uid) {
                out.append(uid)
            } else {
                prefetchDiskHit += 1
            }
        }
        return out
    }

    private func decode(_ data: Data, for uid: PhotoUID) -> DecodedThumbnail? {
        prefetchDecodeStarted += 1
        decodeInFlight += 1
        PhotoDiagnostics.shared.recordDecodeStarted(queueDepth: decodeInFlight)
        let start = Date()
        let image = ThumbnailImageDecoder.downsample(data, maxPixelSize: configuration.targetPixels)
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

    private func storeDecoded(_ image: DecodedThumbnail, for uid: PhotoUID) {
        decoded.setObject(DecodedThumbnailBox(image), forKey: Self.key(uid), cost: image.decodedCostBytes)
        onDecoded(uid, image)
    }

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

private final class DecodedThumbnailBox: @unchecked Sendable {
    let value: DecodedThumbnail

    init(_ value: DecodedThumbnail) {
        self.value = value
    }
}

private struct DecodedTile: @unchecked Sendable {
    let uid: PhotoUID
    let decoded: DecodedThumbnail?
    let diskHadData: Bool
    let durationMs: Double
}

private final class ByteBox: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: Data?

    func set(_ data: Data) {
        lock.withLock { bytes = data }
    }

    var value: Data? {
        lock.withLock { bytes }
    }
}

private final class IntBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int {
        lock.withLock { count }
    }
}

private final class DiskPresenceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Bool] = [:]

    func set(_ uid: PhotoUID, present: Bool) {
        lock.withLock { values[Self.key(uid)] = present }
    }

    private static func key(_ uid: PhotoUID) -> String {
        "\(uid.volumeID)~\(uid.nodeID)"
    }
}
