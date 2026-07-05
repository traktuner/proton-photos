import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// The continuous run must stay BOTTOM-RIGHT anchored at EVERY zoom level: the newest item (last index) sits
/// in the bottom-right corner (column == cols-1, last row full → no black there), and the only partial row is
/// the OLDEST at the top-left. (Guards the regression where a column phase moved the partial row to the
/// bottom-right and produced black.)
@Suite struct GridBottomRightAnchorTests {
    private let width: CGFloat = 1400
    private let viewport = CGSize(width: 1400, height: 900)

    @Test func newestIsBottomRightAtEveryLevel() {
        // Counts that are NOT multiples of the column counts, so the partial row is non-trivial.
        for count in [997, 2000, 5003, 12345, 20000] {
            let e = SquareTileGridEngine.testRegular(sectionCounts: [count])
            for level in 0 ..< e.levelCount {
                let cols = e.resolvedMetrics(level: level, width: width).columns
                guard let last = e.locate(flatIndex: count - 1, level: level, width: width) else {
                    Issue.record("no last item at level \(level)"); continue
                }
                // Newest in the bottom-right corner.
                #expect(last.column == cols - 1, "newest not bottom-right at level \(level), count \(count): col \(last.column)/\(cols)")
                // The last row is full: the previous `cols-1` items lead up to it on the same row, col 0 first.
                if count > cols, let firstOfLastRow = e.locate(flatIndex: count - cols, level: level, width: width) {
                    #expect(firstOfLastRow.row == last.row && firstOfLastRow.column == 0,
                            "last row not full at level \(level), count \(count)")
                }
                // The OLDEST item is in the top row (the partial/empty row is at the top, not the bottom).
                if let first = e.locate(flatIndex: 0, level: level, width: width) {
                    #expect(first.row == 0, "oldest not in the top row at level \(level), count \(count)")
                }
            }
        }
    }

    @Test func noBlackOnTheRightOfTheBottomRowAtEveryLevel() {
        for count in [997, 5003, 20000] {
            let e = SquareTileGridEngine.testRegular(sectionCounts: [count])
            for level in 0 ..< e.levelCount {
                let content = e.contentSize(level: level, width: width)
                // Camera at the very bottom (newest).
                let scrollY = max(0, content.height - viewport.height)
                let plan = e.framePlan(level: level, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: scrollY), overscan: 0)
                // FIXED-COLUMNS, WIDTH-FILL: the bottom-most row is FULL (all columns filled - newest in the last
                // filled column, bottom-right of the CONTENT). It is leading-aligned and FILLS the width: the last
                // column's right edge lands at ~the viewport width (no gutter), clearing to the grid background.
                let bottomRow = plan.visibleSlots.filter { $0.row == plan.visibleSlots.map(\.row).max() }
                #expect(!bottomRow.isEmpty)
                #expect(bottomRow.count == plan.columns, "bottom row not full at level \(level), count \(count): \(bottomRow.count)/\(plan.columns)")
                let rightMost = bottomRow.map { $0.slotRect.maxX }.max()!
                #expect(rightMost <= width + 1.0, "bottom row overflows the width at level \(level)")
                #expect(width - rightMost < 2.0, "bottom row must FILL the width (right edge ≈ viewport, no gutter) at level \(level)")
            }
        }
    }

    @Test func topLeadingFillKeepsSparseRoutesInReadingOrder() {
        let count = 8
        let e = SquareTileGridEngine(sectionCounts: [count], profile: .testRegularTimeline, fillOrder: .topLeading)
        for level in 0 ..< e.levelCount {
            let cols = e.resolvedMetrics(level: level, width: width).columns
            guard let first = e.locate(flatIndex: 0, level: level, width: width),
                  let last = e.locate(flatIndex: count - 1, level: level, width: width)
            else {
                Issue.record("missing sparse-route placement at level \(level)")
                continue
            }
            #expect(first.row == 0)
            #expect(first.column == 0, "bounded routes start at top-leading")
            #expect(last.row == (count - 1) / cols)
            #expect(last.column == (count - 1) % cols, "bounded routes leave trailing empty cells, not leading empty cells")
            for flat in 0 ..< count {
                let loc = e.locate(flatIndex: flat, level: level, width: width)!
                #expect(e.flatIndex(section: loc.section, row: loc.row, column: loc.column, level: level, width: width) == flat)
            }
        }
    }
}
