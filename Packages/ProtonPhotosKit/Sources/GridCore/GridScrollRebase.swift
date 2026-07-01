import CoreGraphics

/// A short, subtle, deterministic SCROLL-REBASE bridge.
///
/// When a zoom commit (or a content-shrinking zoom-out) leaves the camera at an out-of-bounds scroll, the
/// settled grid must move from the gesture/anchored scroll to the legal clamped scroll. Doing that with an
/// instant `scroll(to:)` is a visible JUMP. Instead the presentation layer renders the settled grid at the
/// scroll position this helper interpolates — an ease-out slide over ~150 ms — so the correction is a subtle
/// motion, never a snap. It carries NO grid layout model: it only eases one scalar (the Y scroll) between two
/// engine-derived values, and ends EXACTLY at `toY` (the canonical settled scroll).
public enum GridScrollRebase {
    /// Bridge length — within the 120–180 ms spec.
    public static let duration: CFTimeInterval = 0.15
    /// Minimum scroll delta (px) worth animating; below this the clamp is imperceptible, so commit instantly.
    public static let minPx: CGFloat = 1.5

    /// Whether a rebase from `fromY` to `toY` is large enough to animate (else the caller settles instantly).
    public static func shouldArm(fromY: CGFloat, toY: CGFloat) -> Bool { abs(fromY - toY) > minPx }

    /// Quadratic ease-out (no bounce), clamped to `[0, 1]`. Monotonic, `easeOut(0)=0`, `easeOut(1)=1`.
    public static func easeOut(_ progress: CGFloat) -> CGFloat {
        let p = min(1, max(0, progress))
        return 1 - (1 - p) * (1 - p)
    }

    /// The interpolated scroll Y at `progress` (0 = source, 1 = target). `scrollY(_,_, 1) == toY` exactly.
    public static func scrollY(fromY: CGFloat, toY: CGFloat, progress: CGFloat) -> CGFloat {
        let e = easeOut(progress)
        return e >= 1 ? toY : fromY + (toY - fromY) * e
    }

    /// Linear time → progress for a bridge started at `start`, evaluated at `now`.
    public static func progress(start: CFTimeInterval, now: CFTimeInterval) -> CGFloat {
        guard duration > 0 else { return 1 }
        return CGFloat(min(1, max(0, (now - start) / duration)))
    }
}
