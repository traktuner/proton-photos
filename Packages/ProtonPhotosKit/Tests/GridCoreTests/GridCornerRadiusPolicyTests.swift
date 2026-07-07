import CoreGraphics
import Testing
@testable import GridCore

/// Locks the shared slot-size → corner-radius curve so every platform grid (iPhone, iPad, macOS, future
/// profiles) inherits the same dense-sharp / medium-reduced / large-polished behavior automatically.
@Suite struct GridCornerRadiusPolicyTests {
    private let base = GridVisualConstants.thumbnailCornerRadius   // 11 pt production base

    @Test func tinyDenseSquareSlotsAreSharp() {
        #expect(GridCornerRadiusPolicy.radius(forSlotSidePoints: 48) == 0)
        #expect(GridCornerRadiusPolicy.radius(forSlotSidePoints: 32) == 0)
        #expect(GridCornerRadiusPolicy.radius(forSlotSidePoints: 63.9) == 0)
        // The cutoff itself is still sharp - the ramp starts CONTINUOUSLY at 0 so a live pinch never pops.
        #expect(GridCornerRadiusPolicy.radius(forSlotSidePoints: GridCornerRadiusPolicy.sharpMaxSidePoints) == 0)
    }

    @Test func mediumSlotsGetReducedRadiusBelowBase() {
        let r = GridCornerRadiusPolicy.radius(forSlotSidePoints: 96)
        #expect(r > 0)
        #expect(r < base)
        #expect(abs(r - 6.4) < 0.0001)   // (96 − 64) × 0.2
    }

    @Test func largeSlotsKeepTheFullBaseRadius() {
        #expect(GridCornerRadiusPolicy.radius(forSlotSidePoints: 200) == base)
        #expect(GridCornerRadiusPolicy.radius(forSlotSidePoints: 119) == base)   // ramp reaches base exactly here
        #expect(GridCornerRadiusPolicy.radius(forSlotSidePoints: 1_000) == base)
    }

    @Test func radiusIsMonotonicNonDecreasingInSlotSide() {
        var previous: CGFloat = -1
        for step in 0 ... 600 {
            let side = CGFloat(step) * 0.5
            let r = GridCornerRadiusPolicy.radius(forSlotSidePoints: side)
            #expect(r >= previous, "radius must never shrink as the slot grows (side \(side))")
            previous = r
        }
    }

    @Test func radiusNeverExceedsHalfTheSlotSideOrTheBase() {
        for step in 1 ... 600 {
            let side = CGFloat(step) * 0.5
            let r = GridCornerRadiusPolicy.radius(forSlotSidePoints: side, base: 1_000)   // pathological base
            #expect(r <= side * 0.5)
        }
        for step in 0 ... 600 {
            let side = CGFloat(step) * 0.5
            #expect(GridCornerRadiusPolicy.radius(forSlotSidePoints: side) <= base)
        }
    }

    @Test func customBaseIsHonoredAndZeroBaseStaysSharp() {
        #expect(GridCornerRadiusPolicy.radius(forSlotSidePoints: 300, base: 6) == 6)
        #expect(GridCornerRadiusPolicy.radius(forSlotSidePoints: 300, base: 0) == 0)
        #expect(GridCornerRadiusPolicy.radius(forSlotSidePoints: 90, base: 6) == min(6, (90 - 64) * 0.2))
    }
}
