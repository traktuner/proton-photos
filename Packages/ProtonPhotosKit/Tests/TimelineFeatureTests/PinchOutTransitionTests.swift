import Testing
import CoreGraphics
@testable import TimelineFeature

/// Tests for the pinch-OUT cross-dissolve core (`PinchOutPlan` + `PinchOutTiming`). These pin the behaviour
/// that the previous bug violated: the SOURCE grid must participate (fade out) while the TARGET fades in,
/// with complementary alpha, focus-row protection, a stable mapping, and an autonomous time clock.
@Suite struct PinchOutTransitionTests {

    // A 2-cell source row (uid 0,1) → a denser 3-cell row of DIFFERENT photos (uid 5,6,7) plus a new lower
    // row (uid 8) that the source never covered. Mirrors a real zoom-out re-arrangement.
    func source() -> [PinchOutCell] {
        [PinchOutCell(flatIndex: 0, rect: CGRect(x: 0, y: 0, width: 100, height: 100)),
         PinchOutCell(flatIndex: 1, rect: CGRect(x: 100, y: 0, width: 100, height: 100))]
    }
    func target() -> [PinchOutCell] {
        [PinchOutCell(flatIndex: 5, rect: CGRect(x: 0, y: 0, width: 66, height: 100)),
         PinchOutCell(flatIndex: 6, rect: CGRect(x: 66, y: 0, width: 66, height: 100)),
         PinchOutCell(flatIndex: 7, rect: CGRect(x: 132, y: 0, width: 66, height: 100)),
         PinchOutCell(flatIndex: 8, rect: CGRect(x: 0, y: 150, width: 66, height: 100))]   // new lower row
    }
    /// A plan with NO focus protection (focus far away) so alpha is uniform — easiest to assert the model.
    func unfocusedPlan() -> PinchOutPlan {
        PinchOutPlan(source: source(), target: target(), anchorFlatIndex: 0, focusScreenY: -10_000, focusRadius: 100)
    }

    // 1. The plan is non-trivial: existing centre cells are replacements AND new regions are target-only.
    @Test func replacementPlanNonZero() {
        let p = unfocusedPlan()
        #expect(p.replacementCount > 0, "centre cells must be replaced, not left untouched")
        #expect(p.targetOnlyCount > 0, "newly exposed regions must exist as target-only")
    }

    // 2. In a replacement, source fades out, target fades in, complementary (sum ≈ 1).
    @Test func sourceAlphaDropsInReplacement() {
        let p = unfocusedPlan()
        let srcReplaced = p.source.first { !$0.isUnchanged }!
        let tgtReplacement = p.target.first { $0.kind == .replacement }!
        #expect(p.sourceAlpha(srcReplaced, progress: 0.2) > p.sourceAlpha(srcReplaced, progress: 0.8))
        #expect(p.targetAlpha(tgtReplacement, progress: 0.2) < p.targetAlpha(tgtReplacement, progress: 0.8))
        for prog in stride(from: 0.0, through: 1.0, by: 0.25) {
            let s = p.sourceAlpha(srcReplaced, progress: CGFloat(prog))
            let t = p.targetAlpha(tgtReplacement, progress: CGFloat(prog))
            #expect(abs((s + t) - 1) < 0.001, "complementary alpha must sum to 1 (got \(s + t)) at \(prog)")
        }
    }

    // 3. The bug guard: where target is fading IN, source is NOT fully opaque (so target isn't hidden behind it).
    @Test func targetNotHiddenBehindOpaqueSource() {
        let p = unfocusedPlan()
        let srcReplaced = p.source.first { !$0.isUnchanged }!
        let tgtReplacement = p.target.first { $0.kind == .replacement }!
        #expect(p.targetAlpha(tgtReplacement, progress: 0.5) > 0)
        #expect(p.sourceAlpha(srcReplaced, progress: 0.5) < 1, "source must drop where target is fading in")
    }

    // 4. Target-only (newly exposed) cells fade in cleanly 0 → 1.
    @Test func targetOnlyEdgeFadeIn() {
        let p = unfocusedPlan()
        let edge = p.target.first { $0.kind == .targetOnly }!
        #expect(p.targetAlpha(edge, progress: 0) < 0.01)
        #expect(p.targetAlpha(edge, progress: 1) > 0.99)
    }

    // 5. The focus row is suppressed: at mid-progress a focus target cell is dimmer than a far one.
    @Test func focusRowSuppression() {
        // Focus at the top row (midY 50); the new lower row (midY 200) is outside the band.
        let p = PinchOutPlan(source: source(), target: target(), anchorFlatIndex: 0, focusScreenY: 50, focusRadius: 100)
        let focusTarget = p.target.first { $0.rect.midY < 100 && $0.kind == .replacement }!
        let farTarget = p.target.first { $0.kind == .targetOnly }!
        #expect(p.targetAlpha(focusTarget, progress: 0.5) < p.targetAlpha(farTarget, progress: 0.5),
                "focus-row target must come in later than a far target")
    }

    // 6. The anchor / focus source cell stays the most opaque (topmost / calm) during the dissolve.
    @Test func anchorTopmost() {
        let p = PinchOutPlan(source: source(), target: target(), anchorFlatIndex: 0, focusScreenY: 50, focusRadius: 100)
        let focusSource = p.source.min { $0.rect.midY < $1.rect.midY }!   // top row = focus
        // A source cell far from focus would fade faster; the focus source holds higher alpha at mid-progress.
        let farProgressAlpha = (1 - p.localProgress(focusWeight: 0, progress: 0.5))   // a hypothetical far cell
        #expect(p.sourceAlpha(focusSource, progress: 0.5) > farProgressAlpha)
    }

    // 7. The mapping is deterministic / stable: same snapshots → identical plan (no per-frame identity churn).
    @Test func mappingStability() {
        let a = unfocusedPlan()
        let b = unfocusedPlan()
        #expect(a == b)
        #expect(a.replacementCount == b.replacementCount && a.targetOnlyCount == b.targetOnlyCount)
    }

    // 8. Progress is time-driven: it advances with elapsed time at constant inputs.
    @Test func autonomousProgress() {
        let early = PinchOutTiming.progress(elapsed: 0.1, duration: 1.0)
        let late = PinchOutTiming.progress(elapsed: 0.6, duration: 1.0)
        #expect(late > early)
        #expect(PinchOutTiming.progress(elapsed: 1.0, duration: 1.0) >= 0.999)
    }

    // 9. A fast pinch yields a shorter duration than a slow one (clamped to the sane range).
    @Test func fastPinchShortDuration() {
        let fast = PinchOutTiming.duration(velocity: 6)
        let slow = PinchOutTiming.duration(velocity: 0.2)
        #expect(fast < slow)
        #expect(fast >= PinchOutTiming.fastDuration - 0.001)
        #expect(slow <= PinchOutTiming.slowDuration + 0.001)
    }

    // 10. Where a target cell exists, it resolves to fully opaque (output is the target photo, never blank).
    @Test func noBlackWhenTargetExists() {
        let p = unfocusedPlan()
        for item in p.target where item.kind != .unchanged {
            #expect(p.targetAlpha(item, progress: 1) > 0.99, "target cell \(item.flatIndex) must reach full opacity")
        }
    }
}
