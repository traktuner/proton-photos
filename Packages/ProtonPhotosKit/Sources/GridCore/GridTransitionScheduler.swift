// GridTransitionScheduler.swift
//
// Pure, one-shot (plan-time) scheduling primitives shared by the click and pinch schedulers:
//   • the C1 trapezoidal-velocity click q(t) host profile,
//   • the area-weighted frame allocation (reproduces the V3.6 CLICKV2_420 split),
//   • centre-out-by-area placement, and the mapping of frame blocks → disjoint q-windows.
//
// Nothing here runs per frame; a plan is built once and consumed immutably. No clocks, no timers.

import CoreGraphics

package enum GridTransitionScheduler {

    // ── host-owned click q(t): C1 trapezoidal velocity (matches V3.4-V3.6) ──
    package static func clickQ(_ t: Double, durationSeconds d: Double, rampFraction: Double) -> Double {
        let r = rampFraction * d
        let vpk = 1.0 / (d - r)
        if t <= 0 { return 0 }
        if t >= d { return 1 }
        if t < r { return 0.5 * (vpk / r) * t * t }
        if t < d - r { return 0.5 * vpk * r + vpk * (t - r) }
        let td = d - t
        return 1.0 - 0.5 * (vpk / r) * td * td
    }

    /// Frame-sampled q at a given refresh. n = ceil(d·hz) so the final tick reaches q == 1 (settle).
    package static func clickQSamples(durationSeconds d: Double, hz: Double, rampFraction: Double,
                                      phase: Double = 0) -> [Double] {
        let n = Int(ceil(d * hz - 1e-9))
        return (0...n).map { k in clickQ(min(d, (Double(k) + phase) / hz), durationSeconds: d, rampFraction: rampFraction) }
    }

    // ── area-weighted frame allocation ──
    // Floors: focus comp → focusMinFrames; every other component → 1 (then de-atomized to 2 = 1 interior).
    // Surplus is spent first de-atomizing all components to 2 frames, then raising them to 3 frames
    // (= 2 interior samples) in descending area order, then any remainder by descending area.
    // Reproduces the V3.6 splits exactly: 360→{5,3,3,2,2,2,2}, 420→{5,3,3,3,3,3,2}, 450→{5,3,3,3,3,3,3}.
    package static func allocateFrames(components: [GridTransitionComponent], budget: Int,
                                       focusID: Int, focusMinFrames: Int) -> [Int: Int] {
        let n = components.count
        guard n > 0 else { return [:] }
        if budget < n {  // degenerate: cannot give 1 each - area-weighted (caller will fall back)
            let total = max(1e-9, components.reduce(0) { $0 + $1.visibleAreaFraction })
            var a: [Int: Int] = [:]
            for c in components { a[c.id] = max(0, Int((Double(budget) * c.visibleAreaFraction / total).rounded())) }
            return a
        }
        var alloc = Dictionary(uniqueKeysWithValues: components.map { ($0.id, 1) })
        var rem = budget - n
        while alloc[focusID, default: 1] < focusMinFrames, rem > 0 { alloc[focusID]! += 1; rem -= 1 }
        let nonFocus = components.filter { $0.id != focusID }.sorted { $0.visibleAreaFraction > $1.visibleAreaFraction }
        for target in [2, 3] {
            for c in nonFocus where rem > 0 {
                if alloc[c.id]! < target { alloc[c.id]! += 1; rem -= 1 }
            }
        }
        let allByArea = components.sorted { $0.visibleAreaFraction > $1.visibleAreaFraction }
        var i = 0
        while rem > 0 { alloc[allByArea[i % allByArea.count].id]! += 1; rem -= 1; i += 1 }
        return alloc
    }

    /// Left→right component order: largest area at the timeline centre (≈ peak geometry velocity),
    /// smaller/farther components fanned outward.
    package static func centreOutOrder(components: [GridTransitionComponent]) -> [Int] {
        let byArea = components.sorted {
            ($0.visibleAreaFraction, -Double($0.focusDistance), -Double($0.id))
                > ($1.visibleAreaFraction, -Double($1.focusDistance), -Double($1.id))
        }
        let m = byArea.count
        guard m > 0 else { return [] }
        let centre = (m - 1) / 2
        var seq = [centre]; var k = 1
        while seq.count < m {
            if centre + k < m { seq.append(centre + k) }
            if seq.count < m, centre - k >= 0 { seq.append(centre - k) }
            k += 1
        }
        var out = [Int](repeating: 0, count: m)
        for (rank, pos) in seq.enumerated() { out[pos] = byArea[rank].id }
        return out
    }

    /// Build the CLICKV2_420-style variable, area-weighted, disjoint (touching) q-windows.
    package static func clickWindows(components: [GridTransitionComponent],
                                     tuning: GridTransitionTuning) -> [Int: ClosedRange<Double>] {
        guard !components.isEmpty else { return [:] }
        let d = tuning.clickDurationSeconds, hz = tuning.planRefreshHz, r = tuning.clickRampFraction
        let qs = clickQSamples(durationSeconds: d, hz: hz, rampFraction: r)
        let n = qs.count - 1
        let li = max(0, tuning.leadInFrames60)
        // minimal lead-out so the last window ends at/below the terminal edge zone
        var lo = 1
        while lo < n, qs[n - lo] > tuning.edgeZoneHi { lo += 1 }
        let budget = (n - lo) - li
        guard budget >= components.count else {
            return visibleSampledClickWindows(components: components, qSamples: qs, leadInFrames: li,
                                              leadOutFrames: lo, tuning: tuning)
        }
        let focus = components.max { $0.visibleAreaFraction < $1.visibleAreaFraction }!.id
        let alloc = allocateFrames(components: components, budget: budget,
                                   focusID: focus, focusMinFrames: tuning.minFocusInteriorSamples60 + 1)
        let order = centreOutOrder(components: components)
        var windows: [Int: ClosedRange<Double>] = [:]
        var f = li
        for cid in order {
            let a = f, b = f + (alloc[cid] ?? 1)
            windows[cid] = qs[a] ... qs[min(b, n)]
            f = b
        }
        guard windowsHaveInteriorSamples(windows, qSamples: qs, tuning: tuning) else {
            return visibleSampledClickWindows(components: components, qSamples: qs, leadInFrames: li,
                                              leadOutFrames: lo, tuning: tuning)
        }
        return windows
    }

    /// Overloaded click plans, such as wide 9↔7 focus-row relayouts, can have too many relocation components for
    /// the legacy disjoint frame-budget split. A one-frame q-window is technically scheduled but lands only on
    /// endpoint samples at 60 Hz, so the handoff is invisible. This fallback keeps the same centre-out ordering but
    /// centres each window on an actual host q sample and spans neighbouring samples, guaranteeing real interior
    /// handoff frames. It is plan-time only and may overlap windows instead of snapping an otherwise valid transition.
    private static func visibleSampledClickWindows(components: [GridTransitionComponent],
                                                   qSamples qs: [Double],
                                                   leadInFrames li: Int,
                                                   leadOutFrames lo: Int,
                                                   tuning: GridTransitionTuning) -> [Int: ClosedRange<Double>] {
        let order = centreOutOrder(components: components)
        guard !order.isEmpty, qs.count >= 3 else { return [:] }
        let lastSample = qs.count - 1
        let firstCenter = min(max(1, li + 1), max(1, lastSample - 1))
        let lastCenter = max(firstCenter, min(lastSample - max(1, lo), lastSample - 1))
        let centerSlots = max(1, lastCenter - firstCenter + 1)
        var windows: [Int: ClosedRange<Double>] = [:]
        let floorWidth = tuning.minVisibleWindowWidthQ
        for (rank, cid) in order.enumerated() {
            let centerIndex: Int
            if order.count == 1 {
                centerIndex = firstCenter + (centerSlots - 1) / 2
            } else {
                let pos = Double(rank) * Double(centerSlots - 1) / Double(order.count - 1)
                centerIndex = firstCenter + Int(pos.rounded())
            }
            let a = max(0, centerIndex - 1)
            let b = min(lastSample, centerIndex + 1)
            let center = qs[centerIndex]
            let lower = min(qs[a], center - floorWidth / 2)
            let upper = max(qs[b], center + floorWidth / 2)
            windows[cid] = max(0, lower) ... min(1, upper)
        }
        return windows
    }

    private static func windowsHaveInteriorSamples(_ windows: [Int: ClosedRange<Double>],
                                                   qSamples qs: [Double],
                                                   tuning: GridTransitionTuning) -> Bool {
        let curve = tuning.localAlphaCurve
        return windows.values.allSatisfy { window in
            guard window.upperBound - window.lowerBound >= tuning.minVisibleWindowWidthQ - 1e-9 else { return false }
            return qs.contains { q in
                let lp = curve.localProgress(w0: window.lowerBound, w1: window.upperBound, q: q)
                return lp > 1e-9 && lp < 1 - 1e-9
            }
        }
    }

    /// Fixed-width W071-style pinch windows, centre-out, disjoint within a central band.
    package static func pinchWindows(components: [GridTransitionComponent],
                                     tuning: GridTransitionTuning) -> [Int: ClosedRange<Double>] {
        guard !components.isEmpty else { return [:] }
        let w = tuning.pinchWidthQ
        let order = centreOutOrder(components: components)
        let m = order.count
        // centre slot at 0.5; fan out by exactly w (touching). Clamp into [0.05, 0.95].
        let centreIndex = (m - 1) / 2
        var windows: [Int: ClosedRange<Double>] = [:]
        for (idx, cid) in order.enumerated() {
            let offset = Double(idx - centreIndex)
            var c = 0.5 + offset * w
            c = min(0.95 - w / 2, max(0.05 + w / 2, c))
            windows[cid] = (c - w / 2) ... (c + w / 2)
        }
        return windows
    }
}
