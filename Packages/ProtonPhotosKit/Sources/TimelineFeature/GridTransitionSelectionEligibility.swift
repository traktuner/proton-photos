// GridTransitionSelectionEligibility.swift
//
// Conservative selection rule (matches the V3.x decision): animate only when the selection cannot
// produce a double-outline. Empty selection ⇒ eligible. All selected identities stable on the same
// relative key ⇒ eligible. ANY selected identity relocates ⇒ ineligible ⇒ stable instant snap.

import Foundation

enum GridTransitionSelectionEligibility {
    /// `relocatingIdentities` are the flat indices that change relative key between source and target.
    static func isEligible(selection: Set<Int>, relocatingIdentities: Set<Int>) -> Bool {
        if selection.isEmpty { return true }
        return selection.isDisjoint(with: relocatingIdentities)
    }

    /// Derive the set of relocating identities from a built lattice.
    static func relocatingIdentities(in lattice: GridTransitionLattice) -> Set<Int> {
        var srcKeyOf: [Int: RelativeSlotKey] = [:], tgtKeyOf: [Int: RelativeSlotKey] = [:]
        for (k, id) in lattice.sourceOcc { srcKeyOf[id] = k }
        for (k, id) in lattice.targetOcc { tgtKeyOf[id] = k }
        var out: Set<Int> = []
        for id in Set(srcKeyOf.keys).intersection(tgtKeyOf.keys) where srcKeyOf[id] != tgtKeyOf[id] { out.insert(id) }
        return out
    }
}
