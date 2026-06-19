import Testing
import CoreGraphics
@testable import TimelineFeature

/// Behavior-model tests for the Apple-matched detent zoom (see docs/grid-zoom-apple-model.md). All pure /
/// headless — no Metal, no AppKit — so the *behavior* (detents, snap, transition family, anchor stability,
/// no-flying, settle) is proven, not just "it compiled".
@Suite struct GridZoomDetentTransitionTests {

    let model = GridZoomDetentModel.apple
    let width: CGFloat = 1400

    // MARK: - 1. DetentSnapTests

    @Test func tinyPinchReturnsToSource() {
        // A tiny move from the source with no flick is a no-op.
        #expect(model.snapIndex(position: 2.1, velocity: 0, source: 2) == 2)
        #expect(model.snapIndex(position: 1.85, velocity: 0, source: 2) == 2)
    }

    @Test func nearestDetentOnRelease() {
        #expect(model.snapIndex(position: 2.4, velocity: 0, source: 2) == 2)
        #expect(model.snapIndex(position: 2.6, velocity: 0, source: 2) == 3)
        #expect(model.snapIndex(position: 0.49, velocity: 0, source: 0) == 0)
    }

    @Test func flickBiasesOneDetentInMotionDirection() {
        // Zooming out fast (positive velocity) past the deadzone → momentum carries to the next detent.
        #expect(model.snapIndex(position: 2.3, velocity: 6, source: 2) == 3)
        // Zooming in fast (negative velocity).
        #expect(model.snapIndex(position: 1.7, velocity: -6, source: 2) == 1)
        // A flick never snaps AGAINST the motion direction.
        #expect(model.snapIndex(position: 2.6, velocity: 6, source: 2) >= 3)
    }

    @Test func snapClampsToLadderBounds() {
        #expect(model.snapIndex(position: -3, velocity: -9, source: 0) == 0)
        #expect(model.snapIndex(position: 99, velocity: 9, source: model.count - 1) == model.count - 1)
    }

    @Test func levelPositionMapsPinchDirection() {
        // Positive magnification zooms IN → toward a lower index.
        #expect(model.levelPosition(source: 3, cumulativeMagnification: 0.42) < 3)
        // Negative magnification zooms OUT → toward a higher index.
        #expect(model.levelPosition(source: 3, cumulativeMagnification: -0.42) > 3)
        // Clamped to the ladder.
        #expect(model.levelPosition(source: 0, cumulativeMagnification: 5) == 0)
    }

    // MARK: - 2 & 6 & 7. TransitionFamily / Dense / Near policy

    @Test func adjacentJustifiedLevelsUseFocusPreservingReplacement() {
        // The Apple-verified ladder is justified at EVERY level, so every adjacent pair is a per-slot replace.
        for i in 0 ..< (model.count - 1) {
            let fam = GridZoomTransitionPolicy.family(model.detent(i), model.detent(i + 1), width: width)
            #expect(fam == .focusPreservingReplacement, "pair \(i)↔\(i+1) should be near/per-slot")
        }
    }

    @Test func aspectToSquareBoundaryIsWhoosh() {
        // The default ladder no longer has a square level (Apple stays justified), but the policy must still
        // classify a justified↔square family change as a whoosh wherever a square level IS used. Test directly.
        let justified = GridZoomDetent(id: 0, family: .justifiedAspectRows, size: 242, gap: 16, monthLabels: false)
        let square = GridZoomDetent(id: 1, family: .squareGrid, size: 150, gap: 6, monthLabels: true)
        let fam = GridZoomTransitionPolicy.family(justified, square, width: width)
        #expect(fam == .squareToAspectWhoosh)
    }

    @Test func denseSquareLevelsUseFullGridCrossfade() {
        // Two square levels far apart in column count → global whoosh/crossfade. Policy retained for a
        // possible future dense-square mode; the default ladder no longer exercises it.
        let s0 = GridZoomDetent(id: 0, family: .squareGrid, size: 150, gap: 6, monthLabels: true)
        let s1 = GridZoomDetent(id: 1, family: .squareGrid, size: 88, gap: 3, monthLabels: true)
        let fam = GridZoomTransitionPolicy.family(s0, s1, width: width)
        #expect(fam == .fullGridCrossfade || fam == .squareToAspectWhoosh)
        #expect(fam != .focusPreservingReplacement)
    }

    @Test func familyChoiceIsOrderIndependent() {
        #expect(GridZoomTransitionPolicy.family(model.detent(1), model.detent(2), width: width)
                == GridZoomTransitionPolicy.family(model.detent(2), model.detent(1), width: width))
    }

    // MARK: - 3 & 5. Anchor invariance / Surface alignment

    @Test func anchorContentMapsToSameScreenPointAtEveryProgress() {
        let anchorScreen = CGPoint(x: 600, y: 420)
        // The anchor photo sits at different content positions in the two layouts but the SAME screen point.
        let cSrc = CGPoint(x: 540, y: 1180)
        let cTgt = CGPoint(x: 505, y: 980)
        for step in 0 ... 10 {
            let x = 2 + CGFloat(step) / 10  // 2.0 … 3.0
            let plan = GridZoomTransitionPlanner.plan(
                model: model, levelPosition: x, width: width,
                anchorScreen: anchorScreen, anchorContentSource: cSrc, anchorContentTarget: cTgt
            )
            let s = plan.sourceTransform.screenPoint(plan.sourceTransform.anchorContent)
            let t = plan.targetTransform.screenPoint(plan.targetTransform.anchorContent)
            #expect(approxEqual(s, anchorScreen), "source anchor drifted at x=\(x): \(s)")
            #expect(approxEqual(t, anchorScreen), "target anchor drifted at x=\(x): \(t)")
            // Both surfaces share ONE anchor screen point → one shared world, not a pasted box.
            #expect(plan.sourceTransform.anchorScreen == plan.targetTransform.anchorScreen)
        }
    }

    @Test func transformIsInvertible() {
        let tf = GridZoomSurfaceTransform(anchorScreen: CGPoint(x: 300, y: 200), anchorContent: CGPoint(x: 800, y: 1500), scale: 0.7)
        let p = CGPoint(x: 123, y: 456)
        #expect(approxEqual(tf.contentPoint(tf.screenPoint(p)), p))
    }

    // MARK: - 4. NoFlyingPhotos

    @Test func surfaceOnlyScales_noTileTravelsBetweenSlots() {
        // The source detent's layout is FIXED; only the transform scale changes with progress. So a cell's
        // screen rect is a pure scale of a constant content rect — it can never jump to an unrelated slot.
        let counts = [40, 55, 33]
        let aspects = synthAspects(counts)
        let src = GridDetentLayout(detent: model.detent(2), width: width, sectionCounts: counts, sectionAspects: aspects)
        let probeFlat = 70
        guard let contentRect = src.frame(flatIndex: probeFlat) else { Issue.record("no frame"); return }

        let anchorScreen = CGPoint(x: 600, y: 420)
        var lastScreenMid: CGPoint?
        for step in 0 ... 8 {
            let x = 2 + CGFloat(step) / 8
            let plan = GridZoomTransitionPlanner.plan(
                model: model, levelPosition: x, width: width,
                anchorScreen: anchorScreen, anchorContentSource: contentRect.center, anchorContentTarget: contentRect.center
            )
            // Frame is progress-independent (no reflow).
            #expect(src.frame(flatIndex: probeFlat) == contentRect)
            let screen = plan.sourceTransform.screenRect(contentRect)
            // Screen size is exactly the content size × scale — pure scale, no shape morph.
            #expect(approx(screen.width, contentRect.width * plan.sourceTransform.scale))
            // Position moves CONTINUOUSLY with progress (no teleport between frames).
            if let last = lastScreenMid {
                #expect(distance(last, screen.center) < contentRect.height * 2, "discontinuous jump → flying")
            }
            lastScreenMid = screen.center
        }
    }

    @Test func anchorItemNeverDriftsFromUnderCursor() {
        // Whatever the progress, the anchor content (the photo under the cursor) maps back to the cursor —
        // the item under the cursor cannot become a different item mid-gesture.
        let anchorScreen = CGPoint(x: 500, y: 350)
        let cSrc = CGPoint(x: 480, y: 900), cTgt = CGPoint(x: 470, y: 760)
        for step in 0 ... 6 {
            let x = 1 + CGFloat(step) / 6
            let plan = GridZoomTransitionPlanner.plan(
                model: model, levelPosition: x, width: width,
                anchorScreen: anchorScreen, anchorContentSource: cSrc, anchorContentTarget: cTgt
            )
            #expect(approxEqual(plan.sourceTransform.screenPoint(cSrc), anchorScreen))
            #expect(approxEqual(plan.targetTransform.screenPoint(cTgt), anchorScreen))
        }
    }

    // MARK: - 7. Near transition: focus row protected

    @Test func focusRowHeldWhileFarRowsReplace() {
        let anchorScreen = CGPoint(x: 600, y: 400)
        let plan = GridZoomTransitionPlanner.plan(
            model: model, levelPosition: 1.5, width: width,  // mid justified↔justified
            anchorScreen: anchorScreen, anchorContentSource: CGPoint(x: 600, y: 1000), anchorContentTarget: CGPoint(x: 600, y: 900)
        )
        #expect(plan.family == .focusPreservingReplacement)
        let focusAlpha = plan.targetAlpha(cellScreenMidY: anchorScreen.y)        // at the cursor row
        let farAlpha = plan.targetAlpha(cellScreenMidY: anchorScreen.y + 1200)   // far below
        // At mid-progress the focus row still shows the SOURCE (target alpha ~0) while far rows are replaced.
        #expect(focusAlpha < 0.1, "focus row should be held, got \(focusAlpha)")
        #expect(farAlpha > 0.9, "far row should be replaced, got \(farAlpha)")
        #expect(focusAlpha < farAlpha)
    }

    @Test func fullGridFamilyCrossfadesUniformly() {
        // For a whoosh family the alpha is the SAME everywhere (no focus weighting). The default ladder is
        // all-justified now, so use a synthetic model with a justified→square boundary to exercise the whoosh.
        let synth = GridZoomDetentModel(detents: [
            GridZoomDetent(id: 0, family: .justifiedAspectRows, size: 242, gap: 16, monthLabels: false),
            GridZoomDetent(id: 1, family: .squareGrid, size: 120, gap: 4, monthLabels: true),
        ], defaultIndex: 0)
        let anchorScreen = CGPoint(x: 600, y: 400)
        let plan = GridZoomTransitionPlanner.plan(
            model: synth, levelPosition: 0.5, width: width,  // justified↔square whoosh
            anchorScreen: anchorScreen, anchorContentSource: CGPoint(x: 600, y: 1000), anchorContentTarget: CGPoint(x: 600, y: 900)
        )
        #expect(plan.family == .squareToAspectWhoosh)
        let a1 = plan.targetAlpha(cellScreenMidY: anchorScreen.y)
        let a2 = plan.targetAlpha(cellScreenMidY: anchorScreen.y + 1500)
        #expect(approx(a1, a2), "whoosh must be uniform across the grid")
    }

    // MARK: - 8. ReleaseSettle

    @Test func endpointsAreExact_noTopologyPop() {
        let anchorScreen = CGPoint(x: 600, y: 400)
        func plan(at x: CGFloat) -> GridZoomTransitionPlan {
            GridZoomTransitionPlanner.plan(model: model, levelPosition: x, width: width,
                anchorScreen: anchorScreen, anchorContentSource: CGPoint(x: 600, y: 1000), anchorContentTarget: CGPoint(x: 600, y: 900))
        }
        // Progress 0 → apparent == source size, target fully transparent everywhere.
        let p0 = plan(at: 2.0)
        #expect(approx(p0.apparentSize, model.detent(2).size))
        #expect(approx(p0.targetAlpha(focusWeight: 1), 0))
        #expect(approx(p0.targetAlpha(focusWeight: 0), 0))
        // Progress 1 → apparent == target size, target fully opaque everywhere (source fully hidden).
        let p1 = plan(at: 2.999999)
        #expect(abs(p1.apparentSize - model.detent(3).size) < 0.5)
        #expect(p1.targetAlpha(focusWeight: 1) > 0.99)
        #expect(p1.targetAlpha(focusWeight: 0) > 0.99)
    }

    @Test func apparentSizeIsMonotonicAcrossAPair() {
        let anchorScreen = CGPoint(x: 600, y: 400)
        var prev: CGFloat = .greatestFiniteMagnitude
        for step in 0 ... 10 {
            let x = 2 + CGFloat(step) / 10
            let p = GridZoomTransitionPlanner.plan(model: model, levelPosition: x, width: width,
                anchorScreen: anchorScreen, anchorContentSource: .zero, anchorContentTarget: .zero)
            // detent 2 size (292) > detent 3 size (242): apparent should decrease as we zoom out.
            #expect(p.apparentSize <= prev + 0.001)
            prev = p.apparentSize
        }
    }

    // MARK: - helpers

    func synthAspects(_ counts: [Int]) -> [[CGFloat]] {
        let pool: [CGFloat] = [1.0, 1.5, 0.66, 1.33, 0.75, 1.0]
        return counts.map { n in (0 ..< n).map { pool[$0 % pool.count] } }
    }
}

// MARK: - GridDetentLayout invariants

@Suite struct GridDetentLayoutTests {
    let width: CGFloat = 1400

    @Test func squareDetentMatchesMetalGridLayout() {
        let counts = [50, 23, 77]
        let detent = GridZoomDetent(id: 4, family: .squareGrid, size: 74, gap: 1, monthLabels: true)
        let detentLayout = GridDetentLayout(detent: detent, width: width, sectionCounts: counts, sectionAspects: [])
        let metal = MetalGridLayout(sectionCounts: counts, level: 4, size: 74, gap: 1, cropMode: .squareFill, width: width)
        for flat in stride(from: 0, to: 150, by: 7) {
            #expect(detentLayout.frame(flatIndex: flat) == metal.frame(flatIndex: flat), "square parity broke at \(flat)")
        }
        #expect(approx(detentLayout.contentSize.height, metal.contentSize.height))
    }

    @Test func justifiedFullRowsFillWidth() {
        let counts = [60]
        let aspects: [[CGFloat]] = [(0 ..< 60).map { [1.0, 1.5, 0.7, 1.3][$0 % 4] }]
        let detent = GridZoomDetent(id: 1, family: .justifiedAspectRows, size: 200, gap: 8, monthLabels: false)
        let layout = GridDetentLayout(detent: detent, width: width, sectionCounts: counts, sectionAspects: aspects)
        let cells = layout.visibleCells(in: CGRect(x: 0, y: 0, width: width, height: layout.contentSize.height))
        // Group by row (same y) and assert each FULL row spans the width (within gap tolerance).
        var rows: [CGFloat: [GridDetentCell]] = [:]
        for c in cells { rows[(c.rect.minY * 10).rounded() / 10, default: []].append(c) }
        let sortedRows = rows.values.sorted { ($0.first?.rect.minY ?? 0) < ($1.first?.rect.minY ?? 0) }
        // The last (bottom) row must be full and reach the right edge.
        if let bottom = sortedRows.last, bottom.count > 1 {
            let right = bottom.map { $0.rect.maxX }.max() ?? 0
            #expect(abs(right - width) < 2, "bottom justified row should fill width, got \(right)")
        }
        // Row heights never exceed the detent row height.
        for c in cells { #expect(c.rect.height <= detent.size + 0.5) }
    }

    @Test func justifiedHitTestRoundTrips() {
        let counts = [40]
        let aspects: [[CGFloat]] = [(0 ..< 40).map { [1.0, 1.4, 0.8][$0 % 3] }]
        let detent = GridZoomDetent(id: 2, family: .justifiedAspectRows, size: 186, gap: 6, monthLabels: false)
        let layout = GridDetentLayout(detent: detent, width: width, sectionCounts: counts, sectionAspects: aspects)
        guard let f = layout.frame(flatIndex: 25) else { Issue.record("no frame"); return }
        let hit = layout.hitTest(f.center)
        #expect(hit?.flatIndex == 25)
    }

    @Test func justifiedNewestIsBottomRight() {
        // The last item of the last section sits in the bottom row at the right edge (Apple anchors newest
        // bottom-right; the OLDEST partial row floats to the top).
        let counts = [37]
        let aspects: [[CGFloat]] = [(0 ..< 37).map { [1.0, 1.2, 0.9][$0 % 3] }]
        let detent = GridZoomDetent(id: 1, family: .justifiedAspectRows, size: 220, gap: 8, monthLabels: false)
        let layout = GridDetentLayout(detent: detent, width: width, sectionCounts: counts, sectionAspects: aspects)
        guard let last = layout.frame(flatIndex: 36) else { Issue.record("no frame"); return }
        #expect(abs(last.maxX - width) < 2, "newest should touch the right edge")
        #expect(last.maxY >= layout.contentSize.height - detent.size - 8, "newest should be in the bottom row")
    }
}

// MARK: - tiny float helpers

private func approx(_ a: CGFloat, _ b: CGFloat, _ tol: CGFloat = 1e-6) -> Bool { abs(a - b) <= tol }
private func approxEqual(_ a: CGPoint, _ b: CGPoint, _ tol: CGFloat = 1e-6) -> Bool {
    abs(a.x - b.x) <= tol && abs(a.y - b.y) <= tol
}
private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }
private extension CGRect { var center: CGPoint { CGPoint(x: midX, y: midY) } }
