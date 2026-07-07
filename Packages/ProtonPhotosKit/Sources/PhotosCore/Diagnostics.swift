import Foundation
import CoreGraphics
import OSLog

public enum ThumbnailPriority: Int, CaseIterable, Codable, Sendable, Comparable {
    case visibleNow = 0
    case zoomAnchorAndFocusRow = 1
    case likelyZoomOutTargetCoverage = 2
    case nearViewportScrollAhead = 3
    case idleLibraryCrawl = 4

    public static func < (lhs: ThumbnailPriority, rhs: ThumbnailPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ThumbnailRequest: Hashable, Codable, Sendable {
    public let uid: PhotoUID
    /// Requested decode/upload pixel side. `0` (the default) means "no size opinion - use the feed's
    /// configured target". A positive value can only RAISE the decode above that target (level-aware
    /// hosts ask big for big tiles); it never shrinks the shared RAM image below it.
    public let pixelSize: Int
    public let lod: Int
    public let cropMode: String

    public init(uid: PhotoUID, pixelSize: Int = 0, lod: Int = 0, cropMode: String = "default") {
        self.uid = uid
        self.pixelSize = pixelSize
        self.lod = lod
        self.cropMode = cropMode
    }
}

public struct ThumbnailCacheTierState: Equatable, Sendable {
    public let knownInTimeline: Bool
    public let diskThumbnail: Bool
    public let ramDecoded: Bool
    public let gpuTexture: Bool

    public init(
        knownInTimeline: Bool,
        diskThumbnail: Bool,
        ramDecoded: Bool,
        gpuTexture: Bool
    ) {
        self.knownInTimeline = knownInTimeline
        self.diskThumbnail = diskThumbnail
        self.ramDecoded = ramDecoded
        self.gpuTexture = gpuTexture
    }
}

public struct WarmDecodedResult: Equatable, Sendable {
    public let requested: Int
    public let alreadyDecoded: Int
    public let decodedFromDisk: Int
    public let queuedNetwork: Int
    public let missing: Int
    public let mainThreadDecodeCount: Int

    public init(
        requested: Int,
        alreadyDecoded: Int,
        decodedFromDisk: Int,
        queuedNetwork: Int,
        missing: Int,
        mainThreadDecodeCount: Int = 0
    ) {
        self.requested = requested
        self.alreadyDecoded = alreadyDecoded
        self.decodedFromDisk = decodedFromDisk
        self.queuedNetwork = queuedNetwork
        self.missing = missing
        self.mainThreadDecodeCount = mainThreadDecodeCount
    }
}

public struct WarmTextureResult: Equatable, Sendable {
    public let requested: Int
    public let alreadyResident: Int
    public let decodedWarmed: Int
    public let uploadQueued: Int
    public let missing: Int

    public init(
        requested: Int,
        alreadyResident: Int,
        decodedWarmed: Int,
        uploadQueued: Int,
        missing: Int
    ) {
        self.requested = requested
        self.alreadyResident = alreadyResident
        self.decodedWarmed = decodedWarmed
        self.uploadQueued = uploadQueued
        self.missing = missing
    }
}

public struct ThumbnailHealthSnapshot: Equatable, Sendable {
    public let visibleCellCount: Int
    public let realThumbnailCount: Int
    public let lowResThumbnailCount: Int
    public let sourceFallbackCount: Int
    public let placeholderCount: Int
    public let missingDiskCount: Int
    public let missingNetworkCount: Int
    public let decodeInFlightCount: Int
    public let downloadInFlightCount: Int
    public let diskCacheHitCount: Int
    public let ramDecodedHitCount: Int
    public let gpuTextureHitCount: Int
    public let gpuTextureMissCount: Int

    public init(
        visibleCellCount: Int = 0,
        realThumbnailCount: Int = 0,
        lowResThumbnailCount: Int = 0,
        sourceFallbackCount: Int = 0,
        placeholderCount: Int = 0,
        missingDiskCount: Int = 0,
        missingNetworkCount: Int = 0,
        decodeInFlightCount: Int = 0,
        downloadInFlightCount: Int = 0,
        diskCacheHitCount: Int = 0,
        ramDecodedHitCount: Int = 0,
        gpuTextureHitCount: Int = 0,
        gpuTextureMissCount: Int = 0
    ) {
        self.visibleCellCount = visibleCellCount
        self.realThumbnailCount = realThumbnailCount
        self.lowResThumbnailCount = lowResThumbnailCount
        self.sourceFallbackCount = sourceFallbackCount
        self.placeholderCount = placeholderCount
        self.missingDiskCount = missingDiskCount
        self.missingNetworkCount = missingNetworkCount
        self.decodeInFlightCount = decodeInFlightCount
        self.downloadInFlightCount = downloadInFlightCount
        self.diskCacheHitCount = diskCacheHitCount
        self.ramDecodedHitCount = ramDecodedHitCount
        self.gpuTextureHitCount = gpuTextureHitCount
        self.gpuTextureMissCount = gpuTextureMissCount
    }
}

public enum ThumbnailVisualState: String, CaseIterable, Codable, Sendable {
    case realImageDrawn
    case placeholderDrawn
    case diskMissing
    case diskHitRamMissing
    case ramHitGpuMissing
    case atlasMissing
    case geometryHole
    case intentionallyClipped
    case unknownBug
}

public struct ThumbnailVisualClassification: Sendable, Equatable {
    public let uid: PhotoUID?
    public let rect: CGRect
    public let state: ThumbnailVisualState
    public let phase: String
    public let context: String

    public init(
        uid: PhotoUID?,
        rect: CGRect,
        state: ThumbnailVisualState,
        phase: String,
        context: String = ""
    ) {
        self.uid = uid
        self.rect = rect
        self.state = state
        self.phase = phase
        self.context = context
    }
}

public struct ThumbnailHealthCounters: Sendable, Equatable {
    public var visibleCount = 0
    public var realImageDrawn = 0
    public var placeholderDrawn = 0
    public var diskMissing = 0
    public var diskHitRamMissing = 0
    public var ramHitGpuMissing = 0
    public var atlasMissing = 0
    public var geometryHole = 0
    public var intentionallyClipped = 0
    public var unknownBug = 0

    public init() {}

    public mutating func record(_ state: ThumbnailVisualState) {
        visibleCount += 1
        switch state {
        case .realImageDrawn: realImageDrawn += 1
        case .placeholderDrawn: placeholderDrawn += 1
        case .diskMissing: diskMissing += 1
        case .diskHitRamMissing: diskHitRamMissing += 1
        case .ramHitGpuMissing: ramHitGpuMissing += 1
        case .atlasMissing: atlasMissing += 1
        case .geometryHole: geometryHole += 1
        case .intentionallyClipped: intentionallyClipped += 1
        case .unknownBug: unknownBug += 1
        }
    }
}

public struct GridZoomHotPathCounters: Sendable, Equatable {
    public var dbQueryDuringPinch = 0
    public var diskReadDuringPinch = 0
    /// Cheap `cache.has(_)` existence probes during a pinch - NOT actual byte reads. Split out from
    /// `diskReadDuringPinch` so the "disk read" stat reflects real `diskData(_)` reads only.
    public var diskPresenceCheckDuringPinch = 0
    public var decodeDuringPinch = 0
    public var networkRequestDuringPinch = 0
    public var mainThreadDecodeDuringPinch = 0

    public init() {}
}

public struct ThumbnailDecodeStats: Sendable, Equatable {
    public var diskCacheHit = 0
    public var diskCacheMiss = 0
    public var ramDecodeHit = 0
    public var ramDecodeMiss = 0
    public var ramDecodeStarted = 0
    public var ramDecodeCompleted = 0
    public var ramDecodeFailed = 0
    public var ramDecodeQueueDepth = 0
    public var ramDecodeAverageMs: Double = 0
    public var ramDecodeP95Ms: Double = 0

    public init() {}
}

public struct DBQueryMetric: Sendable, Equatable {
    public let queryName: String
    public let durationMs: Double
    public let rowsReturned: Int
    public let ranOnMainThread: Bool
    public let duringActivePinch: Bool
    public let timestamp: Date

    public init(
        queryName: String,
        durationMs: Double,
        rowsReturned: Int,
        ranOnMainThread: Bool,
        duringActivePinch: Bool,
        timestamp: Date = Date()
    ) {
        self.queryName = queryName
        self.durationMs = durationMs
        self.rowsReturned = rowsReturned
        self.ranOnMainThread = ranOnMainThread
        self.duringActivePinch = duringActivePinch
        self.timestamp = timestamp
    }
}

public struct PhotoPerformanceSignposter: @unchecked Sendable {
    private let signposter: OSSignposter

    public init(category: String) {
        let logger = Logger(subsystem: "me.protonphotos", category: category)
        self.signposter = OSSignposter(logger: logger)
    }

    @discardableResult
    public func interval<T>(_ name: StaticString, _ work: () throws -> T) rethrows -> T {
        let id = signposter.makeSignpostID()
        let state = signposter.beginInterval(name, id: id)
        defer { signposter.endInterval(name, state) }
        return try work()
    }
}

public enum PhotoPerformanceSignposts {
    public static let database = PhotoPerformanceSignposter(category: "Database")
    public static let grid = PhotoPerformanceSignposter(category: "Grid")
    public static let mediaFeed = PhotoPerformanceSignposter(category: "MediaFeed")
    public static let viewer = PhotoPerformanceSignposter(category: "Viewer")
}

public final class PhotoDiagnostics: @unchecked Sendable {
    public static let shared = PhotoDiagnostics()

    private let lock = NSLock()
    private var activePinch = false
    private var dbQueries: [DBQueryMetric] = []
    private var counters: [String: Int] = [:]
    private var lastEventLog: [String: Date] = [:]
    private var thumbHealth = ThumbnailHealthCounters()
    private var hotPath = GridZoomHotPathCounters()
    private var decodeDurationsMs: [Double] = []
    private var decodeQueueDepth = 0

    private init() {}

    public func setActivePinch(_ active: Bool) {
        lock.withLock {
            activePinch = active
        }
    }

    public func isActivePinch() -> Bool {
        lock.withLock { activePinch }
    }

    public func increment(_ key: String, by amount: Int = 1) {
        lock.withLock {
            counters[key, default: 0] += amount
        }
    }

    public func counter(_ key: String) -> Int {
        lock.withLock { counters[key, default: 0] }
    }

    public func resetForTests() {
        lock.withLock {
            activePinch = false
            dbQueries.removeAll()
            counters.removeAll()
            lastEventLog.removeAll()
            thumbHealth = ThumbnailHealthCounters()
            hotPath = GridZoomHotPathCounters()
            decodeDurationsMs.removeAll()
            decodeQueueDepth = 0
        }
    }

    public func recordDBQuery(queryName: String, durationMs: Double, rowsReturned: Int) {
        let ranOnMain = Thread.isMainThread
        let duringPinch = isActivePinch()
        if duringPinch {
            lock.withLock { hotPath.dbQueryDuringPinch += 1 }
        }
        let metric = DBQueryMetric(
            queryName: queryName,
            durationMs: durationMs,
            rowsReturned: rowsReturned,
            ranOnMainThread: ranOnMain,
            duringActivePinch: duringPinch
        )
        lock.withLock {
            dbQueries.append(metric)
            if dbQueries.count > 500 {
                dbQueries.removeFirst(dbQueries.count - 500)
            }
        }
        if duringPinch || ranOnMain || durationMs > 5 {
            emit("DBHealth", [
                "query": queryName,
                "durationMs": format(durationMs),
                "rows": "\(rowsReturned)",
                "main": "\(ranOnMain)",
                "activePinch": "\(duringPinch)",
            ])
        }
    }

    public func classifyThumbnail(_ classification: ThumbnailVisualClassification) {
        lock.withLock {
            thumbHealth.record(classification.state)
        }
        switch classification.state {
        case .geometryHole, .unknownBug, .atlasMissing:
            emit("ThumbHealth", [
                "uid": classification.uid.map { "\($0.volumeID)~\($0.nodeID)" } ?? "none",
                "rect": rectDescription(classification.rect),
                "state": classification.state.rawValue,
                "phase": classification.phase,
                "context": classification.context,
            ], throttleSeconds: 0.10)
        default:
            break
        }
    }

    public func thumbHealthCounters(reset: Bool = false) -> ThumbnailHealthCounters {
        lock.withLock {
            let snapshot = thumbHealth
            if reset { thumbHealth = ThumbnailHealthCounters() }
            return snapshot
        }
    }

    public func recordDiskReadDuringPinch() {
        guard isActivePinch() else { return }
        lock.withLock { hotPath.diskReadDuringPinch += 1 }
    }

    /// Records a cheap on-disk *presence* check (`cache.has`), distinct from an actual byte read, so
    /// presence probes don't inflate the `diskReadDuringPinch` stat.
    public func recordDiskPresenceCheckDuringPinch() {
        guard isActivePinch() else { return }
        lock.withLock { hotPath.diskPresenceCheckDuringPinch += 1 }
    }

    public func recordNetworkRequestDuringPinch() {
        guard isActivePinch() else { return }
        lock.withLock { hotPath.networkRequestDuringPinch += 1 }
    }

    public func recordDecodeStarted(queueDepth: Int) {
        lock.withLock {
            counters["thumb.ramDecodeStarted", default: 0] += 1
            decodeQueueDepth = queueDepth
            if activePinch { hotPath.decodeDuringPinch += 1 }
        }
    }

    public func recordDecodeCompleted(durationMs: Double, queueDepth: Int) {
        lock.withLock {
            counters["thumb.ramDecodeCompleted", default: 0] += 1
            decodeQueueDepth = queueDepth
            decodeDurationsMs.append(durationMs)
            if decodeDurationsMs.count > 500 {
                decodeDurationsMs.removeFirst(decodeDurationsMs.count - 500)
            }
        }
    }

    public func recordDecodeFailed(queueDepth: Int) {
        lock.withLock {
            counters["thumb.ramDecodeFailed", default: 0] += 1
            decodeQueueDepth = queueDepth
        }
    }

    public func decodeStats() -> ThumbnailDecodeStats {
        lock.withLock {
            var stats = ThumbnailDecodeStats()
            stats.diskCacheHit = counters["thumb.diskCacheHit", default: 0]
            stats.diskCacheMiss = counters["thumb.diskCacheMiss", default: 0]
            stats.ramDecodeHit = counters["thumb.ramDecodedHit", default: 0]
            stats.ramDecodeMiss = counters["thumb.ramDecodeMiss", default: 0]
            stats.ramDecodeStarted = counters["thumb.ramDecodeStarted", default: 0]
            stats.ramDecodeCompleted = counters["thumb.ramDecodeCompleted", default: 0]
            stats.ramDecodeFailed = counters["thumb.ramDecodeFailed", default: 0] + counters["thumb.diskDecodeFailed", default: 0]
            stats.ramDecodeQueueDepth = decodeQueueDepth
            stats.ramDecodeAverageMs = average(decodeDurationsMs)
            stats.ramDecodeP95Ms = percentile(decodeDurationsMs, p: 0.95)
            return stats
        }
    }

    public func hotPathCounters(reset: Bool = false) -> GridZoomHotPathCounters {
        lock.withLock {
            let snapshot = hotPath
            if reset { hotPath = GridZoomHotPathCounters() }
            return snapshot
        }
    }

    public func dbQueryCountDuringActivePinch() -> Int {
        lock.withLock { dbQueries.filter(\.duringActivePinch).count }
    }

    public func emit(_ event: String, _ fields: [String: String], throttleSeconds: TimeInterval = 0) {
        let now = Date()
        if throttleSeconds > 0 {
            let key = event + fields.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
            let shouldLog = lock.withLock { () -> Bool in
                if let last = lastEventLog[key], now.timeIntervalSince(last) < throttleSeconds {
                    return false
                }
                lastEventLog[key] = now
                return true
            }
            guard shouldLog else { return }
        }
        let payload = fields.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        #if DEBUG
        print("[\(event)] \(payload)")
        #endif
    }

    private func rectDescription(_ rect: CGRect) -> String {
        "(\(format(rect.minX)),\(format(rect.minY)),\(format(rect.width)),\(format(rect.height)))"
    }

    private func format(_ value: CGFloat) -> String {
        String(format: "%.2f", Double(value))
    }

    private func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func percentile(_ values: [Double], p: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = min(max(Int(Double(sorted.count - 1) * p), 0), sorted.count - 1)
        return sorted[index]
    }
}
