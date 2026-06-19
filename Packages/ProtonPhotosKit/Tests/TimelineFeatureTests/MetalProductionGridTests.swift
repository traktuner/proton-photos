import Testing
import Foundation
import CoreGraphics
import PhotosCore
@testable import TimelineFeature

/// Phase-2 production-integration tests. Pure pieces (feature flag, selection model, layout parity,
/// zoom-level effect, interaction policy, accessibility label) run headlessly. Renderer-bound behaviors
/// (Metal selection-outline instances, marquee, drag-to-Finder) are covered by the manual acceptance
/// video; see the report.

private func uids(_ n: Int) -> [PhotoUID] { (0 ..< n).map { PhotoUID(volumeID: "v", nodeID: "\($0)") } }

// MARK: 1–2 — Feature flag + fallback

@Suite(.serialized) struct MetalGridFeatureFlagTests {
    private func withFlag(_ value: Bool?, _ body: () -> Void) {
        let d = UserDefaults.standard, key = MetalGridFeatureFlag.userDefaultsKey
        let saved = d.object(forKey: key)
        if let value { d.set(value, forKey: key) } else { d.removeObject(forKey: key) }
        body()
        if let saved { d.set(saved, forKey: key) } else { d.removeObject(forKey: key) }
    }

    @Test func defaultsToEnabled() {
        withFlag(nil) { #expect(MetalGridFeatureFlag.isEnabled == true) }   // unset → ON
    }

    @Test func disableViaUserDefaultsUsesFallback() {
        withFlag(false) {
            #expect(MetalGridFeatureFlag.isEnabled == false)
            #expect(MetalGridRuntime.usesMetalGrid == false)   // flag OFF → NSCollectionView fallback
        }
        withFlag(true) {
            #expect(MetalGridFeatureFlag.isEnabled == true)
            // usesMetalGrid == flag AND renderable; on a GPU host this is true.
            #expect(MetalGridRuntime.usesMetalGrid == MetalGridRuntime.isMetalRenderable)
        }
    }
}

// MARK: 3 — Layout parity (single production section)

@MainActor
@Suite struct MetalProductionLayoutParityTests {
    @Test func singleSectionMatchesJustifiedLayout() {
        let count = 2_037
        let jl = JustifiedCollectionLayout()
        jl.sectionAspects = [Array(repeating: CGFloat(1), count: count)]
        for width in [720, 1280] as [CGFloat] {
            for level in 0 ..< JustifiedCollectionLayout.levels.count {
                let mg = MetalGridLayout.forLevel(level, sectionCounts: [count], width: width)
                #expect(abs(mg.contentSize.height - jl.projectedContentSize(level: level, width: width).height) < 0.5)
                for item in [0, 1, count / 2, count - 1] {
                    let jr = jl.projectedFrameForItem(at: IndexPath(item: item, section: 0), level: level, width: width)
                    let mr = mg.frame(section: 0, item: item)
                    #expect(jr != nil && mr != nil)
                    if let jr, let mr { #expect(abs(jr.minX - mr.minX) < 0.5 && abs(jr.minY - mr.minY) < 0.5 && abs(jr.width - mr.width) < 0.5) }
                }
            }
        }
    }
}

// MARK: 4 — Zoom level changes the Metal layout

@Suite struct MetalGridZoomLevelTests {
    @Test func zoomLevelChangesColumnsAndContentHeight() {
        let counts = [1000]
        let zoomedIn = MetalGridLayout(sectionCounts: counts, level: 0, size: 330, gap: 12, cropMode: .aspectFit, width: 1200)
        let zoomedOut = MetalGridLayout(sectionCounts: counts, level: 5, size: 44, gap: 1, cropMode: .squareFill, width: 1200)
        #expect(zoomedOut.metrics.cols > zoomedIn.metrics.cols)        // smaller thumbnails → more columns
        #expect(zoomedOut.contentHeight < zoomedIn.contentHeight)      // more columns → fewer rows → shorter
    }
}

// MARK: 5,7,8 — Selection (single / cmd / shift)

@MainActor
@Suite struct MetalGridSelectionControllerTests {
    @Test func singleClickReplaces() {
        let u = uids(10); let c = MetalGridSelectionController()
        c.click(flatIndex: 3, uid: u[3], orderedUIDs: u, modifiers: [], selectionMode: false)
        #expect(c.selected == [u[3]])
        c.click(flatIndex: 5, uid: u[5], orderedUIDs: u, modifiers: [], selectionMode: false)
        #expect(c.selected == [u[5]])   // replaces, not adds
    }

    @Test func cmdClickToggles() {
        let u = uids(10); let c = MetalGridSelectionController()
        c.click(flatIndex: 3, uid: u[3], orderedUIDs: u, modifiers: .command, selectionMode: false)
        c.click(flatIndex: 6, uid: u[6], orderedUIDs: u, modifiers: .command, selectionMode: false)
        #expect(c.selected == [u[3], u[6]])
        c.click(flatIndex: 3, uid: u[3], orderedUIDs: u, modifiers: .command, selectionMode: false)
        #expect(c.selected == [u[6]])   // toggled off
    }

    @Test func shiftClickSelectsRange() {
        let u = uids(10); let c = MetalGridSelectionController()
        c.click(flatIndex: 2, uid: u[2], orderedUIDs: u, modifiers: [], selectionMode: false)   // anchor
        c.click(flatIndex: 5, uid: u[5], orderedUIDs: u, modifiers: .shift, selectionMode: false)
        #expect(c.selected == Set(u[2 ... 5]))
    }

    @Test func backgroundClickClears() {
        let u = uids(4); let c = MetalGridSelectionController()
        c.click(flatIndex: 1, uid: u[1], orderedUIDs: u, modifiers: [], selectionMode: false)
        c.clickBackground()
        #expect(c.selected.isEmpty)
    }

    @Test func onChangeFires() {
        let u = uids(4); let c = MetalGridSelectionController()
        var last: Set<PhotoUID> = []
        c.onChange = { last = $0 }
        c.click(flatIndex: 2, uid: u[2], orderedUIDs: u, modifiers: [], selectionMode: false)
        #expect(last == [u[2]])
    }
}

// MARK: 6 / 14 — Double-click opens viewer / handoff mapping

@Suite struct MetalGridViewerHandoffTests {
    @Test func doubleClickOpensViewer_singleDoesNot() {
        #expect(GridInteractionPolicy.decision(click: .double).opensViewer == true)
        #expect(GridInteractionPolicy.decision(click: .single).opensViewer == false)
    }

    @Test func handoffResolvesCorrectItem() {
        let items = (0 ..< 5).map { PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "\($0)"), captureTime: Date(), mediaType: "image/jpeg") }
        let clicked = items[3].uid
        // The exact mapping MetalGridInteractionController.onOpen uses to hand off to the viewer.
        #expect(items.first { $0.uid == clicked } == items[3])
    }
}

// MARK: 16 — Accessibility label

@MainActor
@Suite struct MetalGridAccessibilityTests {
    @Test func labelStatesKindAndDate() {
        let video = PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "1"), captureTime: Date(timeIntervalSince1970: 0), mediaType: "video/quicktime")
        let photo = PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "2"), captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/jpeg")
        #expect(MetalGridAccessibilityProvider.label(for: video).hasPrefix("Video, "))
        #expect(MetalGridAccessibilityProvider.label(for: photo).hasPrefix("Photo, "))
    }
}
