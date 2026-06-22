import Testing
import Foundation
import CoreGraphics
@testable import TimelineFeature

/// THE suite for the first Apple-like visual transition layer: the L0↔L1↔L2↔L3 `focusRowRelayout` crossfade
/// (`GridNormalZoomVisualPlanner`). Pure, headless — every fixture is built from `SquareTileGridEngine`
/// value-type math (anchored source/target `GridFramePlan`s + a `GridZoomTransaction` focus band), exactly as
/// the coordinator assembles them for a discrete +/- step. The non-negotiable: a thumbnail IDENTITY must never
/// fly old-rect→new-rect — every tile sits verbatim on an engine/transaction rect; reflow is a crossfade.
@Suite struct FocusRowRelayoutTransitionTests {
    private let viewport = CGSize(width: 1400, height: 900)
    private let overscan: CGFloat = 220
    private let cursor = CGPoint(x: 700, y: 450)   // mid-viewport
    private let anchor = 1500                        // mid-library global index
    private let total = 4000

    // MARK: - Fixture (mirrors the coordinator's drawNormalTransition assembly)

    private func smoothstep(_ x: CGFloat) -> CGFloat { let t = min(max(x, 0), 1); return t * t * (3 - 2 * t) }

    /// A settled plan anchored so `anchor` lands at `cursor` in the cursor column (cursor-aligned phase) —
    /// exactly what the +/- commit produces, so the source and target plans share one viewport frame.
    private func anchoredPlan(_ e: SquareTileGridEngine, level: Int) -> GridFramePlan {
        let width = viewport.width
        let col = e.cursorColumn(viewportX: cursor.x, level: level, width: width)
        let phase = e.columnPhase(forItem: anchor, targetColumn: col, level: level, width: width)
        let scrollY = e.anchoredScrollOffset(flatIndex: anchor, localFraction: CGPoint(x: 0.5, y: 0.5),
                                             viewportPoint: cursor, level: level, width: width, columnPhase: phase).y
        return e.framePlan(level: level, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: scrollY),
                           overscan: overscan, columnPhase: phase)
    }

    private func input(from: Int, to: Int, progress: CGFloat,
                       mode: TileContentDisplayMode = .aspectFitInsideSquare,
                       kind: GridTransitionKind = .focusRowRelayout) -> GridTransitionVisualInput {
        let e = SquareTileGridEngine(sectionCounts: [total])
        let sourcePlan = anchoredPlan(e, level: from)
        let targetPlan = anchoredPlan(e, level: to)
        let tx = GridZoomTransaction(totalItems: e.totalItems, anchorGlobalIndex: anchor,
                                     anchorViewportPoint: cursor, anchorLocalFraction: CGPoint(x: 0.5, y: 0.5),
                                     levels: e.levels, sourceLevel: from)
        let continuous = CGFloat(from) + (CGFloat(to) - CGFloat(from)) * smoothstep(progress)
        let frame = tx.frame(continuousLevel: continuous, viewportSize: viewport, overscan: overscan)
        return GridTransitionVisualInput(sourcePlan: sourcePlan, targetPlan: targetPlan, transactionFrame: frame,
                                         transitionKind: kind, anchorGlobalIndex: anchor, cursorViewportPoint: cursor,
                                         progress: progress, contentMode: mode)
    }

    // Index → engine-produced viewport rects.
    private func sourceRects(_ i: GridTransitionVisualInput) -> [Int: CGRect] {
        Dictionary(i.sourcePlan.visibleSlots.map { ($0.index, $0.viewportRect) }, uniquingKeysWith: { a, _ in a })
    }
    private func targetRects(_ i: GridTransitionVisualInput) -> [Int: CGRect] {
        Dictionary(i.targetPlan.visibleSlots.map { ($0.index, $0.viewportRect) }, uniquingKeysWith: { a, _ in a })
    }
    private func txRects(_ i: GridTransitionVisualInput) -> [Int: CGRect] {
        Dictionary(i.transactionFrame.visibleSlots.map { ($0.index, $0.rect) }, uniquingKeysWith: { a, _ in a })
    }
    /// The focus band of a plan = the anchor's row (same derivation as the planner).
    private func focusRow(_ plan: GridFramePlan) -> Set<Int> {
        guard let row = plan.visibleSlots.first(where: { $0.index == anchor })?.row else { return [] }
        return Set(plan.visibleSlots.filter { $0.row == row }.map(\.index))
    }
    private func rectsApproxEqual(_ a: CGRect, _ b: CGRect, _ eps: CGFloat = 0.6) -> Bool {
        abs(a.minX - b.minX) < eps && abs(a.minY - b.minY) < eps && abs(a.width - b.width) < eps && abs(a.height - b.height) < eps
    }
    private func tileSitsOn(_ tile: GridTransitionVisualTile, _ rect: CGRect?) -> Bool {
        guard let rect else { return false }
        return rectsApproxEqual(rect, tile.rect)
    }
    /// EVERY tile sits verbatim on one of its engine/transaction rects — the structural no-fly guarantee.
    private func everyTileOnEngineRect(_ plan: GridTransitionVisualPlan, _ i: GridTransitionVisualInput, eps: CGFloat = 0.6) -> Bool {
        let sr = sourceRects(i), tr = targetRects(i), xr = txRects(i)
        for tile in plan.tiles {
            let candidates = [sr[tile.globalIndex], tr[tile.globalIndex], xr[tile.globalIndex]].compactMap { $0 }
            guard candidates.contains(where: { rectsApproxEqual($0, tile.rect, eps) }) else { return false }
        }
        return true
    }

    // MARK: 1 — NormalTransitionDoesNotMoveMatchedGlobalIndexRectTest

    @Test func normalTransitionDoesNotMoveMatchedGlobalIndexRect() throws {
        let i = input(from: 1, to: 2, progress: 0.5)        // 5col → 7col reflow
        let plan = GridNormalZoomVisualPlanner.plan(i)
        let sr = sourceRects(i), tr = targetRects(i)
        let allFocus = focusRow(i.sourcePlan).union(focusRow(i.targetPlan))
        // A non-focus index present in BOTH plans but at a DIFFERENT region (the reflow shifted it).
        var shifted: Int?
        for idx in sr.keys where !allFocus.contains(idx) {
            guard let s = sr[idx], let t = tr[idx] else { continue }
            let inter = s.intersection(t)
            let interArea = inter.isNull ? 0 : inter.width * inter.height
            if interArea < 0.25 * s.width * s.height { shifted = idx; break }
        }
        let idx = try #require(shifted, "expected a shifted non-focus index in a 5→7 reflow")
        let srcRect = try #require(sr[idx]); let tgtRect = try #require(tr[idx])
        let tiles = plan.tiles.filter { $0.globalIndex == idx }
        // It must NOT be one tile lerped between the two rects — it appears as a fade-out at its source rect
        // AND a fade-in at its target rect (two pinned tiles), each on an engine rect.
        #expect(tiles.contains { tile in rectsApproxEqual(tile.rect, srcRect) && (tile.role == .sourceFadeOut || tile.role == .replacementSource) })
        #expect(tiles.contains { tile in rectsApproxEqual(tile.rect, tgtRect) && (tile.role == .targetFadeIn || tile.role == .replacementTarget) })
        #expect(tiles.allSatisfy { tile in rectsApproxEqual(tile.rect, srcRect) || rectsApproxEqual(tile.rect, tgtRect) },
                "matched index \(idx) produced a rect that is neither source nor target (a lerp)")
        #expect(everyTileOnEngineRect(plan, i))
        #expect(!plan.diagnostics.flyingIdentityDetected)
    }

    // MARK: 2 — FocusRowAnchorRemainsStableTest

    @Test func focusRowAnchorRemainsStable() throws {
        for (from, to) in [(0, 1), (1, 2), (2, 3)] {
            let i = input(from: from, to: to, progress: 0.5)
            let plan = GridNormalZoomVisualPlanner.plan(i)
            let anchorTiles = plan.tiles.filter { $0.globalIndex == anchor }
            #expect(anchorTiles.count == 1, "anchor drawn once at L\(from)→L\(to)")
            let a = try #require(anchorTiles.first)
            #expect(a.role == .focusRowStable)
            #expect(a.alpha == 1)
            #expect(abs(a.rect.midX - cursor.x) < 2 && abs(a.rect.midY - cursor.y) < 2, "anchor not under cursor at L\(from)→L\(to)")
            #expect(plan.diagnostics.focusAnchorStable)
        }
    }

    // MARK: 3 — ZoomInDropsOuterFocusNeighborsTest (more cols → fewer cols)

    @Test func zoomInDropsOuterFocusNeighbors() {
        let i = input(from: 2, to: 1, progress: 0.4)        // 7col → 5col: focus row narrows
        let plan = GridNormalZoomVisualPlanner.plan(i)
        let sourceFocus = focusRow(i.sourcePlan), targetFocus = focusRow(i.targetPlan)
        let leaving = sourceFocus.subtracting(targetFocus)
        #expect(!leaving.isEmpty, "zoom-in should drop outer focus neighbours")
        // Anchor stays; every leaving neighbour fades OUT; no focus index is replaced by an unrelated identity.
        #expect(plan.tiles.contains { $0.globalIndex == anchor && $0.role == .focusRowStable })
        for idx in leaving {
            #expect(plan.tiles.contains { $0.globalIndex == idx && $0.role == .sourceFadeOut }, "leaving neighbour \(idx) not fading out")
        }
        let focusCore = sourceFocus.intersection(targetFocus)
        #expect(focusCore.allSatisfy { idx in plan.tiles.contains { $0.globalIndex == idx && $0.role == .focusRowStable } })
        #expect(everyTileOnEngineRect(plan, i))
    }

    // MARK: 4 — ZoomOutAddsOuterFocusNeighborsTest (fewer cols → more cols)

    @Test func zoomOutAddsOuterFocusNeighbors() {
        let i = input(from: 1, to: 2, progress: 0.6)        // 5col → 7col: focus row widens
        let plan = GridNormalZoomVisualPlanner.plan(i)
        let sourceFocus = focusRow(i.sourcePlan), targetFocus = focusRow(i.targetPlan)
        let entering = targetFocus.subtracting(sourceFocus)
        #expect(!entering.isEmpty, "zoom-out should add outer focus neighbours")
        #expect(plan.tiles.contains { $0.globalIndex == anchor && $0.role == .focusRowStable })
        for idx in entering {
            #expect(plan.tiles.contains { $0.globalIndex == idx && ($0.role == .targetFadeIn || $0.role == .replacementTarget) },
                    "entering neighbour \(idx) not fading in")
        }
        #expect(everyTileOnEngineRect(plan, i))
    }

    // MARK: 5 — TargetOnlySlotsFadeInTest

    @Test func targetOnlySlotsFadeIn() {
        let progress: CGFloat = 0.35
        let i = input(from: 1, to: 2, progress: progress)
        let plan = GridNormalZoomVisualPlanner.plan(i)
        let eased = smoothstep(progress)
        // Non-focus newly-exposed slots (focus-band entering neighbours sit on the anchored tx rect — covered
        // by zoomOutAddsOuterFocusNeighbors).
        let allFocus = focusRow(i.sourcePlan).union(focusRow(i.targetPlan))
        let fadeIns = plan.tiles.filter { $0.role == .targetFadeIn && !allFocus.contains($0.globalIndex) }
        #expect(!fadeIns.isEmpty, "a 5→7 reflow must expose new target slots")
        #expect(fadeIns.allSatisfy { abs($0.alpha - eased) < 0.001 }, "targetFadeIn alpha must equal eased(progress)")
        let tr = targetRects(i)
        #expect(fadeIns.allSatisfy { tile in tileSitsOn(tile, tr[tile.globalIndex]) }, "targetFadeIn must sit on its target rect")
    }

    // MARK: 6 — SourceOnlySlotsFadeOutTest

    @Test func sourceOnlySlotsFadeOut() {
        let progress: CGFloat = 0.35
        let i = input(from: 2, to: 1, progress: progress)   // zoom-in: source slots vacate
        let plan = GridNormalZoomVisualPlanner.plan(i)
        let eased = smoothstep(progress)
        // Non-focus vacated slots (focus-band leaving neighbours sit on the anchored tx rect — covered by
        // zoomInDropsOuterFocusNeighbors).
        let allFocus = focusRow(i.sourcePlan).union(focusRow(i.targetPlan))
        let fadeOuts = plan.tiles.filter { $0.role == .sourceFadeOut && !allFocus.contains($0.globalIndex) }
        #expect(!fadeOuts.isEmpty, "a 7→5 reflow must vacate source slots")
        #expect(fadeOuts.allSatisfy { abs($0.alpha - (1 - eased)) < 0.001 }, "sourceFadeOut alpha must equal 1-eased(progress)")
        let sr = sourceRects(i)
        #expect(fadeOuts.allSatisfy { tile in tileSitsOn(tile, sr[tile.globalIndex]) }, "sourceFadeOut must sit on its source rect")
    }

    // MARK: 7 — ReplacementSlotsCrossfadeTest

    @Test func replacementSlotsCrossfade() {
        let progress: CGFloat = 0.5
        let i = input(from: 1, to: 2, progress: progress)
        let plan = GridNormalZoomVisualPlanner.plan(i)
        let eased = smoothstep(progress)
        let repSource = plan.tiles.filter { $0.role == .replacementSource }
        let repTarget = plan.tiles.filter { $0.role == .replacementTarget }
        #expect(!repSource.isEmpty && !repTarget.isEmpty, "a column-count reflow must produce occupant-change regions")
        #expect(repSource.allSatisfy { abs($0.alpha - (1 - eased)) < 0.001 }, "replacementSource fades out")
        #expect(repTarget.allSatisfy { abs($0.alpha - eased) < 0.001 }, "replacementTarget fades in")
        // No rect movement: each replacement tile sits on its own plan's rect.
        let sr = sourceRects(i), tr = targetRects(i)
        #expect(repSource.allSatisfy { tile in tileSitsOn(tile, sr[tile.globalIndex]) })
        #expect(repTarget.allSatisfy { tile in tileSitsOn(tile, tr[tile.globalIndex]) })
    }

    // MARK: 8 — FocusRowReplacementIsDelayedOrSuppressedTest

    @Test func focusRowReplacementIsDelayedOrSuppressed() {
        for (from, to) in [(2, 1), (1, 2)] {
            let i = input(from: from, to: to, progress: 0.5)
            let plan = GridNormalZoomVisualPlanner.plan(i)
            let allFocus = focusRow(i.sourcePlan).union(focusRow(i.targetPlan))
            // No focus identity is ever crossfaded to an unrelated occupant (no replacement role on a focus index).
            for tile in plan.tiles where allFocus.contains(tile.globalIndex) {
                #expect(tile.role != .replacementSource && tile.role != .replacementTarget,
                        "focus index \(tile.globalIndex) was replaced early at L\(from)→L\(to)")
            }
            // The focus band holds only the anchor's contiguous neighbourhood — never an unrelated row.
            let stable = plan.tiles.filter { $0.role == .focusRowStable }.map(\.globalIndex)
            #expect(stable.allSatisfy { abs($0 - anchor) <= 12 }, "focus band picked up unrelated identities")
        }
    }

    // MARK: 9 — NoPhotoFlyingInNormalTransitionTest

    @Test func noPhotoFlyingInNormalTransition() {
        for (from, to) in [(0, 1), (1, 2), (2, 3), (3, 2), (2, 1), (1, 0)] {
            for step in 0 ... 4 {
                let progress = CGFloat(step) / 4
                let i = input(from: from, to: to, progress: progress)
                let plan = GridNormalZoomVisualPlanner.plan(i)
                #expect(everyTileOnEngineRect(plan, i), "a tile left its engine rect at L\(from)→L\(to) p=\(progress)")
                #expect(!plan.diagnostics.flyingIdentityDetected, "flying identity at L\(from)→L\(to) p=\(progress)")
                #expect(plan.diagnostics.maxIdentityMovementPx < 0.6, "tile centre off its engine rect at L\(from)→L\(to)")
                // The anchor is pinned under the cursor at every progress (never translates).
                if let a = plan.tiles.first(where: { $0.globalIndex == anchor && $0.role == .focusRowStable }) {
                    #expect(abs(a.rect.midX - cursor.x) < 2 && abs(a.rect.midY - cursor.y) < 2)
                }
            }
        }
    }

    // MARK: 10 — TransitionKindRoutesOnlyNormalLevelsTest

    @Test func transitionKindRoutesOnlyNormalLevels() {
        let normal = GridNormalZoomVisualPlanner.plan(input(from: 1, to: 2, progress: 0.5, kind: .focusRowRelayout))
        #expect(normal.diagnostics.handled && !normal.tiles.isEmpty, "focusRowRelayout must be handled")
        for kind in [GridTransitionKind.overviewWarp, .denseOverviewZoom] {
            let plan = GridNormalZoomVisualPlanner.plan(input(from: 1, to: 2, progress: 0.5, kind: kind))
            #expect(!plan.diagnostics.handled, "\(kind) must be refused by the normal planner")
            #expect(plan.tiles.isEmpty, "\(kind) must produce NO tiles from the normal planner")
        }
    }

    // MARK: 11 — OverviewTransitionsRemainUnimplementedGuardTest

    @Test func overviewTransitionsRemainUnimplementedGuard() {
        // The spec still classifies the overview steps as overview, not normal.
        let specs = SquareTileGridEngine.appleLevelSpecs
        #expect(specs[3].transitionKindToNext == .overviewWarp)
        #expect(specs[4].transitionKindToNext == .denseOverviewZoom)
        // The coordinator arms the normal crossfade ONLY for focusRowRelayout (so L3→L4 / L4→L5 never use it).
        let coord = src("MetalGridCoordinator.swift")
        #expect(coord.contains("transitionKindToNext == .focusRowRelayout"), "arm must gate on focusRowRelayout")
        #expect(!coord.contains(".overviewWarp") && !coord.contains(".denseOverviewZoom"),
                "the normal-transition coordinator path must not reference the overview kinds")
        // The planner itself refuses the overview kinds (functional, re-checked here at the boundary).
        for kind in [GridTransitionKind.overviewWarp, .denseOverviewZoom] {
            #expect(GridNormalZoomVisualPlanner.plan(input(from: 3, to: 4, progress: 0.5, kind: kind)).tiles.isEmpty)
        }
    }

    // MARK: 12 — VisualPlanConsumesEngineGeometryOnlyTest

    @Test func visualPlanConsumesEngineGeometryOnly() {
        let planner = src("GridNormalZoomVisualPlan.swift")
        #expect(!planner.isEmpty, "planner source not found")
        #expect(!planner.contains("import AppKit") && !planner.contains("import MetalKit"), "planner must be AppKit-free")
        // It must not compute its own grid geometry — no engine geometry calls, no slot-size/column/gap math.
        for forbidden in ["nominalSlotSide", "resolvedMetrics", "resolvedForLevel", ".framePlan(",
                          "columnPhase:", "beginZoomTransaction", "slotSide =", "pitch ="] {
            #expect(!planner.contains(forbidden), "planner must not derive geometry (\(forbidden))")
        }
        // Functional proof: with random progress, every tile rect is one the engine/transaction already produced.
        for p in stride(from: CGFloat(0), through: 1, by: 0.2) {
            let i = input(from: 2, to: 3, progress: p)
            #expect(everyTileOnEngineRect(GridNormalZoomVisualPlanner.plan(i), i))
        }
    }

    // MARK: 13 — SyntheticNumberedGridTransitionRegressionTest

    @Test func syntheticNumberedGridTransitionRegression() throws {
        let i = input(from: 1, to: 2, progress: 0.5)
        let plan = GridNormalZoomVisualPlanner.plan(i)
        // The number under the cursor (the anchor) stays itself, stable, centred.
        let a = try #require(plan.tiles.first { $0.globalIndex == anchor })
        #expect(a.role == .focusRowStable && a.alpha == 1)
        #expect(abs(a.rect.midX - cursor.x) < 2 && abs(a.rect.midY - cursor.y) < 2)
        // No number flies; side numbers fade in (zoom-out) — there is real fade-in content.
        #expect(everyTileOnEngineRect(plan, i))
        #expect(plan.tiles.contains { $0.role == .targetFadeIn })
        // The synthetic colour is keyed to identity, so a given number keeps its colour as it fades.
        #expect(SquareGridDebugMode.color(forIndex: anchor) == SquareGridDebugMode.color(forIndex: anchor))
        #expect(SquareGridDebugMode.color(forIndex: anchor) != SquareGridDebugMode.color(forIndex: anchor + 1))
    }

    // MARK: 14 — ContentModeDoesNotChangeTransitionGeometryTest

    @Test func contentModeDoesNotChangeTransitionGeometry() {
        for (from, to) in [(0, 1), (1, 2), (2, 3)] {
            for p in [CGFloat(0), 0.5, 1] {
                let aspect = GridNormalZoomVisualPlanner.plan(input(from: from, to: to, progress: p, mode: .aspectFitInsideSquare))
                let square = GridNormalZoomVisualPlanner.plan(input(from: from, to: to, progress: p, mode: .squareFillCrop))
                #expect(aspect.tiles == square.tiles,
                        "content mode changed transition tiles (rect/alpha/role/zIndex) at L\(from)→L\(to) p=\(p)")
            }
        }
    }

    // MARK: 15 — RendererUsesTileContentFitterDuringTransitionTest

    @Test func rendererUsesTileContentFitterDuringTransition() {
        let coord = src("MetalGridCoordinator.swift")
        guard let r = coord.range(of: "func renderTransitionTiles") else { Issue.record("renderTransitionTiles missing"); return }
        let body = String(coord[r.lowerBound ..< (coord.index(r.lowerBound, offsetBy: 2200, limitedBy: coord.endIndex) ?? coord.endIndex)])
        #expect(body.contains("TileContentFitter.fit"), "transition render must fit content via TileContentFitter")
        #expect(body.contains("alpha: a"), "transition render must carry per-tile alpha into the quad")
        #expect(body.contains("displayMode: displayMode"), "transition render must honour the aspect/square mode for content fit")
    }

    // MARK: source scan
    private func sourceDir() -> URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent("Packages/ProtonPhotosKit/Sources/TimelineFeature")
    }
    private func src(_ name: String) -> String {
        (try? String(contentsOf: sourceDir().appendingPathComponent(name), encoding: .utf8)) ?? ""
    }
}
