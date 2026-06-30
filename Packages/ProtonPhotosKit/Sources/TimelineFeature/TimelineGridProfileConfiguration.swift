import Foundation
import CoreGraphics
import GridCore

enum TimelineGridProfileConfigurationError: Error, CustomStringConvertible {
    case missingBundledResource(String)
    case emptyProfiles
    case duplicateProfileID(String)
    case missingDefaultProfile(String)
    case emptyProfileID(index: Int)
    case emptyLevels(profileID: String)
    case invalidDefaultLevel(profileID: String, defaultLevel: Int, levelCount: Int)
    case invalidLevelID(profileID: String, expected: Int, actual: Int)
    case invalidNominalColumns(profileID: String, level: Int, value: Int)
    case invalidGap(profileID: String, level: Int, value: CGFloat)
    case emptySupportedContentModes(profileID: String, level: Int)
    case invalidContentMode(profileID: String, level: Int, value: String)
    case defaultContentModeNotSupported(profileID: String, level: Int)
    case missingTransition(profileID: String, level: Int)
    case transitionOnLastLevel(profileID: String, level: Int)
    case invalidTransitionKind(profileID: String, level: Int, value: String)
    case emptySelectionProfileID(index: Int)
    case unknownSelectionProfileID(String)
    case invalidSelectionWidth(profileID: String, field: String, value: CGFloat)
    case invalidSelectionRange(profileID: String, min: CGFloat, max: CGFloat)

    var description: String {
        switch self {
        case let .missingBundledResource(name):
            return "missing bundled grid profile resource \(name)"
        case .emptyProfiles:
            return "grid profile configuration contains no profiles"
        case let .duplicateProfileID(id):
            return "duplicate grid profile id \(id)"
        case let .missingDefaultProfile(id):
            return "default grid profile id \(id) does not exist"
        case let .emptyProfileID(index):
            return "grid profile at index \(index) has an empty id"
        case let .emptyLevels(profileID):
            return "grid profile \(profileID) contains no levels"
        case let .invalidDefaultLevel(profileID, defaultLevel, levelCount):
            return "grid profile \(profileID) default level \(defaultLevel) is outside 0..<\(levelCount)"
        case let .invalidLevelID(profileID, expected, actual):
            return "grid profile \(profileID) level id \(actual) must equal its index \(expected)"
        case let .invalidNominalColumns(profileID, level, value):
            return "grid profile \(profileID) level \(level) has invalid nominalColumns \(value)"
        case let .invalidGap(profileID, level, value):
            return "grid profile \(profileID) level \(level) has invalid gap \(value)"
        case let .emptySupportedContentModes(profileID, level):
            return "grid profile \(profileID) level \(level) has no supported content modes"
        case let .invalidContentMode(profileID, level, value):
            return "grid profile \(profileID) level \(level) has invalid content mode \(value)"
        case let .defaultContentModeNotSupported(profileID, level):
            return "grid profile \(profileID) level \(level) default content mode is not supported"
        case let .missingTransition(profileID, level):
            return "grid profile \(profileID) level \(level) is missing transitionKindToNext"
        case let .transitionOnLastLevel(profileID, level):
            return "grid profile \(profileID) last level \(level) must not define transitionKindToNext"
        case let .invalidTransitionKind(profileID, level, value):
            return "grid profile \(profileID) level \(level) has invalid transition kind \(value)"
        case let .emptySelectionProfileID(index):
            return "grid profile selection rule at index \(index) has an empty profile id"
        case let .unknownSelectionProfileID(id):
            return "grid profile selection rule references unknown profile id \(id)"
        case let .invalidSelectionWidth(profileID, field, value):
            return "grid profile selection rule for \(profileID) has invalid \(field) \(value)"
        case let .invalidSelectionRange(profileID, min, max):
            return "grid profile selection rule for \(profileID) has minLayoutWidth \(min) above maxLayoutWidth \(max)"
        }
    }
}

struct TimelineGridProfileConfiguration: Equatable {
    let defaultProfileID: String
    let profiles: [GridLevelProfile]
    let selectionRules: [TimelineGridProfileSelectionRule]

    var defaultProfile: GridLevelProfile {
        guard let profile = profile(id: defaultProfileID) else {
            preconditionFailure("validated grid profile configuration lost its default profile")
        }
        return profile
    }

    func profile(id: String) -> GridLevelProfile? {
        profiles.first { $0.id == id }
    }

    var resolver: TimelineGridProfileResolver {
        TimelineGridProfileResolver(defaultProfileID: defaultProfileID, profiles: profiles, rules: selectionRules)
    }

    static let production: TimelineGridProfileConfiguration = {
        do {
            return try bundled()
        } catch {
            preconditionFailure("Invalid GridProfiles.plist: \(error)")
        }
    }()

    static func bundled(resourceName: String = "GridProfiles", bundle: Bundle = .module) throws -> TimelineGridProfileConfiguration {
        guard let url = bundle.url(forResource: resourceName, withExtension: "plist") else {
            throw TimelineGridProfileConfigurationError.missingBundledResource("\(resourceName).plist")
        }
        return try load(data: Data(contentsOf: url))
    }

    static func load(data: Data) throws -> TimelineGridProfileConfiguration {
        let decoded = try PropertyListDecoder().decode(ConfigurationDTO.self, from: data)
        guard !decoded.profiles.isEmpty else { throw TimelineGridProfileConfigurationError.emptyProfiles }

        var seen: Set<String> = []
        var profiles: [GridLevelProfile] = []
        profiles.reserveCapacity(decoded.profiles.count)

        for (profileIndex, dto) in decoded.profiles.enumerated() {
            let id = dto.id.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw TimelineGridProfileConfigurationError.emptyProfileID(index: profileIndex) }
            guard seen.insert(id).inserted else { throw TimelineGridProfileConfigurationError.duplicateProfileID(id) }
            profiles.append(try buildProfile(id: id, dto: dto))
        }

        let defaultProfileID = decoded.defaultProfileID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard profiles.contains(where: { $0.id == defaultProfileID }) else {
            throw TimelineGridProfileConfigurationError.missingDefaultProfile(defaultProfileID)
        }

        let selectionRules = try buildSelectionRules(
            decoded.selectionRules ?? [],
            validProfileIDs: Set(profiles.map(\.id))
        )
        return TimelineGridProfileConfiguration(
            defaultProfileID: defaultProfileID,
            profiles: profiles,
            selectionRules: selectionRules
        )
    }

    private static func buildProfile(id: String, dto: ProfileDTO) throws -> GridLevelProfile {
        guard !dto.levels.isEmpty else { throw TimelineGridProfileConfigurationError.emptyLevels(profileID: id) }
        guard dto.defaultLevel >= 0, dto.defaultLevel < dto.levels.count else {
            throw TimelineGridProfileConfigurationError.invalidDefaultLevel(
                profileID: id,
                defaultLevel: dto.defaultLevel,
                levelCount: dto.levels.count
            )
        }

        var levels: [GridLevelMetrics] = []
        levels.reserveCapacity(dto.levels.count)
        for (index, level) in dto.levels.enumerated() {
            levels.append(try buildLevel(profileID: id, index: index, level: level, levelCount: dto.levels.count))
        }
        return GridLevelProfile(id: id, levels: levels, defaultLevel: dto.defaultLevel)
    }

    private static func buildLevel(profileID: String, index: Int, level: LevelDTO, levelCount: Int) throws -> GridLevelMetrics {
        guard level.id == index else {
            throw TimelineGridProfileConfigurationError.invalidLevelID(profileID: profileID, expected: index, actual: level.id)
        }
        guard level.nominalColumns >= 1 else {
            throw TimelineGridProfileConfigurationError.invalidNominalColumns(
                profileID: profileID,
                level: index,
                value: level.nominalColumns
            )
        }
        guard level.gap >= 0, level.gap.isFinite else {
            throw TimelineGridProfileConfigurationError.invalidGap(profileID: profileID, level: index, value: level.gap)
        }
        guard !level.supportedContentModes.isEmpty else {
            throw TimelineGridProfileConfigurationError.emptySupportedContentModes(profileID: profileID, level: index)
        }

        let supportedModes = try Set(level.supportedContentModes.map { raw -> TileContentDisplayMode in
            guard let mode = TileContentDisplayMode(rawValue: raw) else {
                throw TimelineGridProfileConfigurationError.invalidContentMode(profileID: profileID, level: index, value: raw)
            }
            return mode
        })

        guard let defaultMode = TileContentDisplayMode(rawValue: level.defaultContentMode) else {
            throw TimelineGridProfileConfigurationError.invalidContentMode(
                profileID: profileID,
                level: index,
                value: level.defaultContentMode
            )
        }
        guard supportedModes.contains(defaultMode) else {
            throw TimelineGridProfileConfigurationError.defaultContentModeNotSupported(profileID: profileID, level: index)
        }

        let transition = try transitionKind(profileID: profileID, index: index, levelCount: levelCount, raw: level.transitionKindToNext)
        return GridLevelMetrics(
            levelID: level.id,
            nominalColumns: level.nominalColumns,
            gap: level.gap,
            monthLabels: level.monthLabels,
            supportedContentModes: supportedModes,
            defaultContentMode: defaultMode,
            transitionKindToNext: transition
        )
    }

    private static func transitionKind(profileID: String, index: Int, levelCount: Int, raw: String?) throws -> GridTransitionKind? {
        if index == levelCount - 1 {
            guard raw == nil else {
                throw TimelineGridProfileConfigurationError.transitionOnLastLevel(profileID: profileID, level: index)
            }
            return nil
        }
        guard let raw else {
            throw TimelineGridProfileConfigurationError.missingTransition(profileID: profileID, level: index)
        }
        guard let kind = GridTransitionKind(rawValue: raw) else {
            throw TimelineGridProfileConfigurationError.invalidTransitionKind(profileID: profileID, level: index, value: raw)
        }
        return kind
    }

    private static func buildSelectionRules(_ dtos: [SelectionRuleDTO],
                                            validProfileIDs: Set<String>) throws -> [TimelineGridProfileSelectionRule] {
        try dtos.enumerated().map { index, dto in
            let id = dto.profileID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else {
                throw TimelineGridProfileConfigurationError.emptySelectionProfileID(index: index)
            }
            guard validProfileIDs.contains(id) else {
                throw TimelineGridProfileConfigurationError.unknownSelectionProfileID(id)
            }
            try validateSelectionWidth(dto.minLayoutWidth, profileID: id, field: "minLayoutWidth")
            try validateSelectionWidth(dto.maxLayoutWidth, profileID: id, field: "maxLayoutWidth")
            if let min = dto.minLayoutWidth, let max = dto.maxLayoutWidth, min > max {
                throw TimelineGridProfileConfigurationError.invalidSelectionRange(profileID: id, min: min, max: max)
            }
            return TimelineGridProfileSelectionRule(
                profileID: id,
                minLayoutWidth: dto.minLayoutWidth,
                maxLayoutWidth: dto.maxLayoutWidth
            )
        }
    }

    private static func validateSelectionWidth(_ value: CGFloat?,
                                               profileID: String,
                                               field: String) throws {
        guard let value else { return }
        guard value >= 0, value.isFinite else {
            throw TimelineGridProfileConfigurationError.invalidSelectionWidth(
                profileID: profileID,
                field: field,
                value: value
            )
        }
    }
}

public enum TimelineGridProfiles {
    public static var productionDefaultProfile: GridLevelProfile {
        TimelineGridProfileConfiguration.production.defaultProfile
    }
}

private struct ConfigurationDTO: Decodable {
    let defaultProfileID: String
    let selectionRules: [SelectionRuleDTO]?
    let profiles: [ProfileDTO]
}

private struct SelectionRuleDTO: Decodable {
    let profileID: String
    let minLayoutWidth: CGFloat?
    let maxLayoutWidth: CGFloat?
}

private struct ProfileDTO: Decodable {
    let id: String
    let defaultLevel: Int
    let levels: [LevelDTO]
}

private struct LevelDTO: Decodable {
    let id: Int
    let nominalColumns: Int
    let gap: CGFloat
    let monthLabels: Bool
    let supportedContentModes: [String]
    let defaultContentMode: String
    let transitionKindToNext: String?
}
