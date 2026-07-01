import Foundation
import PhotosCore

/// Coalesces per-frame viewport thumbnail requests into a single enqueue once the viewport has been
/// STABLE for a short window (~100 ms). During a fast scroll the visible set changes every frame; without
/// this, the visible set would be re-enqueued/reprioritised dozens of times per second. This emits the
/// settled set exactly ONCE per stable viewport so a visible-priority fetch interrupts the background
/// crawl after the scroll comes to rest — matching Apple Photos, where thumbnails fill in when you stop.
///
/// Pure policy: the caller supplies `now` (monotonic seconds), so it is fully deterministic and unit
/// testable with no timers. Thread-safe (NSLock) because the render path and the settle check may touch
/// it from different threads.
public final class ViewportRequestDebouncer: @unchecked Sendable {
    private let lock = NSLock()
    private let window: TimeInterval
    private var pending: [PhotoUID] = []
    private var pendingKey: Int?
    private var lastChangeAt: TimeInterval = 0
    private var lastFlushedKey: Int?

    /// - Parameter window: how long the viewport must stay unchanged before its set is emitted.
    public init(window: TimeInterval = 0.1) {
        self.window = window
    }

    public var settleWindow: TimeInterval { window }

    /// Record the latest visible set. Resets the settle timer only when the set actually CHANGED, so a
    /// stationary viewport (same set every frame) is allowed to settle and emit.
    public func note(_ uids: [PhotoUID], at now: TimeInterval) {
        let key = Self.key(uids)
        lock.withLock {
            guard key != pendingKey else { return }   // same set repeated → keep settling, don't reset
            pending = uids
            pendingKey = key
            lastChangeAt = now
            lastFlushedKey = nil                       // a new set may be flushed even if equal to a prior one
        }
    }

    /// Returns the settled set to enqueue exactly once, or `nil` if the viewport has not been stable for
    /// `window` seconds yet, or the current settled set was already emitted.
    public func flushIfStable(at now: TimeInterval) -> [PhotoUID]? {
        lock.withLock {
            guard let pendingKey, now - lastChangeAt >= window else { return nil }
            guard pendingKey != lastFlushedKey else { return nil }
            lastFlushedKey = pendingKey
            return pending
        }
    }

    /// True when there is a noted set that has NOT yet been emitted (settled or still settling). The caller
    /// uses this — not its own per-frame queue — to decide whether to re-arm the settle check, so a fast
    /// scroll's final viewport still gets emitted after the scroll stops.
    public func hasPendingUnflushed() -> Bool {
        lock.withLock { pendingKey != nil && pendingKey != lastFlushedKey }
    }

    private static func key(_ uids: [PhotoUID]) -> Int {
        var hasher = Hasher()
        hasher.combine(uids.count)
        for u in uids { hasher.combine(u) }
        return hasher.finalize()
    }
}
