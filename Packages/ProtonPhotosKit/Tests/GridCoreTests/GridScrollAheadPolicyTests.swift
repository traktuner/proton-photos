import Testing
@testable import GridCore

/// Locks the shared scroll-direction-biased prefetch range: full rows just beyond the streamed window in
/// the travel direction, clamped at the library bounds, never overlapping the covered window.
@Suite struct GridScrollAheadPolicyTests {
    @Test func scrollingDownWarmsTheRowsAfterTheCoveredWindow() {
        let range = GridScrollAheadPolicy.aheadRange(
            coveredIndexRange: 100 ... 149, itemCount: 1_000, columns: 5, rowsAhead: 3,
            direction: .towardHigherIndices)
        #expect(range == 150 ..< 165)   // 3 rows × 5 columns immediately after the window
    }

    @Test func scrollingUpWarmsTheRowsBeforeTheCoveredWindow() {
        let range = GridScrollAheadPolicy.aheadRange(
            coveredIndexRange: 100 ... 149, itemCount: 1_000, columns: 5, rowsAhead: 3,
            direction: .towardLowerIndices)
        #expect(range == 85 ..< 100)
    }

    @Test func rangesClampAtTheLibraryBounds() {
        let atEnd = GridScrollAheadPolicy.aheadRange(
            coveredIndexRange: 990 ... 999, itemCount: 1_000, columns: 5, rowsAhead: 3,
            direction: .towardHigherIndices)
        #expect(atEnd.isEmpty)

        let nearEnd = GridScrollAheadPolicy.aheadRange(
            coveredIndexRange: 980 ... 992, itemCount: 1_000, columns: 5, rowsAhead: 3,
            direction: .towardHigherIndices)
        #expect(nearEnd == 993 ..< 1_000)   // clamped short of a full 15

        let atStart = GridScrollAheadPolicy.aheadRange(
            coveredIndexRange: 0 ... 49, itemCount: 1_000, columns: 5, rowsAhead: 3,
            direction: .towardLowerIndices)
        #expect(atStart.isEmpty)

        let nearStart = GridScrollAheadPolicy.aheadRange(
            coveredIndexRange: 7 ... 49, itemCount: 1_000, columns: 5, rowsAhead: 3,
            direction: .towardLowerIndices)
        #expect(nearStart == 0 ..< 7)
    }

    @Test func degenerateInputsProduceEmptyRanges() {
        #expect(GridScrollAheadPolicy.aheadRange(
            coveredIndexRange: 0 ... 10, itemCount: 0, columns: 5, rowsAhead: 3,
            direction: .towardHigherIndices).isEmpty)
        #expect(GridScrollAheadPolicy.aheadRange(
            coveredIndexRange: 0 ... 10, itemCount: 100, columns: 0, rowsAhead: 3,
            direction: .towardHigherIndices).isEmpty)
        #expect(GridScrollAheadPolicy.aheadRange(
            coveredIndexRange: 0 ... 10, itemCount: 100, columns: 5, rowsAhead: 0,
            direction: .towardHigherIndices).isEmpty)
    }

    @Test func aheadRangeNeverOverlapsTheCoveredWindow() {
        for direction in [GridScrollAheadPolicy.Direction.towardHigherIndices, .towardLowerIndices] {
            let range = GridScrollAheadPolicy.aheadRange(
                coveredIndexRange: 40 ... 60, itemCount: 200, columns: 7, rowsAhead: 2, direction: direction)
            #expect(!range.contains(40))
            #expect(!range.contains(60))
        }
    }
}
