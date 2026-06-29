import Testing
import Foundation
import CoreGraphics
@testable import TimelineFeature

/// THE FIXED-COLUMNS, WIDTH-FILLING resize contract (Apple parity). Each zoom level HOLDS its `nominalColumns`;
/// the square slot is sized to FILL the viewport width exactly — so the grid NEVER leaves a trailing gutter, and a
/// width change SCALES the tile (same columns, larger/smaller tile), never a column reflow. The column count
/// changes ONLY on a zoom. Pure-engine behavioral guards for the fixed-columns model in
/// `docs/apple-photos-parity-master-spec.md` (and §6/§10 of `docs/metalgrid-engine-contract.md`).
@Suite struct GridSizeBasedResizeTests {
    private let viewportHeight: CGFloat = 900
    private func engine(_ count: Int = 8000) -> SquareTileGridEngine { SquareTileGridEngine(sectionCounts: [count]) }

    // FIXED-COLUMNS, WIDTH-FILLING: across a continuous width sweep the column count is CONSTANT (= the level's
    // `nominalColumns`, it never reflows), the slot content width equals the viewport (no gutter), and the tile
    // SCALES with width (grows as the window widens) — Apple-parity "resize = scale, never reflow".
    @Test func fillsWidthFixedColumnsAcrossAWidthSweep() {
        let e = engine()
        for level in 0 ..< e.levelCount {
            let nominal = e.metrics(level: level).nominalColumns
            var lastSide: CGFloat = 0
            for w in stride(from: CGFloat(500), through: 3000, by: 17) {
                let m = e.resolvedMetrics(level: level, width: w)
                #expect(m.columns == nominal, "L\(level) w\(w): fixed-columns — the count must hold at \(nominal) (got \(m.columns))")
                let contentWidth = CGFloat(m.columns) * m.pitch - m.gap
                #expect(abs(contentWidth - w) < 1.0, "L\(level) w\(w): grid must FILL the width (gutter \(w - contentWidth))")
                #expect(m.slotSide >= lastSide - 0.001, "L\(level): the tile must SCALE up as width grows, never reflow (w=\(w))")
                lastSide = m.slotSide
            }
        }
    }

    // FIXED-COLUMNS: a wide viewport shows the SAME column count as a narrow one at a BIGGER tile (it scales, never
    // reflows); the grid fills the width at both.
    @Test func columnsFixedTileScalesWhenWider() {
        let e = engine()
        for level in 0 ..< e.levelCount {
            for w in [CGFloat(700), 2560] {
                let m = e.resolvedMetrics(level: level, width: w)
                #expect(abs((CGFloat(m.columns) * m.pitch - m.gap) - w) < 1.0, "L\(level) w\(w): grid must fill the width")
            }
            let narrow = e.resolvedMetrics(level: level, width: 700)
            let wide = e.resolvedMetrics(level: level, width: 2560)
            #expect(wide.columns == narrow.columns, "L\(level): a wider viewport keeps the SAME column count (fixed-columns)")
            #expect(wide.slotSide > narrow.slotSide, "L\(level): a wider viewport scales the tile bigger")
        }
    }

    // SIDEBAR TOGGLE = a layout-width change (`layoutWidth = fullWidth − inset`). FIXED-COLUMNS: it must NOT reflow
    // — the column count is unchanged and the tiles just SCALE (shrink) to fill the reduced width.
    @Test func sidebarToggleScalesNoReflow() {
        let e = engine()
        let fullWidth: CGFloat = 1440
        let sidebarInset: CGFloat = 282 + MetalGridScrollHost.normalLevelLeadingGap   // sidebar + normal-level gap
        for level in 0 ..< 4 {   // normal photo levels (the sidebar gap applies here)
            let withoutSidebar = e.resolvedMetrics(level: level, width: fullWidth)
            let withSidebar = e.resolvedMetrics(level: level, width: fullWidth - sidebarInset)
            #expect(withSidebar.columns == withoutSidebar.columns, "L\(level): the sidebar must NOT reflow (same column count)")
            #expect(withSidebar.slotSide < withoutSidebar.slotSide, "L\(level): the sidebar scales the tile smaller to fill the reduced width")
            #expect(abs((CGFloat(withSidebar.columns) * withSidebar.pitch - withSidebar.gap) - (fullWidth - sidebarInset)) < 1.0,
                    "L\(level): grid must keep filling the reduced width with the sidebar shown")
        }
    }

    // The settled grid FILLS the width: leading-aligned, and the content width EQUALS the viewport at every level
    // and (multi-column) width — NO trailing gutter (the rejected "huge blank margin" state is impossible).
    @Test func settledGridFillsWidthNoGutter() {
        let e = engine()
        for level in 0 ..< e.levelCount {
            for w in [CGFloat(640), 1024, 1440, 1920, 2560] {
                let m = e.resolvedMetrics(level: level, width: w)
                guard m.columns >= 2 else { continue }   // a single column on an extreme-narrow viewport may exceed w
                let contentWidth = CGFloat(m.columns) * m.pitch - m.gap
                #expect(contentWidth <= w + 0.5, "L\(level) w\(w): content overflows the viewport")
                #expect(abs(contentWidth - w) < 1.0, "L\(level) w\(w): grid must FILL the width (gutter \(w - contentWidth))")
            }
        }
    }

    // A click to the right of the last FILLED column hits NOTHING. Under width-fill the grid fills the viewport,
    // so a real margin rarely exists (the guard early-returns); this asserts no phantom slot when one does.
    @Test func clickInTrailingMarginHitsNothing() {
        let e = engine(8000)
        let level = 1, w: CGFloat = 1500
        let m = e.resolvedMetrics(level: level, width: w)
        let contentWidth = CGFloat(m.columns) * m.pitch - m.gap
        guard w - contentWidth > 4 else { return }   // only meaningful when a real margin exists
        let marginX = contentWidth + (w - contentWidth) / 2     // middle of the trailing margin
        #expect(e.hitTest(contentPoint: CGPoint(x: marginX, y: 4000), level: level, width: w) == nil,
                "a point right of the last filled column must not hit a slot")
    }

    // REGRESSION GUARD for the rejected screenshots: at the widths where the OLD `floor` + fixed-`side` model
    // left a trailing gutter up to a FULL tile (≈421pt at L0 @ 1700 = ~25% of the window), the grid now FILLS
    // the width. This test FAILS on the old model and passes on the width-fill model.
    @Test func wideWindowHasNoHugeGutter() {
        let e = engine()
        let cases: [(level: Int, width: CGFloat)] = [(0, 1700), (0, 2141), (0, 1440), (1, 1440), (1, 2309), (2, 1644), (3, 1418)]
        for c in cases {
            let m = e.resolvedMetrics(level: c.level, width: c.width)
            let gutter = c.width - (CGFloat(m.columns) * m.pitch - m.gap)
            #expect(gutter < 2.0, "L\(c.level) w\(c.width): gutter \(gutter)pt (must be ~0 — the rejected huge-margin state is gone)")
        }
    }

    // PINCH COMMIT SEAM at NON-REFERENCE widths: at every integer detent the live apparent side equals the
    // settled (width-filled) side, so a pinch/click commit lands with NO size pop. Guards the width-fill
    // lock-step between the live lattice and the settled grid at widths other than the 1280 calibration width.
    @Test func pinchCommitSeamHoldsAtNonReferenceWidths() {
        let e = engine()
        for w in [CGFloat(1500), 1733, 980, 2200] {     // none is the 1280 reference width
            for level in 0 ..< e.levelCount {
                let settled = e.resolvedMetrics(level: level, width: w).slotSide
                #expect(abs(e.apparentSlotSide(at: CGFloat(level), width: w) - settled) < 0.5,
                        "seam: live apparent side \(e.apparentSlotSide(at: CGFloat(level), width: w)) != settled \(settled) at L\(level) w\(w)")
            }
        }
    }
}
