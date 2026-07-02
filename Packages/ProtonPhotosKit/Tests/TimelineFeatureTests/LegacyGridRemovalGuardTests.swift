import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

/// Guards that the legacy grid implementations stay GONE and the canonical MetalGrid path is the only one.
/// These read the real source tree (via `#filePath`) so a future change that reintroduces the NSCollectionView
/// grid, the justified/aspect layout, the detent-zoom machinery, or the old sprite-transition overlay fails
/// CI immediately. Implements the cleanup's required guard tests (no NSCollectionView fallback flag, no
/// PhotoGridView/justified/zoom-math production references, removed files unreachable, MetalGrid-only timeline).
@Suite struct LegacyGridRemovalGuardTests {

    // .../Packages/ProtonPhotosKit/Tests/TimelineFeatureTests/<this>.swift → up 3 → ProtonPhotosKit
    private var packageDir: URL {
        var url = URL(fileURLWithPath: #filePath)
        url.deleteLastPathComponent()   // TimelineFeatureTests
        url.deleteLastPathComponent()   // Tests
        url.deleteLastPathComponent()   // ProtonPhotosKit
        return url
    }
    private var sourcesDir: URL { packageDir.appendingPathComponent("Sources/TimelineFeature") }

    /// Every production `.swift` under Sources/TimelineFeature (recursive), as (filename, contents).
    private func productionSources() -> [(name: String, text: String)] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: sourcesDir, includingPropertiesForKeys: nil) else { return [] }
        var out: [(String, String)] = []
        for case let url as URL in en where url.pathExtension == "swift" {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                out.append((url.lastPathComponent, text))
            }
        }
        return out
    }

    // MARK: - NoProductionPhotoGridView / Justified / ZoomMath / detent references (#3, #4, #5)

    /// No production source may reference any removed legacy grid symbol - not even in a comment, so the
    /// names cannot creep back. Bare-identifier scan (none of these is a substring of a kept symbol).
    @Test func noProductionReferenceToRemovedLegacySymbols() {
        let banned = [
            // NSCollectionView grid
            "PhotoGridView", "PhotoGridItem", "RoundedCellView", "DateHeaderView", "MagnifyingCollectionView",
            // justified / aspect + the dead square replica
            "JustifiedCollectionLayout", "MetalGridLayout",
            // detent zoom machinery
            "GridDetentLayout", "GridZoomDetentModel", "GridZoomTransition", "MetalGridDetentZoomFlag",
            "GridZoomDebug", "GridLayoutFamily", "GridDetentCell", "detentModel", "usesDetentZoom",
            // old zoom math + sprite-transition overlay
            "GridZoomMath", "GridSpriteTransitionView", "GridSpriteRenderer", "GridResizeStabilizer",
            "ContinuousGridLayoutEngine", "GridThumbnailFallback",
            // edge-fill / two-surface transition vocabulary
            "sourcePlate", "targetBackdrop", "targetWall", "exposedLeftRect", "replacementPlan",
            // the removed NSCollectionView feature flag
            "MetalGridFeatureFlag",
        ]
        let sources = productionSources()
        #expect(!sources.isEmpty, "could not read production sources")
        for (name, text) in sources {
            for term in banned {
                #expect(!text.contains(term), "production source \(name) still references removed legacy symbol '\(term)'")
            }
        }
    }

    // MARK: - RemovedLegacyFilesUnreachable (#9)

    /// The legacy grid files are deleted outright (not quarantined), so they cannot be reached at all.
    @Test func removedLegacyFilesDoNotExist() {
        let fm = FileManager.default
        let removed = [
            "PhotoGridView.swift", "PhotoGridItem.swift", "JustifiedCollectionLayout.swift",
            "MetalGridLayout.swift", "GridSpriteTransitionView.swift", "GridZoomMath.swift",
            "GridResizeStabilizer.swift", "ContinuousGridLayoutEngine.swift", "ThumbnailFallback.swift",
            "DurationLookupGate.swift", "MetalGridFeatureFlag.swift",
            "GridZoom/GridDetentLayout.swift", "GridZoom/GridZoomDetentModel.swift",
            "GridZoom/GridZoomTransition.swift", "GridZoom/MetalGridDetentZoomFlag.swift",
        ]
        for rel in removed {
            #expect(!fm.fileExists(atPath: sourcesDir.appendingPathComponent(rel).path),
                    "legacy file \(rel) must be deleted, not present")
        }
    }

    // MARK: - NoNSCollectionViewFallbackFlag (#2)

    /// No production source defines or reads a flag that could switch the timeline back to NSCollectionView.
    @Test func noNSCollectionViewFallbackFlag() {
        for (name, text) in productionSources() {
            #expect(!text.contains("MetalGrid.enabled"),
                    "production source \(name) must not gate the grid on a MetalGrid.enabled flag")
            #expect(!text.lowercased().contains("nscollectionview"),
                    "production source \(name) must not mention an NSCollectionView grid path")
        }
    }

    // MARK: - ProductionTimelineUsesMetalGridOnly (#1) + AppBuildPathSmoke (#10, compile-level)

    /// `TimelineView` (the production entry) constructs `MetalProductionGridView` and nothing else. Building
    /// the engine + a frame here also proves the canonical geometry path links and runs headlessly.
    @Test func productionTimelineUsesMetalGridOnly() {
        let tv = (try? String(contentsOf: sourcesDir.appendingPathComponent("TimelineView.swift"), encoding: .utf8)) ?? ""
        #expect(tv.contains("MetalProductionGridView("), "timeline must build the Metal grid")
        #expect(!tv.contains("PhotoGridView("), "timeline must not build the NSCollectionView grid")

        let e = SquareTileGridEngine.testRegular(sectionCounts: [5_000])
        let plan = e.framePlan(level: 3, viewportSize: CGSize(width: 1280, height: 800),
                               scrollOffset: CGPoint(x: 0, y: 4000), overscan: 0)
        #expect(!plan.visibleSlots.isEmpty)
        for s in plan.visibleSlots { #expect(abs(s.slotRect.width - s.slotRect.height) < 0.01) }   // square only
    }

    // MARK: - SquareTileGridEngineIsGeometrySource (#6) + TileContentFitterIsContentOnly (#7)

    /// The fitter only changes the content rect / UV inside a slot; it can never change the (square) slot.
    @Test func tileContentFitterIsContentOnly() {
        let slot = CGRect(x: 100, y: 200, width: 140, height: 140)
        for aspect in [0.25, 0.5, 1.0, 1.78, 4.0] as [CGFloat] {
            let fill = TileContentFitter.fit(slotRect: slot, mediaAspect: aspect, mode: .aspectFill)
            #expect(fill.contentRect == slot, "aspectFill fills the square slot exactly; aspect lives only in UV")
            let fit = TileContentFitter.fit(slotRect: slot, mediaAspect: aspect, mode: .aspectFit)
            #expect(slot.contains(fit.contentRect) || fit.contentRect == slot, "aspectFit stays inside the slot")
            // The slot itself is never mutated by the fitter (geometry is the engine's, content is the fitter's).
            #expect(fill.contentRect.width <= slot.width + 0.01 && fill.contentRect.height <= slot.height + 0.01)
        }
    }
}
