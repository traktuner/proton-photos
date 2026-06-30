import Testing
import Foundation
import GridCore
@testable import TimelineFeature

@Suite struct TimelineGridProfileConfigurationTests {
    @Test func bundledGridProfilesLoadRegularAndCompactProfiles() throws {
        let config = try TimelineGridProfileConfiguration.bundled()
        let regular = try #require(config.profile(id: "regularTimeline"))
        let compact = try #require(config.profile(id: "compactTimeline"))

        #expect(config.defaultProfile.id == "regularTimeline")
        #expect(regular.defaultLevel == 3)
        #expect(regular.levels.map(\.nominalColumns) == [3, 5, 7, 9, 20, 30])
        #expect(regular.showsMonthLabels(level: 3) == false)
        #expect(regular.showsMonthLabels(level: 4) == true)

        #expect(compact.defaultLevel == 2)
        #expect(compact.levels.map(\.nominalColumns) == [1, 2, 3, 5, 12, 20])
        #expect(SquareTileGridEngine(sectionCounts: [100], profile: compact).resolvedMetrics(level: 0, width: 390).columns == 1)
    }

    @Test func invalidDefaultLevelIsRejected() throws {
        let data = try plistData([
            "defaultProfileID": "broken",
            "profiles": [[
                "id": "broken",
                "defaultLevel": 3,
                "levels": [level(id: 0, columns: 1, transition: nil)]
            ]]
        ])

        do {
            _ = try TimelineGridProfileConfiguration.load(data: data)
            Issue.record("invalid default level must be rejected")
        } catch let error as TimelineGridProfileConfigurationError {
            #expect(error.description.contains("default level"))
        }
    }

    @Test func missingIntermediateTransitionIsRejected() throws {
        let data = try plistData([
            "defaultProfileID": "broken",
            "profiles": [[
                "id": "broken",
                "defaultLevel": 0,
                "levels": [
                    level(id: 0, columns: 1, transition: nil),
                    level(id: 1, columns: 2, transition: nil)
                ]
            ]]
        ])

        do {
            _ = try TimelineGridProfileConfiguration.load(data: data)
            Issue.record("missing non-final transition must be rejected")
        } catch let error as TimelineGridProfileConfigurationError {
            #expect(error.description.contains("missing transitionKindToNext"))
        }
    }

    private func plistData(_ object: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }

    private func level(id: Int, columns: Int, transition: String?) -> [String: Any] {
        var result: [String: Any] = [
            "id": id,
            "nominalColumns": columns,
            "gap": 0,
            "monthLabels": false,
            "supportedContentModes": ["squareFillCrop"],
            "defaultContentMode": "squareFillCrop"
        ]
        if let transition {
            result["transitionKindToNext"] = transition
        }
        return result
    }
}
