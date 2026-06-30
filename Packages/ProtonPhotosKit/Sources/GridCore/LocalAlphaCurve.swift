// LocalAlphaCurve.swift
//
// C1 slope-limited "linear-core" local-alpha curve for the single-presentation-lattice transition
// (CLICKV2 / CLICKV2_420_FULLER_CORNER, per the V3.4–V3.6 offline evidence passes).
//
// Pure function of a normalized position u ∈ [0,1]. No state, no timer, no clock. Reversible.
// For edge fraction a and core slope s = 1/(1-a):
//   0      <= u < a    : f(u) = s·u²/(2a)            (smooth ease-in, slope 0 → s)
//   a      <= u <= 1-a : f(u) = s·a/2 + s·(u-a)      (near-linear core, slope s)
//   1-a    <  u <= 1   : f(u) = 1 - s·(1-u)²/(2a)    (smooth ease-out, slope s → 0)
//
// Properties (asserted by tests): f(0)=0, f(1)=1, f'(0)=f'(1)=0, C1 at the joins, monotone,
// reversible f(1-u) == 1 - f(u). At a = 0.20 the peak slope s = 1.25 (vs smootherstep's 1.875).

package struct LocalAlphaCurve: Equatable, Sendable {
    /// Smooth-edge fraction `a` on each side. Clamped to the open interval (0, 0.5).
    package let edgeFraction: Double

    package init(edgeFraction: Double = 0.20) {
        self.edgeFraction = min(0.49, max(0.0001, edgeFraction))
    }

    /// Peak slope of f in u-space. = 1.25 at a = 0.20.
    package var coreSlope: Double { 1.0 / (1.0 - edgeFraction) }

    /// f(u): C1 linear-core ramp, clamped to [0,1] outside the unit interval.
    package func value(_ u: Double) -> Double {
        let a = edgeFraction
        let s = coreSlope
        if u <= 0 { return 0 }
        if u >= 1 { return 1 }
        if u < a { return s * u * u / (2 * a) }
        if u <= 1 - a { return s * a / 2 + s * (u - a) }
        let ud = 1 - u
        return 1 - s * ud * ud / (2 * a)
    }

    /// localProgress for canonical progress q inside the window [w0, w1].
    /// lp = 0 for q <= w0, lp = 1 for q >= w1. Pure function of q (no hysteresis ⇒ reversible).
    package func localProgress(w0: Double, w1: Double, q: Double) -> Double {
        if w1 <= w0 { return q < w0 ? 0 : 1 }
        return value((q - w0) / (w1 - w0))
    }
}
