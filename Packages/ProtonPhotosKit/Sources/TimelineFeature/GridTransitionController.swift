// GridTransitionController.swift
//
// Coordinator-side driver for the single-presentation-lattice transition between ADJACENT normal
// levels (any lo→lo+1 in the focusRowRelayout band [0,3]; pinch chains across the band). It is the single
// integration point: builds the immutable plan from engine frame plans, enforces selection eligibility
// (else reports a fallback reason and the host uses the stable instant snap),
// holds the HOST-OWNED canonical q (the coordinator's display-link advances it — there is NO
// component-local timer here), and produces per-frame draw intent. Reversible: setting q backward
// reverses the presentation exactly. Building happens ONCE per gesture; per frame is read-only.

import Foundation
import CoreGraphics
import PhotosCore

enum GridTransitionFallbackReason: String, Sendable {
    case latticeBuildFailed, selectionRelocates, scheduleDegenerate, none
}

final class GridTransitionController {
    private(set) var plan: GridTransitionPlan?
    private(set) var q: Double = 0
    private(set) var lastFallback: GridTransitionFallbackReason = .none
    private var elapsed: Double = 0
    var tuning: GridTransitionTuning

    init(tuning: GridTransitionTuning = .default) { self.tuning = tuning }

    var isActive: Bool { plan != nil }

    /// Try to begin a click (toolbar/keyboard +/-) transition. Returns true iff a plan was built and
    /// is eligible; false ⇒ the host must use the stable instant snap (reason in `lastFallback`).
    @discardableResult
    func beginClick(source: GridFramePlan, target: GridFramePlan, anchorIndex: Int,
                    viewportSize: CGSize, selection: Set<Int>) -> Bool {
        guard let lat = GridTransitionComponentBuilder.build(source: source, target: target,
                                                             anchorIndex: anchorIndex, viewportSize: viewportSize),
              !lat.components.isEmpty else { return fail(.latticeBuildFailed) }
        let relocating = GridTransitionSelectionEligibility.relocatingIdentities(in: lat)
        guard GridTransitionSelectionEligibility.isEligible(selection: selection, relocatingIdentities: relocating)
        else { return fail(.selectionRelocates) }
        guard let p = ClickZoomTransitionScheduler.makePlan(source: source, target: target, anchorIndex: anchorIndex,
                                                            viewportSize: viewportSize, tuning: tuning)
        else { return fail(.scheduleDegenerate) }
        plan = p; q = 0; elapsed = 0; lastFallback = .none
        PhotoDiagnostics.shared.emit("GridTransition", [
            "event": "PLAN_BUILT", "candidate": "CLICKV2_420_FULLER_CORNER",
            "durationMs": "\(Int(tuning.clickDurationMs))", "components": "\(p.components.count)",
            "src": "\(source.levelID)", "tgt": "\(target.levelID)"])
        return true
    }

    /// Try to begin a LIVE pinch (PINCH071) transition. Same eligibility gate as the click, but the plan's
    /// progress `q` is then HOST-DRIVEN via `setProgress` (the V3.8 scrub driver) instead of the trapezoidal
    /// time profile — there is no `advanceClick`/timer for a pinch plan. Returns true iff a plan was built
    /// and is eligible; false ⇒ the host uses the legacy geometry-only `GridZoomTransaction` reflow.
    @discardableResult
    func beginPinch(source: GridFramePlan, target: GridFramePlan, anchorIndex: Int,
                    viewportSize: CGSize, selection: Set<Int>) -> Bool {
        guard let lat = GridTransitionComponentBuilder.build(source: source, target: target,
                                                             anchorIndex: anchorIndex, viewportSize: viewportSize),
              !lat.components.isEmpty else { return fail(.latticeBuildFailed) }
        let relocating = GridTransitionSelectionEligibility.relocatingIdentities(in: lat)
        guard GridTransitionSelectionEligibility.isEligible(selection: selection, relocatingIdentities: relocating)
        else { return fail(.selectionRelocates) }
        guard let p = PinchZoomTransitionScheduler.makePlan(source: source, target: target, anchorIndex: anchorIndex,
                                                            viewportSize: viewportSize, tuning: tuning)
        else { return fail(.scheduleDegenerate) }
        plan = p; q = 0; elapsed = 0; lastFallback = .none
        PhotoDiagnostics.shared.emit("GridTransition", [
            "event": "PLAN_BUILT", "candidate": "PINCH071",
            "components": "\(p.components.count)", "src": "\(source.levelID)", "tgt": "\(target.levelID)"])
        return true
    }

    /// The kind of the active plan (nil when inactive). The coordinator's draw branch uses it to pick the
    /// progress source: `.click` ⇒ trapezoidal `advanceClick`; `.pinch` ⇒ host-driven `setProgress`.
    var activeKind: GridTransitionKindTag? { plan?.kind }

    private func fail(_ reason: GridTransitionFallbackReason) -> Bool {
        lastFallback = reason; plan = nil; q = 0
        // Every fallback now is a genuine ineligible-geometry case (the feature flag is gone) → worth logging.
        PhotoDiagnostics.shared.emit("GridTransition", ["event": "FALLBACK", "reason": reason.rawValue])
        return false
    }

    /// Host-owned progress. The coordinator calls this from its display-link tick with the wall-clock
    /// delta; q is the trapezoidal click profile of total elapsed time (NOT a component timer).
    /// Returns true while the transition is still running; false once it has settled (q==1) and ended.
    @discardableResult
    func advanceClick(bySeconds dt: Double) -> Bool {
        guard plan != nil else { return false }
        elapsed += max(0, dt)
        q = ClickZoomTransitionScheduler.progress(atElapsed: elapsed, tuning: tuning)
        if elapsed >= tuning.clickDurationSeconds { q = 1; end(); return false }
        return true
    }

    /// Directly set host-owned q (used by live pinch / reverse — q is authoritative, lp follows it).
    func setProgress(_ value: Double) { q = min(1, max(0, value)) }

    func end() { let was = plan != nil; plan = nil; q = 0; elapsed = 0
        if was { PhotoDiagnostics.shared.emit("GridTransition", ["event": "SETTLED"]) } }

    /// Per-frame draw intent (read-only on the immutable plan). Empty when inactive.
    func currentDraws() -> [GridTransitionDraw] {
        guard let plan else { return [] }
        return GridTransitionRendererInput.draws(plan: plan, at: q)
    }

    func partialComponentCount() -> Int { plan?.partialComponentCount(at: q) ?? 0 }
}
