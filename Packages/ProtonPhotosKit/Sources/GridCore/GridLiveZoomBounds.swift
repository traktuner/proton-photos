import CoreGraphics

/// Bounds the LIVE (visual) zoom level for the rubber-band over-zoom past the largest-thumbnail detent.
///
/// Pinching IN at level 0 drives the raw continuous level NEGATIVE. The apparent-metric model
/// (`GridZoomTransaction.apparentSlotSide` / `SquareTileGridEngine.apparentSlotSide`) already grows the tile
/// for `x < 0` - that is the intended elastic over-zoom - but an older host-level live-zoom path used to
/// hard-clamp `x` to `0`, so the rubber-band never showed.
///
/// This maps the raw pinch level to the bounded VISUAL level:
///  • in-band / densest end (`x >= 0`): unchanged - pass through, clamped to the densest detent.
///  • over-zoom (`x < 0`): iOS-style elastic resistance with diminishing return, asymptotically approaching
///    `-maxOverZoom`, so an aggressive pinch cannot produce absurd tile sizes.
///
/// This is VISUAL ONLY. The COMMITTED grid level is clamped to valid detents separately
/// (`finishLiveZoom` + `engine.clampLevel`), so a temporarily-negative visual level never commits a negative
/// level. The densest end is intentionally NOT rubber-banded (the apparent model clamps there).
public enum GridLiveZoomBounds {
    /// Maximum elastic overshoot past the largest detent, in level units (the negative asymptote). This is the
    /// ORIGINAL working rubber-band's `softOver` asymptote (~half a level). Named so the depth is one tunable.
    public static let maxOverZoom: CGFloat = 0.5

    /// Map a RAW continuous pinch level to the bounded VISUAL live level - the ORIGINAL `softOver` over-travel.
    public static func visualLevel(rawLevel x: CGFloat, levelCount: Int, maxOverZoom: CGFloat = maxOverZoom) -> CGFloat {
        let densest = CGFloat(max(0, levelCount - 1))
        guard x < 0 else { return min(x, densest) }          // in-band / densest end: unchanged (clamped)
        guard maxOverZoom > 0 else { return 0 }
        // The original "soft over-travel": softOver(o) = cap·(1 − 1/(1+o)); monotonic, 0 at o=0, → cap as o→∞.
        let over = -x
        return -maxOverZoom * (1 - 1 / (1 + over))
    }

    /// Clamp an already-resolved visual level to the safe live range `[-maxOverZoom, densest]` (used by the
    /// release spring-back, which works directly in visual-level space rather than raw pinch space).
    public static func clampVisual(_ v: CGFloat, levelCount: Int) -> CGFloat {
        let densest = CGFloat(max(0, levelCount - 1))
        return min(max(v, -maxOverZoom), densest)
    }
}
