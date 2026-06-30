import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// Guards that the PRODUCTION timeline geometry stays canonical: MetalGrid-only, square slots from the
/// engine, no NSCollectionView fallback, no justified/aspect layout, no edge-fill as a layout source. The
/// source-scan guards read the real tree (via `#filePath`) so they fail if a non-canonical path is
/// reintroduced; the pure guards pin the engine/renderer contract.
@Suite struct GridCanonicalGuardTests {
    private let eps: CGFloat = 0.01

    // .../Packages/ProtonPhotosKit/Tests/TimelineFeatureTests/<this>.swift  → up 3 → ProtonPhotosKit
    private var packageRoot: URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()   // TimelineFeatureTests
        url.deleteLastPathComponent()   // Tests
        url.deleteLastPathComponent()   // ProtonPhotosKit
        return url
    }
    private func source(_ name: String) -> String {
        for target in ["TimelineFeature", "GridCore"] {
            let url = packageRoot.appendingPathComponent("Sources/\(target)/\(name)")
            if let source = try? String(contentsOf: url, encoding: .utf8) { return source }
        }
        return ""
    }

    private func engine(_ count: Int = 1500) -> SquareTileGridEngine { SquareTileGridEngine.testRegular(sectionCounts: [count]) }
    private let viewport = CGSize(width: 1400, height: 900)

    // NoProductionNSCollectionViewFallbackTest — the production timeline instantiates the Metal grid and
    // NEVER the legacy NSCollectionView grid (`PhotoGridView`).
    @Test func noProductionNSCollectionViewFallback() {
        let tv = source("TimelineView.swift")
        #expect(tv.contains("MetalProductionGridView("), "production timeline must use the Metal grid")
        #expect(!tv.contains("PhotoGridView("), "production timeline must NOT fall back to the NSCollectionView grid")
    }

    // NoProductionJustifiedAspectLayoutTest — production never feeds media aspect into the layout (no
    // justified/aspect rows); the engine is square-only by construction.
    @Test func noProductionJustifiedAspectLayout() {
        let tv = source("TimelineView.swift")
        #expect(!tv.contains("sectionAspects(for:"), "production timeline must not feed aspect ratios into layout")
        // Every engine slot is square at every level — the engine cannot produce a justified (aspect) cell.
        let e = engine()
        for level in 0 ..< e.levelCount {
            let plan = e.framePlan(level: level, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 2000), overscan: 0)
            for s in plan.visibleSlots { #expect(abs(s.slotRect.width - s.slotRect.height) < eps) }
        }
    }

    // NoEdgeFillHackAsLayoutSourceTest — the layout source of truth (SquareTileGridEngine) depends on NO
    // edge-fill / exposed-rect / replacement / wall machinery.
    @Test func noEdgeFillHackInEngine() {
        let engineSrc = source("SquareTileGridEngine.swift")
        let banned = ["exposedLeft", "exposedRight", "shrunkenSource", "sourcePlate", "targetWall",
                      "targetBackdrop", "replacementPlan", "PinchOutEdgeFill", "edgeFill"]
        for term in banned {
            #expect(!engineSrc.contains(term), "the canonical engine must not depend on '\(term)'")
        }
    }

    // MetalRendererReceivesSquareSlotQuadsTest — the outer quad rects the renderer is handed (the slots'
    // viewport rects) are square.
    @Test func rendererReceivesSquareSlotQuads() {
        let e = engine()
        let plan = e.framePlan(level: 2, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 1500), overscan: 200)
        #expect(!plan.visibleSlots.isEmpty)
        for s in plan.visibleSlots {
            #expect(abs(s.viewportRect.width - s.viewportRect.height) < eps)   // the outer quad is square
            #expect(abs(s.viewportRect.width - plan.slotSide) < eps)
        }
    }

    // GridZoomTransactionProductionPathTest — the live pinch is an engine-owned `GridZoomTransaction`
    // (focus-row stable), NOT a stateless per-frame re-resolve that rewraps columns, and NOT the deleted
    // detent/justified machinery.
    @Test func productionLiveZoomUsesEngineTransaction() {
        let coord = source("MetalGridCoordinator.swift")
        #expect(coord.contains("zoomTransaction"), "live zoom must be the engine-owned GridZoomTransaction")
        #expect(coord.contains("beginLiveZoom"), "the coordinator must drive the live-zoom transaction")
        // The deleted detent/justified zoom machinery must not come back into the coordinator.
        for banned in ["GridDetentLayout", "GridZoomDetentModel", "detentModel", "MetalGridLayout", "usesDetentZoom"] {
            #expect(!coord.contains(banned), "the coordinator must not reference removed '\(banned)'")
        }
    }

    // VideoThumbnailUsesSquareSlotTest — the engine has no media-type input, so a video occupies the same
    // square slot as a photo (the renderer would fit the video frame INSIDE the square via TileContentFitter).
    @Test func videoUsesSquareSlot() {
        let e = engine()
        let plan = e.framePlan(level: 2, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 1500), overscan: 0)
        let sides = Set(plan.visibleSlots.map { Int(($0.slotRect.width * 100).rounded()) })
        #expect(sides.count == 1, "every slot is the identical square regardless of payload (photo or video)")
        // A wide-video frame still fits inside the square slot via the fitter (contained, slot unchanged).
        let slot = plan.visibleSlots[0].slotRect
        let fit = TileContentFitter.fit(slotRect: slot, mediaAspect: 16.0 / 9.0, mode: .aspectFill)
        #expect(fit.contentRect == slot)   // fills the square; the crop is in UV, the slot is unchanged
    }
}
