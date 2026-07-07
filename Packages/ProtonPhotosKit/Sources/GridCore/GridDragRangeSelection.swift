/// Pure range-selection policy for an iOS-style finger drag over a flat grid order.
///
/// A drag from `anchorIndex` to `currentIndex` (inclusive, in either order) sweeps the CONTIGUOUS run of items
/// between them in library order. `selecting` chooses whether that run is ADDED to (`true`) or REMOVED from
/// (`false`) `base` - decided from the anchor cell's membership at drag start, the iOS Photos convention. Cells
/// OUTSIDE the swept run keep their `base` membership, so shrinking the drag reverts the cells the finger left.
///
/// Because the swept run is a contiguous index range, the resulting selection can never develop skipped holes -
/// even while the grid auto-scrolls under a stationary finger and the host feeds a moving `currentIndex`.
///
/// Value-only and platform-free, so the range logic is unit-tested here (`GridCoreTests`) and the UIKit host is
/// a thin driver that only supplies the anchor/current indices and the base set.
package enum GridDragRangeSelection {

    /// The selection after a drag from `anchorIndex` to `currentIndex` over `orderedIDs`. Out-of-range indices
    /// are clamped into `[0, count-1]`; an empty order returns `base` unchanged.
    package static func selection<ID: Hashable>(
        base: Set<ID>,
        orderedIDs: [ID],
        anchorIndex: Int,
        currentIndex: Int,
        selecting: Bool
    ) -> Set<ID> {
        guard !orderedIDs.isEmpty else { return base }
        let last = orderedIDs.count - 1
        let a = min(max(anchorIndex, 0), last)
        let c = min(max(currentIndex, 0), last)
        let lo = min(a, c)
        let hi = max(a, c)
        let swept = orderedIDs[lo ... hi]
        var result = base
        if selecting {
            result.formUnion(swept)
        } else {
            result.subtract(swept)
        }
        return result
    }
}
