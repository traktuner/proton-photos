// ClickZoomTransitionScheduler.swift
//
// Builds the immutable CLICKV2_420_FULLER_CORNER plan for a toolbar/keyboard +/- L0↔L1 click:
// area-weighted variable windows (V3.6 split), C1 linear-core alpha, host-owned trapezoidal q.

import CoreGraphics

package enum ClickZoomTransitionScheduler {
    /// Build a click transition plan from settled source/target frame plans. Returns nil if the
    /// lattice can't be derived or the schedule would be degenerate ⇒ caller falls back to snap.
    package static func makePlan(source: GridFramePlan, target: GridFramePlan, anchorIndex: Int,
                                 viewportSize: CGSize, tuning: GridTransitionTuning = .default) -> GridTransitionPlan? {
        guard let lat = GridTransitionComponentBuilder.build(source: source, target: target,
                                                             anchorIndex: anchorIndex, viewportSize: viewportSize),
              !lat.components.isEmpty else { return nil }
        return makePlan(lattice: lat, sourceLevel: source.levelID, targetLevel: target.levelID, tuning: tuning)
    }

    /// Build a click transition plan from a precomputed presentation lattice. Used by the controller after
    /// eligibility checks so the expensive relocation lattice is not rebuilt for scheduling.
    package static func makePlan(lattice lat: GridTransitionLattice, sourceLevel: Int, targetLevel: Int,
                                 tuning: GridTransitionTuning = .default) -> GridTransitionPlan? {
        guard !lat.components.isEmpty else { return nil }
        let windows = GridTransitionScheduler.clickWindows(components: lat.components, tuning: tuning)
        guard windows.count == lat.components.count else { return nil }   // every component scheduled
        return GridTransitionComponentBuilder.assemble(
            kind: .click, lattice: lat, windows: windows,
            sourceLevel: sourceLevel, targetLevel: targetLevel,
            durationMs: tuning.clickDurationMs, curve: tuning.localAlphaCurve)
    }

    /// Host-owned canonical progress for the click at elapsed time `t` (seconds). Forward only;
    /// the reverse path replays q backward (lp is a pure function of q ⇒ reversible).
    package static func progress(atElapsed t: Double, tuning: GridTransitionTuning = .default) -> Double {
        GridTransitionScheduler.clickQ(t, durationSeconds: tuning.clickDurationSeconds,
                                       rampFraction: tuning.clickRampFraction)
    }
}
