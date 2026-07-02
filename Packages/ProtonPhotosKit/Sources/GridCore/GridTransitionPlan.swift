// GridTransitionPlan.swift
//
// Immutable per-direction transition plan + the pure per-frame draw-intent generator.
// One continuous geometry rect per lattice key (lerp source⇄target by smootherstep(q)); the
// occupant handoff is a FULL-SLOT mix(sourceResolved, targetResolved, localProgress) carried as
// complementary source/target weights. localProgress is a pure function of the host-owned q, so
// reversing q reverses the whole presentation exactly. No clocks, no per-frame graph building.

import CoreGraphics

package enum GridTransitionKindTag: String, Sendable { case click, pinch }

package enum TransitionSlotRole: String, Sendable, Equatable {
    case stable     // same occupant both ends - drawn once
    case source     // mixed key, before window - source occupant
    case target     // mixed key, after window - target occupant
    case dissolve   // mixed/relocating key, inside window - source⇄target full-slot mix
    case entry      // target-only occupant arriving (no crossfade partner)
    case exit       // source-only occupant departing
}

/// Immutable per-frame draw intent for one lattice key at one canonical q.
package struct ResolvedTransitionSlot: Equatable, Sendable {
    package let key: RelativeSlotKey
    package let rect: CGRect                 // continuous viewport rect at this q
    package let role: TransitionSlotRole
    package let sourceIdentity: Int?         // flat index of source occupant (nil ⇒ background)
    package let targetIdentity: Int?         // flat index of target occupant (nil ⇒ background)
    package let sourceWeight: Double         // 1-lp for dissolve; 1 for source/stable/exit; 0 for entry/target
    package let targetWeight: Double         // lp for dissolve; 1 for target/entry; 0 otherwise
    package let localProgress: Double        // crossfade progress within the component window (0…1)
    package let componentID: Int             // -1 ⇒ none
}

package func gridTransitionSmootherstep(_ x: Double) -> Double {
    if x <= 0 { return 0 }
    if x >= 1 { return 1 }
    return x * x * x * (x * (x * 6 - 15) + 10)
}

package struct GridTransitionPlan: Sendable {
    package let kind: GridTransitionKindTag
    package let sourceLevel: Int
    package let targetLevel: Int
    package let durationMs: Double
    package let curve: LocalAlphaCurve

    package let components: [GridTransitionComponent]
    package let keys: [RelativeSlotKey]
    package let sourceOcc: [RelativeSlotKey: Int]      // flat index of source occupant
    package let targetOcc: [RelativeSlotKey: Int]
    package let sourceRect: [RelativeSlotKey: CGRect]  // REAL viewport rect at q=0 (nil for entries)
    package let targetRect: [RelativeSlotKey: CGRect]  // REAL viewport rect at q=1 (nil for exits)
    // V3.7 presentation geometry - filled for EVERY key. Mixed/stable: real source/target. Entries:
    // a SYNTHESIZED source-side endpoint (so they slide/scale IN). Exits: a synthesized target-side
    // endpoint (so they slide/scale OUT). Identity/role decisions still use sourceOcc/targetOcc +
    // the REAL source/targetRect; only the spatial path uses these.
    package let presentationSourceRect: [RelativeSlotKey: CGRect]
    package let presentationTargetRect: [RelativeSlotKey: CGRect]
    package let componentOfKey: [RelativeSlotKey: Int]
    package let windowOf: [Int: ClosedRange<Double>]   // componentID → q-window

    /// Geometry eases with smootherstep(q); the occupant crossfade is gated by the component window.
    package func geomProgress(_ q: Double) -> Double { gridTransitionSmootherstep(q) }

    /// Continuous spatial path for a key: interpolate its PRESENTATION endpoints (defined for every
    /// key). Mixed/stable keys move real source → real target; entries/exits move along their
    /// synthesized off-grid endpoint - so side/new images participate in the grid motion, not fade.
    private func rect(for key: RelativeSlotKey, gp: Double) -> CGRect {
        let s = presentationSourceRect[key] ?? sourceRect[key] ?? targetRect[key] ?? .zero
        let t = presentationTargetRect[key] ?? targetRect[key] ?? sourceRect[key] ?? .zero
        return CGRect(x: s.minX + (t.minX - s.minX) * gp,
                      y: s.minY + (t.minY - s.minY) * gp,
                      width: s.width + (t.width - s.width) * gp,
                      height: s.height + (t.height - s.height) * gp)
    }

    /// Pure per-frame draw intent at canonical progress q ∈ [0,1].
    package func renderIntent(at q: Double) -> [ResolvedTransitionSlot] {
        let gp = geomProgress(q)
        var out: [ResolvedTransitionSlot] = []
        out.reserveCapacity(keys.count)
        for key in keys {
            let r = rect(for: key, gp: gp)
            let s = sourceOcc[key]
            let t = targetOcc[key]
            let cid = componentOfKey[key] ?? -1
            let win = windowOf[cid]

            if let s, let t, s == t {
                out.append(.init(key: key, rect: r, role: .stable, sourceIdentity: s, targetIdentity: s,
                                 sourceWeight: 1, targetWeight: 0, localProgress: 0, componentID: cid))
                continue
            }
            // mixed / relocating-common / entry / exit
            let lp: Double = {
                guard let win else { return q < (s != nil ? 1 : 0) ? 0 : 1 }
                return curve.localProgress(w0: win.lowerBound, w1: win.upperBound, q: q)
            }()

            if let s, let t { // mixed key: source occupant ⇄ target occupant
                if lp <= 0 {
                    out.append(.init(key: key, rect: r, role: .source, sourceIdentity: s, targetIdentity: nil,
                                     sourceWeight: 1, targetWeight: 0, localProgress: 0, componentID: cid))
                } else if lp >= 1 {
                    out.append(.init(key: key, rect: r, role: .target, sourceIdentity: t, targetIdentity: nil,
                                     sourceWeight: 1, targetWeight: 0, localProgress: 1, componentID: cid))
                } else {
                    out.append(.init(key: key, rect: r, role: .dissolve, sourceIdentity: s, targetIdentity: t,
                                     sourceWeight: 1 - lp, targetWeight: lp, localProgress: lp, componentID: cid))
                }
            } else if let s { // source-only: relocating-common departs to background (or exit)
                if win != nil {
                    if lp <= 0 {
                        out.append(.init(key: key, rect: r, role: .source, sourceIdentity: s, targetIdentity: nil,
                                         sourceWeight: 1, targetWeight: 0, localProgress: 0, componentID: cid))
                    } else if lp < 1 {
                        out.append(.init(key: key, rect: r, role: .dissolve, sourceIdentity: s, targetIdentity: nil,
                                         sourceWeight: 1 - lp, targetWeight: lp, localProgress: lp, componentID: cid))
                    } // lp>=1 ⇒ fully background ⇒ not drawn
                } else {
                    if gp >= 1 - 1e-9 { continue }   // exit item is gone once geometry reaches target ⇒ q=1 == target settled
                    out.append(.init(key: key, rect: r, role: .exit, sourceIdentity: s, targetIdentity: nil,
                                     sourceWeight: 1, targetWeight: 0, localProgress: 0, componentID: cid))
                }
            } else if let t { // target-only: relocating-common arrives from background (or entry)
                if win != nil {
                    if lp >= 1 {
                        out.append(.init(key: key, rect: r, role: .target, sourceIdentity: t, targetIdentity: nil,
                                         sourceWeight: 1, targetWeight: 0, localProgress: 1, componentID: cid))
                    } else if lp > 0 {
                        out.append(.init(key: key, rect: r, role: .dissolve, sourceIdentity: nil, targetIdentity: t,
                                         sourceWeight: 1 - lp, targetWeight: lp, localProgress: lp, componentID: cid))
                    } // lp<=0 ⇒ background ⇒ not drawn
                } else {
                    if gp <= 1e-9 { continue }       // entry item not present until geometry leaves source ⇒ q=0 == source settled
                    out.append(.init(key: key, rect: r, role: .entry, sourceIdentity: nil, targetIdentity: t,
                                     sourceWeight: 0, targetWeight: 1, localProgress: 1, componentID: cid))
                }
            }
        }
        return out
    }

    /// Count of keys whose component is partially dissolving (0 < lp < 1) at this q.
    package func partialComponentCount(at q: Double) -> Int {
        var cids = Set<Int>()
        for (cid, win) in windowOf {
            let lp = curve.localProgress(w0: win.lowerBound, w1: win.upperBound, q: q)
            if lp > 1e-9 && lp < 1 - 1e-9 { cids.insert(cid) }
        }
        return cids.count
    }
}
