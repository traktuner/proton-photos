import Testing
@testable import GridCore

/// Locks the pure iOS drag-select range policy: a contiguous sweep (no holes) that adds to or removes from a
/// base selection, reverts cells the finger leaves, and clamps out-of-range indices — the behavior that keeps
/// finger-drag + edge auto-scroll selection gap-free.
@Suite struct GridDragRangeSelectionTests {
    private let ids = Array(0 ..< 10)

    private func sel(base: Set<Int> = [], anchor: Int, current: Int, selecting: Bool = true) -> Set<Int> {
        GridDragRangeSelection.selection(
            base: base, orderedIDs: ids, anchorIndex: anchor, currentIndex: current, selecting: selecting
        )
    }

    @Test func sweepSelectsContiguousRangeInEitherDirection() {
        #expect(sel(anchor: 2, current: 5) == [2, 3, 4, 5])
        #expect(sel(anchor: 5, current: 2) == [2, 3, 4, 5])   // dragging "up" selects the same run
    }

    @Test func singleCellSweepSelectsJustTheAnchor() {
        #expect(sel(anchor: 4, current: 4) == [4])
    }

    @Test func sweepUnionsWithTheBaseSelection() {
        // A previously-selected cell outside the sweep is preserved (multi-range drag selection).
        #expect(sel(base: [8], anchor: 1, current: 3) == [1, 2, 3, 8])
    }

    @Test func shrinkingTheDragRevertsCellsTheFingerLeft() {
        // Every move recomputes from `base`, so extending to 6 then pulling back to 3 deselects 4…6.
        #expect(sel(anchor: 2, current: 6) == [2, 3, 4, 5, 6])
        #expect(sel(anchor: 2, current: 3) == [2, 3])
    }

    @Test func deselectingModeRemovesTheSweptRunFromBase() {
        let base: Set<Int> = [0, 1, 2, 3, 4, 5]
        #expect(sel(base: base, anchor: 2, current: 4, selecting: false) == [0, 1, 5])
    }

    @Test func indicesAreClampedIntoRange() {
        #expect(sel(anchor: -5, current: 100) == Set(0 ..< 10))   // whole library
        #expect(sel(anchor: 100, current: 100) == [9])            // clamps to the last item
    }

    @Test func emptyOrderReturnsBaseUnchanged() {
        let base: Set<Int> = [1, 2]
        #expect(GridDragRangeSelection.selection(
            base: base, orderedIDs: [], anchorIndex: 0, currentIndex: 3, selecting: true
        ) == base)
    }
}
