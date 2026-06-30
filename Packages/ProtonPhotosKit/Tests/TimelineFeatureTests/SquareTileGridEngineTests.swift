import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// Pure, headless tests for the canonical `SquareTileGridEngine` (no Metal, no window). These pin the
/// engine's geometry contract BEFORE any thumbnail/renderer wiring: square slots, first-class gaps,
/// width-filling columns (no black left/right), hit testing on the square slot, engine-owned zoom metrics,
/// and anchor preservation.
@Suite struct SquareTileGridEngineTests {

    // A single large section so rows pack cleanly (the production layout anchors bottom-right; a single
    // section keeps the math obvious while still exercising the real kernel).
    private func engine(_ count: Int = 2000) -> SquareTileGridEngine {
        SquareTileGridEngine.testRegular(sectionCounts: [count])
    }
    private let width: CGFloat = 1400
    private let viewport = CGSize(width: 1400, height: 900)
    private let eps: CGFloat = 0.01

    private func settledPlan(level: Int, scrollY: CGFloat = 0, count: Int = 2000) -> GridFramePlan {
        engine(count).framePlan(level: level, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: scrollY), overscan: 0)
    }

    /// The set of slots forming a fully-populated row (exactly `columns` slots at one row index).
    private func fullRows(_ plan: GridFramePlan) -> [Int: [GridSlot]] {
        var byRow: [Int: [GridSlot]] = [:]
        for s in plan.visibleSlots { byRow[s.row, default: []].append(s) }
        return byRow.filter { $0.value.count == plan.columns }
    }

    // 1. Slot rects are square for every visible slot, at every level.
    @Test func slotRectsAreSquare() {
        for level in 0 ..< engine().levelCount {
            let plan = settledPlan(level: level)
            #expect(!plan.visibleSlots.isEmpty)
            for s in plan.visibleSlots {
                #expect(abs(s.slotRect.width - s.slotRect.height) < eps)
                #expect(abs(s.viewportRect.width - s.viewportRect.height) < eps)
                #expect(abs(s.slotRect.width - plan.slotSide) < eps)
            }
        }
    }

    // 2. Media aspect cannot affect the slot rect — the engine takes NO aspect input. The content fit lives
    // entirely in `TileContentFitter` (outside the engine) and is always contained in the unchanged slot.
    @Test func mediaAspectDoesNotAffectSlotRect() {
        let plan = settledPlan(level: 1)
        let slot = plan.visibleSlots[plan.visibleSlots.count / 2]
        let square = slot.slotRect
        for aspect in [CGFloat(0.25), 0.5, 1.0, 1.78, 3.5] {
            for mode in [TileContentMode.aspectFill, .aspectFit] {
                let inner = TileContentFitter.fit(slotRect: slot.slotRect, mediaAspect: aspect, mode: mode).contentRect
                #expect(slot.slotRect == square)                                   // slot unchanged
                #expect(inner.minX >= square.minX - eps && inner.maxX <= square.maxX + eps) // contained
                #expect(inner.minY >= square.minY - eps && inner.maxY <= square.maxY + eps)
            }
        }
    }

    // 3. Gap is a first-class metric: horizontally and vertically adjacent slots are exactly `pitch` apart.
    @Test func gapIsFirstClassMetric() {
        let plan = settledPlan(level: 2)
        let pitch = plan.slotSide + plan.gap
        #expect(abs(plan.pitch - pitch) < eps)
        // Horizontal adjacency within a full row.
        let row = fullRows(plan).values.first!
        let sorted = row.sorted { $0.column < $1.column }
        for i in 1 ..< sorted.count {
            #expect(abs(sorted[i].slotRect.minX - sorted[i - 1].slotRect.minX - pitch) < eps)
            #expect(abs(sorted[i].slotRect.minX - sorted[i - 1].slotRect.maxX - plan.gap) < eps) // the gap itself
        }
        // Vertical adjacency: same column, consecutive rows.
        let col0 = plan.visibleSlots.filter { $0.column == 0 }.sorted { $0.row < $1.row }
        for i in 1 ..< col0.count where col0[i].row == col0[i - 1].row + 1 {
            #expect(abs(col0[i].slotRect.minY - col0[i - 1].slotRect.minY - pitch) < eps)
        }
    }

    // 4. Different levels can have different gaps (dynamic gap).
    @Test func dynamicGapPerLevel() {
        let e = engine()
        let gaps = (0 ..< e.levelCount).map { e.metrics(level: $0).gap }
        #expect(Set(gaps).count > 1)                       // not all the same
        // And the resolved plan reports the level's gap.
        for level in 0 ..< e.levelCount {
            #expect(abs(settledPlan(level: level).gap - e.metrics(level: level).gap) < eps)
        }
    }

    // 5. pitch == slotSide + gap everywhere (plan + adjacency).
    @Test func pitchConsistency() {
        for level in 0 ..< engine().levelCount {
            let plan = settledPlan(level: level)
            #expect(abs(plan.pitch - (plan.slotSide + plan.gap)) < eps)
        }
    }

    /// A scroll Y guaranteed to land in the middle of the content at this level (content height shrinks at
    /// dense levels, so a fixed offset would overshoot).
    private func midScroll(level: Int, count: Int = 2000) -> CGFloat {
        let h = engine(count).contentSize(level: level, width: width).height
        return max(0, h / 2 - viewport.height / 2)
    }

    // 6/7/8. FIXED-COLUMNS, WIDTH-FILL: the grid is LEADING-aligned — a full visible row starts at column 0 (x≈0)
    // and runs to column count-1, and the last column's right edge FILLS the viewport width (no gutter).
    @Test func visibleQueryIsLeadingAlignedAndFillsWidth() {
        for level in 0 ..< engine().levelCount {
            let plan = settledPlan(level: level, scrollY: midScroll(level: level))   // mid-library → full rows
            let rows = fullRows(plan)
            #expect(!rows.isEmpty, "expected at least one full row at level \(level)")
            let row = rows.values.first!.sorted { $0.column < $1.column }
            #expect(row.first!.column == 0)                                  // left edge present
            #expect(row.last!.column == plan.columns - 1)                    // last filled column present
            #expect(abs(row.first!.slotRect.minX) < 1.0)                     // leading-aligned: left edge at x≈0
            #expect(row.last!.slotRect.maxX <= width + 1.0)                  // never overflows the viewport
            #expect(width - row.last!.slotRect.maxX < 2.0)                   // FILLS the width (right edge ≈ viewport, no gutter)
        }
    }

    // 9. FIXED-COLUMNS, WIDTH-FILLING window resize: a level FILLS the width at every width (no gutter); the COLUMN
    // COUNT is CONSTANT (held at nominalColumns) and the tile SCALES with width (resize = scale, never reflow). No overlap.
    @Test func windowResizeFillsWidthFixedColumnsScalesTile() {
        let e = engine()
        var sides: [CGFloat] = []
        var columnsSeen: [Int] = []
        for w in [CGFloat(600), 900, 1280, 1920] {
            let plan = e.framePlan(level: 2, viewportSize: CGSize(width: w, height: 900), scrollOffset: CGPoint(x: 0, y: 3000), overscan: 0)
            #expect(plan.contentSize.width == w)
            columnsSeen.append(plan.columns)
            sides.append(plan.slotSide)
            if let row = fullRows(plan).values.first?.sorted(by: { $0.column < $1.column }) {
                for i in 1 ..< row.count {
                    #expect(row[i].slotRect.minX - row[i - 1].slotRect.maxX >= plan.gap - eps) // no overlap
                }
                #expect(row.last!.slotRect.maxX <= w + 1.0)                                     // never overflows
                #expect(w - row.last!.slotRect.maxX < 2.0)                                      // FILLS the width (no gutter)
            }
        }
        let nominal = e.metrics(level: 2).nominalColumns
        for c in columnsSeen { #expect(c == nominal, "FIXED-COLUMNS: the count holds at \(nominal) across widths (resize scales, never reflows)") }
        #expect(sides.first! < sides.last!, "the tile must SCALE with width (fixed-columns, not the old re-column reflow)")
        for i in 1 ..< sides.count { #expect(sides[i] >= sides[i - 1], "tile size monotone non-decreasing in width") }
    }

    // 10. Hit testing uses the SQUARE slot rect — a point in the slot corner that an aspectFit inner rect
    // would exclude still hits; a point in the inter-slot gap misses.
    @Test func hitTestingUsesSlotRect() {
        let e = engine()
        let plan = e.framePlan(level: 1, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 3000), overscan: 0)
        let slot = fullRows(plan).values.first!.first!
        // Center hits.
        #expect(e.hitTest(contentPoint: CGPoint(x: slot.slotRect.midX, y: slot.slotRect.midY), level: 1, width: width)?.index == slot.index)
        // A near-corner point (inside the square, outside a portrait aspectFit inner rect) still hits.
        let corner = CGPoint(x: slot.slotRect.minX + 1, y: slot.slotRect.midY)
        #expect(e.hitTest(contentPoint: corner, level: 1, width: width)?.index == slot.index)
        // A point in the inter-slot gap to the right of a slot misses (gap, not a slot).
        if slot.slotRect.maxX + plan.gap * 0.5 < width {
            let gapPoint = CGPoint(x: slot.slotRect.maxX + plan.gap * 0.5, y: slot.slotRect.midY)
            #expect(e.hitTest(contentPoint: gapPoint, level: 1, width: width) == nil)
        }
    }

    // 11. Zoom modifies/chooses grid METRICS (slot size / gap → columns), never media geometry. Slots stay
    // square at every apparent level, and zooming out increases columns.
    @Test func zoomUsesMetrics() {
        let e = engine()
        let w = viewport.width
        // SEAM: the live apparent side at an integer detent equals the SETTLED (width-filled) side for that
        // level — so a pinch commit lands with no size pop. (Was: the raw reference side, which only matched at
        // the reference width.) Between detents it interpolates strictly between the two filled sides.
        func filledSide(_ lvl: Int) -> CGFloat { e.resolvedMetrics(level: lvl, width: w).slotSide }
        #expect(abs(e.apparentSlotSide(at: 2, width: w) - filledSide(2)) < eps)     // detent → settled filled side (seam closes)
        let mid = e.apparentSlotSide(at: 2.5, width: w)
        #expect(mid < filledSide(2) && mid > filledSide(3))                         // between detents
        let anchor = GridZoomAnchor(flatIndex: 1000, viewportPoint: CGPoint(x: 700, y: 450),
                                    contentFractionY: 0.5, relInCell: CGPoint(x: 0.5, y: 0.5))
        let inPlan = e.zoomFramePlan(continuousLevel: 2.0, viewportSize: viewport, anchor: anchor, overscan: 0)
        let outPlan = e.zoomFramePlan(continuousLevel: 3.0, viewportSize: viewport, anchor: anchor, overscan: 0)
        #expect(outPlan.columns > inPlan.columns)                                  // zoom out → more columns
        for s in outPlan.visibleSlots { #expect(abs(s.slotRect.width - s.slotRect.height) < eps) } // still square
    }

    // 11b. Continuous zoom-out lens: at every apparent (between-detent) level the lens is leading-aligned with a
    // BOUNDED trailing margin (< one pitch) — the round column count + interpolated side need not fill exactly
    // mid-zoom (unlike the settled grid, which fills); background, never a black strip or missing column.
    @Test func zoomOutIsLeadingAlignedWithBoundedTrailingMargin() {
        let e = engine()
        let anchor = GridZoomAnchor(flatIndex: 1000, viewportPoint: CGPoint(x: 700, y: 450),
                                    contentFractionY: 0.5, relInCell: CGPoint(x: 0.5, y: 0.5))
        for x in stride(from: CGFloat(2.0), through: 5.0, by: 0.25) {
            let plan = e.zoomFramePlan(continuousLevel: x, viewportSize: viewport, anchor: anchor, overscan: 0)
            let rows = fullRows(plan)
            #expect(!rows.isEmpty, "no full row at apparent level \(x)")
            let row = rows.values.first!.sorted { $0.column < $1.column }
            #expect(abs(row.first!.slotRect.minX) < 1.0)            // leading-aligned
            #expect(row.last!.slotRect.maxX <= width + 1.0)         // never overflows
            #expect(width - row.last!.slotRect.maxX < plan.pitch)   // bounded trailing margin (no black strip)
        }
    }

    // 12. Anchor preservation: the anchored item stays under the same viewport point as the metrics change.
    @Test func anchorPreservation() {
        let e = engine()
        let anchorPoint = CGPoint(x: 700, y: 450)
        let anchor = GridZoomAnchor(flatIndex: 1200, viewportPoint: anchorPoint,
                                    contentFractionY: 0.5, relInCell: CGPoint(x: 0.5, y: 0.5))
        for x in [CGFloat(2.0), 2.4, 3.0, 3.7] {
            let plan = e.zoomFramePlan(continuousLevel: x, viewportSize: viewport, anchor: anchor, overscan: 200)
            guard let slot = plan.visibleSlots.first(where: { $0.index == 1200 }) else {
                Issue.record("anchor item not visible at level \(x)"); continue
            }
            // The anchor's relative-in-cell point (center) lands on the anchor viewport Y.
            let landedY = slot.viewportRect.minY + 0.5 * slot.viewportRect.height
            #expect(abs(landedY - anchorPoint.y) < 1.0, "anchor drifted at level \(x): \(landedY)")
        }
    }

    // globalIndex ⇄ (section, row, column) round-trips at a settled level.
    @Test func rowColumnRoundTrips() {
        let e = engine()
        for flat in [0, 1, 50, 137, 999, 1999] {
            guard let loc = e.locate(flatIndex: flat, level: 2, width: width) else { Issue.record("no loc for \(flat)"); continue }
            #expect(e.flatIndex(section: loc.section, row: loc.row, column: loc.column, level: 2, width: width) == flat)
        }
    }

    // The engine owns section geometry: multi-section content stacks, every slot is square, section/item
    // mapping round-trips, and headers (supplementary query) are available.
    @Test func ownsSectionGeometry() {
        let e = SquareTileGridEngine.testRegular(sectionCounts: [37, 80, 12, 150, 9])
        // globalIndex ⇄ (section,item) round-trips across sections.
        for s in 0 ..< 5 {
            let gi = e.globalIndex(section: s, item: 0)!
            let si = e.sectionItem(globalIndex: gi)!
            #expect(si.section == s && si.item == 0)
        }
        // Sections stack with increasing tops; content size spans them all.
        var lastTop: CGFloat = -1
        for s in 0 ..< 5 {
            let top = e.sectionTop(section: s, level: 2, width: width)!
            #expect(top > lastTop); lastTop = top
        }
        // A frame plan over a multi-section library still yields square slots + a header query.
        let plan = e.framePlan(level: 2, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
        for s in plan.visibleSlots { #expect(abs(s.slotRect.width - s.slotRect.height) < eps) }
        #expect(!plan.visibleHeaders.isEmpty)   // section headers are owned + queryable
    }

    // A wide-video-shaped item occupies the SAME square slot as any other — the engine has no media-type
    // input, so the slot size is identical regardless of payload.
    @Test func videoUsesSameSquareSlot() {
        let plan = settledPlan(level: 2, scrollY: 3000)
        let row = fullRows(plan).values.first!
        let sides = Set(row.map { Int(($0.slotRect.width * 100).rounded()) })
        #expect(sides.count == 1)   // every slot in a row is the identical square
    }
}
