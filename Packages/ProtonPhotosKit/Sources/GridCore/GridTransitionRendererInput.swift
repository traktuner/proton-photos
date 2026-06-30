// GridTransitionRendererInput.swift
//
// Adapts the pure per-frame draw intent into renderer-facing draws under the renderer's PREMULTIPLIED
// SOURCE-OVER blend (sourceRGB=.one, destRGB=.oneMinusSourceAlpha; MetalGridRenderer).
//
// A source↔target (mixed) dissolve must NOT draw both occupants translucent over the background:
// under source-over that yields  tgt·lp + src·(1-lp)² + bg·lp·(1-lp)  — background bleed-through and an
// under-weighted source (≈25% bg at lp=0.5), which is NOT the validated full-slot mix. Instead the
// SOURCE occupant is the OPAQUE BASE (alpha 1, drawn first) and the TARGET is drawn OVER it at alpha
// = lp, so source-over composites to the exact full-slot mix  src·(1-lp) + tgt·lp  with no bg bleed.
//   • mixed dissolve  → source alpha 1 (opaque base) + target alpha lp (over it).
//   • source-only      → the relocating common departs to BACKGROUND ⇒ it stays translucent (alpha 1-lp).
//   • target-only      → the relocating common arrives from BACKGROUND ⇒ translucent (alpha lp).
//   • stable/source/target/entry/exit → one opaque draw.
// Draw order is far-to-near (largest focusDistance behind); within a mixed slot, source precedes target.

import CoreGraphics

package struct GridTransitionDraw: Equatable, Sendable {
    package let index: Int          // flat identity index → UID / texture lookup
    package let rect: CGRect        // viewport-space
    package let alpha: Double       // 0…1
    package let componentID: Int
    package let isTarget: Bool      // source vs target occupant (diagnostics / ordering)
    package let localProgress: Double
}

package enum GridTransitionRendererInput {
    package static func draws(plan: GridTransitionPlan, at q: Double) -> [GridTransitionDraw] {
        var out: [GridTransitionDraw] = []
        for slot in plan.renderIntent(at: q) {
            switch slot.role {
            case .stable, .source, .target, .exit:
                if let id = slot.sourceIdentity {
                    out.append(.init(index: id, rect: slot.rect, alpha: 1, componentID: slot.componentID,
                                     isTarget: false, localProgress: slot.localProgress))
                }
            case .entry:
                if let id = slot.targetIdentity {
                    out.append(.init(index: id, rect: slot.rect, alpha: 1, componentID: slot.componentID,
                                     isTarget: true, localProgress: slot.localProgress))
                }
            case .dissolve:
                // Mixed (source AND target present) ⇒ source is the opaque base, target over it at lp
                // (source-over ⇒ src·(1-lp)+tgt·lp, no bg bleed). A single-sided dissolve to/from the
                // background keeps its (1-lp)/lp weight — it really does fade against the uniform bg.
                let mixed = slot.sourceIdentity != nil && slot.targetIdentity != nil
                if let s = slot.sourceIdentity {
                    out.append(.init(index: s, rect: slot.rect, alpha: mixed ? 1.0 : slot.sourceWeight,
                                     componentID: slot.componentID, isTarget: false, localProgress: slot.localProgress))
                }
                if let t = slot.targetIdentity {
                    out.append(.init(index: t, rect: slot.rect, alpha: slot.targetWeight,
                                     componentID: slot.componentID, isTarget: true, localProgress: slot.localProgress))
                }
            }
        }
        return out
    }
}
