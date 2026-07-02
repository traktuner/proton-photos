// PinchZoomTransitionScheduler.swift
//
// Builds the immutable PINCH071 plan for a live L0↔L1 pinch: W071 fixed-width (0.0706 q) component
// windows, centre-out, host-owned q (the coordinator drives q from a critically-damped follower on
// the raw magnification — NOT computed here). No component-local timers; lp is a pure function of q,
// so a fast gesture that crosses a window between frames is legitimately compressed (no prolonging),
// and reversing the gesture reverses the presentation immediately.

import CoreGraphics

package enum PinchZoomTransitionScheduler {
    package static func makePlan(source: GridFramePlan, target: GridFramePlan, anchorIndex: Int,
                                 viewportSize: CGSize, tuning: GridTransitionTuning = .default) -> GridTransitionPlan? {
        guard let lat = GridTransitionComponentBuilder.build(source: source, target: target,
                                                             anchorIndex: anchorIndex, viewportSize: viewportSize),
              !lat.components.isEmpty else { return nil }
        return makePlan(lattice: lat, sourceLevel: source.levelID, targetLevel: target.levelID, tuning: tuning)
    }

    package static func makePlan(lattice lat: GridTransitionLattice, sourceLevel: Int, targetLevel: Int,
                                 tuning: GridTransitionTuning = .default) -> GridTransitionPlan? {
        guard !lat.components.isEmpty else { return nil }
        let windows = GridTransitionScheduler.pinchWindows(components: lat.components, tuning: tuning)
        guard windows.count == lat.components.count else { return nil }
        return GridTransitionComponentBuilder.assemble(
            kind: .pinch, lattice: lat, windows: windows,
            sourceLevel: sourceLevel, targetLevel: targetLevel,
            durationMs: 0, curve: tuning.localAlphaCurve)
    }
}
