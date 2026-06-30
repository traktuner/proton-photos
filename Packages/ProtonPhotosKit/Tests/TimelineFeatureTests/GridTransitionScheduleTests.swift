// GridTransitionScheduleTests.swift
//
// Phase-B grid transition layer (PRODUCTION DEFAULT, no flag): structural verification of the
// single-presentation-lattice schedule (CLICKV2_420_FULLER_CORNER + PINCH071). Pure unit tests; no GPU, no app build.

import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

@Suite struct GridTransitionScheduleTests {

    // Calibrated component areas (band/alloc-area fractions) — the production reference set.
    private func v36Components() -> [GridTransitionComponent] {
        func c(_ id: Int, _ area: Double, fd: Int) -> GridTransitionComponent {
            .init(id: id, keys: [RelativeSlotKey(dr: fd == 0 ? 0 : (id % 2 == 0 ? -fd : fd), dc: id)],
                  focusDistance: fd, side: fd == 0 ? .focus : (id % 2 == 0 ? .upper : .lower),
                  visibleAreaFraction: area, window: nil)
        }
        return [c(0, 0.2859, fd: 0), c(2, 0.1566, fd: 1), c(1, 0.1260, fd: 1),
                c(3, 0.0850, fd: 1), c(4, 0.0667, fd: 1), c(5, 0.0284, fd: 1), c(6, 0.0264, fd: 2)]
    }

    private func overloadedClickComponents(count: Int = 40) -> [GridTransitionComponent] {
        (0 ..< count).map { id in
            let distance = 1 + id / 8
            return GridTransitionComponent(
                id: id,
                keys: [RelativeSlotKey(dr: id.isMultiple(of: 2) ? -distance : distance, dc: id % 8)],
                focusDistance: distance,
                side: id.isMultiple(of: 2) ? .upper : .lower,
                visibleAreaFraction: 1.0 / Double(id + 2),
                window: nil
            )
        }
    }

    private func interior60(_ window: ClosedRange<Double>, tuning: GridTransitionTuning, phases: Int = 16) -> Int {
        let curve = tuning.localAlphaCurve
        var mn = Int.max
        for i in 0 ..< phases {
            let ph = Double(i) / Double(phases)
            let qs = GridTransitionScheduler.clickQSamples(durationSeconds: tuning.clickDurationSeconds,
                                                           hz: 60, rampFraction: tuning.clickRampFraction, phase: ph)
            let n = qs.filter { $0 > window.lowerBound && $0 < window.upperBound }
                .map { curve.localProgress(w0: window.lowerBound, w1: window.upperBound, q: $0) }
                .filter { $0 > 1e-6 && $0 < 1 - 1e-6 }.count
            mn = min(mn, n)
        }
        return mn
    }

    private func maxSimultaneousPartial(_ windows: [Int: ClosedRange<Double>], tuning: GridTransitionTuning,
                                        durationSeconds: Double, phases: Int = 50) -> Int {
        let curve = tuning.localAlphaCurve
        var worst = 0
        for hz in [60.0, 120.0] {
            for i in 0 ..< phases {
                let ph = Double(i) / Double(phases)
                let qs = GridTransitionScheduler.clickQSamples(durationSeconds: durationSeconds, hz: hz,
                                                               rampFraction: tuning.clickRampFraction, phase: ph)
                for q in qs {
                    let p = windows.values.filter {
                        let lp = curve.localProgress(w0: $0.lowerBound, w1: $0.upperBound, q: q)
                        return lp > 1e-9 && lp < 1 - 1e-9
                    }.count
                    worst = max(worst, p)
                }
            }
        }
        return worst
    }

    // ── 1. Local alpha curve ──
    @Test func alphaCurveEndpointsAndShape() {
        let f = LocalAlphaCurve(edgeFraction: 0.20)
        #expect(abs(f.value(0)) < 1e-12)
        #expect(abs(f.value(1) - 1) < 1e-12)
        #expect(abs(f.coreSlope - 1.25) < 1e-12)
        // derivative ~0 at endpoints (finite difference)
        let h = 1e-4
        #expect(f.value(h) / h < 0.05)               // slope near 0 at u=0
        #expect((1 - f.value(1 - h)) / h < 0.05)     // slope near 0 at u=1
        // monotone
        var prev = -1.0
        for i in 0 ... 1000 { let v = f.value(Double(i) / 1000); #expect(v >= prev - 1e-12); prev = v }
    }

    @Test func alphaCurveReversible() {
        let f = LocalAlphaCurve(edgeFraction: 0.20)
        for i in 0 ... 1000 {
            let u = Double(i) / 1000
            #expect(abs(f.value(1 - u) - (1 - f.value(u))) < 1e-9)   // f(1-u) == 1 - f(u)
        }
    }

    @Test func alphaPeakSlopeBelowSmootherstep() {
        let f = LocalAlphaCurve(edgeFraction: 0.20)
        var maxStep = 0.0
        let n = 100_000
        for i in 0 ..< n { maxStep = max(maxStep, abs(f.value(Double(i + 1) / Double(n)) - f.value(Double(i) / Double(n)))) }
        let peakSlope = maxStep * Double(n)
        #expect(peakSlope <= 1.26)            // ≈ 1.25, substantially below smootherstep's 1.875
    }

    // ── 2. Frame allocation reproduces the V3.6 splits ──
    @Test func allocationReproducesV36Splits() {
        let comps = v36Components()
        // 420 ms: n=26, li=1, lo=3 ⇒ budget 22 ⇒ {focus:5, five:3, smallest:2}
        let a420 = GridTransitionScheduler.allocateFrames(components: comps, budget: 22, focusID: 0, focusMinFrames: 5)
        #expect(a420[0] == 5)
        #expect(a420[6] == 2)                                   // smallest top component
        #expect(Set([1, 2, 3, 4, 5].map { a420[$0]! }) == [3])  // the five mid comps all 3
        #expect(a420.values.reduce(0, +) == 22)
        // 360 ms: budget 19 ⇒ {5,3,3,2,2,2,2}
        let a360 = GridTransitionScheduler.allocateFrames(components: comps, budget: 19, focusID: 0, focusMinFrames: 5)
        #expect(a360[0] == 5)
        #expect(a360.values.reduce(0, +) == 19)
        #expect(a360.values.filter { $0 >= 3 }.count == 3)      // focus + 2 largest reach 3
        // 450 ms: budget 23 ⇒ {5,3,3,3,3,3,3} — every component ≥3 (2 interior)
        let a450 = GridTransitionScheduler.allocateFrames(components: comps, budget: 23, focusID: 0, focusMinFrames: 5)
        #expect(a450[0] == 5)
        #expect([1, 2, 3, 4, 5, 6].allSatisfy { a450[$0]! == 3 })
        #expect(a450.values.reduce(0, +) == 23)
    }

    // ── 3. Click windows: invariants + interior-sample targets (CLICKV2_420_FULLER_CORNER) ──
    @Test func clickWindowsStructural() {
        let comps = v36Components()
        let tuning = GridTransitionTuning.default          // 420 ms
        let windows = GridTransitionScheduler.clickWindows(components: comps, tuning: tuning)
        #expect(windows.count == comps.count)
        // disjoint (touching allowed), sorted by start
        let sorted = windows.values.sorted { $0.lowerBound < $1.lowerBound }
        for i in 0 ..< sorted.count - 1 { #expect(sorted[i + 1].lowerBound >= sorted[i].upperBound - 1e-9) }
        // no visible (≥2%) component compressed ONLY into an edge zone, none a sub-0.035 sliver
        for c in comps {
            let w = windows[c.id]!
            #expect(!(w.lowerBound >= tuning.edgeZoneHi))      // not only in terminal zone
            #expect(!(w.upperBound <= tuning.edgeZoneLo))      // not only in initial zone
            #expect(w.upperBound - w.lowerBound >= tuning.minVisibleWindowWidthQ - 1e-9)
        }
        // focus (largest = cid0) ≥ 4 interior @60; corner (cid5) ≥ 2 interior @60
        #expect(interior60(windows[0]!, tuning: tuning) >= tuning.minFocusInteriorSamples60)
        #expect(interior60(windows[5]!, tuning: tuning) >= tuning.minCornerInteriorSamples60)
        // no atomic visible component (every component ≥ 1 interior)
        for c in comps { #expect(interior60(windows[c.id]!, tuning: tuning) >= 1) }
        // at most one partial component per frame (50 phases × 60/120 Hz)
        #expect(maxSimultaneousPartial(windows, tuning: tuning, durationSeconds: tuning.clickDurationSeconds) == 1)
    }

    @Test func overloadedClickWindowsRemainVisibleAtHostSamples() {
        let comps = overloadedClickComponents()
        let tuning = GridTransitionTuning.default
        let windows = GridTransitionScheduler.clickWindows(components: comps, tuning: tuning)
        let qs = GridTransitionScheduler.clickQSamples(durationSeconds: tuning.clickDurationSeconds,
                                                       hz: tuning.planRefreshHz,
                                                       rampFraction: tuning.clickRampFraction)
        let curve = tuning.localAlphaCurve

        #expect(windows.count == comps.count)
        for c in comps {
            let window = windows[c.id]!
            let interiorSamples = qs.filter { q in
                let lp = curve.localProgress(w0: window.lowerBound, w1: window.upperBound, q: q)
                return lp > 1e-9 && lp < 1 - 1e-9
            }
            #expect(!interiorSamples.isEmpty, "overloaded click window \(c.id) must have a visible sampled handoff")
        }
    }

    @Test func clickDurationIs420() {
        #expect(GridTransitionTuning.default.clickDurationMs == 420)
    }

    // ── 4. Plan render intent: exact endpoints, dissolve weights, reverse equality, no seam ──
    private func makeSyntheticPlan(window: ClosedRange<Double> = 0.3 ... 0.7) -> GridTransitionPlan {
        let k0 = RelativeSlotKey(dr: 0, dc: 0)   // anchor (stable)
        let kA = RelativeSlotKey(dr: 1, dc: 0)   // mixed
        let kB = RelativeSlotKey(dr: -1, dc: 0)  // mixed
        let unit = CGRect(x: 0, y: 0, width: 100, height: 100)
        let srcR: [RelativeSlotKey: CGRect] = [k0: unit, kA: unit.offsetBy(dx: 0, dy: 100), kB: unit.offsetBy(dx: 0, dy: -100)]
        let tgtR: [RelativeSlotKey: CGRect] = [k0: unit, kA: unit.offsetBy(dx: 0, dy: 120), kB: unit.offsetBy(dx: 0, dy: -120)]
        let lat = GridTransitionLattice(
            keys: [k0, kA, kB],
            sourceOcc: [k0: 100, kA: 200, kB: 300],
            targetOcc: [k0: 100, kA: 201, kB: 301],
            sourceRect: srcR, targetRect: tgtR,
            presentationSourceRect: srcR, presentationTargetRect: tgtR,   // all mixed ⇒ presentation == real
            components: [.init(id: 0, keys: [kA, kB], focusDistance: 1, side: .focus,
                              visibleAreaFraction: 0.2, window: nil)])
        return GridTransitionComponentBuilder.assemble(kind: .click, lattice: lat, windows: [0: window],
                                                       sourceLevel: 0, targetLevel: 1, durationMs: 420,
                                                       curve: LocalAlphaCurve())
    }

    @Test func renderIntentEndpointsExact() {
        let plan = makeSyntheticPlan()
        let at0 = plan.renderIntent(at: 0)
        // q=0: every key shows its SOURCE occupant, lp 0
        #expect(at0.first { $0.key == RelativeSlotKey(dr: 1, dc: 0) }?.sourceIdentity == 200)
        #expect(at0.allSatisfy { $0.localProgress <= 1e-9 })
        let at1 = plan.renderIntent(at: 1)
        // q=1: mixed keys show TARGET occupant, lp 1
        #expect(at1.first { $0.key == RelativeSlotKey(dr: 1, dc: 0) }?.sourceIdentity == 201)
        #expect(at1.first { $0.key == RelativeSlotKey(dr: -1, dc: 0) }?.sourceIdentity == 301)
        // anchor stable both ends
        #expect(at0.first { $0.key == RelativeSlotKey(dr: 0, dc: 0) }?.role == .stable)
        #expect(at1.first { $0.key == RelativeSlotKey(dr: 0, dc: 0) }?.sourceIdentity == 100)
    }

    @Test func dissolveWeightsComplementary() {
        let plan = makeSyntheticPlan()
        let mid = plan.renderIntent(at: 0.5).first { $0.key == RelativeSlotKey(dr: 1, dc: 0) }!
        #expect(mid.role == .dissolve)
        #expect(mid.sourceIdentity == 200 && mid.targetIdentity == 201)
        #expect(abs(mid.sourceWeight + mid.targetWeight - 1) < 1e-9)   // full-slot mix
    }

    @Test func reverseEqualityExact() {
        let plan = makeSyntheticPlan()
        // lp is a pure function of q ⇒ forward(q) == reverse(q). Compare lp at q vs at q traversed back.
        let curve = plan.curve
        for i in 0 ... 1000 {
            let q = Double(i) / 1000
            let fwd = curve.localProgress(w0: 0.3, w1: 0.7, q: q)
            let rev = curve.localProgress(w0: 0.3, w1: 0.7, q: q)   // identical call ⇒ deterministic, no hysteresis
            #expect(fwd == rev)
        }
    }

    @Test func noCompletionSeam() {
        let plan = makeSyntheticPlan()
        // total localProgress across keys is continuous and ends exactly settled (all target).
        let curve = plan.curve
        var prev = curve.localProgress(w0: 0.3, w1: 0.7, q: 0)
        var maxStep = 0.0
        let n = 2000
        for i in 1 ... n {
            let q = Double(i) / Double(n)
            let v = curve.localProgress(w0: 0.3, w1: 0.7, q: q)
            maxStep = max(maxStep, abs(v - prev)); prev = v
        }
        #expect(prev == 1.0)                       // settles exactly at q=1
        #expect(maxStep < 0.01)                    // continuous (no jump) at fine sampling
    }

    // ── 4b. Full-slot mix render fidelity (premultiplied source-over) ──

    /// A relocating-common identity that DEPARTS one key (source-only) and ARRIVES at another
    /// (target-only) — both dissolve against the uniform BACKGROUND, so both stay translucent.
    private func makeBackgroundDissolvePlan(window: ClosedRange<Double> = 0.3 ... 0.7) -> GridTransitionPlan {
        let kS = RelativeSlotKey(dr: 1, dc: 0)   // source-only (id 300 departs to bg)
        let kT = RelativeSlotKey(dr: 2, dc: 0)   // target-only (id 300 arrives from bg)
        let unit = CGRect(x: 0, y: 0, width: 100, height: 100)
        let srcKS = unit                                   // exit real source
        let tgtKT = unit.offsetBy(dx: 0, dy: 100)          // entry real target
        let synthExitTarget = CGRect(x: 50, y: -200, width: 130, height: 130)   // exit's synthesized off-grid endpoint
        let synthEntrySource = CGRect(x: -50, y: 300, width: 70, height: 70)    // entry's synthesized off-grid endpoint
        let lat = GridTransitionLattice(
            keys: [kS, kT], sourceOcc: [kS: 300], targetOcc: [kT: 300],
            sourceRect: [kS: srcKS], targetRect: [kT: tgtKT],
            presentationSourceRect: [kS: srcKS, kT: synthEntrySource],
            presentationTargetRect: [kS: synthExitTarget, kT: tgtKT],
            components: [.init(id: 0, keys: [kS, kT], focusDistance: 1, side: .lower,
                              visibleAreaFraction: 0.05, window: nil)])
        return GridTransitionComponentBuilder.assemble(kind: .click, lattice: lat, windows: [0: window],
                                                       sourceLevel: 0, targetLevel: 1, durationMs: 420,
                                                       curve: LocalAlphaCurve())
    }

    @Test func mixedDissolveSourceOpaqueTargetAlpha() {
        let plan = makeSyntheticPlan(window: 0.3 ... 0.7)
        let draws = GridTransitionRendererInput.draws(plan: plan, at: 0.5)
        let lp = plan.curve.localProgress(w0: 0.3, w1: 0.7, q: 0.5)
        // mixed key kA (src 200 → tgt 201): two draws, source then target
        let src = draws.firstIndex { $0.index == 200 && !$0.isTarget }
        let tgt = draws.firstIndex { $0.index == 201 && $0.isTarget }
        #expect(src != nil && tgt != nil)
        #expect(src! < tgt!)                                   // source drawn BEFORE target (opaque base first)
        #expect(abs(draws[src!].alpha - 1.0) < 1e-12)         // mixed source is OPAQUE (alpha 1, not 1-lp)
        #expect(abs(draws[tgt!].alpha - lp) < 1e-12)          // target at alpha lp
    }

    @Test func sourceOnlyDissolveStaysTranslucent() {
        let plan = makeBackgroundDissolvePlan()
        let draws = GridTransitionRendererInput.draws(plan: plan, at: 0.5)
        let lp = plan.curve.localProgress(w0: 0.3, w1: 0.7, q: 0.5)
        // id 300 at the source-only key fades to background ⇒ alpha 1-lp (NOT opaque)
        let s = draws.first { $0.index == 300 && !$0.isTarget }
        #expect(s != nil)
        #expect(abs(s!.alpha - (1 - lp)) < 1e-12)
    }

    @Test func targetOnlyDissolveAlphaLp() {
        let plan = makeBackgroundDissolvePlan()
        let draws = GridTransitionRendererInput.draws(plan: plan, at: 0.5)
        let lp = plan.curve.localProgress(w0: 0.3, w1: 0.7, q: 0.5)
        let t = draws.first { $0.index == 300 && $0.isTarget }   // arrives from bg ⇒ alpha lp
        #expect(t != nil)
        #expect(abs(t!.alpha - lp) < 1e-12)
    }

    @Test func sourceOverWithOpaqueSourceEqualsLinearMix() {
        // premultiplied source-over: out = top·topAlpha + under·(1-topAlpha)
        func over(top: Double, alpha: Double, under: Double) -> Double { top * alpha + under * (1 - alpha) }
        let src = 0.30, tgt = 0.80
        for i in 0 ... 100 {
            let lp = Double(i) / 100
            // CORRECT: opaque source base, then target at alpha lp
            let out = over(top: tgt, alpha: lp, under: src)
            #expect(abs(out - (src * (1 - lp) + tgt * lp)) < 1e-12)   // == full-slot mix
        }
        // CONTRAST: the OLD wrong approach (src at 1-lp + tgt at lp over opaque bg) bleeds background
        let bg = 0.0, lp = 0.5
        let layer1 = over(top: src, alpha: 1 - lp, under: bg)
        let wrong = over(top: tgt, alpha: lp, under: layer1)         // = tgt·lp + src·(1-lp)² + bg·lp(1-lp)
        #expect(abs(wrong - (src * (1 - lp) + tgt * lp)) > 0.05)     // demonstrably NOT the linear mix
    }

    // ── 4c. V3.7 entry/exit presentation geometry (side images move spatially, not fade-in-place) ──

    private func rectOf(_ key: RelativeSlotKey, in plan: GridTransitionPlan, at q: Double) -> CGRect? {
        plan.renderIntent(at: q).first { $0.key == key }?.rect
    }

    @Test func mixedKeyStillInterpolatesRealSourceToRealTarget() {
        let plan = makeSyntheticPlan()
        let kA = RelativeSlotKey(dr: 1, dc: 0)
        let src = CGRect(x: 0, y: 100, width: 100, height: 100)      // real source rect of kA
        let tgt = CGRect(x: 0, y: 120, width: 100, height: 100)      // real target rect of kA
        #expect(rectOf(kA, in: plan, at: 0) == src)                   // q=0 → real source
        #expect(rectOf(kA, in: plan, at: 1) == tgt)                   // q=1 → real target
        let mid = rectOf(kA, in: plan, at: 0.5)!
        #expect(mid.minY > src.minY && mid.minY < tgt.minY)          // genuinely interpolating between them
    }

    @Test func targetOnlyEntryHasSyntheticSourceGeometry() {
        let plan = makeBackgroundDissolvePlan()
        let kT = RelativeSlotKey(dr: 2, dc: 0)
        let realTarget = CGRect(x: 0, y: 100, width: 100, height: 100)
        #expect(rectOf(kT, in: plan, at: 0) == nil)                   // q=0: not drawn (settled source)
        let mid = rectOf(kT, in: plan, at: 0.5)
        #expect(mid != nil && mid! != realTarget)                     // 0<q<1: moving, NOT yet at final target
        #expect(rectOf(kT, in: plan, at: 1) == realTarget)            // q=1: exactly the real target rect
    }

    @Test func sourceOnlyExitHasSyntheticTargetGeometry() {
        let plan = makeBackgroundDissolvePlan()
        let kS = RelativeSlotKey(dr: 1, dc: 0)
        let realSource = CGRect(x: 0, y: 0, width: 100, height: 100)
        #expect(rectOf(kS, in: plan, at: 0) == realSource)           // q=0: exactly the real source rect
        let mid = rectOf(kS, in: plan, at: 0.5)
        #expect(mid != nil && mid! != realSource)                     // 0<q<1: moving toward synthesized target
        #expect(rectOf(kS, in: plan, at: 1) == nil)                   // q≈1: departed (existing exit semantics)
    }

    @Test func settledEndpointsRemainExact() {
        let plan = makeBackgroundDissolvePlan()
        let kS = RelativeSlotKey(dr: 1, dc: 0), kT = RelativeSlotKey(dr: 2, dc: 0)
        let q0 = plan.renderIntent(at: 0).map(\.key)
        let q1 = plan.renderIntent(at: 1).map(\.key)
        #expect(q0.contains(kS) && !q0.contains(kT))                  // q=0: source present, NO target-only entry
        #expect(q1.contains(kT) && !q1.contains(kS))                  // q=1: target present, NO source-only exit
    }

    @Test func presentationTransformFitSynthesizeAndAbort() {
        // common keys with a KNOWN transform: target = 0.5·source + (10, 20)
        let common = (0 ..< 5).map { RelativeSlotKey(dr: $0, dc: 0) }
        var src: [RelativeSlotKey: CGRect] = [:], tgt: [RelativeSlotKey: CGRect] = [:]
        for (i, k) in common.enumerated() {
            let s = CGRect(x: Double(i) * 100, y: Double(i) * 80, width: 80, height: 80)
            src[k] = s
            tgt[k] = CGRect(x: 0.5 * s.midX + 10 - 20, y: 0.5 * s.midY + 20 - 20, width: 40, height: 40)
        }
        let entry = RelativeSlotKey(dr: 9, dc: 0)   // target-only
        let exit = RelativeSlotKey(dr: -9, dc: 0)   // source-only
        tgt[entry] = CGRect(x: 500, y: 500, width: 40, height: 40)
        src[exit] = CGRect(x: 700, y: 700, width: 80, height: 80)
        let all = common + [entry, exit]
        let tf = GridTransitionPresentationTransform.fit(keys: all, sourceRect: src, targetRect: tgt)
        #expect(tf != nil)
        #expect(abs(tf!.sx - 0.5) < 1e-6 && abs(tf!.sy - 0.5) < 1e-6 && abs(tf!.tx - 10) < 1e-6 && abs(tf!.ty - 20) < 1e-6)
        let (ps, pt) = tf!.endpoints(keys: all, sourceRect: src, targetRect: tgt)
        #expect(ps[common[0]] == src[common[0]] && pt[common[0]] == tgt[common[0]])   // common: presentation == real
        #expect(ps[entry] != nil && ps[entry] != tgt[entry])         // entry: synthesized source-side endpoint
        #expect(pt[exit] != nil && pt[exit] != src[exit])            // exit: synthesized target-side endpoint
        #expect(GridTransitionPresentationTransform.fit(keys: [common[0], entry, exit], sourceRect: src, targetRect: tgt) != nil)
        // no common rects ⇒ abort (caller falls back to snap)
        #expect(GridTransitionPresentationTransform.fit(keys: [entry, exit], sourceRect: src, targetRect: tgt) == nil)
    }

    // ── 5. Selection eligibility ──
    @Test func selectionDoesNotGateTransitionGeometry() {
        let relocating: Set<Int> = [201, 301]
        #expect(GridTransitionSelectionEligibility.isEligible(selection: [], relocatingIdentities: relocating))      // empty ⇒ ok
        #expect(GridTransitionSelectionEligibility.isEligible(selection: [100], relocatingIdentities: relocating))   // stable ⇒ ok
        #expect(GridTransitionSelectionEligibility.isEligible(selection: [201], relocatingIdentities: relocating))   // selected overlays are settled-only
        #expect(GridTransitionSelectionEligibility.isEligible(selection: [100, 201], relocatingIdentities: relocating))
    }

    // (feature-flag default-OFF + gating tests live in the .serialized GridTransitionControllerTests
    //  suite — the flag is global UserDefaults state, so those tests must not run in parallel.)

    // ── 7. Builder on real engine geometry: focus row stable, components exist ──
    @Test func builderOnEngineGeometryFocusRowStable() {
        let viewport = CGSize(width: 1400, height: 900)
        let engine = SquareTileGridEngine.testRegular(sectionCounts: [4000])
        // Scroll to top so both levels show the item-0 neighbourhood; anchor on item 0 (top-left,
        // row 0 / col 0 at EVERY level ⇒ guaranteed common, relative key (0,0)).
        let src = engine.framePlan(level: 0, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 0), overscan: 0)
        let tgt = engine.framePlan(level: 1, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 0), overscan: 0)
        let common = Set(src.visibleSlots.map(\.index)).intersection(tgt.visibleSlots.map(\.index))
        #expect(common.contains(0))
        let anchor = 0
        guard let lat = GridTransitionComponentBuilder.build(source: src, target: tgt, anchorIndex: anchor, viewportSize: viewport) else {
            Issue.record("lattice build returned nil"); return
        }
        // anchor key (0,0) must be stable (same occupant)
        let k00 = RelativeSlotKey(dr: 0, dc: 0)
        #expect(lat.sourceOcc[k00] == anchor && lat.targetOcc[k00] == anchor)
        // some relocation components exist (other rows re-lay-out)
        #expect(!lat.components.isEmpty)
        // and a click plan builds + schedules every component with one-partial-at-a-time
        if let plan = ClickZoomTransitionScheduler.makePlan(source: src, target: tgt, anchorIndex: anchor, viewportSize: viewport) {
            for q in stride(from: 0.0, through: 1.0, by: 0.01) { #expect(plan.partialComponentCount(at: q) <= 1) }
            #expect(plan.renderIntent(at: 0).allSatisfy { $0.localProgress <= 1e-9 })   // q=0 settled source
        }
    }

    // ── 8. Pinch windows: fixed W071 width, disjoint, one-partial ──
    @Test func pinchWindowsStructural() {
        let comps = v36Components()
        let tuning = GridTransitionTuning.default
        let windows = GridTransitionScheduler.pinchWindows(components: comps, tuning: tuning)
        #expect(windows.count == comps.count)
        for w in windows.values { #expect(abs((w.upperBound - w.lowerBound) - tuning.pinchWidthQ) < 1e-9) }  // W071 width
        let sorted = windows.values.sorted { $0.lowerBound < $1.lowerBound }
        for i in 0 ..< sorted.count - 1 { #expect(sorted[i + 1].lowerBound >= sorted[i].upperBound - 1e-9) }   // disjoint
    }

    // ── 8b. V3.8 pinch seam: plan q=0 reproduces the SOURCE frame, q=1 the TARGET frame ──
    // This is the central "no release pop / no flash" guarantee. The coordinator builds the pinch plan from
    // engine.framePlan(source) + engine.framePlan(target-at-committed-state) and, on release, commits to that
    // SAME (level/phase/scroll) — so the settled source == plan@q=0 and settled target == plan@q=1. Here we
    // prove the plan-endpoint half purely (every drawn occupant sits exactly on its source/target frame slot).
    @Test func pinchPlanEndpointsReproduceSourceAndTargetFrames() {
        let viewport = CGSize(width: 1400, height: 900)
        let engine = SquareTileGridEngine.testRegular(sectionCounts: [4000])
        let src = engine.framePlan(level: 1, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
        let tgt = engine.framePlan(level: 2, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
        #expect(Set(src.visibleSlots.map(\.index)).contains(0) && Set(tgt.visibleSlots.map(\.index)).contains(0))
        guard let plan = PinchZoomTransitionScheduler.makePlan(source: src, target: tgt, anchorIndex: 0, viewportSize: viewport) else {
            Issue.record("pinch plan nil"); return
        }
        #expect(plan.kind == .pinch)
        var srcRect: [Int: CGRect] = [:]; for s in src.visibleSlots { srcRect[s.index] = s.viewportRect }
        var tgtRect: [Int: CGRect] = [:]; for s in tgt.visibleSlots { tgtRect[s.index] = s.viewportRect }
        func approx(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
        }
        let atZero = GridTransitionRendererInput.draws(plan: plan, at: 0)
        #expect(!atZero.isEmpty)
        for d in atZero {                                  // q=0: every drawn occupant sits on its SOURCE slot
            if let r = srcRect[d.index] { #expect(approx(d.rect, r)) }
            else { Issue.record("q=0 draw index \(d.index) absent from source frame") }
        }
        let atOne = GridTransitionRendererInput.draws(plan: plan, at: 1)
        #expect(!atOne.isEmpty)
        for d in atOne {                                   // q=1: every drawn occupant sits on its TARGET slot
            if let r = tgtRect[d.index] { #expect(approx(d.rect, r)) }
            else { Issue.record("q=1 draw index \(d.index) absent from target frame") }
        }
    }

    // ── 8b'. V3.9 chaining seam: adjacent segments sharing a detent render it IDENTICALLY ──
    // The coordinator builds each segment from the SAME per-detent frame (deterministic from the anchor), so
    // segment [3→2] at q=1 (settled L2) and segment [2→1] at q=0 (settled L2) draw the same occupants at the
    // same rects ⇒ a continuous inter-segment seam (no blank frame, no snap) when the finger crosses a detent.
    @Test func chainingSeamSharedDetentIsContinuous() {
        let viewport = CGSize(width: 1400, height: 900)
        let engine = SquareTileGridEngine.testRegular(sectionCounts: [4000])
        let f3 = engine.framePlan(level: 3, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
        let f2 = engine.framePlan(level: 2, viewportSize: viewport, scrollOffset: .zero, overscan: 0)   // shared detent
        let f1 = engine.framePlan(level: 1, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
        guard let seg1 = PinchZoomTransitionScheduler.makePlan(source: f3, target: f2, anchorIndex: 0, viewportSize: viewport),
              let seg2 = PinchZoomTransitionScheduler.makePlan(source: f2, target: f1, anchorIndex: 0, viewportSize: viewport) else {
            Issue.record("segment plan nil"); return
        }
        func byIndex(_ ds: [GridTransitionDraw]) -> [Int: CGRect] {
            Dictionary(ds.map { ($0.index, $0.rect) }, uniquingKeysWith: { a, _ in a })
        }
        let endOfSeg1 = byIndex(GridTransitionRendererInput.draws(plan: seg1, at: 1))   // settled L2 (as target)
        let startOfSeg2 = byIndex(GridTransitionRendererInput.draws(plan: seg2, at: 0)) // settled L2 (as source)
        let common = Set(endOfSeg1.keys).intersection(startOfSeg2.keys)
        #expect(!common.isEmpty)
        for i in common {
            let a = endOfSeg1[i]!, b = startOfSeg2[i]!
            #expect(abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01)
        }
    }

    // ── 8c. Lattice eligibility boundary (the live pinch / click scope) ──
    @Test func latticeEligibilityBoundary() {
        let e = SquareTileGridEngine.testRegular(sectionCounts: [100])
        // Single-lattice scope = adjacent NORMAL-level pairs (lo ∈ {0,1,2}, focusRowRelayout). The normal→
        // overview boundary (L3→L4) is NOT eligible ⇒ the live pinch falls back to the GridZoomTransaction reflow.
        #expect(e.metrics(level: 0).transitionKindToNext == .focusRowRelayout)
        #expect(e.metrics(level: 1).transitionKindToNext == .focusRowRelayout)
        #expect(e.metrics(level: 2).transitionKindToNext == .focusRowRelayout)
        #expect(e.metrics(level: 3).transitionKindToNext != .focusRowRelayout)
    }

    // ── 8d. Chain band = the contiguous focusRowRelayout run (mirrors coordinator.eligiblePinchChainBand) ──
    @Test func chainBandIsContiguousFocusRowRelayoutRun() {
        let e = SquareTileGridEngine.testRegular(sectionCounts: [100])
        func band(around level: Int) -> (lo: Int, hi: Int) {
            var lo = level, hi = level
            while lo > 0, e.metrics(level: lo - 1).transitionKindToNext == .focusRowRelayout { lo -= 1 }
            while hi < e.levelCount - 1, e.metrics(level: hi).transitionKindToNext == .focusRowRelayout { hi += 1 }
            return (lo, hi)
        }
        for start in 0 ... 3 { #expect(band(around: start) == (0, 3)) }   // every normal level chains across [0,3]
        #expect(band(around: 4).lo == band(around: 4).hi)                // overview start ⇒ degenerate (reflow)
        #expect(band(around: 5).lo == band(around: 5).hi)
    }

    // ── 9. Performance structure: scheduling is one-shot (no per-frame allocation/sort) ──
    @Test func schedulingIsOneShotAndCheap() {
        let comps = v36Components()
        let tuning = GridTransitionTuning.default
        let windows = GridTransitionScheduler.clickWindows(components: comps, tuning: tuning)   // built ONCE
        // per-frame draw intent reads the immutable plan; no graph/sort rebuild. Just exercise it.
        let plan = makeSyntheticPlan(window: windows[0]!)
        for i in 0 ... 25 { _ = GridTransitionRendererInput.draws(plan: plan, at: Double(i) / 25) }
        #expect(windows.count == comps.count)
    }
}
