import CoreGraphics

/// Edge auto-scroll velocity for a Photos-style drag-selection gesture.
///
/// When the user holds a thumbnail and drags toward the top or bottom of the grid, the grid must scroll
/// automatically so the selection can extend past the visible rows. This is the shared, pure calculation
/// behind that behavior: given the finger's Y in viewport space, it returns a signed scroll velocity
/// (points/second) — zero in the middle "dead zone", ramping linearly to `maxSpeed` as the finger enters the
/// edge band, and clamped at `maxSpeed` once the finger reaches (or passes) the very edge.
///
/// Sign convention matches content-offset space: NEGATIVE scrolls toward the top (older photos), POSITIVE
/// toward the bottom (newest). Platform-free and value-only so the ramp is unit-tested here (`GridCoreTests`)
/// and the UIKit host is a thin driver that just multiplies by the frame delta.
package enum GridEdgeAutoScrollPolicy {

    /// Signed auto-scroll velocity in points/second for a finger at `touchY` within a viewport of height
    /// `viewportHeight`. `edgeInset` is the band thickness at each edge; `maxSpeed` the velocity at the edge.
    ///
    /// - Returns: `< 0` in the top band (scroll up), `> 0` in the bottom band (scroll down), `0` in the middle.
    ///   The band is capped at half the viewport so a dead zone always remains on short viewports, and a finger
    ///   dragged beyond an edge (`touchY < 0` or `> viewportHeight`, which happens during auto-scroll) clamps to
    ///   `±maxSpeed` rather than overshooting.
    package static func velocity(
        touchY: CGFloat,
        viewportHeight: CGFloat,
        edgeInset: CGFloat,
        maxSpeed: CGFloat
    ) -> CGFloat {
        guard viewportHeight > 0, edgeInset > 0, maxSpeed > 0 else { return 0 }
        // Never let the two bands meet: keep at least a middle dead zone even on a very short viewport.
        let band = min(edgeInset, viewportHeight / 2)

        // Top band: 0 at the inner edge → -maxSpeed at (or above) the very top.
        if touchY < band {
            let depth = (band - max(touchY, 0)) / band     // 0 at inner edge, 1 at/above the top
            return -maxSpeed * min(depth, 1)
        }

        // Bottom band: 0 at the inner edge → +maxSpeed at (or below) the very bottom.
        let bottomInnerEdge = viewportHeight - band
        if touchY > bottomInnerEdge {
            let depth = (min(touchY, viewportHeight) - bottomInnerEdge) / band   // 0 at inner edge, 1 at/below bottom
            return maxSpeed * min(depth, 1)
        }

        return 0
    }

    /// Whether the finger is currently in either edge band (auto-scroll is active). Convenience for the host
    /// so it can start/stop its display-link driver without recomputing the ramp.
    package static func isInEdgeBand(
        touchY: CGFloat,
        viewportHeight: CGFloat,
        edgeInset: CGFloat
    ) -> Bool {
        guard viewportHeight > 0, edgeInset > 0 else { return false }
        let band = min(edgeInset, viewportHeight / 2)
        return touchY < band || touchY > (viewportHeight - band)
    }
}
