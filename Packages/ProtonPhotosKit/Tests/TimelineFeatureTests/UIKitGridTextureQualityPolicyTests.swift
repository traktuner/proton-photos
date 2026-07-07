import CoreGraphics
import Testing
@testable import GridCore
@testable import MetalGridTextureUIKitAdapter

/// Locks the iOS texture-quality calibration: dense levels keep uploading small (scroll cost unchanged)
/// while the largest tiles can reach enough pixels to render sharp on 3× iPhones and 2× iPads, and the
/// jetsam-calibrated byte budgets stay exactly where the memory audit set them.
@Suite("UIKitGridTextureQualityPolicy")
struct UIKitGridTextureQualityPolicyTests {

    @Test func denseLevelUploadsStaySmallUnderTheRaisedCaps() {
        // A dense-overview tile (~31 pt on a 3× iPhone) must resolve far below the absolute cap -
        // the cap raise may not touch dense-scroll upload cost.
        let dense = GridTextureUploadSizing.uploadPixels(
            slotSidePoints: 31, backingScale: 3, headroom: 1.15, floor: 64,
            cap: UIKitMetalGridTexturePolicies.compact.maxTexturePixels
        )
        #expect(dense == 107)
        #expect(dense < 128)
    }

    @Test func largestCompactTilesCanRequestSharpPixels() {
        // The largest L0 tile a compact surface produces (~133 pt at 3×) must no longer clamp to the old
        // 224/288 ceilings - it should reach its native supersampled size within the new cap.
        let sparse = GridTextureUploadSizing.uploadPixels(
            slotSidePoints: 133, backingScale: 3, headroom: 1.15, floor: 64,
            cap: UIKitMetalGridTexturePolicies.compact.maxTexturePixels
        )
        #expect(sparse == 459)
        #expect(sparse > 288)   // above every pre-fix iOS ceiling
    }

    @Test func absolutePixelCapsMatchTheSurfaceCalibration() {
        #expect(UIKitMetalGridTexturePolicies.compact.maxTexturePixels == 480)
        #expect(UIKitMetalGridTexturePolicies.regular.maxTexturePixels == 512)
        #expect(UIKitMetalGridTexturePolicies.expanded.maxTexturePixels == 512)
    }

    @Test func jetsamCalibratedByteBudgetsAreUnchangedByTheCapRaise() {
        #expect(UIKitMetalGridTexturePolicies.compact.budget.maxResidentBytes == 67_108_864)     // 64 MiB
        #expect(UIKitMetalGridTexturePolicies.regular.budget.maxResidentBytes == 100_663_296)    // 96 MiB
        #expect(UIKitMetalGridTexturePolicies.expanded.budget.maxResidentBytes == 201_326_592)   // 192 MiB
        #expect(UIKitMetalGridTexturePolicies.compact.budget.maxUploadBytesPerFrame == 2_097_152)
        #expect(UIKitMetalGridTexturePolicies.regular.budget.maxUploadBytesPerFrame == 3_145_728)
        #expect(UIKitMetalGridTexturePolicies.expanded.budget.maxUploadBytesPerFrame == 4_194_304)
    }
}
