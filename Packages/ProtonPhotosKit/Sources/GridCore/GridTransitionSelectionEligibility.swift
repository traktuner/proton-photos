// GridTransitionSelectionEligibility.swift
//
// Selection no longer gates transition eligibility.
//
// The Metal transition renderer draws only image quads while a transition is active; selection outlines and
// badges are settled-grid decorations and are intentionally not emitted by `renderTransitionDraws`. Therefore a
// relocating selected identity cannot produce a double outline during the animation. Blocking such transitions
// forced the selected/focused-photo pinch onto the legacy reflow fallback, which can diverge at release from the
// single-lattice endpoint the user was visually following.

package enum GridTransitionSelectionEligibility {
    /// Kept as a named policy because the controller still owns the decision point. Today, selection is a
    /// decoration-layer concern, not a geometry eligibility concern.
    package static func isEligible(selection: Set<Int>, relocatingIdentities: Set<Int>) -> Bool {
        _ = selection
        _ = relocatingIdentities
        return true
    }

    /// `relocatingIdentities` are the flat indices that change relative key between source and target.
    /// Derive the set of relocating identities from a built lattice.
    package static func relocatingIdentities(in lattice: GridTransitionLattice) -> Set<Int> {
        var srcKeyOf: [Int: RelativeSlotKey] = [:], tgtKeyOf: [Int: RelativeSlotKey] = [:]
        for (k, id) in lattice.sourceOcc { srcKeyOf[id] = k }
        for (k, id) in lattice.targetOcc { tgtKeyOf[id] = k }
        var out: Set<Int> = []
        for id in Set(srcKeyOf.keys).intersection(tgtKeyOf.keys) where srcKeyOf[id] != tgtKeyOf[id] { out.insert(id) }
        return out
    }
}
