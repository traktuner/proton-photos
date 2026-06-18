import Testing
import CoreGraphics
@testable import TimelineFeature

/// Guardrails for the DISCRETE grid zoom — the only zoom path. A pinch mirrors the + / − buttons:
/// one gesture = at most one discrete step, no continuous live scaling, and a level change is a full
/// grid crossfade (no per-photo motion). These pure tests cover the step detector, the level math,
/// the transition state machine, and the anchor-origin math headlessly (no AppKit window).
///
/// Note: swift-testing's `#expect` captures its argument immutably, so every mutating call
/// (`accumulate`, `requestTransition`, `finishTransition`) is made on its own line and the result is
/// checked separately.
@MainActor
@Suite struct DiscreteGridZoomTests {

    private let levelCount = JustifiedCollectionLayout.levels.count   // 6

    // MARK: 1. A pinch crossing the threshold triggers EXACTLY one step

    @Test func pinchTriggersSingleStepAcrossThreshold() {
        var d = PinchStepDetector(threshold: 0.10)
        d.begin()
        let below1 = d.accumulate(0.04)   // 0.04 — below threshold
        let below2 = d.accumulate(0.04)   // 0.08 — still below
        let fire = d.accumulate(0.04)     // 0.12 — crosses → fire once
        let after = d.accumulate(0.50)    // rest of the gesture is ignored
        #expect(below1 == nil)
        #expect(below2 == nil)
        #expect(fire == .zoomIn)
        #expect(after == nil)
        d.end()
        // A clearly separate gesture is allowed to step again.
        d.begin()
        let again = d.accumulate(0.20)
        #expect(again == .zoomIn)
    }

    // MARK: 2. Direction follows the sign of the magnification

    @Test func pinchDirectionMapsSign() {
        var zin = PinchStepDetector(threshold: 0.10); zin.begin()
        let inDir = zin.accumulate(0.15)     // positive → zoom in (the + button)
        #expect(inDir == .zoomIn)

        var zout = PinchStepDetector(threshold: 0.10); zout.begin()
        let outDir = zout.accumulate(-0.15)  // negative → zoom out (the − button)
        #expect(outDir == .zoomOut)
    }

    // MARK: 3. The gesture NEVER produces continuous scaling

    @Test func pinchDoesNotContinuouslyScale() {
        var d = PinchStepDetector(threshold: 0.10)
        d.begin()
        var fires = 0
        for _ in 0 ..< 50 where d.accumulate(0.05) != nil { fires += 1 }   // large cumulative magnification
        #expect(fires == 1)                 // exactly one discrete step — never a continuous ramp
        #expect(d.firedThisGesture)
        // The detector's only output is a discrete `GridZoomDirection?`; there is no scale/progress
        // value anywhere, so a `.changed` tick can never drive a live layout.
    }

    // MARK: 4. Buttons and pinch use the SAME step definition

    @Test func buttonsAndPinchUseSameStep() {
        for current in 0 ..< levelCount {
            // The + button (zoom in) and pinch-in both resolve through `steppedGridLevel(.zoomIn)`.
            #expect(steppedGridLevel(current: current, direction: .zoomIn, count: levelCount) == max(0, current - 1))
            // The − button (zoom out) and pinch-out both resolve through `steppedGridLevel(.zoomOut)`.
            #expect(steppedGridLevel(current: current, direction: .zoomOut, count: levelCount) == min(levelCount - 1, current + 1))
        }
        // Pinch sign maps to the same directions the buttons use.
        var zin = PinchStepDetector(threshold: 0.10); zin.begin()
        let inDir = zin.accumulate(0.20)
        #expect(inDir == .zoomIn)
        var zout = PinchStepDetector(threshold: 0.10); zout.begin()
        let outDir = zout.accumulate(-0.20)
        #expect(outDir == .zoomOut)
    }

    // MARK: 5. Cannot zoom beyond min/max level

    @Test func clampAndStepRespectBounds() {
        #expect(clampGridLevel(-3, count: levelCount) == 0)
        #expect(clampGridLevel(99, count: levelCount) == levelCount - 1)
        #expect(steppedGridLevel(current: 0, direction: .zoomIn, count: levelCount) == 0)               // already most zoomed-in
        #expect(steppedGridLevel(current: levelCount - 1, direction: .zoomOut, count: levelCount) == levelCount - 1) // already most zoomed-out
    }

    // MARK: 6. Anchor preservation places the anchor back under the same viewport point

    @Test func anchorPreservationPlacesAnchorAtViewportPoint() {
        // The anchor photo's cell at the TARGET level (document space), the image-local point the
        // cursor was over, and where that point sat in the viewport.
        let targetCell = CGRect(x: 400, y: 1200, width: 120, height: 120)
        let imageSize = CGSize(width: 120, height: 120)   // squareFill → the image fills the cell
        let local = CGPoint(x: 0.5, y: 0.5)
        let viewportPoint = CGPoint(x: 300, y: 250)

        let origin = GridZoomMath.anchoredImageOrigin(
            targetCellFrame: targetCell, imageSize: imageSize, cropMode: .squareFill,
            imageLocalUnitPoint: local, viewportPoint: viewportPoint)

        // After scrolling to `origin`, the anchor's content point must land at `viewportPoint`.
        let imageFrame = GridZoomMath.displayedImageFrame(cellFrame: targetCell, imageSize: imageSize, cropMode: .squareFill)
        let contentPoint = CGPoint(x: imageFrame.minX + local.x * imageFrame.width,
                                   y: imageFrame.minY + local.y * imageFrame.height)
        #expect(abs((contentPoint.x - origin.x) - viewportPoint.x) < 0.001)
        #expect(abs((contentPoint.y - origin.y) - viewportPoint.y) < 0.001)
    }

    // MARK: 7. Cannot start overlapping transitions; latest queued wins

    @Test func cannotStartOverlappingTransitions() {
        var c = DiscreteZoomController()
        #expect(c.state == .idle)
        let started = c.requestTransition(from: 2, to: 1)    // starts
        #expect(started)
        #expect(c.state.isTransitioning)
        let refused1 = c.requestTransition(from: 1, to: 0)   // refused while running → queued
        let refused2 = c.requestTransition(from: 1, to: 3)   // latest queued target wins
        #expect(refused1 == false)
        #expect(refused2 == false)
        let next = c.finishTransition()
        #expect(next == 3)                                   // exactly the latest queued
        #expect(c.state == .idle)
        let noop = c.requestTransition(from: 2, to: 2)       // no-op (same level) — neither starts nor queues
        #expect(noop == false)
    }

    // MARK: 8. The old continuous/live zoom path is never reached by the discrete model

    @Test func oldLivePathNotInvokedByDiscreteModel() {
        let before = DiscreteGridZoomDiagnostics.oldLiveZoomPathInvocations
        var d = PinchStepDetector()
        d.begin()
        _ = d.accumulate(0.05)
        _ = d.accumulate(0.10)   // crosses threshold → one discrete step
        _ = d.accumulate(0.30)   // ignored
        d.end()
        var c = DiscreteZoomController()
        _ = c.requestTransition(from: 2, to: 1)
        _ = c.finishTransition()
        // Nothing in the discrete model touches the quarantined live path (which also assertion-fails
        // at runtime if ever reached).
        #expect(DiscreteGridZoomDiagnostics.oldLiveZoomPathInvocations == before)
    }

    // MARK: 9. The transition is a full-grid crossfade — no per-photo rect interpolation

    @Test func crossfadeIsFullGridNoRectMove() {
        // The only knob is a duration in the spec range; a transition is described by INTEGER level
        // endpoints, never by per-photo rects or a fractional progress value — so nothing can morph
        // oldRect → newRect.
        #expect(DiscreteGridZoomTuning.crossfadeDuration >= 0.12)
        #expect(DiscreteGridZoomTuning.crossfadeDuration <= 0.20)
        var c = DiscreteZoomController()
        let started = c.requestTransition(from: 2, to: 1)
        #expect(started)
        var matched = false
        if case .transitioning(let from, let to) = c.state, from == 2, to == 1 { matched = true }
        #expect(matched)
    }

    // MARK: 10. A failed transition cleans up (returns to idle, grid not wedged)

    @Test func failedTransitionReturnsToIdle() {
        var c = DiscreteZoomController()
        let started = c.requestTransition(from: 2, to: 4)
        #expect(started)
        // Simulate a failure: finish with no queued work. State must reset and nothing should be pending.
        let next = c.finishTransition()
        #expect(next == nil)
        #expect(c.state == .idle)
        // The machine accepts new work again — the grid is never stuck.
        let restart = c.requestTransition(from: 2, to: 1)
        #expect(restart)
    }
}
