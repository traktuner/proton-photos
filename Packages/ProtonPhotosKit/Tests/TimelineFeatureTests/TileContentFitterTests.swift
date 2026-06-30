import Testing
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// Pins the content-fit contract: the fit is the ONLY place media aspect enters, the output is always
/// contained in the slot, and switching mode/aspect never changes the slot.
@Suite struct TileContentFitterTests {
    private let slot = CGRect(x: 100, y: 200, width: 140, height: 140)   // a square slot
    private let eps: CGFloat = 0.001

    // ContentRectContainedInSlotRect — every mode/aspect produces a rect inside the slot.
    @Test func contentRectContainedInSlot() {
        for aspect in [CGFloat(0.2), 0.6, 1.0, 1.5, 3.0, 5.0] {
            for mode in [TileContentMode.aspectFill, .aspectFit] {
                let r = TileContentFitter.fit(slotRect: slot, mediaAspect: aspect, mode: mode).contentRect
                #expect(r.minX >= slot.minX - eps && r.maxX <= slot.maxX + eps)
                #expect(r.minY >= slot.minY - eps && r.maxY <= slot.maxY + eps)
            }
        }
    }

    // aspectFill covers the whole square (content rect == slot; the crop is in the UV window).
    @Test func aspectFillCoversSlotAndCropsViaUV() {
        let wide = TileContentFitter.fit(slotRect: slot, mediaAspect: 2.0, mode: .aspectFill)
        #expect(wide.contentRect == slot)                          // fills the square
        #expect(wide.uvMin.x > 0 && wide.uvMax.x < 1)              // wide media → crop left/right in UV
        #expect(abs(wide.uvMin.y) < 0.001 && abs(wide.uvMax.y - 1) < 0.001)
        let tall = TileContentFitter.fit(slotRect: slot, mediaAspect: 0.5, mode: .aspectFill)
        #expect(tall.uvMin.y > 0 && tall.uvMax.y < 1)              // tall media → crop top/bottom
    }

    // aspectFit letterboxes inside the square (content rect smaller for non-square media, UV full).
    @Test func aspectFitLetterboxesInsideSlot() {
        let wide = TileContentFitter.fit(slotRect: slot, mediaAspect: 2.0, mode: .aspectFit)
        #expect(wide.contentRect.width <= slot.width + eps)
        #expect(wide.contentRect.height < slot.height)             // letterbox bars top/bottom
        #expect(wide.uvMin == SIMD2(0, 0) && wide.uvMax == SIMD2(1, 1))
    }

    // Switching mode (or aspect) never changes the slot it was fitted to.
    @Test func modeNeverChangesSlot() {
        let base = slot
        for aspect in [CGFloat(0.3), 1.0, 2.5] {
            _ = TileContentFitter.fit(slotRect: slot, mediaAspect: aspect, mode: .aspectFill)
            _ = TileContentFitter.fit(slotRect: slot, mediaAspect: aspect, mode: .aspectFit)
            #expect(slot == base)   // value type; the slot is never mutated by fitting
        }
    }
}
