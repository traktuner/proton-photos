import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// STEP 1 (additive foundation for the size-based grid model). Pins the `GridSizePolicy` level→fixed-size map
/// and the shared `SquareTileGridEngine.columnsForFixedSide` column rule BEFORE any resolve flips to use them,
/// so the foundation is proven while the engine still behaves exactly as today (whole suite stays green).
@Suite struct GridSizePolicyTests {
    private let levels = SquareTileGridEngine.testRegularLevels

    // The fixed per-level size round-trips: at the reference width it yields EXACTLY the level's nominalColumns
    // (the ε-nudge defeats the FP floor-truncation that would otherwise drop L2→6 / L5→29).
    @Test func referenceSlotSideRoundTripsAtReferenceWidth() {
        let w = GridSizePolicy.referenceWidth
        for m in levels {
            let cols = SquareTileGridEngine.columnsForFixedSide(side: m.referenceSlotSide, gap: m.gap, width: w)
            #expect(cols == m.nominalColumns, "level \(m.levelID): \(cols) ≠ nominalColumns \(m.nominalColumns) at W_ref \(w)")
        }
    }

    // Strictly monotone-decreasing sizes → unambiguous density ladder (zoom in = smaller tiles).
    @Test func referenceSlotSidesAreMonotoneDecreasing() {
        let sides = levels.map(\.referenceSlotSide)
        for i in 1 ..< sides.count {
            #expect(sides[i] < sides[i-1], "level \(i) side \(sides[i]) not < level \(i-1) side \(sides[i-1])")
        }
    }

    // CONSTANT size ⇒ column count is non-decreasing in width and strictly grows on a wide enough viewport
    // (the responsive "more big photos when wider", never a rescale). This is the core size-based invariant.
    @Test func columnsGrowWithWidthAtConstantSize() {
        for m in levels {
            let side = m.referenceSlotSide
            let narrow = SquareTileGridEngine.columnsForFixedSide(side: side, gap: m.gap, width: 800)
            let wide = SquareTileGridEngine.columnsForFixedSide(side: side, gap: m.gap, width: 2560)
            #expect(wide > narrow, "level \(m.levelID): columns did not grow with width (\(narrow) → \(wide))")
            var last = 0
            for w in stride(from: CGFloat(400), through: 3200, by: 25) {
                let c = SquareTileGridEngine.columnsForFixedSide(side: side, gap: m.gap, width: w)
                #expect(c >= last, "columns decreased as width grew (level \(m.levelID), w=\(w): \(c) < \(last))")
                #expect(c >= 1, "always at least one column")
                last = c
            }
        }
    }

    // The optional hard cap binds WITHOUT changing the size (margin-only, never a stretch).
    @Test func maxColumnsCapBindsWithoutResize() {
        let m = levels[0]
        let uncapped = SquareTileGridEngine.columnsForFixedSide(side: m.referenceSlotSide, gap: m.gap, width: 4000)
        let capped = SquareTileGridEngine.columnsForFixedSide(side: m.referenceSlotSide, gap: m.gap, width: 4000, maxColumns: 4)
        #expect(uncapped > 4, "test needs a width where more than the cap fits")
        #expect(capped == 4, "the cap must bind exactly")
    }

    // Responsive classes scale the size in DISCRETE steps (no continuous tracking); regular is the desktop seed.
    @Test func sizeClassesScaleDiscretely() {
        let nc = 9, gap: CGFloat = 8
        let compact = GridSizePolicy.slotSide(nominalColumns: nc, gap: gap, sizeClass: .compact)
        let regular = GridSizePolicy.slotSide(nominalColumns: nc, gap: gap, sizeClass: .regular)
        let wide = GridSizePolicy.slotSide(nominalColumns: nc, gap: gap, sizeClass: .wide)
        let ultra = GridSizePolicy.slotSide(nominalColumns: nc, gap: gap, sizeClass: .ultra)
        #expect(compact < regular)
        #expect(wide > regular)
        #expect(ultra > wide)
        // Desktop still selects regular (no silent responsive jump yet).
        #expect(GridSizePolicy.sizeClass(forWidth: 800) == .regular)
        #expect(GridSizePolicy.sizeClass(forWidth: 3840) == .regular)
    }

    // Foundation is ADDITIVE: no cap shipped by default (largest level shows more photos on a wide display).
    @Test func noHardCapByDefault() {
        for m in levels { #expect(GridSizePolicy.maxColumns(forLevelID: m.levelID) == nil) }
    }
}
