import Testing
import Foundation
import CoreGraphics
@testable import TimelineFeature

/// THE size-based resize contract (Apple parity, no breathing). A zoom level fixes the PHOTO SIZE; the column
/// count adapts to width in discrete steps; the photo size NEVER rescales just because the window/sidebar width
/// changes. These are pure-engine behavioral guards for the requirements in
/// `GRID_SIZE_BASED_RESIZE_DESIGN.md` and `docs/apple-photos-parity-master-spec.md`.
@Suite struct GridSizeBasedResizeTests {
    private let viewportHeight: CGFloat = 900
    private func engine(_ count: Int = 8000) -> SquareTileGridEngine { SquareTileGridEngine(sectionCounts: [count]) }

    // NO TILE BREATHING: across a continuous width sweep the slot/photo size is CONSTANT at every level; only
    // the column count changes (monotone non-decreasing as width grows).
    @Test func noTileBreathingAcrossAWidthSweep() {
        let e = engine()
        for level in 0 ..< e.levelCount {
            let baseSide = e.resolvedMetrics(level: level, width: 1280).slotSide
            var lastColumns = 0
            for w in stride(from: CGFloat(500), through: 3000, by: 17) {
                let m = e.resolvedMetrics(level: level, width: w)
                #expect(abs(m.slotSide - baseSide) < 0.5, "L\(level): tile size changed with width \(w) (breathing!)")
                #expect(m.columns >= lastColumns, "L\(level): columns must not shrink as width grows (w=\(w))")
                #expect(m.columns >= 1)
                lastColumns = m.columns
            }
        }
    }

    // The column count adapts DISCRETELY (changes only by stepping; never a fractional rescale) and a wide
    // viewport genuinely shows MORE photos at the SAME size than a narrow one.
    @Test func columnsAdaptDiscretelyMoreWhenWider() {
        let e = engine()
        for level in 0 ..< e.levelCount {
            let narrow = e.resolvedMetrics(level: level, width: 700)
            let wide = e.resolvedMetrics(level: level, width: 2560)
            #expect(wide.columns > narrow.columns, "L\(level): a wide viewport must show more columns")
            #expect(abs(narrow.slotSide - wide.slotSide) < 0.5, "L\(level): at the SAME size, not rescaled")
        }
    }

    // SIDEBAR TOGGLE = a layout-width change (the host passes `layoutWidth = fullWidth − inset`). It must DROP a
    // column (or more) at the SAME photo size — the Apple sidebar behavior — never shrink the tiles.
    @Test func sidebarToggleDropsColumnsAtConstantSize() {
        let e = engine()
        let fullWidth: CGFloat = 1440
        let sidebarInset: CGFloat = 282 + MetalGridScrollHost.normalLevelLeadingGap   // sidebar + normal-level gap
        for level in 0 ..< 4 {   // normal photo levels (the sidebar gap applies here)
            let withoutSidebar = e.resolvedMetrics(level: level, width: fullWidth)
            let withSidebar = e.resolvedMetrics(level: level, width: fullWidth - sidebarInset)
            #expect(withSidebar.columns < withoutSidebar.columns, "L\(level): showing the sidebar must drop at least one column")
            #expect(abs(withSidebar.slotSide - withoutSidebar.slotSide) < 0.5, "L\(level): sidebar must NOT shrink the tiles")
        }
    }

    // The settled grid is LEADING-aligned with a BOUNDED trailing reveal margin (< one pitch) at every level and
    // width — content never overflows the viewport and never leaves a gap wide enough for another column.
    @Test func leadingAlignedBoundedTrailingMargin() {
        let e = engine()
        for level in 0 ..< e.levelCount {
            for w in [CGFloat(640), 1024, 1440, 1920, 2560] {
                let m = e.resolvedMetrics(level: level, width: w)
                let contentWidth = CGFloat(m.columns) * m.pitch - m.gap
                #expect(contentWidth <= w + 0.5, "L\(level) w\(w): content overflows the viewport")
                #expect(w - contentWidth < m.pitch, "L\(level) w\(w): trailing margin ≥ one column (a column is missing)")
            }
        }
    }

    // A click in the trailing reveal margin (right of the last column) hits NOTHING (no slot there).
    @Test func clickInTrailingMarginHitsNothing() {
        let e = engine(8000)
        let level = 1, w: CGFloat = 1500
        let m = e.resolvedMetrics(level: level, width: w)
        let contentWidth = CGFloat(m.columns) * m.pitch - m.gap
        guard w - contentWidth > 4 else { return }   // only meaningful when a real margin exists
        let marginX = contentWidth + (w - contentWidth) / 2     // middle of the trailing margin
        #expect(e.hitTest(contentPoint: CGPoint(x: marginX, y: 4000), level: level, width: w) == nil,
                "a point in the trailing reveal margin must not hit a slot")
    }
}
