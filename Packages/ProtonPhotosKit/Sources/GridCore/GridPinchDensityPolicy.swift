import CoreGraphics

/// Maps a cumulative pinch-gesture scale onto discrete grid density steps.
///
/// This is the single shared tuning for hosts that drive the level ladder with a discrete pinch (one
/// gesture → n level steps): the platform recognizer supplies its raw cumulative scale and this policy
/// decides how many ladder steps that motion is worth. Positive steps mean zoom IN (fewer columns,
/// lower level id); negative steps mean zoom OUT.
///
/// Tuning: one step per 2× of finger scale, committed at the geometric midpoint (√2 ≈ 1.41×). A casual
/// small pinch (< ~1.4×) therefore changes nothing, a deliberate pinch moves exactly one level, and only
/// a full-range gesture crosses several — the previous 1.4×-per-step mapping stepped at ~1.18×, which let
/// one ordinary pinch run through the entire ladder.
public enum GridPinchDensityPolicy {
    /// Finger-scale ratio worth one density step.
    public static let scaleRatioPerStep: CGFloat = 2.0

    /// Recognizer scales are clamped into this range so a degenerate reading (0, ∞) cannot produce a
    /// runaway step count; ±4 steps is already beyond any production ladder.
    public static let clampedScaleRange: ClosedRange<CGFloat> = 1.0 / 16.0 ... 16.0

    /// The number of ladder steps a cumulative gesture scale is worth (rounded to the nearest step, so
    /// each step commits at the geometric midpoint between step anchors).
    public static func levelSteps(pinchScale: CGFloat) -> Int {
        Int(continuousLevelDelta(pinchScale: pinchScale).rounded())
    }

    /// Continuous ladder displacement for live pinch rendering. Positive means zoom IN (toward lower level ids),
    /// negative means zoom OUT. Hosts that can render intermediate frames should feed this directly into the shared
    /// `GridZoomTransaction`; hosts that only commit discrete changes should use `levelSteps`.
    public static func continuousLevelDelta(pinchScale: CGFloat) -> CGFloat {
        guard pinchScale.isFinite, pinchScale > 0 else { return 0 }
        let clamped = min(max(pinchScale, clampedScaleRange.lowerBound), clampedScaleRange.upperBound)
        return log2(clamped) / log2(scaleRatioPerStep)
    }
}
