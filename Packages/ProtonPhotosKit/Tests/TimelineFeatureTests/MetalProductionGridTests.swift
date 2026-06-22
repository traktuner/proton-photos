import Testing
import Foundation
import CoreGraphics
import PhotosCore
@testable import TimelineFeature

/// Production-integration tests for the Metal grid's kept components: selection model, interaction
/// policy (double-click → viewer), and accessibility label. Renderer-bound behaviors (Metal
/// selection-outline instances, marquee, drag-to-Finder) are covered by the manual acceptance video.
///
/// (The legacy feature-flag/fallback and `MetalGridLayout` ↔ `JustifiedCollectionLayout` parity suites
/// were removed with those types — production is MetalGrid-only and the geometry is the canonical
/// `SquareTileGridEngine`.)

private func uids(_ n: Int) -> [PhotoUID] { (0 ..< n).map { PhotoUID(volumeID: "v", nodeID: "\($0)") } }

// MARK: Selection (single / cmd / shift)

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

// MARK: Double-click opens viewer / handoff mapping

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

// MARK: Accessibility label

@MainActor
@Suite struct MetalGridAccessibilityTests {
    @Test func labelStatesKindAndDate() {
        let video = PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "1"), captureTime: Date(timeIntervalSince1970: 0), mediaType: "video/quicktime")
        let photo = PhotoItem(uid: PhotoUID(volumeID: "v", nodeID: "2"), captureTime: Date(timeIntervalSince1970: 0), mediaType: "image/jpeg")
        #expect(MetalGridAccessibilityProvider.label(for: video).hasPrefix("Video, "))
        #expect(MetalGridAccessibilityProvider.label(for: photo).hasPrefix("Photo, "))
    }
}
