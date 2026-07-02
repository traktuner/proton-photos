// GridTransitionComponent.swift
//
// The relocation-component model for the single presentation lattice. A lattice key is an
// anchor-relative (row, col) offset. The anchor (the pinned focus item under the cursor / viewport
// centre) is key (0,0) and is always stable. The anchor (0,0) stays put; the rest of the focus row AND other rows re-lay-out when the column
// count changes between levels - those keys "relocate" and are grouped
// into components that hand off one window at a time.

/// Anchor-relative lattice key: integer (row, col) offset from the pinned anchor.
package struct RelativeSlotKey: Hashable, Sendable, Comparable {
    package let dr: Int
    package let dc: Int

    package init(dr: Int, dc: Int) {
        self.dr = dr
        self.dc = dc
    }

    package static func < (lhs: RelativeSlotKey, rhs: RelativeSlotKey) -> Bool {
        (lhs.dr, lhs.dc) < (rhs.dr, rhs.dc)
    }
}

package enum GridTransitionComponentSide: String, Sendable, Equatable {
    case focus, upper, lower
}

/// One relocation component: a set of lattice keys whose occupants dissolve together within one
/// q-window. `visibleAreaFraction` is the peak viewport-clipped area of the component (fraction of
/// the viewport) - the weight used by the area-weighted scheduler.
package struct GridTransitionComponent: Equatable, Sendable, Identifiable {
    package let id: Int
    package let keys: [RelativeSlotKey]
    package let focusDistance: Int                 // min |dr| over keys (0 ⇒ focus-row band)
    package let side: GridTransitionComponentSide
    package let visibleAreaFraction: Double
    /// Assigned canonical-q dissolve window [w0, w1]. nil ⇒ not scheduled (stable / pure entry-exit).
    package var window: ClosedRange<Double>?

    package init(id: Int,
                 keys: [RelativeSlotKey],
                 focusDistance: Int,
                 side: GridTransitionComponentSide,
                 visibleAreaFraction: Double,
                 window: ClosedRange<Double>? = nil) {
        self.id = id
        self.keys = keys
        self.focusDistance = focusDistance
        self.side = side
        self.visibleAreaFraction = visibleAreaFraction
        self.window = window
    }
}
