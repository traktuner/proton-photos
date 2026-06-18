import CoreGraphics
import Foundation
import Testing
@testable import TimelineFeature

@MainActor
@Suite("Grid resize transition coordinator")
struct GridResizeTransitionCoordinatorTests {
    @Test func resizeTransactionStateTest() {
        let coordinator = GridResizeTransitionCoordinator()
        let transaction = begin(coordinator, now: 0)

        #expect(coordinator.state == .resizing(transaction))
        #expect(coordinator.beginCommit() == transaction)
        if case .committing(let committing) = coordinator.state {
            #expect(committing.id == transaction.id)
        } else {
            Issue.record("Expected committing state")
        }
        coordinator.finishCommit()
        #expect(coordinator.state == .idle)
    }

    @Test func resizeDebounceTest() {
        let coordinator = GridResizeTransitionCoordinator()
        _ = begin(coordinator, now: 10)
        coordinator.noteSizeChange(targetViewportSize: CGSize(width: 900, height: 600), sidebarWidth: 240, now: 10.05)

        #expect(!coordinator.readyToCommit(now: 10.10, debounce: 0.11))
        #expect(coordinator.readyToCommit(now: 10.17, debounce: 0.11))
    }

    @Test func anchorPreservationMathTest() {
        let result = GridResizeTransitionCoordinator.preservedScrollOrigin(
            sourceAnchorContentPoint: CGPoint(x: 400, y: 1_500),
            targetAnchorViewportPoint: CGPoint(x: 400, y: 300),
            targetContentSize: CGSize(width: 900, height: 3_000),
            targetViewportSize: CGSize(width: 800, height: 600)
        )

        #expect(result.scrollOrigin.y == 1_200)
        #expect(result.anchorError == .zero)
    }

    @Test func noOverlappingTransitionTest() {
        let coordinator = GridResizeTransitionCoordinator()
        let first = begin(coordinator, now: 0, overlayID: 42)
        _ = coordinator.beginCommit()
        coordinator.noteSizeChange(targetViewportSize: CGSize(width: 960, height: 640), sidebarWidth: 300, now: 0.2)

        guard case .resizing(let resumed) = coordinator.state else {
            Issue.record("Expected commit to be cancelled back into resizing")
            return
        }
        #expect(resumed.id == first.id)
        #expect(resumed.overlayID == 42)
        #expect(resumed.pendingTargetViewportSize == CGSize(width: 960, height: 640))
    }

    @Test func overlayCleanupTest() {
        let coordinator = GridResizeTransitionCoordinator()
        _ = begin(coordinator, now: 0)
        _ = coordinator.beginCommit()
        coordinator.cleanup()

        #expect(coordinator.state == .idle)
        #expect(coordinator.activeTransaction == nil)
    }

    @Test func overlayTransformScalesOrClipsAsOneSurface() {
        let anchor = GridResizeAnchor(
            kind: .viewportCenter,
            viewportPoint: CGPoint(x: 400, y: 300),
            contentPoint: CGPoint(x: 400, y: 1_000)
        )

        let wider = GridResizeTransitionCoordinator.overlayTransform(
            sourceViewportSize: CGSize(width: 800, height: 600),
            targetViewportSize: CGSize(width: 1_000, height: 600),
            anchor: anchor
        )
        #expect(wider.scale == 1.25)
        #expect(wider.frame.width == 1_000)
        #expect(wider.frame.midX == 400)

        let narrower = GridResizeTransitionCoordinator.overlayTransform(
            sourceViewportSize: CGSize(width: 800, height: 600),
            targetViewportSize: CGSize(width: 600, height: 600),
            anchor: anchor
        )
        #expect(narrower.scale == 1)
        #expect(narrower.frame.width == 800)
        #expect(narrower.frame.midX == 400)
    }

    private func begin(
        _ coordinator: GridResizeTransitionCoordinator,
        now: TimeInterval,
        overlayID: Int = 1
    ) -> GridResizeTransaction {
        coordinator.begin(
            reason: .windowResize,
            sourceViewportSize: CGSize(width: 800, height: 600),
            sourceContentOrigin: CGPoint(x: 0, y: 900),
            sourceVisibleRect: CGRect(x: 0, y: 900, width: 800, height: 600),
            sourceSnapshotSize: CGSize(width: 800, height: 600),
            sourceSnapshotFrame: CGRect(x: 0, y: 0, width: 800, height: 600),
            anchor: GridResizeAnchor(
                kind: .viewportCenter,
                viewportPoint: CGPoint(x: 400, y: 300),
                contentPoint: CGPoint(x: 400, y: 1_200)
            ),
            sidebarWidth: nil,
            now: now,
            overlayID: overlayID
        )
    }
}
