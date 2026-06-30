import AppKit
import CoreGraphics
import PhotosCore
import MediaCache

/// Supplies the grid with the library structure (per-section counts + flat UID order) and decoded RAM
/// images for GPU texture upload. One production implementation, `RealMetalGridDataSource`, backed by the
/// real `ThumbnailFeed`/timeline (a `PresentationTestDataSource` exists only in tests).
@MainActor
protocol MetalGridDataSource: AnyObject {
    var label: String { get }            // "real" (the only production source)
    var sectionCounts: [Int] { get }
    var flatUIDs: [PhotoUID] { get }
    /// Cheap "is a RAM image ready?" check (no decode/conversion) — drives upload selection.
    func hasImage(for uid: PhotoUID) -> Bool
    /// Synchronous in-RAM image for `uid`, or nil if not yet available (caller draws a placeholder).
    /// Only called for the bounded set of UIDs actually being uploaded this frame.
    func image(for uid: PhotoUID) -> CGImage?
    /// Prime the given UIDs into RAM (off-main); cheap + idempotent. Called for visible placeholders.
    func warm(_ uids: [PhotoUID])
    /// Main-actor notification after an async warm pass may have made new RAM images visible.
    var onImagesAvailable: (() -> Void)? { get set }
    /// Whether this item is a video (drives the video badge). Default: false.
    func isVideo(_ uid: PhotoUID) -> Bool
}

extension MetalGridDataSource {
    func isVideo(_ uid: PhotoUID) -> Bool { false }
}

// MARK: - Real data (ThumbnailFeed-backed)

/// Reads the live library: decoded images come from the shared `ThumbnailFeed` (RAM-hit only on the render
/// thread; disk/network decode stays on the feed actor). `warm` drives the feed's bounded priority pipeline
/// — no architecture change to the feed.
///
/// Production geometry is ONE continuous square-tile photo wall: all `TimelineSection`s are flattened into a
/// single ordered run, so `sectionCounts` is always `[flatUIDs.count]` (or `[]` when empty). The date-grouped
/// `TimelineSection`s are NOT used as physical grid layout sections — they only feed the month/date label
/// overlay, via `MetalGridProductionAdapter.monthMarkers(sections:)`. (Multi-section layout stays supported by
/// `SquareTileGridEngine` + its tests; production just never uses more than one section.)
@MainActor
final class RealMetalGridDataSource: MetalGridDataSource {
    let label = "real"
    let sectionCounts: [Int]
    let flatUIDs: [PhotoUID]
    var onImagesAvailable: (() -> Void)?
    private let feed: ThumbnailFeed
    private let videoUIDs: Set<PhotoUID>
    private var warmInFlight = false
    private var pendingWarm: [PhotoUID] = []
    /// Decode at most this many disk→RAM per in-flight batch so thumbnails STREAM in (≈100 ms/batch)
    /// instead of the actor blocking on one huge sequential decode of the whole visible+overscan set.
    private let maxWarmBatch = 48
    /// Coalesces the per-frame visible set so the NETWORK reprioritisation (`.visibleNow`) is enqueued once
    /// per stable viewport (~100 ms), not every scroll frame. Disk→RAM decode below stays immediate.
    private let networkDebouncer = ViewportRequestDebouncer(window: 0.1)
    private var settleCheckScheduled = false

    init(sections: [TimelineSection], feed: ThumbnailFeed) {
        let uids = sections.flatMap { $0.items.map(\.uid) }
        self.flatUIDs = uids
        self.sectionCounts = uids.isEmpty ? [] : [uids.count]   // one continuous section (production photo wall)
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
        // Reprioritise the background crawl toward what's on screen, but only once the viewport has been
        // stable for ~100 ms — so a fast scroll doesn't re-enqueue the visible set every frame.
        networkDebouncer.note(uids, at: CACurrentMediaTime())
        scheduleSettleCheck()
    }

    /// After the debounce window, if the viewport has settled, enqueue the still-missing visible cells at
    /// `.visibleNow` so they interrupt the crawl. Self-terminating: re-arms only while the viewport is still
    /// in flux. The decode pump above is unaffected — on-screen cells already on disk fill immediately.
    private func scheduleSettleCheck() {
        guard !settleCheckScheduled else { return }
        settleCheckScheduled = true
        let window = networkDebouncer.settleWindow
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(window + 0.02))
            guard let self else { return }
            self.settleCheckScheduled = false
            guard let settled = self.networkDebouncer.flushIfStable(at: CACurrentMediaTime()) else {
                // Re-arm off the DEBOUNCER's own pending state, not `pendingWarm` (which `pumpWarm` clears
                // immediately) — otherwise a fast scroll's final viewport would never get emitted.
                if self.networkDebouncer.hasPendingUnflushed() { self.scheduleSettleCheck() }
                return
            }
            let missing = settled.filter { self.feed.memoryImage(for: $0) == nil }
            guard !missing.isEmpty else { return }
            Task { [feed = self.feed] in
                for uid in missing { await feed.requestPriority(uid, priority: .visibleNow) }
            }
        }
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
                self.onImagesAvailable?()
                self.pumpWarm()
            }
        }
    }
}
