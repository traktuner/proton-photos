// GridTransitionComponent.swift
//
// The relocation-component model for the single presentation lattice. A lattice key is an
// anchor-relative (row, col) offset. The anchor (the pinned focus item under the cursor / viewport
// centre) is key (0,0) and is always stable. The focus ROW (dr == 0) stays put; other rows
// re-lay-out when the column count changes between levels — those keys "relocate" and are grouped
// into components that hand off one window at a time.

import CoreGraphics

/// Anchor-relative lattice key: integer (row, col) offset from the pinned anchor.
struct RelativeSlotKey: Hashable, Sendable, Comparable {
    let dr: Int
    let dc: Int
    static func < (lhs: RelativeSlotKey, rhs: RelativeSlotKey) -> Bool {
        (lhs.dr, lhs.dc) < (rhs.dr, rhs.dc)
    }
}

enum GridTransitionComponentSide: String, Sendable, Equatable {
    case focus, upper, lower
}

/// One relocation component: a set of lattice keys whose occupants dissolve together within one
/// q-window. `visibleAreaFraction` is the peak viewport-clipped area of the component (fraction of
/// the viewport) — the weight used by the area-weighted scheduler.
struct GridTransitionComponent: Equatable, Sendable, Identifiable {
    let id: Int
    let keys: [RelativeSlotKey]
    let focusDistance: Int                 // min |dr| over keys (0 ⇒ focus-row band)
    let side: GridTransitionComponentSide
    let visibleAreaFraction: Double
    /// Assigned canonical-q dissolve window [w0, w1]. nil ⇒ not scheduled (stable / pure entry-exit).
    var window: ClosedRange<Double>?

    var areaPct: Double { visibleAreaFraction * 100 }
}
