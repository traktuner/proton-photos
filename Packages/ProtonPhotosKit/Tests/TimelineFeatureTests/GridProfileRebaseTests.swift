import Testing
import CoreGraphics
import GridCore
@testable import TimelineFeature

@Suite struct GridProfileRebaseTests {
    private let eps: CGFloat = 0.5

    private func regular(_ count: Int = 6000) -> SquareTileGridEngine {
        SquareTileGridEngine(sectionCounts: [count], profile: .testRegularTimeline)
    }

    private func compact(_ count: Int = 6000) -> SquareTileGridEngine {
        SquareTileGridEngine(sectionCounts: [count], profile: .testCompactTimeline)
    }

    private func anchorAt(_ engine: SquareTileGridEngine,
                          width: CGFloat,
                          height: CGFloat,
                          scrollY: CGFloat,
                          level: Int,
                          fraction: CGFloat = 0.5,
                          phase: Int? = nil) -> Int? {
        engine.anchorItem(
            nearContentPoint: CGPoint(x: width / 2, y: scrollY + height * fraction),
            level: level,
            width: width,
            columnPhase: phase
        )?.flatIndex
    }

    private func rebase(source: SquareTileGridEngine,
                        target: SquareTileGridEngine,
                        oldWidth: CGFloat,
                        newWidth: CGFloat,
                        height: CGFloat = 900,
                        oldScrollY: CGFloat = 6000,
                        sourceLevel: Int,
                        wasBottomPinned: Bool = false,
                        mapping: GridProfileRebaseLevelMapping = .closestVisualMatch) -> GridProfileRebaseResult {
        source.rebasedScrollOffsetForProfileChange(GridProfileRebaseInput(
            targetEngine: target,
            oldViewportFrame: CGRect(x: 0, y: 0, width: oldWidth, height: height),
            newViewportFrame: CGRect(x: 0, y: 0, width: newWidth, height: height),
            oldScrollY: oldScrollY,
            sourceLevel: sourceLevel,
            sourceCommittedPhase: nil,
            wasBottomPinned: wasBottomPinned,
            levelMapping: mapping
        ))
    }

    @Test func regularDefaultMapsToCompactClosestNormalLevelAndPreservesAnchor() throws {
        let source = regular()
        let target = compact()
        let before = try #require(anchorAt(source, width: 1280, height: 900, scrollY: 6000, level: 3))
        let result = rebase(source: source, target: target, oldWidth: 1280, newWidth: 390, sourceLevel: 3)
        let after = try #require(anchorAt(target, width: 390, height: 900, scrollY: result.newScrollY, level: result.targetLevel))

        #expect(result.sourceLevel == 3)
        #expect(result.targetLevel == 2, "regular L3 should visually map to compact L2, not the too-small compact L3")
        #expect(result.anchorGlobalIndex == before)
        #expect(after == before)
        #expect(!result.bottomPinned)
    }

    @Test func compactDefaultMapsBackToRegularDefaultAndPreservesAnchor() throws {
        let source = compact()
        let target = regular()
        let before = try #require(anchorAt(source, width: 390, height: 900, scrollY: 6000, level: 2))
        let result = rebase(source: source, target: target, oldWidth: 390, newWidth: 1280, sourceLevel: 2)
        let after = try #require(anchorAt(target, width: 1280, height: 900, scrollY: result.newScrollY, level: result.targetLevel))

        #expect(result.targetLevel == 3)
        #expect(result.anchorGlobalIndex == before)
        #expect(after == before)
    }

    @Test func visualMappingDoesNotCrossTheOverviewMonthLabelBoundary() {
        let source = regular()
        let target = compact()
        let result = rebase(source: source, target: target, oldWidth: 1280, newWidth: 390, sourceLevel: 4)

        #expect(source.metrics(level: result.sourceLevel).monthLabels)
        #expect(target.metrics(level: result.targetLevel).monthLabels,
                "profile rebase must not map an overview/month-label level back to a normal photo level")
    }

    @Test func preserveLevelIDPolicyIsAvailableForAdapterControlledTransitions() throws {
        let source = regular()
        let target = compact()
        let before = try #require(anchorAt(source, width: 1280, height: 900, scrollY: 6000, level: 3))
        let result = rebase(source: source, target: target, oldWidth: 1280, newWidth: 390,
                            sourceLevel: 3, mapping: .preserveLevelID)

        #expect(result.targetLevel == 3)
        #expect(result.anchorGlobalIndex == before)
        let targetSlot = try #require(target.slotRect(flatIndex: before, level: result.targetLevel, width: 390))
        let localY = try #require(result.anchorLocalFractionY)
        let anchoredViewportY = targetSlot.minY + localY * targetSlot.height - result.newScrollY
        #expect(abs(anchoredViewportY - 450) < eps)
    }

    @Test func bottomPinnedProfileChangeStaysPinnedToTargetBottom() {
        let source = regular()
        let target = compact()
        let result = rebase(source: source, target: target, oldWidth: 1280, newWidth: 390,
                            sourceLevel: 3, wasBottomPinned: true)
        let expected = max(0, target.contentSize(level: result.targetLevel, width: 390).height - 900)

        #expect(result.bottomPinned)
        #expect(result.anchorGlobalIndex == nil)
        #expect(abs(result.newScrollY - expected) < eps)
    }

    @Test func shortLibrariesClampWithoutInventingAStaleScrollOffset() {
        let source = regular(2)
        let target = compact(2)
        let result = rebase(source: source, target: target, oldWidth: 1280, newWidth: 390,
                            oldScrollY: 4000, sourceLevel: 3)

        #expect(result.targetLevel == 2)
        #expect(result.newScrollY == 0)
        #expect(result.clamped)
        #expect(result.targetContentSize.height <= 900)
    }
}
