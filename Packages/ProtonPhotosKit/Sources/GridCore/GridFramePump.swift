/// Coalesces render invalidations into at-most-one render per display tick, and keeps the tick loop
/// alive until a frame actually reached the screen.
///
/// Hosts that render a scroll surface must never draw per input event: touch deltas arrive faster than
/// vsync, and every extra draw acquires another drawable from a small fixed pool — once the pool is
/// exhausted the acquire BLOCKS the render thread, which is felt as scroll stutter. Instead, events call
/// `invalidate()` and the platform display link asks `shouldTick`; after each render the host reports
/// `completeTick(presented:hasPendingWork:)`:
///  - `presented: false` (no drawable / zero-sized surface / not in a window) keeps the frame dirty so
///    the next tick RETRIES — a transiently unavailable drawable can never strand stale or empty content
///    on screen until some future input event happens to redraw.
///  - `hasPendingWork: true` (visible thumbnails still streaming in, deferred quality upgrades) keeps
///    the loop ticking so arriving content is drawn without any external nudge.
///
/// Pure state, no timing: the host owns the actual display link and simply starts it while `shouldTick`
/// and stops it when `completeTick` returns `false`.
public struct GridFramePump: Equatable, Sendable {
    /// A fresh pump wants a first frame — content configured before the first tick must draw.
    private var dirty = true

    public init() {}

    /// Note that the on-screen state changed (scroll, new items, layout, arrived thumbnails).
    public mutating func invalidate() { dirty = true }

    /// Whether the next display tick should render.
    public var shouldTick: Bool { dirty }

    /// Report the outcome of a tick's render. Returns whether the tick loop must keep running.
    @discardableResult
    public mutating func completeTick(presented: Bool, hasPendingWork: Bool) -> Bool {
        dirty = !presented || hasPendingWork
        return dirty
    }
}
