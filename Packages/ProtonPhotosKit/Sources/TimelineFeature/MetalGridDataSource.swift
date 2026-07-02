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
    /// Cheap "is a RAM image ready?" check (no decode/conversion) - drives upload selection.
    func hasImage(for uid: PhotoUID) -> Bool
    /// True when a missing thumbnail can still make progress through disk/network/decode. Backend-refused
    /// thumbnails draw as stable placeholders and must not keep the display link or warm queue alive.
    func canRetryThumbnail(for uid: PhotoUID) -> Bool
    /// Synchronous in-RAM image for `uid`, or nil if not yet available (caller draws a placeholder).
    /// Only called for the bounded set of UIDs actually being uploaded this frame.
    func image(for uid: PhotoUID) -> CGImage?
    /// Prime the given UIDs into RAM (off-main); cheap + idempotent. Called for visible placeholders.
    func warm(_ uids: [PhotoUID])
    /// Decode the given UIDs into RAM as a PREFETCH, independent of the per-frame `warm` pump (does not disturb
    /// `pendingWarm`). Lets a pinch's TARGET level be warmed at segment-build time. Default: no-op.
    func prefetchWarm(_ uids: [PhotoUID])
    /// Main-actor notification after an async warm pass may have made new RAM images visible.
    var onImagesAvailable: (() -> Void)? { get set }
    /// Whether this item is a video (drives the video badge). Default: false.
    func isVideo(_ uid: PhotoUID) -> Bool
}

extension MetalGridDataSource {
    func isVideo(_ uid: PhotoUID) -> Bool { false }
    func canRetryThumbnail(for uid: PhotoUID) -> Bool { true }
    func prefetchWarm(_ uids: [PhotoUID]) {}   // only the real source decodes; test sources opt out
}

// MARK: - Real data (ThumbnailFeed-backed)

/// Reads the live library: decoded images come from the shared `ThumbnailFeed` (RAM-hit only on the render
/// thread; disk/network decode stays on the feed actor). `warm` drives the feed's bounded priority pipeline
/// - no architecture change to the feed.
///
/// Production geometry is ONE continuous square-tile photo wall: all `TimelineSection`s are flattened into a
/// single ordered run, so `sectionCounts` is always `[flatUIDs.count]` (or `[]` when empty). The date-grouped
/// `TimelineSection`s are NOT used as physical grid layout sections - they only feed the month/date label
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
    /// Cleared per data source (a new route/library builds a new instance). The first warm batch is the
    /// opening viewport, warmed at `.visibleNow`; every later batch uses the steady-state warm priority.
    private var didFirstVisiblePass = false
    private var prefetchTask: Task<Void, Never>?
    /// Decode at most this many disk→RAM per in-flight batch. `warmDecoded` now decodes a batch CONCURRENTLY
    /// across all cores, so this is sized to cover a typical screenful in one or two batches (fewer main-thread
    /// round-trips, faster cold-start fill) rather than the old serial ≈100 ms/batch cap.
    private let maxWarmBatch = 96
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

    func hasImage(for uid: PhotoUID) -> Bool { feed.memoryCGImage(for: uid) != nil }

    func canRetryThumbnail(for uid: PhotoUID) -> Bool {
        !feed.isKnownUnfetchable(uid)
    }

    func image(for uid: PhotoUID) -> CGImage? {
        feed.memoryCGImage(for: uid)
    }

    /// Anticipatory decode of an entire target set into RAM, independent of the per-frame `warm`/`pumpWarm`
    /// pipeline (whose `pendingWarm = uids` would otherwise clobber it). Used to warm a pinch's TARGET level at
    /// segment-build time so it is resident by commit instead of popping in black. Idempotent (warmDecoded skips
    /// already-decoded); cancels any prior in-flight prefetch so rapid level-chaining doesn't pile up callbacks.
    func prefetchWarm(_ uids: [PhotoUID]) {
        guard !uids.isEmpty else { return }
        prefetchTask?.cancel()
        prefetchTask = Task { [weak self, feed] in
            _ = await feed.warmDecoded(uids, limit: uids.count)
            if Task.isCancelled { return }
            await MainActor.run { self?.onImagesAvailable?() }
        }
    }

    func warm(_ uids: [PhotoUID]) {
        let uids = uids.filter { !feed.isKnownUnfetchable($0) }
        guard !uids.isEmpty else { return }
        // Tell the feed a viewport is live BEFORE the heavier `warmDecoded` is enqueued. `noteVisibleDemand`
        // is `nonisolated` (a lock-guarded write), so it records demand SYNCHRONOUSLY without queuing behind
        // the crawl on the serial feed actor — the crawl reads it `nonisolated` and backs its scan off at once,
        // yielding the actor to this decode instead of starving it on a cold start.
        feed.noteVisibleDemand()
        // Latest viewport wins (the coordinator passes the still-missing cells in visible-first order each
        // frame). No permanent suppression - a cell evicted from the RAM cache must be able to re-warm.
        pendingWarm = uids
        pumpWarm()
        // Reprioritise the background crawl toward what's on screen, but only once the viewport has been
        // stable for ~100 ms - so a fast scroll doesn't re-enqueue the visible set every frame.
        networkDebouncer.note(uids, at: CACurrentMediaTime())
        scheduleSettleCheck()
    }

    /// After the debounce window, if the viewport has settled, enqueue the still-missing visible cells at
    /// `.visibleNow` so they interrupt the crawl. Self-terminating: re-arms only while the viewport is still
    /// in flux. The decode pump above is unaffected - on-screen cells already on disk fill immediately.
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
                // immediately) - otherwise a fast scroll's final viewport would never get emitted.
                if self.networkDebouncer.hasPendingUnflushed() { self.scheduleSettleCheck() }
                return
            }
            let missing = settled.filter { self.feed.memoryCGImage(for: $0) == nil && !self.feed.isKnownUnfetchable($0) }
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
        pendingWarm.removeFirst(min(maxWarmBatch, pendingWarm.count))
        // The FIRST batch of a fresh data source is the opening viewport. Enqueue its true disk-misses at
        // `.visibleNow` so they jump the background crawl immediately, instead of sitting at
        // `.zoomAnchorAndFocusRow` until the ~120 ms viewport-settle upgrade (`scheduleSettleCheck`). Disk
        // hits still decode straight from disk and never touch the network. One-shot per data source — a new
        // route/library builds a new `RealMetalGridDataSource`, so steady-state scrolling is unchanged.
        let priority: ThumbnailPriority = didFirstVisiblePass ? .zoomAnchorAndFocusRow : .visibleNow
        let firstPass = !didFirstVisiblePass
        didFirstVisiblePass = true
        // One-shot cold-start trace: the gap between queueing the first warm batch and its result lands the
        // actor-starvation signal (large gap + decodedFromDisk>0 ⇒ feed actor was blocked; small gap +
        // queuedNetwork>0 ⇒ genuine disk miss going to the network). Grep `[FirstContent]`.
        let queuedAt = firstPass ? CACurrentMediaTime() : 0
        if firstPass {
            PhotoDiagnostics.shared.emit("FirstContent", ["event": "warmQueued", "count": "\(batch.count)", "phase": "coldStart"])
        }
        Task { [feed] in
            let result = await feed.warmDecoded(batch.map { ThumbnailRequest(uid: $0) }, priority: priority, limit: batch.count)
            if firstPass {
                let elapsedMs = (CACurrentMediaTime() - queuedAt) * 1000
                PhotoDiagnostics.shared.emit("FirstContent", [
                    "event": "warmDecoded", "elapsedMs": String(format: "%.0f", elapsedMs),
                    "diskDecoded": "\(result.decodedFromDisk)", "alreadyDecoded": "\(result.alreadyDecoded)",
                    "queuedNetwork": "\(result.queuedNetwork)", "missing": "\(result.missing)", "phase": "coldStart",
                ])
            }
            await MainActor.run {
                self.warmInFlight = false
                self.onImagesAvailable?()
                self.pumpWarm()
            }
        }
    }
}
