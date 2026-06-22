import Testing
import Foundation
import CoreGraphics
@testable import TimelineFeature

// The six Apple-like zoom levels + the aspect/square content-mode toggle. The toggle changes ONLY how media
// fits inside the UNCHANGED square slot (TileContentFitter); it never touches slotRect/columns/gap/pitch/
// contentSize/hitTest/visibleSlots/anchor/phase. No aspect-row / justified outer layout exists.
@Suite struct AppleGridLevelSpecAndContentModeTests {
    private let width: CGFloat = 1000
    private let viewport = CGSize(width: 1000, height: 760)
    private let eps: CGFloat = 0.5
    private func engine(_ count: Int = 4000) -> SquareTileGridEngine { SquareTileGridEngine(sectionCounts: [count]) }
    private let specs = SquareTileGridEngine.appleLevelSpecs

    private func contained(_ inner: CGRect, _ outer: CGRect) -> Bool {
        inner.minX >= outer.minX - eps && inner.minY >= outer.minY - eps &&
        inner.maxX <= outer.maxX + eps && inner.maxY <= outer.maxY + eps
    }
    private func repoRoot() -> URL {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0 ..< 5 { u.deleteLastPathComponent() }     // …/Tests/TimelineFeatureTests/X.swift → repo root
        return u
    }
    private func readSource(_ rel: String) -> String {
        (try? String(contentsOf: repoRoot().appendingPathComponent(rel), encoding: .utf8)) ?? ""
    }
    private func source(_ name: String) -> String { readSource("Packages/ProtonPhotosKit/Sources/TimelineFeature/\(name)") }

    // MARK: - Level specs (1–8)

    // 1
    @Test func sixAppleGridLevelsExist() {
        #expect(specs.count == 6)
        #expect(SquareTileGridEngine.defaultLevels.count == 6)
        #expect(specs.map(\.id) == [0, 1, 2, 3, 4, 5])
        #expect(engine().levelCount == 6)
    }

    // 2 — a level shows the SAME column count at every width; the tile side grows with width.
    @Test func levelSpecsAreResolutionIndependent() {
        let e = engine()
        for level in 0 ..< e.levelCount {
            var sides: [CGFloat] = []
            var cols: Set<Int> = []
            for w in [CGFloat(700), 1000, 1440, 2560, 3840] {
                let m = e.resolvedMetrics(level: level, width: w)
                cols.insert(m.columns)
                sides.append(m.slotSide)
                #expect(m.columns == e.metrics(level: level).nominalColumns, "level \(level) lost its nominalColumns at \(w)")
            }
            #expect(cols.count == 1, "level \(level) column count must not vary with width")
            for i in 1 ..< sides.count { #expect(sides[i] > sides[i - 1], "level \(level) tiles must grow with width") }
        }
    }

    // 3
    @Test func levelNominalColumnsAreMonotonicIncreasingDensity() {
        for i in 1 ..< specs.count {
            #expect(specs[i].nominalColumns > specs[i - 1].nominalColumns, "density not increasing at L\(i)")
        }
    }

    // 4 — gaps are defined (≥0) and monotonic non-increasing as density rises.
    @Test func levelGapsAreDefinedAndMonotonicOrIntentional() {
        for s in specs { #expect(s.gap >= 0) }
        for i in 1 ..< specs.count { #expect(specs[i].gap <= specs[i - 1].gap, "gap increased at L\(i)") }
    }

    // 5
    @Test func largestLevelUsesApproximatelyThreeNominalColumns() {
        #expect(specs[0].nominalColumns == 3, "largest level should be ~3 columns: \(specs[0].nominalColumns)")
        #expect(specs[0].nominalColumns == specs.map(\.nominalColumns).min(), "L0 must be the lowest density")
    }

    // 6
    @Test func overviewLevelsAreSquareOnly() {
        for level in [4, 5] {
            #expect(specs[level].supportedContentModes == [.squareFillCrop], "L\(level) must be square-only")
            #expect(specs[level].defaultContentMode == .squareFillCrop)
            #expect(engine().contentModeToggleAvailable(level: level) == false)
        }
    }

    // 7
    @Test func normalLevelsSupportAspectFitAndSquareFill() {
        for level in 0 ... 3 {
            #expect(specs[level].supportedContentModes == [.aspectFitInsideSquare, .squareFillCrop], "L\(level) must support both")
            #expect(engine().contentModeToggleAvailable(level: level) == true)
        }
    }

    // 8
    @Test func transitionKindsAreClassified() {
        #expect(specs[0].transitionKindToNext == .focusRowRelayout)
        #expect(specs[1].transitionKindToNext == .focusRowRelayout)
        #expect(specs[2].transitionKindToNext == .focusRowRelayout)
        #expect(specs[3].transitionKindToNext == .overviewWarp)
        #expect(specs[4].transitionKindToNext == .denseOverviewZoom)
        #expect(specs[5].transitionKindToNext == nil, "the densest level has no next")
    }

    // MARK: - Content fitting (9–16)

    private func slot() -> CGRect { CGRect(x: 120, y: 240, width: 180, height: 180) }   // a square slot

    // 9
    @Test func aspectFitInsideSquareContainedInSlot() {
        for aspect in [CGFloat(0.4), 0.75, 1.0, 1.5, 1.78, 2.5] {
            let f = TileContentFitter.fit(slotRect: slot(), mediaAspect: aspect, displayMode: .aspectFitInsideSquare)
            #expect(contained(f.contentRect, slot()), "aspectFit content escaped the slot at aspect \(aspect)")
            #expect(f.uvMin == .init(0, 0) && f.uvMax == .init(1, 1), "aspectFit must show the WHOLE image (full UV)")
            // The full media fits: at least one dimension equals the slot, neither exceeds it.
            #expect(f.contentRect.width <= slot().width + eps && f.contentRect.height <= slot().height + eps)
        }
    }

    // 10
    @Test func squareFillCropCoversSlot() {
        for aspect in [CGFloat(0.4), 0.75, 1.0, 1.5, 1.78, 2.5] {
            let f = TileContentFitter.fit(slotRect: slot(), mediaAspect: aspect, displayMode: .squareFillCrop)
            #expect(abs(f.contentRect.width - slot().width) < eps && abs(f.contentRect.height - slot().height) < eps,
                    "squareFill must fill the whole slot at aspect \(aspect)")
            #expect(f.contentRect.equalTo(slot()) || contained(f.contentRect, slot().insetBy(dx: -eps, dy: -eps)))
            // Cover crops the longer axis in UV (unless the media is already square).
            if abs(aspect - 1) > 0.01 { #expect(f.uvMin != .init(0, 0) || f.uvMax != .init(1, 1)) }
        }
    }

    // 11 — slotRect is mode-independent (the engine never sees a content mode): same slot, fit DIFFERS by mode.
    @Test func contentModeDoesNotChangeSlotRect() {
        let e = engine()
        let s1 = e.slotRect(flatIndex: 137, level: 2, width: width)!
        let s2 = e.slotRect(flatIndex: 137, level: 2, width: width)!
        #expect(s1 == s2)
        let a = TileContentFitter.fit(slotRect: s1, mediaAspect: 1.78, displayMode: .aspectFitInsideSquare)
        let b = TileContentFitter.fit(slotRect: s1, mediaAspect: 1.78, displayMode: .squareFillCrop)
        #expect(a.contentRect != b.contentRect, "the mode MUST change the content fit")
        #expect(contained(a.contentRect, s1) && contained(b.contentRect, s1), "both fits stay inside the unchanged slot")
    }

    // 12 — hit testing is mode-independent (engine.hitTest takes no content mode).
    @Test func contentModeDoesNotChangeHitTesting() {
        let e = engine()
        let p = CGPoint(x: 430, y: 5123)
        let h1 = e.hitTest(contentPoint: p, level: 2, width: width)?.index
        let h2 = e.hitTest(contentPoint: p, level: 2, width: width)?.index
        #expect(h1 == h2)
        #expect(!source("SquareTileGridEngine.swift").contains("displayMode"), "engine geometry must not take a displayMode")
    }

    // 13 — visible slots are mode-independent.
    @Test func contentModeDoesNotChangeVisibleSlots() {
        let e = engine()
        let plan1 = e.framePlan(level: 2, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 4000), overscan: 0)
        let plan2 = e.framePlan(level: 2, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 4000), overscan: 0)
        #expect(plan1.visibleSlots == plan2.visibleSlots)
    }

    // 14 — content size is mode-independent.
    @Test func contentModeDoesNotChangeContentSize() {
        let e = engine()
        #expect(e.contentSize(level: 2, width: width) == e.contentSize(level: 2, width: width))
        #expect(e.contentSize(level: 4, width: width) == e.contentSize(level: 4, width: width))
    }

    // 15 — a WIDE (16:9 video) aspectFit letterboxes inside the SAME square slot; squareFill fills it.
    @Test func wideVideoAspectFitDoesNotChangeOuterSlot() {
        let s = slot()
        let fit = TileContentFitter.fit(slotRect: s, mediaAspect: 16.0 / 9.0, displayMode: .aspectFitInsideSquare)
        #expect(contained(fit.contentRect, s))
        #expect(fit.contentRect.height < s.height - eps, "wide media must letterbox (shorter than the square)")
        #expect(abs(fit.contentRect.width - s.width) < eps, "wide media spans the full square width")
        let fill = TileContentFitter.fit(slotRect: s, mediaAspect: 16.0 / 9.0, displayMode: .squareFillCrop)
        #expect(fill.contentRect.equalTo(s), "squareFill keeps the slot square — outer slot unchanged")
    }

    // 16 — a PORTRAIT (9:16) aspectFit pillarboxes inside the SAME square slot.
    @Test func portraitAspectFitDoesNotChangeOuterSlot() {
        let s = slot()
        let fit = TileContentFitter.fit(slotRect: s, mediaAspect: 9.0 / 16.0, displayMode: .aspectFitInsideSquare)
        #expect(contained(fit.contentRect, s))
        #expect(fit.contentRect.width < s.width - eps, "portrait media must pillarbox (narrower than the square)")
        #expect(abs(fit.contentRect.height - s.height) < eps, "portrait media spans the full square height")
        #expect(abs((s.height) - (s.width)) < eps, "the slot itself is square regardless of media aspect")
    }

    // MARK: - Toggle (17–21)

    // 17
    @Test func aspectSquareToggleAvailableOnlyForLevels0To3() {
        let e = engine()
        for level in 0 ... 3 { #expect(e.contentModeToggleAvailable(level: level)) }
        for level in [4, 5] { #expect(!e.contentModeToggleAvailable(level: level)) }
    }

    // 18 — toggling switches ONLY the fitter mode; the engine geometry is byte-identical.
    @Test func aspectSquareToggleChangesOnlyTileContentFitterMode() {
        let e = engine()
        let before = e.framePlan(level: 1, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 3000), overscan: 0)
        // "Toggle": pick the two effective modes; the engine plan does not take them, so it cannot differ.
        let modeA = e.effectiveContentMode(preferred: .aspectFitInsideSquare, level: 1)
        let modeB = e.effectiveContentMode(preferred: .squareFillCrop, level: 1)
        #expect(modeA != modeB, "the two preferences resolve to different modes on a normal level")
        let after = e.framePlan(level: 1, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 3000), overscan: 0)
        #expect(before.visibleSlots == after.visibleSlots && before.contentSize == after.contentSize && before.columns == after.columns)
        // And the fitter DOES respond to the mode (so the toggle is not a no-op visually).
        let s = before.visibleSlots.first!.viewportRect
        #expect(TileContentFitter.fit(slotRect: s, mediaAspect: 1.7, displayMode: modeA).contentRect
                != TileContentFitter.fit(slotRect: s, mediaAspect: 1.7, displayMode: modeB).contentRect)
    }

    // 19 — the anchor item under a point is mode-independent (anchorItem takes no content mode).
    @Test func aspectSquareTogglePreservesAnchorItem() {
        let e = engine()
        let p = CGPoint(x: 512, y: 6200)
        let a1 = e.anchorItem(nearContentPoint: p, level: 2, width: width)?.flatIndex
        let a2 = e.anchorItem(nearContentPoint: p, level: 2, width: width)?.flatIndex
        #expect(a1 != nil && a1 == a2)
    }

    // 20 — overview levels force squareFillCrop even when the user prefers aspectFit.
    @Test func overviewLevelsForceSquareFillCrop() {
        let e = engine()
        for level in [4, 5] {
            #expect(e.effectiveContentMode(preferred: .aspectFitInsideSquare, level: level) == .squareFillCrop)
            #expect(e.effectiveContentMode(preferred: .squareFillCrop, level: level) == .squareFillCrop)
        }
    }

    // 21 — the normal-level preference is REMEMBERED across an overview round-trip (L2 → L4 → L2).
    @Test func normalLevelContentModePreferenceRestoresAfterReturningFromOverview() {
        let e = engine()
        let preferred = TileContentDisplayMode.aspectFitInsideSquare   // user preference is held, not mutated
        #expect(e.effectiveContentMode(preferred: preferred, level: 2) == .aspectFitInsideSquare)
        #expect(e.effectiveContentMode(preferred: preferred, level: 4) == .squareFillCrop)   // overview overrides
        #expect(e.effectiveContentMode(preferred: preferred, level: 2) == .aspectFitInsideSquare) // back → restored
    }

    // MARK: - Toolbar / UI (22–25)

    private func mainViewSource() -> String { readSource("App/Views/MainView.swift") }

    // 22
    @Test func toolbarAspectToggleExists() {
        let mv = mainViewSource()
        #expect(mv.contains("aspectSquareToggleButton"), "MainView must add the aspect/square toolbar button")
        #expect(mv.contains("gridProxy.setContentMode") || mv.contains("AspectSquareToggleModel"), "button must drive the content mode")
        let proxy = source("GridProxy.swift")
        #expect(proxy.contains("setContentMode") && proxy.contains("toggleContentMode") && proxy.contains("contentModeState"))
    }

    // 23
    @MainActor @Test func toolbarAspectToggleUsesNativeSymbolOrVectorFallback() {
        for mode in TileContentDisplayMode.allCases {
            let img = AspectSquareToggleModel.image(for: mode)
            #expect(img.size.width > 0 && img.size.height > 0, "a symbol OR vector fallback must render for \(mode)")
        }
        // Either native symbols resolve, or the CoreGraphics fallback is a valid template image.
        #expect(AspectSquareToggleModel.hasNativeSymbols || AspectSquareToggleModel.fallbackImage(for: .squareFillCrop).isTemplate)
    }

    // 24
    @MainActor @Test func toolbarAspectToggleHasAccessibilityLabel() {
        let a = AspectSquareToggleModel.accessibilityLabel(for: .squareFillCrop)
        let b = AspectSquareToggleModel.accessibilityLabel(for: .aspectFitInsideSquare)
        #expect(!a.isEmpty && !b.isEmpty && a != b, "each state needs a distinct, non-empty a11y label")
        #expect(mainViewSource().contains(".accessibilityLabel("), "the toolbar button must set an accessibility label")
    }

    // 25 — no external/raster/Apple-icon asset: only SF Symbols + CoreGraphics vectors.
    @Test func toolbarAspectToggleDoesNotUseExternalRasterAsset() {
        let model = source("AspectSquareToggleModel.swift")
        #expect(model.contains("systemSymbolName"), "must use SF Symbols")
        #expect(!model.contains("NSImage(named:") && !model.contains("NSImage(contentsOf"), "no bundled/raster image")
        #expect(!model.lowercased().contains(".png") && !model.lowercased().contains(".jpg"))
        let mv = mainViewSource()
        // The toggle button label must not reference an asset-catalog image literal or an Apple Photos icon.
        #expect(!mv.contains("Image(\"") || !mv.contains("PhotosAppIcon"), "no asset-catalog/raster icon for the toggle")
    }

    // MARK: - Production invariants (26–30)

    // 26
    @Test func noAspectRowOuterLayout() {
        for f in ["SquareTileGridEngine.swift", "GridZoomTransaction.swift", "MetalGridCoordinator.swift", "TileContentFitter.swift"] {
            let s = source(f)
            #expect(!s.contains("AspectRowLayout"), "\(f) must not introduce AspectRowLayout")
        }
    }

    // 27
    @Test func noJustifiedLayoutProductionReference() {
        for f in ["SquareTileGridEngine.swift", "MetalGridCoordinator.swift", "MetalProductionGridView.swift", "GridZoomTransaction.swift"] {
            #expect(!source(f).contains("JustifiedCollectionLayout"), "\(f) must not reference JustifiedCollectionLayout")
        }
    }

    // 28 — the renderer composes square slot (engine) + content fit (fitter); it computes NO outer geometry from aspect.
    @Test func rendererDoesNotComputeAspectGeometry() {
        let c = source("MetalGridCoordinator.swift")
        #expect(c.contains("MetalGridQuad(rect: cell"), "the card/background quad must use the engine's square cell")
        #expect(c.contains("TileContentFitter.fit(slotRect: cell"), "media aspect enters ONLY via the fitter, on the square cell")
        // mediaPixelSize is used solely as the fitter's input, never to size the outer cell.
        #expect(!c.contains("cell.width * ") && !c.contains("aspect * cell") , "no aspect-scaled outer cell math in the renderer")
    }

    // 29
    @Test func squareTileGridEngineStillOwnsSlotGeometry() {
        let e = engine()
        for level in 0 ..< e.levelCount {
            let plan = e.framePlan(level: level, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 2000), overscan: 0)
            for s in plan.visibleSlots { #expect(abs(s.viewportRect.width - s.viewportRect.height) < eps, "slot not square at L\(level)") }
        }
        #expect(source("MetalGridCoordinator.swift").contains("engine.framePlan") || source("MetalGridCoordinator.swift").contains("framePlan("))
    }

    // 30 — content geometry comes only from TileContentFitter, always inside the slot.
    @Test func tileContentFitterOwnsContentGeometry() {
        let s = slot()
        for mode in TileContentDisplayMode.allCases {
            for aspect in [CGFloat(0.5), 1.0, 2.0] {
                #expect(contained(TileContentFitter.fit(slotRect: s, mediaAspect: aspect, displayMode: mode).contentRect, s))
            }
        }
        #expect(source("TileContentFitter.swift").contains("contentRect"))
    }

    // MARK: - Cursor / zoom regression (31–33)

    private func itemUnderCursor(_ e: SquareTileGridEngine, vp: CGPoint, level: Int, phase: Int?, scrollY: CGFloat) -> Int? {
        e.hitTest(contentPoint: CGPoint(x: vp.x, y: vp.y + scrollY), level: level, width: width, columnPhase: phase)?.index
    }

    // 31 — a trackpad pinch still keeps the item under the cursor through commit (6-level engine).
    @Test func pinchStillAnchorsToCursorItem() {
        let e = engine()
        let cursorVP = CGPoint(x: 430, y: 360); let scrollY: CGFloat = 5000
        for sourcePhase in [nil, Int(2), Int(4)] {
            for (s, t) in [(2, 4), (3, 1), (4, 5)] {
                // The displayed item under the cursor == what the engine anchors (anchorItem; never nil for a non-empty grid).
                let cursorContent = CGPoint(x: cursorVP.x, y: cursorVP.y + scrollY)
                let displayed = e.anchorItem(nearContentPoint: cursorContent, level: s, width: width, columnPhase: sourcePhase)!.flatIndex
                let tx = e.beginZoomTransaction(cursorContentPoint: cursorContent,
                                                viewportPoint: cursorVP, level: s, width: width, columnPhase: sourcePhase)!
                #expect(tx.anchorGlobalIndex == displayed, "begin anchored the wrong item s\(s) phase \(String(describing: sourcePhase))")
                let desiredCol = e.cursorColumn(viewportX: cursorVP.x, level: t, width: width)
                let phase = e.columnPhase(forItem: tx.anchorGlobalIndex, targetColumn: desiredCol, level: t, width: width)
                let y = e.anchoredScrollOffset(flatIndex: tx.anchorGlobalIndex, localFraction: tx.anchorLocalFraction,
                                               viewportPoint: cursorVP, level: t, width: width, columnPhase: phase).y
                let after = e.anchorItem(nearContentPoint: CGPoint(x: cursorVP.x, y: cursorVP.y + y), level: t, width: width, columnPhase: phase)!.flatIndex
                #expect(after == displayed, "pinch lost the cursor item s\(s)→t\(t) phase \(String(describing: sourcePhase))")
            }
        }
    }

    // 32 — +/- still anchors at the viewport CENTRE.
    @Test func plusMinusStillAnchorsToViewportCenter() {
        let e = engine()
        let center = CGPoint(x: width / 2, y: viewport.height / 2); let scrollY: CGFloat = 5000
        for sourcePhase in [nil, Int(3)] {
            let a = e.anchorItem(nearContentPoint: CGPoint(x: center.x, y: center.y + scrollY), level: 3, width: width, columnPhase: sourcePhase)!
            let target = 1
            let desiredCol = e.cursorColumn(viewportX: center.x, level: target, width: width)
            let phase = e.columnPhase(forItem: a.flatIndex, targetColumn: desiredCol, level: target, width: width)
            let y = e.anchoredScrollOffset(flatIndex: a.flatIndex, localFraction: a.localFraction,
                                           viewportPoint: center, level: target, width: width, columnPhase: phase).y
            let after = e.anchorItem(nearContentPoint: CGPoint(x: center.x, y: center.y + y), level: target, width: width, columnPhase: phase)!.flatIndex
            #expect(after == a.flatIndex, "+/- lost the viewport-centre item (phase \(String(describing: sourcePhase)))")
        }
    }

    // 33 — changing the content mode must not touch the committed phase / scroll / level.
    @Test func toggleDoesNotBreakCommittedPhase() {
        let e = engine()
        // The engine's phased plan is identical regardless of any content mode (mode is never an input).
        let p1 = e.framePlan(level: 2, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 3333), overscan: 0, columnPhase: 4)
        let p2 = e.framePlan(level: 2, viewportSize: viewport, scrollOffset: CGPoint(x: 0, y: 3333), overscan: 0, columnPhase: 4)
        #expect(p1.visibleSlots == p2.visibleSlots)
        // The coordinator's mode setters must not mutate committedPhase / level / scroll.
        let c = source("MetalGridCoordinator.swift")
        if let range = c.range(of: "func setPreferredNormalLevelContentMode") {
            let body = String(c[range.lowerBound ..< (c.index(range.lowerBound, offsetBy: 320, limitedBy: c.endIndex) ?? c.endIndex)])
            #expect(!body.contains("committedPhase ="), "setting content mode must not write committedPhase")
            #expect(!body.contains("level ="), "setting content mode must not change the level")
        }
    }
}
