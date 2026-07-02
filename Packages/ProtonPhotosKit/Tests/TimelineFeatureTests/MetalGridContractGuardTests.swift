import Testing
import Foundation
import CoreGraphics
import GridCore
import TimelineCore
@testable import TimelineFeature

/// THE canonical guard suite for the frozen MetalGrid engine contract - see `docs/metalgrid-engine-contract.md`.
/// These consolidate boundaries otherwise scattered across other suites so a future transition-effects branch
/// cannot quietly reintroduce an old geometry path or mix responsibilities. Structural/functional assertions,
/// not comment matching.
@Suite struct MetalGridContractGuardTests {
    private let eps: CGFloat = 0.5
    private func engine(_ count: Int = 6000) -> SquareTileGridEngine { SquareTileGridEngine.testRegular(sectionCounts: [count]) }

    // MARK: source access (production sources only - never the tests)
    private func packageRoot() -> URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { u.deleteLastPathComponent() }                 // …/Tests/TimelineFeatureTests/X.swift → repo root
        return u.appendingPathComponent("Packages/ProtonPhotosKit")
    }
    private func sourceDirs() -> [URL] {
        ["TimelineFeature", "GridCore", "MetalRenderingCore"].map { packageRoot().appendingPathComponent("Sources/\($0)") }
    }
    private func src(_ name: String) -> String {
        for dir in sourceDirs() {
            if let source = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) { return source }
        }
        return ""
    }
    private func allProductionSource() -> String {
        let files = sourceDirs().flatMap {
            (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? []
        }
        return files.filter { $0.pathExtension == "swift" }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
    }

    // 1
    @Test func productionTimelineIsMetalGridOnlyGuard() {
        let all = allProductionSource()
        #expect(!all.contains("PhotoGridView"), "production must not construct the old PhotoGridView")
        #expect(!all.contains("NSCollectionView"), "production must not use an NSCollectionView grid")
        // The production grid view drives the Metal host.
        #expect(src("MetalProductionGridView.swift").contains("MetalGridScrollHost"), "production grid must use the Metal host")
    }

    // 2
    @Test func noLegacyGridSymbolsGuard() {
        let all = allProductionSource()
        for symbol in ["PhotoGridView", "PhotoGridItem", "JustifiedCollectionLayout", "GridZoomMath",
                       "GridDetentLayout", "GridZoomDetentModel", "sourcePlate", "targetBackdrop", "exposedLeftRect"] {
            #expect(!all.contains(symbol), "forbidden legacy symbol present in production source: \(symbol)")
        }
    }

    // 3 - slot geometry comes from the engine; the renderer does no layout math.
    @Test func engineOwnsSlotGeometryGuard() {
        let e = engine()
        for level in 0 ..< e.levelCount {
            let plan = e.framePlan(level: level, viewportSize: CGSize(width: 1000, height: 800), scrollOffset: CGPoint(x: 0, y: 2000), overscan: 0)
            for s in plan.visibleSlots { #expect(abs(s.viewportRect.width - s.viewportRect.height) < eps, "slot not square at L\(level)") }
        }
        let renderer = src("MetalGridRenderer.swift")
        for layoutTerm in ["nominalColumns", "resolvedMetrics", "framePlan", "slotSide ="] {
            #expect(!renderer.contains(layoutTerm), "renderer must not do layout math (\(layoutTerm))")
        }
        #expect(src("MetalGridCoordinator.swift").contains("engine.framePlan"), "coordinator must source geometry from the engine")
    }

    // 4 - content fitting (aspectFit vs squareFill) differs, but the engine slot/grid geometry is identical.
    @Test func tileContentFitterDoesNotAffectSlotGeometryGuard() {
        let e = engine()
        let before = e.framePlan(level: 1, viewportSize: CGSize(width: 1000, height: 800), scrollOffset: CGPoint(x: 0, y: 3000), overscan: 0)
        let after = e.framePlan(level: 1, viewportSize: CGSize(width: 1000, height: 800), scrollOffset: CGPoint(x: 0, y: 3000), overscan: 0)
        #expect(before.visibleSlots == after.visibleSlots && before.contentSize == after.contentSize && before.columns == after.columns)
        let slot = before.visibleSlots.first!.viewportRect
        let fit = TileContentFitter.fit(slotRect: slot, mediaAspect: 1.7, displayMode: .aspectFitInsideSquare)
        let fill = TileContentFitter.fit(slotRect: slot, mediaAspect: 1.7, displayMode: .squareFillCrop)
        #expect(fit.contentRect != fill.contentRect, "the two modes must fit content differently")
        for r in [fit.contentRect, fill.contentRect] {
            #expect(r.minX >= slot.minX - eps && r.maxX <= slot.maxX + eps && r.minY >= slot.minY - eps && r.maxY <= slot.maxY + eps,
                    "content must stay inside the (unchanged) slot")
        }
    }

    // 5 - FIXED-COLUMNS, WIDTH-FILLING contract: a level FILLS the width across widths (no trailing gutter); the
    // column count is CONSTANT (held at nominalColumns) and the tile SCALES with width (resize = scale, never
    // reflow). The reference width reproduces the level's nominalColumns.
    @Test func fillWidthFixedColumnsGuard() {
        let e = engine()
        for level in 0 ..< e.levelCount {
            let nominal = e.metrics(level: level).nominalColumns
            var sides: [CGFloat] = []
            for w in [CGFloat(800), 1400, 2400] {
                let m = e.resolvedMetrics(level: level, width: w)
                #expect(m.columns == nominal, "L\(level) fixed-columns: count holds at \(nominal)")
                sides.append(m.slotSide)
                #expect(abs((CGFloat(m.columns) * m.pitch - m.gap) - w) < 2.0, "L\(level) must fill width \(w)")
            }
            #expect(sides.first! < sides.last!, "L\(level) tile must SCALE with width (fixed-columns, no reflow)")
            #expect(e.resolvedMetrics(level: level, width: GridSizePolicy.referenceWidth).columns == e.metrics(level: level).nominalColumns,
                    "L\(level) must reproduce nominalColumns at the reference width")
        }
    }

    // 6
    @Test func resizeDoesNotUseZoomTransactionGuard() {
        let resize = src("GridViewportResizeRebase.swift")
        #expect(!resize.contains("beginZoomTransaction") && !resize.contains("GridZoomCommitBridge.") && !resize.contains("GridZoomTransaction("))
        let host = src("MetalGridScrollHost.swift")
        if let range = host.range(of: "private func rebaseForResize") {
            let body = String(host[range.lowerBound ..< (host.index(range.lowerBound, offsetBy: 1100, limitedBy: host.endIndex) ?? host.endIndex)])
            #expect(!body.contains("beginZoomTransaction") && !body.contains("beginCommitBridge"))
        }
    }

    // 7
    @Test func plusMinusUsesViewportCenterGuard() {
        let host = src("MetalGridScrollHost.swift")
        // Viewport CENTRE in LAYOUT space (unobscured width, sidebar inset removed) - see MetalGridScrollHost.
        #expect(host.contains("anchorContentPoint ?? CGPoint(x: max(1, bounds.width - coordinator.leadingObstructionInset) / 2, y: origin.y + vh / 2)"),
                "+/- must anchor at the grid viewport centre (layout space)")
        #expect(!host.contains("lastMouseContentPoint"), "+/- must not use a stale mouse/hover point")
    }

    // 7b - normal AppKit scroll/rubber-band owns the clip origin. The settled draw path may render at the
    // elastic origin, but it must not programmatically clamp/scroll the NSClipView or arm a second rebase.
    @Test func settledDrawDoesNotFightNativeScrollElasticityGuard() throws {
        let coordinator = src("MetalGridCoordinator.swift")
        guard let start = coordinator.range(of: "private func drawEngineFrame"),
              let end = coordinator[start.lowerBound...].range(of: "/// Real thumbnails: resident images") else {
            Issue.record("Could not locate drawEngineFrame body")
            return
        }
        let body = String(coordinator[start.lowerBound..<end.lowerBound])
        #expect(!body.contains("clip.scroll(to:"), "settled draw must not clamp the NSClipView during native rubber-band")
        #expect(!body.contains("beginScrollRebase(fromY:"), "normal draw must not arm a second scroll rebase")
        #expect(body.contains("renderY = rawOrigin.y"), "normal draw should render at AppKit's native clip origin")
    }

    // 8 - trackpad pinch anchors the item under the cursor (resolved in the displayed/phased grid).
    @Test func pinchUsesCursorAnchorGuard() {
        let e = engine()
        let width: CGFloat = 900, scrollY: CGFloat = 5000
        let cursorVP = CGPoint(x: 430, y: 360)
        for phase in [nil, Int(3)] {
            let cursorContent = CGPoint(x: cursorVP.x, y: cursorVP.y + scrollY)
            let displayed = e.anchorItem(nearContentPoint: cursorContent, level: 2, width: width, columnPhase: phase)!.flatIndex
            let tx = e.beginZoomTransaction(cursorContentPoint: cursorContent, viewportPoint: cursorVP, level: 2, width: width, columnPhase: phase)!
            #expect(tx.anchorGlobalIndex == displayed, "pinch must anchor the item under the cursor (phase \(String(describing: phase)))")
        }
        #expect(src("MetalGridCoordinator.swift").contains("beginZoomTransaction(cursorContentPoint:"), "live zoom uses the cursor content point")
    }

    // 9 - media aspect ratio must not change the OUTER slot geometry; no aspect-row layout exists.
    @Test func noAspectOuterLayoutGuard() {
        let all = allProductionSource()
        #expect(!all.contains("AspectRowLayout"), "no aspect-row outer layout")
        // The engine slot geometry has no media-aspect input: same square slot regardless of any content aspect.
        let e = engine()
        let s = e.slotRect(flatIndex: 137, level: 2, width: 1000)!
        #expect(abs(s.width - s.height) < eps, "engine slot is square (independent of media aspect)")
        #expect(e.slotRect(flatIndex: 137, level: 2, width: 1000) == s, "engine slotRect is deterministic / aspect-free")
        // The engine resolve API takes no aspect/content-mode parameter (structural).
        #expect(!src("SquareTileGridEngine.swift").contains("mediaAspect") && !src("SquareTileGridEngine.swift").contains("displayMode"))
    }

    // 10
    @Test func sixLevelSpecGuard() {
        #expect(SquareTileGridEngine.appleLevelSpecs.count == 6)
        #expect(SquareTileGridEngine.testRegularLevels.count == 6)
        #expect(engine().levelCount == 6)
        #expect(SquareTileGridEngine.appleLevelSpecs.map(\.nominalColumns) == [3, 5, 7, 9, 20, 30],
                "accepted six-level nominal columns")
    }

    @Test func coordinatorUsesInjectedViewportProfileWithRegularDefault() {
        let coord = src("MetalGridCoordinator.swift")
        let host = src("MetalGridScrollHost.swift")

        #expect(coord.contains("gridProfile: GridLevelProfile)"))
        #expect(coord.contains("engine = SquareTileGridEngine(sectionCounts: dataSource.sectionCounts, profile: gridProfile)"))
        #expect(coord.contains("level = gridProfile.defaultLevel"))
        #expect(host.contains("gridProfile: GridLevelProfile,"))
        #expect(host.contains("gridProfile: gridProfile"))
        #expect(host.contains("gridProfileResolver: TimelineGridProfileResolver?"))
        #expect(host.contains("applyResolvedGridProfileIfNeeded"))
        #expect(host.contains("coordinator.applyGridProfile"))
        #expect(coord.contains("func applyGridProfile"))
        #expect(coord.contains("rebasedScrollOffsetForProfileChange"))
        #expect(!coord.contains("regularTimelineProfile"))
        #expect(!host.contains("regularTimelineProfile"))
    }
}
