import GridCore
@testable import TimelineFeature

extension GridLevelProfile {
    static var testRegularTimeline: GridLevelProfile {
        TimelineGridProfileConfiguration.production.profile(id: "regularTimeline")!
    }

    static var testCompactTimeline: GridLevelProfile {
        TimelineGridProfileConfiguration.production.profile(id: "compactTimeline")!
    }
}

extension SquareTileGridEngine {
    static var testRegularLevels: [GridLevelMetrics] { GridLevelProfile.testRegularTimeline.levels }

    static func testRegular(sectionCounts: [Int]) -> SquareTileGridEngine {
        SquareTileGridEngine(sectionCounts: sectionCounts, profile: .testRegularTimeline)
    }
}
