import Testing
import CoreGraphics
@testable import TimelineFeature

/// Guardrails for the frozen-source coverage math and the experimental ghost-alpha curve. These are
/// the pure pieces the grid-zoom pass depends on; they run headlessly (no Metal, no AppKit window) so
/// "build succeeded" is never the only evidence the logic is right.
@Suite struct GridZoomMathTests {

    // MARK: Frozen transform mirrors the shader

    @Test func frozenTransformMatchesShaderSpec() {
        let anchor = CGPoint(x: 100, y: 50)
        // scale 1 → identity
        #expect(GridZoomMath.frozenTransform(base: CGPoint(x: 30, y: 70), anchor: anchor, scale: 1) == CGPoint(x: 30, y: 70))
        // the anchor is a fixed point of the transform at any scale
        #expect(GridZoomMath.frozenTransform(base: anchor, anchor: anchor, scale: 0.37) == anchor)
        // a point 100pt right of the anchor lands 50pt right at scale 0.5: anchor + (200-100)*0.5 = 150
        let p = GridZoomMath.frozenTransform(base: CGPoint(x: 200, y: 50), anchor: anchor, scale: 0.5)
        #expect(abs(p.x - 150) < 1e-9)
        #expect(abs(p.y - 50) < 1e-9)
    }

    // MARK: Coverage / needed-rect math

    @Test func neededRectScale1IsTheViewport() {
        let vp = CGRect(x: 0, y: 0, width: 800, height: 600)
        let r = GridZoomMath.sourceRectNeededForFrozenScale(viewport: vp, anchor: CGPoint(x: 400, y: 300), scale: 1, margin: .zero)
        #expect(abs(r.minX) < 1e-6 && abs(r.minY) < 1e-6)
        #expect(abs(r.width - 800) < 1e-6 && abs(r.height - 600) < 1e-6)
    }

    @Test func neededRectZoomOutDoublesAroundAnchor() {
        let vp = CGRect(x: 0, y: 0, width: 800, height: 600)
        let r = GridZoomMath.sourceRectNeededForFrozenScale(viewport: vp, anchor: CGPoint(x: 400, y: 300), scale: 0.5, margin: .zero)
        #expect(abs(r.width - 1600) < 1e-6 && abs(r.height - 1200) < 1e-6)
        #expect(abs(r.midX - 400) < 1e-6 && abs(r.midY - 300) < 1e-6)   // stays centred on the anchor
    }

    @Test func neededRectZoomInHalvesAroundAnchor() {
        let vp = CGRect(x: 0, y: 0, width: 800, height: 600)
        let r = GridZoomMath.sourceRectNeededForFrozenScale(viewport: vp, anchor: CGPoint(x: 400, y: 300), scale: 2, margin: .zero)
        #expect(abs(r.width - 400) < 1e-6 && abs(r.height - 300) < 1e-6)
        #expect(abs(r.midX - 400) < 1e-6 && abs(r.midY - 300) < 1e-6)
    }

    @Test func neededRectAnchorOffCentreSkewsExpansion() {
        // anchor at the left edge: zoom-out expands the rect mostly to the right.
        let vp = CGRect(x: 0, y: 0, width: 800, height: 600)
        let r = GridZoomMath.sourceRectNeededForFrozenScale(viewport: vp, anchor: CGPoint(x: 0, y: 300), scale: 0.5, margin: .zero)
        #expect(abs(r.minX) < 1e-6)              // left edge pinned (anchor is a fixed point)
        #expect(abs(r.maxX - 1600) < 1e-6)       // expands right to 2× width
    }

    @Test func coverageFullWhenCapturedContainsNeeded() {
        let captured = CGRect(x: -100, y: -100, width: 1000, height: 800)
        let needed = CGRect(x: 0, y: 0, width: 800, height: 600)
        let c = GridZoomMath.coverage(captured: captured, needed: needed)
        #expect(c.ratio >= 0.999)
        #expect(c.isCovered)
        #expect(!c.hasMissingRegion)
    }

    @Test func coverageReportsMissingBandsOnZoomOut() {
        // needed extends beyond captured on every side (the zoom-out island case).
        let captured = CGRect(x: 0, y: 0, width: 800, height: 600)
        let needed = CGRect(x: -200, y: -150, width: 1200, height: 900)
        let c = GridZoomMath.coverage(captured: captured, needed: needed)
        #expect(c.ratio < 0.6)
        #expect(!c.isCovered)
        #expect(c.hasMissingRegion)
        #expect(!c.missingTop.isNull)     // needed reaches above captured (y < 0)
        #expect(!c.missingBottom.isNull)  // and below (y > 600)
        #expect(!c.missingLeft.isNull)    // and left (x < 0)
        #expect(!c.missingRight.isNull)   // and right (x > 800)
        // the top band must sit above the captured top edge
        #expect(c.missingTop.maxY <= captured.minY + 1e-6)
    }

    @Test func coverageNullCapturedIsFullyMissing() {
        let needed = CGRect(x: 0, y: 0, width: 800, height: 600)
        let c = GridZoomMath.coverage(captured: .null, needed: needed)
        #expect(c.ratio == 0)
        #expect(c.hasMissingRegion)
    }

    // MARK: Ghost alpha (focus band stays source-stable)

    @Test func ghostFocusBandStaysZeroUntilLateProgress() {
        let h: CGFloat = 600, anchorY: CGFloat = 300
        #expect(GridZoomMath.ghostAlpha(progress: 0.50, rowCenterY: 300, anchorY: anchorY, viewportHeight: h, isNewlyExposedEdge: false) == 0)
        #expect(GridZoomMath.ghostAlpha(progress: 0.71, rowCenterY: 300, anchorY: anchorY, viewportHeight: h, isNewlyExposedEdge: false) == 0)
        #expect(GridZoomMath.ghostAlpha(progress: 0.90, rowCenterY: 300, anchorY: anchorY, viewportHeight: h, isNewlyExposedEdge: false) > 0)
        // even fully resolved, the focus-band ghost stays faint (≤0.35)
        #expect(GridZoomMath.ghostAlpha(progress: 1.0, rowCenterY: 300, anchorY: anchorY, viewportHeight: h, isNewlyExposedEdge: false) <= 0.351)
    }

    @Test func ghostFarBandAppearsEarlierThanFocusBand() {
        let h: CGFloat = 600, anchorY: CGFloat = 300
        let far = GridZoomMath.ghostAlpha(progress: 0.5, rowCenterY: 590, anchorY: anchorY, viewportHeight: h, isNewlyExposedEdge: false)
        let focus = GridZoomMath.ghostAlpha(progress: 0.5, rowCenterY: 300, anchorY: anchorY, viewportHeight: h, isNewlyExposedEdge: false)
        #expect(far > focus)
    }

    @Test func ghostEdgeBoostRaisesAlpha() {
        let h: CGFloat = 600
        let withEdge = GridZoomMath.ghostAlpha(progress: 0.4, rowCenterY: 580, anchorY: 300, viewportHeight: h, isNewlyExposedEdge: true)
        let without = GridZoomMath.ghostAlpha(progress: 0.4, rowCenterY: 580, anchorY: 300, viewportHeight: h, isNewlyExposedEdge: false)
        #expect(withEdge >= without)
    }

    @Test func smoothstepAndLerpBasics() {
        #expect(GridZoomMath.smoothstep(0, 1, -1) == 0)
        #expect(GridZoomMath.smoothstep(0, 1, 2) == 1)
        #expect(abs(GridZoomMath.smoothstep(0, 1, 0.5) - 0.5) < 1e-9)
        #expect(abs(GridZoomMath.lerp(10, 20, 0.25) - 12.5) < 1e-9)
    }

    @Test func newlyExposedEdgeFillsEarlyRegardlessOfFocusBand() {
        // A left/right zoom-out margin cell sits at the anchor's Y (inside the focus band) but has no
        // source behind it → it must fill early, unlike a normal focus-band row.
        let h: CGFloat = 600, anchorY: CGFloat = 300
        let edge = GridZoomMath.ghostAlpha(progress: 0.2, rowCenterY: 300, anchorY: anchorY, viewportHeight: h, isNewlyExposedEdge: true)
        let focus = GridZoomMath.ghostAlpha(progress: 0.2, rowCenterY: 300, anchorY: anchorY, viewportHeight: h, isNewlyExposedEdge: false)
        #expect(edge > 0.3)     // edge already partly filled early
        #expect(focus == 0)     // same row, but source-backed → silent
    }

    // MARK: Visual commit plan (weighted-median origin)

    @Test func weightedMedianEmptyIsNil() {
        #expect(GridZoomMath.weightedMedian([]) == nil)
    }

    @Test func weightedMedianUnweightedIsMiddleVote() {
        let votes = [10, 20, 30].map { GridZoomMath.OriginVote(value: CGFloat($0), weight: 1) }
        #expect(GridZoomMath.weightedMedian(votes) == 20)
    }

    @Test func weightedMedianAnchorWeightWins() {
        // anchor (value 0, weight 10) outweighs the two neighborhood votes ⇒ origin stays at the anchor.
        let votes = [
            GridZoomMath.OriginVote(value: 0, weight: 10),
            GridZoomMath.OriginVote(value: 50, weight: 1),
            GridZoomMath.OriginVote(value: 60, weight: 1),
        ]
        #expect(GridZoomMath.weightedMedian(votes) == 0)
    }

    @Test func originVotesRecoverUniformTranslation() {
        // Every visible proxy is shifted by the SAME true origin (targetDocY = screenY + origin) ⇒ all
        // votes agree and the weighted median is exactly that origin. This is the "neighborhood preserved
        // perfectly" case: the chosen origin reproduces every proxy's on-screen position.
        let trueOrigin: CGFloat = 137
        let votes = [(10.0, 1.0), (200.0, 4.0), (380.0, 1.0)].map {
            GridZoomMath.originVote(sourceScreenMidY: $0.0, targetDocMidY: $0.0 + trueOrigin, weight: $0.1)
        }
        #expect(GridZoomMath.weightedMedian(votes) == trueOrigin)
    }

    @Test func anchorWeightingKeepsAnchorErrorBounded() {
        // Anchor wants origin 100; five neighbors want 0. Anchor weight (10) > Σ neighbors (5) ⇒ the
        // anchor's vote is the weighted median, so the committed anchor error stays ~0.
        let anchorVote = GridZoomMath.OriginVote(value: 100, weight: 10)
        let neighbors = Array(repeating: GridZoomMath.OriginVote(value: 0, weight: 1), count: 5)
        #expect(GridZoomMath.weightedMedian([anchorVote] + neighbors) == 100)
    }

    @Test func zoomOutExposesMarginsBeyondContentWidth() {
        // Source content width == viewport width (no horizontal scroll). Zooming out needs source area
        // wider than content on BOTH sides → those margins can't be sourced and require target fill.
        let vp = CGRect(x: 0, y: 0, width: 800, height: 600)
        let needed = GridZoomMath.sourceRectNeededForFrozenScale(viewport: vp, anchor: CGPoint(x: 400, y: 300), scale: 0.5, margin: .zero)
        #expect(needed.minX < 0)        // left margin beyond content → source-width-limited
        #expect(needed.maxX > 800)      // right margin beyond content → source-width-limited
    }

    // MARK: Live target-fill (not static)

    @Test func targetFillScaleBreathesWithApparentSize() {
        let fillSize: CGFloat = 70
        // equal apparent size → scale 1
        #expect(abs(GridZoomMath.targetFillScale(apparentSize: 70, fillSize: fillSize) - 1) < 1e-9)
        // a LARGER apparent size (still mid-zoom-out) → scale > 1, and DIFFERENT from another size:
        // proves the fill is driven by the live pinch, not screen-static.
        let a = GridZoomMath.targetFillScale(apparentSize: 120, fillSize: fillSize)
        let b = GridZoomMath.targetFillScale(apparentSize: 95, fillSize: fillSize)
        #expect(a > 1)
        #expect(a != b)
    }

    @Test func targetFillScaleClampsToAvoidOverZoom() {
        #expect(GridZoomMath.targetFillScale(apparentSize: 10000, fillSize: 44) == 2.5)
        #expect(GridZoomMath.targetFillScale(apparentSize: 1, fillSize: 330) == 0.5)
    }

    // MARK: Square-fill crop

    @Test func squareCropInsetLandscapeCropsSides() {
        let inset = GridZoomMath.squareFillCropInset(imageSize: CGSize(width: 200, height: 100)) // 2:1
        #expect(abs(inset.x - 0.25) < 1e-9)   // keep center 1/2 of width
        #expect(inset.y == 0)
    }

    @Test func squareCropInsetPortraitCropsTopBottom() {
        let inset = GridZoomMath.squareFillCropInset(imageSize: CGSize(width: 100, height: 200)) // 1:2
        #expect(inset.x == 0)
        #expect(abs(inset.y - 0.25) < 1e-9)   // keep center 1/2 of height
    }

    @Test func squareCropInsetSquareNoCrop() {
        let inset = GridZoomMath.squareFillCropInset(imageSize: CGSize(width: 120, height: 120))
        #expect(inset.x == 0 && inset.y == 0)
    }

    // MARK: Dense square-fill level descriptors + shared corner radius

    @Test func denseLevelsAreSquareFillAndNearlyGapless() {
        let levels = JustifiedCollectionLayout.levels
        // the two most zoomed-out levels crop to square and are nearly gapless…
        for i in [levels.count - 2, levels.count - 1] {
            #expect(levels[i].cropMode == .squareFill)
            #expect(levels[i].square)
            #expect(levels[i].gap <= 1)
        }
        // …while the largest-thumbnail levels preserve the whole photo (letterbox), not square-fill.
        #expect(levels[0].cropMode == .aspectFit)
        #expect(levels[0].gap > 1)
    }

    @Test func sharedCornerRadiusIsSmallAndPositive() {
        // The radius is a deliberate design value: the reference capture's rounded corner measures
        // ~20-22px ≈ 11pt on Retina, so the grid + Metal overlay share 11 (see GridVisualConstants).
        // This guards it stays small/positive — not an accidental large or zero radius.
        #expect(GridVisualConstants.thumbnailCornerRadius > 0)
        #expect(GridVisualConstants.thumbnailCornerRadius <= 12)
    }

    // MARK: Full target backdrop alpha mask (no holes; focus stays source-dominant)

    @Test func backdropEdgeMissingCoverageIsOpaque() {
        // A cell with no source behind it (outside the shrunk source block) must be FULLY opaque at any
        // progress — a real target image is always better than a black edge.
        let h: CGFloat = 600
        #expect(GridZoomMath.targetBackdropAlpha(progress: 0.0, cellCenterY: 40, anchorY: 300, viewportHeight: h, isOutsideSourceBlock: true) == 1)
        #expect(GridZoomMath.targetBackdropAlpha(progress: 0.5, cellCenterY: 560, anchorY: 300, viewportHeight: h, isOutsideSourceBlock: true) == 1)
    }

    @Test func backdropFocusBandStaysSourceDominantUntilLate() {
        // Inside the focus band (and source-backed), the backdrop is suppressed until late progress, so
        // the source thumbnail around the pointer stays dominant.
        let h: CGFloat = 600
        #expect(GridZoomMath.targetBackdropAlpha(progress: 0.3, cellCenterY: 300, anchorY: 300, viewportHeight: h, isOutsideSourceBlock: false) == 0)
        #expect(GridZoomMath.targetBackdropAlpha(progress: 0.71, cellCenterY: 300, anchorY: 300, viewportHeight: h, isOutsideSourceBlock: false) == 0)
        #expect(GridZoomMath.targetBackdropAlpha(progress: 0.95, cellCenterY: 300, anchorY: 300, viewportHeight: h, isOutsideSourceBlock: false) > 0)
    }

    @Test func inverseScaledBackdropRectCoversViewportAfterTransform() {
        // The backdrop is built from sourceRectNeededForFrozenScale(viewport, anchor, backdropScale) and
        // then the shader scales the page by backdropScale around the anchor. Re-applying that scale to
        // the requested rect must still cover the whole viewport — otherwise cells move out after the
        // transform and leave holes (the bug this pass fixes by building from the INVERSE rect).
        let vp = CGRect(x: 0, y: 0, width: 800, height: 600)
        let anchor = CGPoint(x: 250, y: 400)   // off-centre to stress the asymmetry
        for scale in [CGFloat(0.5), 0.8, 1.3, 2.0] {
            let baseRect = GridZoomMath.sourceRectNeededForFrozenScale(viewport: vp, anchor: anchor, scale: scale, margin: .zero)
            let scaled = CGRect(x: anchor.x + (baseRect.minX - anchor.x) * scale,
                                y: anchor.y + (baseRect.minY - anchor.y) * scale,
                                width: baseRect.width * scale, height: baseRect.height * scale)
            #expect(scaled.minX <= vp.minX + 0.001)
            #expect(scaled.minY <= vp.minY + 0.001)
            #expect(scaled.maxX >= vp.maxX - 0.001)
            #expect(scaled.maxY >= vp.maxY - 0.001)
        }
    }

    // MARK: TargetDetentPlan scales + masking

    @Test func detentScalesUseEachLevelSize() {
        // source uses sourceSize, target uses its OWN size — NOT the source scale.
        let s = GridZoomMath.detentScales(apparentSize: 130, sourceLevelSize: 130, targetLevelSize: 95)
        #expect(abs(s.source - 1) < 1e-9)               // apparent == sourceSize → sourceScale 1
        #expect(abs(s.target - 130.0 / 95.0) < 1e-9)    // target enlarged (its own size is smaller)
        let atDetent = GridZoomMath.detentScales(apparentSize: 95, sourceLevelSize: 130, targetLevelSize: 95)
        #expect(abs(atDetent.target - 1) < 1e-9)         // at the detent targetScale → 1 (natural target grid)
        #expect(atDetent.source < 1)                      // source shrunk to target size
    }

    @Test func targetSurfaceCoversViewportAtTargetScale() {
        // Cells requested for the inverse viewport at targetScale, then scaled by targetScale, cover the
        // whole viewport (so the target wall has no holes — independent of the source scale).
        let vp = CGRect(x: 0, y: 0, width: 800, height: 600)
        let anchor = CGPoint(x: 300, y: 250)
        for targetScale in [CGFloat(0.7), 1.0, 1.6] {
            let base = GridZoomMath.sourceRectNeededForFrozenScale(viewport: vp, anchor: anchor, scale: targetScale, margin: .zero)
            let scaled = GridZoomMath.scaledRect(base, anchor: anchor, scale: targetScale)
            #expect(scaled.minX <= 0.001 && scaled.minY <= 0.001)
            #expect(scaled.maxX >= 799.999 && scaled.maxY >= 599.999)
        }
    }

    @Test func maskVisibleFractionBehindExposedAndPartial() {
        let mask = GridZoomMath.SourceOcclusionMask(rowBands: [CGRect(x: 0, y: 0, width: 200, height: 100)])
        #expect(mask.visibleFraction(ofScreenRect: CGRect(x: 50, y: 25, width: 50, height: 50), anchor: .zero, scale: 1) <= 0.02)   // fully behind source
        #expect(mask.visibleFraction(ofScreenRect: CGRect(x: 300, y: 25, width: 50, height: 50), anchor: .zero, scale: 1) >= 0.98)  // fully exposed
        let half = mask.visibleFraction(ofScreenRect: CGRect(x: 175, y: 25, width: 50, height: 50), anchor: .zero, scale: 1)
        #expect(half > 0.3 && half < 0.7)   // half overlapping a big target cell → partial (rect-overlap, not center-point)
    }

    @Test func commitOriginReusesLivePlanWhenLevelMatches() {
        // Identity: when the release snaps to the SAME level the live plan was frozen at, the commit
        // origin IS the plan origin (the exact content the gesture previewed) — not a re-derivation.
        let planOrigin = CGPoint(x: 0, y: 1234.5)
        let reused = GridZoomMath.commitOrigin(livePlanTargetLevel: 3, livePlanOrigin: planOrigin, finalLevel: 3)
        #expect(reused == planOrigin)
    }

    @Test func commitOriginNilWhenNoMatchingPlan() {
        // Different snap level → caller must derive from target-projected geometry (helper returns nil).
        #expect(GridZoomMath.commitOrigin(livePlanTargetLevel: 3, livePlanOrigin: CGPoint(x: 0, y: 10), finalLevel: 4) == nil)
        // No live plan at all (tiny gesture / same-crop path) → nil.
        #expect(GridZoomMath.commitOrigin(livePlanTargetLevel: nil, livePlanOrigin: nil, finalLevel: 2) == nil)
        #expect(GridZoomMath.commitOrigin(livePlanTargetLevel: 2, livePlanOrigin: nil, finalLevel: 2) == nil)
    }

    // MARK: Focus anchor + deterministic detent preview (pass #9)

    /// The displayed-image-local anchor point lands at the viewport point across crop-mode changes.
    @Test func imageLocalAnchorOriginPreservedAcrossLevels() {
        let imageSize = CGSize(width: 1200, height: 1600)   // portrait → letterbox on aspectFit
        let local = CGPoint(x: 0.35, y: 0.60)
        let viewportPoint = CGPoint(x: 410, y: 300)
        func check(targetCell: CGRect, crop: GridCropMode) {
            let origin = GridZoomMath.anchoredImageOrigin(targetCellFrame: targetCell, imageSize: imageSize,
                                                          cropMode: crop, imageLocalUnitPoint: local, viewportPoint: viewportPoint)
            // The image-local point, mapped through the displayed-image frame and offset by origin, must
            // land back at viewportPoint.
            let imageFrame = GridZoomMath.displayedImageFrame(cellFrame: targetCell, imageSize: imageSize, cropMode: crop)
            let landedX = imageFrame.minX + local.x * imageFrame.width - origin.x
            let landedY = imageFrame.minY + local.y * imageFrame.height - origin.y
            #expect(abs(landedX - viewportPoint.x) < 0.01)
            #expect(abs(landedY - viewportPoint.y) < 0.01)
        }
        // aspectFit → aspectFit (different-sized square cells), aspectFit → squareFill, squareFill → aspectFit
        check(targetCell: CGRect(x: 100, y: 2000, width: 130, height: 130), crop: .aspectFit)
        check(targetCell: CGRect(x: 60, y: 900, width: 70, height: 70), crop: .squareFill)
        check(targetCell: CGRect(x: 220, y: 4000, width: 330, height: 330), crop: .aspectFit)
    }

    /// squareFill displays the photo filling the whole cell; aspectFit letterboxes inside it.
    @Test func displayedImageFrameCropVsFit() {
        let cell = CGRect(x: 0, y: 0, width: 100, height: 100)
        let portrait = CGSize(width: 600, height: 1200)
        #expect(GridZoomMath.displayedImageFrame(cellFrame: cell, imageSize: portrait, cropMode: .squareFill) == cell)
        let fit = GridZoomMath.displayedImageFrame(cellFrame: cell, imageSize: portrait, cropMode: .aspectFit)
        #expect(fit.width < cell.width - 1)          // portrait letterboxes left/right
        #expect(abs(fit.height - cell.height) < 0.01)
        #expect(abs(fit.midX - cell.midX) < 0.01)    // centered
        // Missing image size → falls back to the cell frame.
        #expect(GridZoomMath.displayedImageFrame(cellFrame: cell, imageSize: .zero, cropMode: .aspectFit) == cell)
    }

    /// The live target backdrop may never decide the resting level — the snap does. resolveFinalLevel
    /// takes no plan argument, so it is structurally impossible to override.
    @Test func noLivePlanOverrideOfSnap() {
        // snap returns source for a tiny rock → final is source even though a (stale) plan sat at level 4.
        let snapTiny = GridZoomMath.snapLevel(sourceLevel: 2, livePosition: 2.1, velocity: 0, levelCount: 6)
        #expect(snapTiny == 2)
        #expect(GridZoomMath.resolveFinalLevel(cancelled: false, sourceLevel: 2, snapLevel: snapTiny) == 2)
        #expect(GridZoomMath.commitOrigin(livePlanTargetLevel: 4, livePlanOrigin: CGPoint(x: 0, y: 99), finalLevel: 2) == nil)
        // snap to level 3 while the live plan was at level 4 → final is 3 and the plan is not reused.
        #expect(GridZoomMath.resolveFinalLevel(cancelled: false, sourceLevel: 2, snapLevel: 3) == 3)
        #expect(GridZoomMath.commitOrigin(livePlanTargetLevel: 4, livePlanOrigin: CGPoint(x: 0, y: 99), finalLevel: 3) == nil)
        // Cancelled → source regardless of snap.
        #expect(GridZoomMath.resolveFinalLevel(cancelled: true, sourceLevel: 2, snapLevel: 5) == 2)
    }

    /// EVERY level change needs a preview; only a same-level release settles source-only. cropMode
    /// equality (e.g. 1→2, both aspectFit) does NOT exempt it.
    @Test func everyLevelChangeRequiresPreview() {
        for s in 0..<6 {
            for f in 0..<6 {
                #expect(GridZoomMath.requiresTargetPreview(sourceLevel: s, finalLevel: f) == (s != f))
            }
        }
        // 1→2 is same-crop (both aspectFit) but still a topology change → preview required.
        #expect(GridZoomMath.requiresTargetPreview(sourceLevel: 1, finalLevel: 2))
    }

    /// Preview & commit use the same origin, so a viewport cell's on-screen rect is identical in the
    /// preview overlay and the committed grid (their document frames and origin match).
    @Test func previewCommitOriginIdentity() {
        let planLevel = 3
        let planOrigin = CGPoint(x: 0, y: 1880)
        // Commit reuses the live plan's exact origin when the snap lands on the plan's level.
        let commitOrigin = GridZoomMath.commitOrigin(livePlanTargetLevel: planLevel, livePlanOrigin: planOrigin, finalLevel: planLevel)
        #expect(commitOrigin == planOrigin)
        // Therefore any cell's screen rect (docFrame - origin) is the same for preview and commit.
        let docFrame = CGRect(x: 90, y: 1950, width: 95, height: 95)
        let previewScreen = docFrame.offsetBy(dx: -planOrigin.x, dy: -planOrigin.y)
        let commitScreen = docFrame.offsetBy(dx: -(commitOrigin?.x ?? .nan), dy: -(commitOrigin?.y ?? .nan))
        #expect(previewScreen == commitScreen)
    }

    /// Focus-band preview cells dissolve in LATER than far-band cells (focus replaced last).
    @Test func focusBandPreviewAlphaIsDelayed() {
        let vh: CGFloat = 1000
        let anchorY: CGFloat = 500
        let focusCellY: CGFloat = 520                 // within 0.18·vh = 180 of anchor
        let farCellY: CGFloat = 500 + 300             // outside the focus band
        // Mid settle: the far band is already dissolving while the focus band is still ~0.
        let midFocus = GridZoomMath.previewCellAlpha(settleProgress: 0.7, cellCenterY: focusCellY, anchorY: anchorY, viewportHeight: vh)
        let midFar = GridZoomMath.previewCellAlpha(settleProgress: 0.7, cellCenterY: farCellY, anchorY: anchorY, viewportHeight: vh)
        #expect(midFar > midFocus)
        #expect(midFocus < 0.05)                      // focus stays source-dominant until late
        // Both reach full by the end.
        #expect(GridZoomMath.previewCellAlpha(settleProgress: 1.0, cellCenterY: focusCellY, anchorY: anchorY, viewportHeight: vh) > 0.99)
        #expect(GridZoomMath.previewCellAlpha(settleProgress: 1.0, cellCenterY: farCellY, anchorY: anchorY, viewportHeight: vh) > 0.94)
        // Neither dissolves from the first frame.
        #expect(GridZoomMath.previewCellAlpha(settleProgress: 0.3, cellCenterY: farCellY, anchorY: anchorY, viewportHeight: vh) < 0.02)
    }

    // MARK: One global zoom world / focus anchor (pass #10)

    /// The topmost photo under the pointer: a source node occludes a target node at the same point.
    @Test func topNodeAtAnchorSourceOccludesTarget() {
        let p = CGPoint(x: 50, y: 50)
        let src = [(id: 1, rect: CGRect(x: 0, y: 0, width: 100, height: 100))]
        let tgt = [(id: 2, rect: CGRect(x: 0, y: 0, width: 100, height: 100))]
        #expect(GridZoomMath.topNodeAtAnchor(sourceRects: src, targetRects: tgt, at: p) == 1)   // source wins
        #expect(GridZoomMath.topNodeAtAnchor(sourceRects: [], targetRects: tgt, at: p) == 2)     // only target
        #expect(GridZoomMath.topNodeAtAnchor(sourceRects: src, targetRects: tgt, at: CGPoint(x: 500, y: 500)) == nil)
    }

    /// The protected focus row is exactly the photos sharing the pointer's row.
    @Test func focusRowGroupsPointerRow() {
        let cells: [(id: Int, frame: CGRect)] = [
            (1, CGRect(x: 0, y: 0, width: 100, height: 100)),
            (2, CGRect(x: 110, y: 0, width: 100, height: 100)),
            (3, CGRect(x: 220, y: 0, width: 100, height: 100)),
            (4, CGRect(x: 0, y: 140, width: 100, height: 100)),
            (5, CGRect(x: 110, y: 140, width: 100, height: 100)),
        ]
        let row = Set(GridZoomMath.focusRowIDs(cells: cells, anchorFrame: cells[0].frame, gapPad: 6))
        #expect(row == Set([1, 2, 3]))   // only the anchor's row
    }

    /// The screen-space focus band catches ANY photo reflowing into the pointer band (not just the
    /// source-level focus-row uids) — half-height 0.18·viewportHeight around the anchor Y.
    @Test func focusBandIsScreenSpace() {
        let vh: CGFloat = 1000, anchorY: CGFloat = 500
        #expect(GridZoomMath.inFocusBand(screenY: 520, anchorY: anchorY, viewportHeight: vh))     // within 180
        #expect(GridZoomMath.inFocusBand(screenY: 660, anchorY: anchorY, viewportHeight: vh))     // 160 < 180
        #expect(!GridZoomMath.inFocusBand(screenY: 700, anchorY: anchorY, viewportHeight: vh))    // 200 > 180
        #expect(!GridZoomMath.inFocusBand(screenY: 300, anchorY: anchorY, viewportHeight: vh))    // far above
    }

    // MARK: Per-cell global compositor (pass #11)

    /// The live gesture progress runs 0→1 from the source thumbnail size to the target size.
    @Test func liveProgressTowardDetentZeroToOne() {
        #expect(GridZoomMath.liveProgressTowardDetent(apparentSize: 130, sourceLevelSize: 130, targetLevelSize: 44) == 0)
        #expect(abs(GridZoomMath.liveProgressTowardDetent(apparentSize: 44, sourceLevelSize: 130, targetLevelSize: 44) - 1) < 1e-9)
        let mid = GridZoomMath.liveProgressTowardDetent(apparentSize: 87, sourceLevelSize: 130, targetLevelSize: 44)
        #expect(mid > 0.4 && mid < 0.6)
    }

    /// Inside the focus band NO target photo shows — target alpha is 0 for any progress/distance/edge.
    @Test func focusBandSuppressesAllTargetNodes() {
        for i in 0...4 {
            let p = CGFloat(i) / 4
            #expect(GridZoomMath.targetNodeAlpha(progress: p, distanceFromFocus: 0, viewportHeight: 1000, inFocusBand: true, isEdgeOrTargetOnly: false) == 0)
            #expect(GridZoomMath.targetNodeAlpha(progress: p, distanceFromFocus: 0, viewportHeight: 1000, inFocusBand: true, isEdgeOrTargetOnly: true) == 0)
        }
    }

    /// The focus row source never dissolves (anchor stays under the pointer).
    @Test func focusRowSourceStaysOpaque() {
        for i in 0...4 {
            #expect(GridZoomMath.sourceNodeAlpha(progress: CGFloat(i) / 4, distanceFromFocus: 0, viewportHeight: 1000, inFocusBand: true) == 1)
        }
    }

    /// Rows far from the focus crossfade earlier than rows near it.
    @Test func farRowsCrossfadeBeforeFocusRow() {
        let vh: CGFloat = 1000
        let near = GridZoomMath.replacementAlpha(progress: 0.5, distanceFromFocus: 60, viewportHeight: vh, isEdgeOrTargetOnly: false)
        let far = GridZoomMath.replacementAlpha(progress: 0.5, distanceFromFocus: 500, viewportHeight: vh, isEdgeOrTargetOnly: false)
        #expect(far > near)
    }

    /// THE anti-boxy invariant: a source photo OUTSIDE the focus does NOT stay fully opaque — it fades
    /// per cell as progress grows. If this ever stayed ≈1, the rectangular source patch would be back.
    @Test func sourceOutsideFocusDoesNotRemainFullyOpaque() {
        let lo = GridZoomMath.sourceNodeAlpha(progress: 0.3, distanceFromFocus: 400, viewportHeight: 1000, inFocusBand: false)
        let hi = GridZoomMath.sourceNodeAlpha(progress: 0.9, distanceFromFocus: 400, viewportHeight: 1000, inFocusBand: false)
        #expect(hi < lo)            // monotonically dissolves with progress
        #expect(hi < 0.5)           // clearly faded by high progress — not an opaque rectangle
    }

    /// Edge / target-only cells fade in EARLY so a zoom-out fills the viewport before the bulk crossfades.
    @Test func edgeTargetOnlyCellsFadeInEarly() {
        let vh: CGFloat = 1000
        let edge = GridZoomMath.targetNodeAlpha(progress: 0.2, distanceFromFocus: 300, viewportHeight: vh, inFocusBand: false, isEdgeOrTargetOnly: true)
        let normal = GridZoomMath.targetNodeAlpha(progress: 0.2, distanceFromFocus: 300, viewportHeight: vh, inFocusBand: false, isEdgeOrTargetOnly: false)
        #expect(edge > normal)
        #expect(edge > 0)
    }

    /// Outside the focus band, source and target alphas are a true crossfade (sum to 1).
    @Test func sourceAndTargetAlphasComplementOutsideFocus() {
        let vh: CGFloat = 1000, d: CGFloat = 300, p: CGFloat = 0.85
        let s = GridZoomMath.sourceNodeAlpha(progress: p, distanceFromFocus: d, viewportHeight: vh, inFocusBand: false)
        let t = GridZoomMath.targetNodeAlpha(progress: p, distanceFromFocus: d, viewportHeight: vh, inFocusBand: false, isEdgeOrTargetOnly: false)
        #expect(abs((s + t) - 1) < 1e-9)
    }

    /// The live target detent equals the commit target (origin identity carried from pass #8/#9).
    @Test func targetDetentSnapshotMatchesCommitSnapshot() {
        let planOrigin = CGPoint(x: 0, y: 2400)
        #expect(GridZoomMath.commitOrigin(livePlanTargetLevel: 4, livePlanOrigin: planOrigin, finalLevel: 4) == planOrigin)
        #expect(GridZoomMath.commitOrigin(livePlanTargetLevel: 4, livePlanOrigin: planOrigin, finalLevel: 5) == nil)
    }

    // MARK: Discrete snap model (release continues anchored zoom to a resting level)

    @Test func snapTinyReturnsSource() {
        #expect(GridZoomMath.snapLevel(sourceLevel: 2, livePosition: 2.1, velocity: 0, levelCount: 6) == 2)
        #expect(GridZoomMath.snapLevel(sourceLevel: 2, livePosition: 1.9, velocity: 0, levelCount: 6) == 2)
    }
    @Test func snapModerateOutGoesToSourcePlusOne() {
        #expect(GridZoomMath.snapLevel(sourceLevel: 2, livePosition: 2.6, velocity: 0, levelCount: 6) == 3)
        #expect(GridZoomMath.snapLevel(sourceLevel: 2, livePosition: 2.9, velocity: 0, levelCount: 6) == 3)
    }
    @Test func snapModerateInGoesToSourceMinusOne() {
        #expect(GridZoomMath.snapLevel(sourceLevel: 3, livePosition: 2.5, velocity: 0, levelCount: 6) == 2)
    }
    @Test func snapVelocityCanPushOneLevel() {
        // small position move but a fast flick outward → commit one level
        #expect(GridZoomMath.snapLevel(sourceLevel: 2, livePosition: 2.3, velocity: 1.5, levelCount: 6) == 3)
    }
    @Test func snapNormalGestureCrossesOneLevel() {
        #expect(GridZoomMath.snapLevel(sourceLevel: 2, livePosition: 2.95, velocity: 0.4, levelCount: 6) == 3)
    }
    @Test func snapHugeGestureCanCrossMultiple() {
        #expect(GridZoomMath.snapLevel(sourceLevel: 2, livePosition: 4.6, velocity: 0, levelCount: 6) == 5)   // 3 steps
        #expect(GridZoomMath.snapLevel(sourceLevel: 2, livePosition: 3.6, velocity: 0, levelCount: 6) == 4)   // 2 steps
    }
    @Test func snapClampsToValidRange() {
        #expect(GridZoomMath.snapLevel(sourceLevel: 5, livePosition: 7.0, velocity: 0, levelCount: 6) == 5)
        #expect(GridZoomMath.snapLevel(sourceLevel: 0, livePosition: -2.0, velocity: 0, levelCount: 6) == 0)
    }

    // MARK: Source occlusion mask (row bands, not one big rectangle)

    @Test func sourceRowBandsGroupIntoRows() {
        let row0 = (0..<3).map { CGRect(x: CGFloat($0) * 110, y: 0, width: 100, height: 100) }
        let row1 = (0..<3).map { CGRect(x: CGFloat($0) * 110, y: 120, width: 100, height: 100) }
        let bands = GridZoomMath.sourceRowBands(cellFrames: row0 + row1, gapPad: 10)
        #expect(bands.count == 2)
        #expect(bands[0].minX == 0 && abs(bands[0].maxX - 320) < 0.001)   // first cell minX → last cell maxX
    }
    @Test func targetBackdropDoesNotShowInsideSourceRowBand() {
        let mask = GridZoomMath.SourceOcclusionMask(rowBands: [CGRect(x: 0, y: 0, width: 300, height: 100)])
        #expect(mask.covers(CGPoint(x: 150, y: 50), anchor: .zero, scale: 1))   // inside the row → occluded
    }
    @Test func targetBackdropCanShowOutsideRowBandLeftRight() {
        let mask = GridZoomMath.SourceOcclusionMask(rowBands: [CGRect(x: 100, y: 0, width: 100, height: 100)])
        #expect(!mask.covers(CGPoint(x: 50, y: 50), anchor: .zero, scale: 1))    // left of a short row → allowed
        #expect(!mask.covers(CGPoint(x: 250, y: 50), anchor: .zero, scale: 1))   // right of a short row → allowed
    }
    @Test func singleRectPlateWouldBlockTooMuch() {
        // Two short rows offset diagonally: a single bounding rect would cover the empty corner; the row
        // bands do NOT, so the backdrop can fill it (this is the "black box" the single rect caused).
        let bands = GridZoomMath.sourceRowBands(cellFrames: [CGRect(x: 0, y: 0, width: 100, height: 100),
                                                             CGRect(x: 200, y: 120, width: 100, height: 100)], gapPad: 5)
        let mask = GridZoomMath.SourceOcclusionMask(rowBands: bands)
        let corner = CGPoint(x: 250, y: 50)
        #expect(mask.boundingRect.contains(corner))                     // a single rect WOULD block this
        #expect(!mask.covers(corner, anchor: .zero, scale: 1))          // row bands do NOT → backdrop allowed
    }

    @Test func backdropFarBandFadesInWithProgress() {
        // A source-backed far-band cell fades its backdrop in as zoom progresses (monotonic).
        let h: CGFloat = 600
        let early = GridZoomMath.targetBackdropAlpha(progress: 0.3, cellCenterY: 560, anchorY: 300, viewportHeight: h, isOutsideSourceBlock: false)
        let mid = GridZoomMath.targetBackdropAlpha(progress: 0.6, cellCenterY: 560, anchorY: 300, viewportHeight: h, isOutsideSourceBlock: false)
        let late = GridZoomMath.targetBackdropAlpha(progress: 0.9, cellCenterY: 560, anchorY: 300, viewportHeight: h, isOutsideSourceBlock: false)
        #expect(mid >= early)
        #expect(late >= mid)
        #expect(late > 0)
    }

    // MARK: Source plate regression guardrails

    @Test func sourcePlateCoversInternalGaps() {
        let plate = CGRect(x: 0, y: 0, width: 220, height: 100)
        let thumbnails = [
            CGRect(x: 0, y: 0, width: 100, height: 100),
            CGRect(x: 120, y: 0, width: 100, height: 100),
        ]
        let gapPoint = CGPoint(x: 110, y: 50)

        #expect(!thumbnails.contains { $0.contains(gapPoint) })
        #expect(plate.contains(gapPoint))
        #expect(!GridZoomMath.targetBackdropVisibleAt(gapPoint, sourcePlateRect: plate, anchor: CGPoint(x: 110, y: 50), sourceScale: 1))
    }

    @Test func targetBackdropOnlyOutsideSourcePlate() {
        let plate = CGRect(x: 0, y: 0, width: 800, height: 600)
        let anchor = CGPoint(x: 400, y: 300)
        let scale: CGFloat = 0.8
        let inside = CGPoint(x: 400, y: 300)
        let outside = CGPoint(x: 20, y: 20)

        #expect(!GridZoomMath.targetBackdropVisibleAt(inside, sourcePlateRect: plate, anchor: anchor, sourceScale: scale))
        #expect(GridZoomMath.targetBackdropVisibleAt(outside, sourcePlateRect: plate, anchor: anchor, sourceScale: scale))
    }

    @Test func tinyZoomOutDoesNotShowBackdrop() {
        #expect(!GridZoomMath.shouldShowTargetBackdrop(sourceScale: 0.97, uncoveredRatio: 0.03))
        #expect(!GridZoomMath.shouldShowTargetBackdrop(sourceScale: 0.91, uncoveredRatio: 0.04))
    }

    @Test func zoomInDoesNotShowBackdrop() {
        #expect(!GridZoomMath.shouldShowTargetBackdrop(sourceScale: 1.1, uncoveredRatio: 0.4))
    }

    @Test func backdropUIDSetStableDuringSmallOscillation() {
        #expect(!GridZoomMath.shouldReplaceFrozenBackdrop(
            frozenLevel: 3,
            frozenOriginY: 1_000,
            candidateLevel: 3,
            candidateOriginY: 1_018,
            viewportHeight: 700
        ))
        #expect(GridZoomMath.shouldReplaceFrozenBackdrop(
            frozenLevel: 3,
            frozenOriginY: 1_000,
            candidateLevel: 4,
            candidateOriginY: 1_018,
            viewportHeight: 700
        ))
    }
}
