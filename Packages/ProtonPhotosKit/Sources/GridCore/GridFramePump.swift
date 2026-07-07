/// Coalesces render invalidations into at-most-one render per display tick, and keeps the tick loop
/// alive until a frame actually reached the screen.
///
/// Hosts that render a scroll surface must never draw per input event: touch deltas arrive faster than
/// vsync, and every extra draw acquires another drawable from a small fixed pool - once the pool is
/// exhausted the acquire BLOCKS the render thread, which is felt as scroll stutter. Instead, events call
/// `invalidate()` and the platform display link asks `shouldTick`; after each render the host reports
/// `completeTick(presented:hasPendingWork:)`:
///  - `presented: false` (no drawable / zero-sized surface / not in a window) keeps the frame dirty so
///    the next tick RETRIES - a transiently unavailable drawable can never strand stale or empty content
///    on screen until some future input event happens to redraw.
///  - `hasPendingWork: true` (visible thumbnails still streaming in, deferred quality upgrades) keeps
///    the loop ticking so arriving content is drawn without any external nudge.
///
/// The pump also owns an `active` gate for host lifecycle: an inactive host (its tab/window is not the
/// foreground surface) must NOT keep the display link alive doing render/warm work that competes with the
/// menus/transitions on screen. While inactive `shouldTick` is always false, so the host's tick loop stops;
/// reactivating re-arms exactly one frame (`dirty = true`) so returning to the surface redraws immediately
/// with no external nudge. Window presence stays a host concern (a UIKit concept); this gate is the
/// platform-neutral "is this surface the active one" signal, so it is unit-testable in isolation.
///
/// Pure state, no timing: the host owns the actual display link and simply starts it while `shouldTick`
/// and stops it when `completeTick` returns `false`.
public struct GridFramePump: Equatable, Sendable {
    /// A fresh pump wants a first frame - content configured before the first tick must draw.
    private var dirty = true
    /// Whether the host surface is the active one. A fresh pump is active (the common single-surface case).
    private var active = true

    public init() {}

    /// Note that the on-screen state changed (scroll, new items, layout, arrived thumbnails).
    public mutating func invalidate() { dirty = true }

    /// Whether the host surface is currently active (its tab/window is foreground).
    public var isActive: Bool { active }

    /// Set whether the host surface is active. Reactivating re-arms one frame so the surface redraws on
    /// return; deactivating leaves `dirty` untouched (so the pending frame is drawn once the surface is
    /// active again) but immediately gates `shouldTick` to false. Returns whether the active state changed,
    /// so the host only reacts (stop the link / arm a render) on a real transition.
    @discardableResult
    public mutating func setActive(_ active: Bool) -> Bool {
        guard active != self.active else { return false }
        self.active = active
        if active { dirty = true }
        return true
    }

    /// Whether the next display tick should render: only when active AND something is dirty.
    public var shouldTick: Bool { active && dirty }

    /// Report the outcome of a tick's render. Returns whether the tick loop must keep running - never while
    /// inactive, so a host that deactivates mid-flight stops its loop on the next `completeTick`.
    @discardableResult
    public mutating func completeTick(presented: Bool, hasPendingWork: Bool) -> Bool {
        dirty = !presented || hasPendingWork
        return active && dirty
    }
}
