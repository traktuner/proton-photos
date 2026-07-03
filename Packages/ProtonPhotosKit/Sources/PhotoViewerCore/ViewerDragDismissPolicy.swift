import CoreGraphics

/// Shared semantics for the viewer's one-finger drag-to-dismiss — the interaction iOS users reach for first.
///
/// With the media UNZOOMED, a downward drag sticks the media to the finger (it translates and shrinks a little
/// while the backdrop dims), and on release it either springs back to its resting position or — past a
/// distance/velocity threshold — closes the viewer back to the grid. Platform adapters own the recognizers and
/// the transform; the engagement axis, the finger→scale/opacity mapping and the release decision live here so it
/// feels identical everywhere. Complements ``ViewerPinchDismissPolicy`` (two-finger pinch): both can be attached
/// at once, and neither engages while the media is zoomed in (that regime belongs to pan/zoom).
public enum ViewerDragDismissPolicy {
    /// A drag must travel at least this far (points) before it can take the media, so a tap with a little jitter
    /// never grabs it.
    public static let engageDistance: CGFloat = 12

    /// Vertical dominance required to engage: |dy| must exceed |dx| × this. A horizontal-ish drag stays with the
    /// pager's swipe, so paging is never stolen.
    public static let verticalDominance: CGFloat = 1.2

    /// Release dismisses when the drag travelled at least this fraction of the viewport height…
    public static let dismissDistanceFraction: CGFloat = 0.20

    /// …OR the downward release velocity (points/second) is at least this — a quick flick closes early.
    public static let dismissVelocity: CGFloat = 900

    /// The media never shrinks below this while attached to the finger (so it stays clearly the same photo).
    public static let minimumDisplayScale: CGFloat = 0.6

    /// How far the black backdrop dims at full drag (1 = opaque, this = most transparent) — a subtle "peeling
    /// away toward the grid" cue.
    public static let minimumBackdropOpacity: CGFloat = 0.5

    /// Spring-back animation parameters (duration seconds, damping 0…1) for a below-threshold release.
    public static let springBackDuration: Double = 0.32
    public static let springBackDamping: CGFloat = 0.82

    /// Whether a drag translation should take the media: only when it is not zoomed in (panning owns that), and
    /// the drag is a clear, past-the-engage-distance VERTICAL gesture (so horizontal paging keeps its swipe).
    public static func engages(translation: CGSize, isZoomedIn: Bool) -> Bool {
        guard !isZoomedIn else { return false }
        let dx = abs(translation.width), dy = abs(translation.height)
        guard dx.isFinite, dy.isFinite else { return false }
        return dy >= engageDistance && dy >= dx * verticalDominance
    }

    /// Normalized drag progress 0…1 from the vertical travel over the viewport height.
    public static func progress(translationY: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard viewportHeight > 0, translationY.isFinite else { return 0 }
        return min(1, max(0, abs(translationY) / viewportHeight))
    }

    /// The on-screen scale while attached: shrinks gently with progress, floored so it never collapses.
    public static func displayScale(progress: CGFloat) -> CGFloat {
        let p = min(1, max(0, progress))
        return max(minimumDisplayScale, 1 - p * (1 - minimumDisplayScale))
    }

    /// The backdrop opacity while attached (1 → ``minimumBackdropOpacity`` as the drag grows).
    public static func backdropOpacity(progress: CGFloat) -> CGFloat {
        let p = min(1, max(0, progress))
        return max(minimumBackdropOpacity, 1 - p * (1 - minimumBackdropOpacity))
    }

    /// The release decision: dismiss when the drag travelled far enough downward OR was flicked down fast enough.
    /// A degenerate reading never spuriously closes the viewer.
    public static func shouldDismiss(translationY: CGFloat, velocityY: CGFloat, viewportHeight: CGFloat) -> Bool {
        guard viewportHeight > 0, translationY.isFinite, velocityY.isFinite else { return false }
        if translationY >= viewportHeight * dismissDistanceFraction { return true }
        return velocityY >= dismissVelocity && translationY > 0
    }
}
