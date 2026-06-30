// GridTransitionControllerTests.swift
//
// Phase-B grid transition driver — PRODUCTION DEFAULT (no feature flag). The controller builds the
// single-presentation-lattice click/pinch transition for every eligible step and falls back to the stable
// instant snap ONLY for ineligible geometry (lattice build failed, degenerate plan). Selection is a settled-grid
// decoration concern and must not force the grid onto a reflow/snap fallback.

import Testing
import Foundation
import CoreGraphics
import GridCore
@testable import TimelineFeature

@Suite struct GridTransitionControllerTests {

    private func plans() -> (GridFramePlan, GridFramePlan) {
        let viewport = CGSize(width: 1400, height: 900)
        let engine = SquareTileGridEngine.testRegular(sectionCounts: [4000])
        let src = engine.framePlan(level: 0, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
        let tgt = engine.framePlan(level: 1, viewportSize: viewport, scrollOffset: .zero, overscan: 0)
        return (src, tgt)
    }

    // The transition is on by DEFAULT — no flag, no UserDefaults — and builds/draws/settles a click.
    @Test func clickBuildsPlanAndDrawsAndSettlesByDefault() {
        let (src, tgt) = plans()
        let c = GridTransitionController()
        #expect(c.beginClick(source: src, target: tgt, anchorIndex: 0,
                             viewportSize: CGSize(width: 1400, height: 900), selection: []))
        #expect(c.isActive)
        #expect(!c.currentDraws().isEmpty)
        #expect(c.q == 0)
        // advance to settle (420 ms in 60 Hz steps); one partial component at a time throughout
        var partialOK = true
        for _ in 0 ..< 40 { if c.partialComponentCount() > 1 { partialOK = false }; _ = c.advanceClick(bySeconds: 1.0 / 60.0) }
        #expect(partialOK)
        #expect(c.isActive == false)        // settled and ended itself (host clock owns q, no timer)
    }

    @Test func sevenNineViewportCenterClickBuildsPlan() throws {
        let viewport = CGSize(width: 1400, height: 900)
        let engine = SquareTileGridEngine.testRegular(sectionCounts: [4000])
        let sourceLevel = 3
        let targetLevel = 2
        let sourceScroll = CGPoint(x: 0, y: 6000)
        let viewportPoint = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let anchorContent = CGPoint(x: viewportPoint.x, y: sourceScroll.y + viewportPoint.y)
        let anchor = try #require(engine.anchorItem(
            nearContentPoint: anchorContent,
            level: sourceLevel,
            width: viewport.width
        ))
        let targetColumn = engine.cursorColumn(viewportX: viewportPoint.x, level: targetLevel, width: viewport.width)
        let targetPhase = engine.columnPhase(
            forItem: anchor.flatIndex,
            targetColumn: targetColumn,
            level: targetLevel,
            width: viewport.width
        )
        let targetScroll = engine.anchoredScrollOffset(
            flatIndex: anchor.flatIndex,
            localFraction: anchor.localFraction,
            viewportPoint: viewportPoint,
            level: targetLevel,
            width: viewport.width,
            columnPhase: targetPhase
        )
        let source = engine.framePlan(level: sourceLevel, viewportSize: viewport, scrollOffset: sourceScroll, overscan: 0)
        let target = engine.framePlan(
            level: targetLevel,
            viewportSize: viewport,
            scrollOffset: CGPoint(x: 0, y: targetScroll.y),
            overscan: 0,
            columnPhase: targetPhase
        )

        let controller = GridTransitionController()
        #expect(controller.beginClick(
            source: source,
            target: target,
            anchorIndex: anchor.flatIndex,
            viewportSize: viewport,
            selection: []
        ))
        #expect(controller.lastFallback == .none)
        #expect(controller.isActive)
        #expect(!controller.currentDraws().isEmpty)
    }

    @Test func sevenNineClickProducesVisibleMotionAcrossHostTicks() throws {
        let viewport = CGSize(width: 1400, height: 900)
        let engine = SquareTileGridEngine.testRegular(sectionCounts: [4000])
        let sourceLevel = 3
        let targetLevel = 2
        let sourceScroll = CGPoint(x: 0, y: 6000)
        let viewportPoint = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let anchorContent = CGPoint(x: viewportPoint.x, y: sourceScroll.y + viewportPoint.y)
        let anchor = try #require(engine.anchorItem(
            nearContentPoint: anchorContent,
            level: sourceLevel,
            width: viewport.width
        ))
        let targetColumn = engine.cursorColumn(viewportX: viewportPoint.x, level: targetLevel, width: viewport.width)
        let targetPhase = engine.columnPhase(
            forItem: anchor.flatIndex,
            targetColumn: targetColumn,
            level: targetLevel,
            width: viewport.width
        )
        let targetScroll = engine.anchoredScrollOffset(
            flatIndex: anchor.flatIndex,
            localFraction: anchor.localFraction,
            viewportPoint: viewportPoint,
            level: targetLevel,
            width: viewport.width,
            columnPhase: targetPhase
        )
        let source = engine.framePlan(level: sourceLevel, viewportSize: viewport, scrollOffset: sourceScroll, overscan: viewport.height)
        let target = engine.framePlan(
            level: targetLevel,
            viewportSize: viewport,
            scrollOffset: CGPoint(x: 0, y: targetScroll.y),
            overscan: viewport.height,
            columnPhase: targetPhase
        )

        let controller = GridTransitionController()
        #expect(controller.beginClick(
            source: source,
            target: target,
            anchorIndex: anchor.flatIndex,
            viewportSize: viewport,
            selection: []
        ))
        let initial = controller.currentDraws()
        #expect(!initial.isEmpty)

        var mid: [GridTransitionDraw] = []
        var sawPartialHandoff = false
        for _ in 0 ..< 25 {
            _ = controller.advanceClick(bySeconds: 1.0 / 60.0)
            if controller.partialComponentCount() > 0 { sawPartialHandoff = true }
            let draws = controller.currentDraws()
            if !draws.isEmpty { mid = draws }
        }
        #expect(!mid.isEmpty)
        let initialRects = Dictionary(uniqueKeysWithValues: initial.map { ($0.index, $0.rect) })
        let movingRects = mid.filter { draw in
            guard let start = initialRects[draw.index] else { return false }
            let delta = abs(start.minX - draw.rect.minX)
                + abs(start.minY - draw.rect.minY)
                + abs(start.width - draw.rect.width)
                + abs(start.height - draw.rect.height)
            return delta > 1
        }
        #expect(!movingRects.isEmpty, "9<->7 click plans must visibly move at least one thumbnail mid-transition")
        #expect(sawPartialHandoff, "9<->7 click plans must have at least one visible handoff frame during the click")
    }

    @Test func relocatingSelectionDoesNotBlockClickPlan() {
        let (src, tgt) = plans()
        let viewport = CGSize(width: 1400, height: 900)
        guard let lat = GridTransitionComponentBuilder.build(source: src, target: tgt, anchorIndex: 0, viewportSize: viewport) else {
            Issue.record("lattice nil"); return
        }
        let relocating = GridTransitionSelectionEligibility.relocatingIdentities(in: lat)
        guard let r = relocating.first else { Issue.record("no relocating identity"); return }
        let c = GridTransitionController()
        #expect(c.beginClick(source: src, target: tgt, anchorIndex: 0, viewportSize: viewport, selection: [r]))
        #expect(c.lastFallback == .none)
        #expect(c.isActive)
    }

    // ── live pinch: host-driven q (no timer), default-on like the click ──

    @Test func pinchBuildsHostDrivenPlanByDefault() {
        let (src, tgt) = plans()
        let viewport = CGSize(width: 1400, height: 900)
        let c = GridTransitionController()
        #expect(c.beginPinch(source: src, target: tgt, anchorIndex: 0, viewportSize: viewport, selection: []))
        #expect(c.isActive)
        #expect(c.activeKind == .pinch)
        #expect(c.q == 0)
        let atZero = c.currentDraws()
        #expect(!atZero.isEmpty)
        #expect(atZero.allSatisfy { $0.localProgress <= 1e-9 })
        #expect(c.partialComponentCount() == 0)
        c.setProgress(0.5); #expect(abs(c.q - 0.5) < 1e-12)
        c.setProgress(1.0); #expect(abs(c.q - 1) < 1e-12)
        #expect(c.partialComponentCount() == 0)          // q=1: fully handed off, nothing dissolving
        #expect(c.currentDraws() != atZero)              // the transition actually changed the frame
        c.setProgress(2.0); #expect(c.q == 1)            // setProgress clamps to [0,1]
        c.setProgress(-1.0); #expect(c.q == 0)
    }

    @Test func pinchProgressIsReversible() {
        let (src, tgt) = plans()
        let viewport = CGSize(width: 1400, height: 900)
        let c = GridTransitionController()
        #expect(c.beginPinch(source: src, target: tgt, anchorIndex: 0, viewportSize: viewport, selection: []))
        c.setProgress(0.37)
        let forward = c.currentDraws()
        c.setProgress(0.8)
        c.setProgress(0.37)                 // scrub back to the same q
        let back = c.currentDraws()
        #expect(forward == back)            // pure function of q ⇒ no hysteresis
    }

    @Test func pinchRelocatingSelectionStillBuildsPlan() {
        let (src, tgt) = plans()
        let viewport = CGSize(width: 1400, height: 900)
        guard let lat = GridTransitionComponentBuilder.build(source: src, target: tgt, anchorIndex: 0, viewportSize: viewport) else {
            Issue.record("lattice nil"); return
        }
        guard let r = GridTransitionSelectionEligibility.relocatingIdentities(in: lat).first else {
            Issue.record("no relocating identity"); return
        }
        let c = GridTransitionController()
        #expect(c.beginPinch(source: src, target: tgt, anchorIndex: 0, viewportSize: viewport, selection: [r]))
        #expect(c.lastFallback == .none)
        #expect(c.isActive)
    }
}
