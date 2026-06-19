import AppKit
import CoreGraphics
import PhotosCore
import MediaCache

/// Supplies the lab with the library structure (per-section counts + flat UID order) and decoded RAM
/// images for upload. Two implementations: one backed by the real `ThumbnailFeed`/timeline, one
/// synthetic (so the lab runs before sign-in and for deterministic stress testing).
@MainActor
protocol MetalGridDataSource: AnyObject {
    var label: String { get }            // "real" / "synthetic"
    var sectionCounts: [Int] { get }
    var flatUIDs: [PhotoUID] { get }
    /// Cheap "is a RAM image ready?" check (no decode/conversion) — drives upload selection.
    func hasImage(for uid: PhotoUID) -> Bool
    /// Synchronous in-RAM image for `uid`, or nil if not yet available (caller draws a placeholder).
    /// Only called for the bounded set of UIDs actually being uploaded this frame.
    func image(for uid: PhotoUID) -> CGImage?
    /// Prime the given UIDs into RAM (off-main); cheap + idempotent. Called for visible placeholders.
    func warm(_ uids: [PhotoUID])
    /// Whether this item is a video (drives the video badge). Default: false.
    func isVideo(_ uid: PhotoUID) -> Bool
}

extension MetalGridDataSource {
    func isVideo(_ uid: PhotoUID) -> Bool { false }
}

// MARK: - Real data (ThumbnailFeed-backed)

/// Reads the live library: per-section counts come from the loaded `TimelineSection`s, decoded images
/// from the shared `ThumbnailFeed` (RAM-hit only on the render thread; disk/network decode stays on the
/// feed actor). `warm` drives the feed's bounded priority pipeline — no architecture change to the feed.
@MainActor
final class RealMetalGridDataSource: MetalGridDataSource {
    let label = "real"
    let sectionCounts: [Int]
    let flatUIDs: [PhotoUID]
    private let feed: ThumbnailFeed
    private let videoUIDs: Set<PhotoUID>
    private var warmInFlight = false
    private var pendingWarm: [PhotoUID] = []
    /// Decode at most this many disk→RAM per in-flight batch so thumbnails STREAM in (≈100 ms/batch)
    /// instead of the actor blocking on one huge sequential decode of the whole visible+overscan set.
    private let maxWarmBatch = 48

    init(sections: [TimelineSection], feed: ThumbnailFeed) {
        self.sectionCounts = sections.map(\.items.count)
        self.flatUIDs = sections.flatMap { $0.items.map(\.uid) }
        self.videoUIDs = Set(sections.flatMap { $0.items }.filter(\.isVideo).map(\.uid))
        self.feed = feed
    }

    func isVideo(_ uid: PhotoUID) -> Bool { videoUIDs.contains(uid) }

    func hasImage(for uid: PhotoUID) -> Bool { feed.memoryImage(for: uid) != nil }

    func image(for uid: PhotoUID) -> CGImage? {
        guard let nsImage = feed.memoryImage(for: uid) else { return nil }
        return nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    func warm(_ uids: [PhotoUID]) {
        // Latest viewport wins (the coordinator passes the still-missing cells in visible-first order each
        // frame). No permanent suppression — a cell evicted from the RAM cache must be able to re-warm.
        pendingWarm = uids
        pumpWarm()
    }

    /// Decode the next bounded batch disk→RAM (or queue network for missing), then pump the rest. Bounding
    /// the batch keeps the feed actor responsive so thumbnails appear continuously rather than in big stalls.
    private func pumpWarm() {
        guard !warmInFlight, !pendingWarm.isEmpty else { return }
        warmInFlight = true
        let batch = Array(pendingWarm.prefix(maxWarmBatch))
        pendingWarm.removeAll(keepingCapacity: true)
        Task { [feed] in
            _ = await feed.warmDecoded(batch, limit: batch.count)
            await MainActor.run {
                self.warmInFlight = false
                self.pumpWarm()
            }
        }
    }
}

// MARK: - Synthetic data (no Proton, deterministic, simulated streaming latency)

/// Generates colored gradient tiles with a visible index number and a simulated decode latency, so the
/// lab can prove placeholder→thumbnail streaming + smooth scroll over a 20k+ item grid without any
/// network. Sections are random day-sized runs to exercise the per-section square layout.
@MainActor
final class SyntheticMetalGridDataSource: MetalGridDataSource {
    let label = "synthetic"
    let sectionCounts: [Int]
    let flatUIDs: [PhotoUID]
    private var readyAt: [PhotoUID: CFTimeInterval] = [:]
    private let indexByUID: [PhotoUID: Int]
    /// A small pool of distinct tile images, reused across the whole library (index % poolCount). Tiles
    /// are generated once and cached, so an upload is just a cheap texture copy — NOT a per-photo
    /// `NSString`/`NSGradient` render on the main thread, which otherwise stutters fast scroll.
    private static let poolCount = 96
    private var pool: [CGImage?] = Array(repeating: nil, count: SyntheticMetalGridDataSource.poolCount)
    /// Simulated per-thumbnail latency range (seconds) to mimic disk/network streaming.
    var latencyRange: ClosedRange<Double> = 0.05 ... 0.7

    init(itemCount: Int) {
        var counts: [Int] = []
        var remaining = itemCount
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func next() -> UInt64 { seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17; return seed }
        while remaining > 0 {
            let day = min(remaining, 8 + Int(next() % 60))   // 8…67 photos per "day"
            counts.append(day)
            remaining -= day
        }
        self.sectionCounts = counts
        var uids: [PhotoUID] = []
        uids.reserveCapacity(itemCount)
        var map: [PhotoUID: Int] = [:]
        for i in 0 ..< itemCount {
            let uid = PhotoUID(volumeID: "synthetic", nodeID: "\(i)")
            uids.append(uid)
            map[uid] = i
        }
        self.flatUIDs = uids
        self.indexByUID = map
    }

    func hasImage(for uid: PhotoUID) -> Bool {
        guard let due = readyAt[uid] else { return false }
        return CACurrentMediaTime() >= due
    }

    func image(for uid: PhotoUID) -> CGImage? {
        guard let due = readyAt[uid], CACurrentMediaTime() >= due, let index = indexByUID[uid] else { return nil }
        return tile(paletteIndex: index % Self.poolCount)
    }

    func warm(_ uids: [PhotoUID]) {
        let now = CACurrentMediaTime()
        for uid in uids where readyAt[uid] == nil {
            let span = latencyRange.upperBound - latencyRange.lowerBound
            readyAt[uid] = now + latencyRange.lowerBound + Double.random(in: 0 ... span)
        }
    }

    /// Lazily build + cache one pool tile (cheap thereafter — uploads just copy it).
    private func tile(paletteIndex: Int) -> CGImage? {
        if let cached = pool[paletteIndex] { return cached }
        let image = Self.makeTile(index: paletteIndex)
        pool[paletteIndex] = image
        return image
    }

    /// A distinct gradient tile with a label + varied aspect ratio (cycled), so scrolling motion +
    /// letterboxing are obvious. Generated at most `poolCount` times for the whole library. It is drawn
    /// into an `NSImage` and returned via `nsImage.cgImage(...)` — the SAME conversion real thumbnails use
    /// — so synthetic and real tiles are guaranteed to share the same orientation through the texture cache.
    private static func makeTile(index: Int) -> CGImage? {
        let aspects: [(CGFloat, CGFloat)] = [(256, 256), (256, 170), (170, 256), (256, 144), (200, 256)]
        let (w, h) = aspects[index % aspects.count]
        let hue = CGFloat((index * 37) % 360) / 360
        let base = NSColor(hue: hue, saturation: 0.55, brightness: 0.85, alpha: 1)
        let image = NSImage(size: NSSize(width: w, height: h))
        image.lockFocus()
        let gradient = NSGradient(starting: base, ending: base.blended(withFraction: 0.5, of: .black) ?? base)
        gradient?.draw(in: CGRect(x: 0, y: 0, width: w, height: h), angle: 45)
        let label = "\(index)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: min(w, h) * 0.28),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85),
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(at: NSPoint(x: (w - size.width) / 2, y: (h - size.height) / 2), withAttributes: attrs)
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }
}
