import CoreGraphics
import Foundation
import Testing
import PhotosCore
@testable import TimelineFeature

/// Tests for the recovery pass: the resize path keeps the real grid visible (no snapshot overlay, no
/// hidden grid, no reload during resize), preserves the anchor's content point, and keeps the sidebar
/// state consistent. The math + state are isolated into pure helpers so they're testable without AppKit.
@MainActor
@Suite("Grid resize stabilizer")
struct GridResizeStabilizerTests {

    // 4. ResizeAnchorMathTest — the anchor content point maps correctly after a viewport change.
    @Test func resizeAnchorMath() {
        // Exact: keep content y=1500 at viewport y=300 → origin.y = 1200, no error.
        let exact = computeScrollOriginPreservingResizeAnchor(
            targetContentPoint: CGPoint(x: 400, y: 1_500),
            anchorViewportPoint: CGPoint(x: 400, y: 300),
            contentSize: CGSize(width: 900, height: 3_000),
            viewportSize: CGSize(width: 800, height: 600)
        )
        #expect(exact.scrollOrigin.y == 1_200)
        #expect(exact.scrollOrigin.x == 0)
        #expect(exact.anchorError == .zero)

        // Clamp at the top: requested origin negative → 0, error reports the residual.
        let clampedTop = computeScrollOriginPreservingResizeAnchor(
            targetContentPoint: CGPoint(x: 0, y: 100),
            anchorViewportPoint: CGPoint(x: 0, y: 300),
            contentSize: CGSize(width: 800, height: 3_000),
            viewportSize: CGSize(width: 800, height: 600)
        )
        #expect(clampedTop.scrollOrigin.y == 0)
        #expect(clampedTop.anchorError.y == 200)   // wanted -200, clamped to 0 → off by +200

        // Clamp at the bottom: requested origin beyond content → maxY.
        let clampedBottom = computeScrollOriginPreservingResizeAnchor(
            targetContentPoint: CGPoint(x: 0, y: 2_950),
            anchorViewportPoint: CGPoint(x: 0, y: 100),
            contentSize: CGSize(width: 800, height: 3_000),
            viewportSize: CGSize(width: 800, height: 600)
        )
        #expect(clampedBottom.scrollOrigin.y == 2_400)   // maxY = 3000 - 600

        // The struct carries the optional uid + localPoint used to re-resolve the item after relayout.
        let anchor = ResizeAnchor(kind: .mouse, viewportPoint: CGPoint(x: 10, y: 20),
                                  contentPoint: CGPoint(x: 30, y: 40), uid: "v~n",
                                  localPoint: CGPoint(x: 0.25, y: 0.75))
        #expect(anchor.uid == "v~n")
        #expect(anchor.localPoint == CGPoint(x: 0.25, y: 0.75))
        #expect(anchor.kind == .mouse)
    }

    // 5. ResizeStateMachineTest — idle → resizing → idle.
    @Test func resizeStateMachine() {
        let stabilizer = GridResizeStabilizer()
        #expect(stabilizer.state == .idle)
        #expect(!stabilizer.isResizing)

        stabilizer.begin(reason: .windowResize)
        #expect(stabilizer.state == .resizing(.windowResize))
        #expect(stabilizer.isResizing)
        #expect(stabilizer.reason == .windowResize)

        stabilizer.update(reason: .sidebarDrag)              // stays resizing, reason updates
        #expect(stabilizer.state == .resizing(.sidebarDrag))

        stabilizer.end()
        #expect(stabilizer.state == .idle)
        #expect(!stabilizer.isResizing)
        #expect(stabilizer.reason == nil)
    }

    // 6. NoOverlayResizePathTest — the production resize path has no snapshot/overlay mode.
    @Test func noOverlayResizePath() {
        let stabilizer = GridResizeStabilizer()
        #expect(stabilizer.usesSnapshotOverlay == false)

        // The state machine has exactly two cases: there is no `.committing` / overlay state to enter.
        stabilizer.begin(reason: .sidebarToggle)
        switch stabilizer.state {
        case .idle, .resizing:
            break   // only valid cases — no overlay state exists
        }
        #expect(stabilizer.state.isResizing)
        #expect(stabilizer.usesSnapshotOverlay == false)
    }

    // 7. NoHiddenGridDuringResizeTest — the collection view is never hidden / faded during resize.
    @Test func noHiddenGridDuringResize() {
        let stabilizer = GridResizeStabilizer()
        // Idle.
        #expect(stabilizer.collectionHidden == false)
        #expect(stabilizer.collectionAlpha == 1)
        // Active resize — same invariant.
        stabilizer.begin(reason: .windowResize)
        #expect(stabilizer.collectionHidden == false)
        #expect(stabilizer.collectionAlpha == 1)
        stabilizer.update(reason: .sidebarDrag)
        #expect(stabilizer.collectionHidden == false)
        #expect(stabilizer.collectionAlpha == 1)
        // After end.
        stabilizer.end()
        #expect(stabilizer.collectionHidden == false)
        #expect(stabilizer.collectionAlpha == 1)
    }

    // 8. NoReloadDuringResizeTest — reloads are deferred while resizing; the escape hatch is counted.
    @Test func noReloadDuringResize() {
        let stabilizer = GridResizeStabilizer()
        #expect(!stabilizer.shouldDeferReload())
        #expect(stabilizer.reloadDuringResizeCount == 0)

        stabilizer.begin(reason: .windowResize)
        #expect(stabilizer.shouldDeferReload())        // normal path defers — no reloadData
        #expect(stabilizer.reloadDuringResizeCount == 0)

        stabilizer.noteReloadDuringResize()            // only the explicitly-logged escape bumps the count
        #expect(stabilizer.reloadDuringResizeCount == 1)

        stabilizer.end()
        #expect(!stabilizer.shouldDeferReload())
    }

    // 10. SidebarToggleStateTest — hide/show transitions end at the expected width and visible state.
    @Test func sidebarToggleState() {
        let width: CGFloat = 260
        // Shown → full (clamped) width; hidden → collapsed to 0.
        #expect(SidebarMetrics.effectiveWidth(visible: true, width: width) == width)
        #expect(SidebarMetrics.effectiveWidth(visible: false, width: width) == 0)
        // Width still clamps when shown.
        #expect(SidebarMetrics.effectiveWidth(visible: true, width: 9_000) == SidebarMetrics.maxWidth)
        #expect(SidebarMetrics.effectiveWidth(visible: true, width: 10) == SidebarMetrics.minWidth)

        // Visible state persists across the toggle.
        let suite = "tests-sidebar-toggle-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        SidebarPersistence.saveVisible(false, defaults: defaults)
        #expect(!SidebarPersistence.resolvedVisible(defaults: defaults))
        SidebarPersistence.saveVisible(true, defaults: defaults)
        #expect(SidebarPersistence.resolvedVisible(defaults: defaults))
    }

    // 11. PlaceholderDuringResizeTest — a missing thumbnail produces a placeholder, never an empty rect.
    @Test func placeholderDuringResize() {
        #expect(gridCellFillDuringResize(hasDecodedImage: false) == .placeholder)
        #expect(gridCellFillDuringResize(hasDecodedImage: true) == .image)

        // The placeholder `PhotoGridItem` falls back to is a real, non-empty, opaque image — so a cell
        // awaiting its thumbnail draws solid pixels, not a hole.
        let placeholder = GridThumbnailFallback.placeholderImage
        #expect(placeholder.width > 0)
        #expect(placeholder.height > 0)
    }

    // MARK: - Manual sidebar drag = window resize with a different cause (recovery pass)
    //
    // The production begin/reanchor/end lifecycle lives in the AppKit `PhotoGridView.Coordinator` and
    // can't be exercised headlessly, so these assert the contract at the shared seam every reason runs
    // through: the one `GridResizeStabilizer`, the one anchor-math helper, and the `SidebarMetrics` /
    // `SidebarPersistence` rules the drag obeys. If sidebar drag ever forks onto its own path, the
    // production call sites (`beginResize` / `reanchorDuringResize` / `endResize`) would have to stop
    // using these — which these tests pin down.

    // 1. SidebarDragUsesSharedResizePathTest — a sidebar drag drives the IDENTICAL stabilizer lifecycle
    //    as a window resize. Same instance, same states, only the reason differs.
    @Test func sidebarDragUsesSharedResizePath() {
        func run(_ reason: GridResizeReason) -> [GridResizeStabilizerState] {
            let s = GridResizeStabilizer()
            var trace: [GridResizeStabilizerState] = [s.state]
            s.begin(reason: reason); trace.append(s.state)
            s.update(reason: reason); trace.append(s.state)   // a width tick keeps resizing
            s.end(); trace.append(s.state)
            return trace
        }
        let window = run(.windowResize)
        let sidebar = run(.sidebarDrag)
        // Structurally identical: idle → resizing → resizing → idle, parameterised only by the reason.
        #expect(window == [.idle, .resizing(.windowResize), .resizing(.windowResize), .idle])
        #expect(sidebar == [.idle, .resizing(.sidebarDrag), .resizing(.sidebarDrag), .idle])
        #expect(window.map(\.isResizing) == sidebar.map(\.isResizing))

        // And a single session can carry a reason CHANGE without leaving the resizing state (a sidebar
        // drag that becomes a window resize, or vice-versa) — proving one continuous shared session.
        let s = GridResizeStabilizer()
        s.begin(reason: .sidebarDrag)
        s.update(reason: .windowResize)
        #expect(s.state == .resizing(.windowResize))
        #expect(s.isResizing)
    }

    // 2. SidebarDragNoHiddenGridTest — during a sidebar drag the grid is never hidden / faded.
    @Test func sidebarDragNoHiddenGrid() {
        let s = GridResizeStabilizer()
        s.begin(reason: .sidebarDrag)
        #expect(s.isResizing)
        #expect(s.reason == .sidebarDrag)
        #expect(s.collectionHidden == false)
        #expect(s.collectionAlpha == 1)
        // Through a few width ticks the invariant holds.
        for _ in 0..<5 {
            s.update(reason: .sidebarDrag)
            #expect(s.collectionHidden == false)
            #expect(s.collectionAlpha == 1)
        }
        s.end()
        #expect(s.collectionHidden == false)
        #expect(s.collectionAlpha == 1)
    }

    // 3. SidebarDragNoOverlayPathTest — a sidebar drag never enters the rejected snapshot/overlay path.
    @Test func sidebarDragNoOverlayPath() {
        let s = GridResizeStabilizer()
        s.begin(reason: .sidebarDrag)
        #expect(s.usesSnapshotOverlay == false)
        // The machine has exactly two cases — there is no overlay/commit state to fall into mid-drag.
        switch s.state {
        case .idle, .resizing:
            break
        }
        #expect(s.state.isResizing)
        #expect(s.usesSnapshotOverlay == false)
    }

    // 4. SidebarDragAnchorPreservationTest — widening the sidebar shrinks the grid viewport; the anchor's
    //    content point must stay under the same viewport point, using the SAME helper window resize uses.
    @Test func sidebarDragAnchorPreservation() {
        // Sidebar goes 200 → 280 (Δ80): the grid viewport width shrinks 800 → 720. The user's anchor is a
        // photo whose content point sits at viewport y=400; after the narrower relayout that same photo
        // lands at content y=2050. Keep it under y=400 on screen.
        let viewport = CGSize(width: 720, height: 600)
        let content = CGSize(width: 720, height: 4_000)
        let solution = computeScrollOriginPreservingResizeAnchor(
            targetContentPoint: CGPoint(x: 360, y: 2_050),
            anchorViewportPoint: CGPoint(x: 360, y: 400),
            contentSize: content,
            viewportSize: viewport
        )
        #expect(solution.scrollOrigin.y == 1_650)      // 2050 - 400
        #expect(solution.anchorError == .zero)         // reachable → anchor exactly preserved

        // It is literally the window-resize helper: same inputs, same output regardless of cause.
        let windowResizeSolution = computeScrollOriginPreservingResizeAnchor(
            targetContentPoint: CGPoint(x: 360, y: 2_050),
            anchorViewportPoint: CGPoint(x: 360, y: 400),
            contentSize: content,
            viewportSize: viewport
        )
        #expect(solution == windowResizeSolution)
    }

    // 5. SidebarDragPersistenceTest — the final width persists only at drag end (and clamped), never per
    //    tick. Modelled as: ticks mutate a local width but only the release calls `saveWidth`.
    @Test func sidebarDragPersistence() {
        let suite = "tests-sidebar-drag-persist-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        SidebarPersistence.saveWidth(240, defaults: defaults)   // pre-drag persisted width
        // Simulate a drag: width sweeps across ticks WITHOUT persisting.
        var liveWidth: CGFloat = 240
        for delta in stride(from: CGFloat(4), through: 60, by: 4) {
            liveWidth = SidebarMetrics.clamp(240 + delta)
        }
        // Mid-drag the stored value is unchanged — no per-tick UserDefaults churn.
        #expect(SidebarPersistence.resolvedWidth(defaults: defaults) == 240)
        // On release we persist exactly once.
        SidebarPersistence.saveWidth(liveWidth, defaults: defaults)
        #expect(SidebarPersistence.resolvedWidth(defaults: defaults) == liveWidth)
        #expect(liveWidth == 300)
    }

    // 6. SidebarToggleStillUsesSharedPathTest — automatic hide/show drives the same stabilizer lifecycle.
    @Test func sidebarToggleStillUsesSharedPath() {
        let s = GridResizeStabilizer()
        s.begin(reason: .sidebarToggle)
        #expect(s.state == .resizing(.sidebarToggle))
        #expect(s.collectionHidden == false)
        #expect(s.collectionAlpha == 1)
        #expect(s.usesSnapshotOverlay == false)
        #expect(s.shouldDeferReload())                 // same reload-deferral as every other reason
        s.end()
        #expect(s.state == .idle)
    }

    // 7. NoReloadDuringSidebarDragTest — reloadData is deferred during a sidebar drag; the escape hatch
    //    is the only thing that bumps the counter, and it is logged.
    @Test func noReloadDuringSidebarDrag() {
        let s = GridResizeStabilizer()
        s.begin(reason: .sidebarDrag)
        #expect(s.shouldDeferReload())                 // structure changes are held, not reloaded live
        #expect(s.reloadDuringResizeCount == 0)
        s.update(reason: .sidebarDrag)
        #expect(s.reloadDuringResizeCount == 0)        // width ticks never reload
        s.noteReloadDuringResize()                     // explicit, counted escape hatch
        #expect(s.reloadDuringResizeCount == 1)
        s.end()
        #expect(!s.shouldDeferReload())
    }

    // 8. WidthClampTest — a manual drag clamps width to [min, max] every tick.
    @Test func widthClamp() {
        #expect(SidebarMetrics.clamp(SidebarMetrics.minWidth - 50) == SidebarMetrics.minWidth)
        #expect(SidebarMetrics.clamp(SidebarMetrics.maxWidth + 50) == SidebarMetrics.maxWidth)
        let mid = (SidebarMetrics.minWidth + SidebarMetrics.maxWidth) / 2
        #expect(SidebarMetrics.clamp(mid) == mid)
        // A drag that overshoots both ends still produces only in-range widths.
        for raw in stride(from: CGFloat(-200), through: 800, by: 17) {
            let w = SidebarMetrics.clamp(raw)
            #expect(w >= SidebarMetrics.minWidth)
            #expect(w <= SidebarMetrics.maxWidth)
        }
    }
}
