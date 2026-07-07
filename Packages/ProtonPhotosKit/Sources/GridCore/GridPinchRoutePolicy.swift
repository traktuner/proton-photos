/// The shared routing decision for a live grid pinch: which presentation the first adjacent step in the
/// resolved direction should ATTEMPT. Both platform hosts (macOS trackpad magnify, iOS two-finger pinch)
/// previously duplicated this tree in their `.undecided` routing and short-pinch release paths. The attempt
/// ORDER is policy and lives here; hosts still own attempting the candidate - plan building can fail - and
/// fall back to the `GridZoomTransaction` reflow.
public enum GridPinchRoutePolicy {
    public enum Candidate: Equatable, Sendable {
        /// The step stays inside the focus-row chain band → scrub the shared lattice plan.
        case lattice(target: Int)
        /// The step crosses an overview boundary → the two-layer offscreen dissolve.
        case overviewDissolve(target: Int)
        /// Out of ladder bounds or no eligible presentation → the transaction reflow (a short-pinch
        /// release interprets this as "no step" - there is nothing to animate).
        case reflow
    }

    /// The contiguous adjacent-step band around `level` that is lattice-eligible (every step `lo→lo+1` is
    /// `.focusRowRelayout`). An overview start yields a degenerate band (`lo == hi`) → reflow routing.
    public static func chainBand(around level: Int, engine: SquareTileGridEngine) -> (lo: Int, hi: Int) {
        var lo = level, hi = level
        while lo > 0, engine.metrics(level: lo - 1).transitionKindToNext == .focusRowRelayout { lo -= 1 }
        while hi < engine.levelCount - 1, engine.metrics(level: hi).transitionKindToNext == .focusRowRelayout { hi += 1 }
        return (lo, hi)
    }

    /// Route one resolved pinch direction from `startLevel`. `direction < 0` means zoom in (toward lower
    /// level ids). `chainBand` is the band captured at gesture start, not recomputed per sample.
    public static func candidate(
        startLevel: Int,
        direction: Int,
        chainBand: (lo: Int, hi: Int),
        engine: SquareTileGridEngine
    ) -> Candidate {
        let next = startLevel + (direction < 0 ? -1 : 1)
        guard next >= 0, next < engine.levelCount else { return .reflow }
        if next >= chainBand.lo, next <= chainBand.hi { return .lattice(target: next) }
        if engine.isOverviewBoundary(startLevel, next) { return .overviewDissolve(target: next) }
        return .reflow
    }
}
