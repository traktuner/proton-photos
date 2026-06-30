import CoreGraphics
import GridCore

/// The adapter-facing description of the grid surface available to the timeline.
/// It deliberately describes viewport facts, not platform or device families.
struct TimelineGridViewport: Equatable, Sendable {
    let layoutWidth: CGFloat
    let layoutHeight: CGFloat

    init(layoutWidth: CGFloat, layoutHeight: CGFloat = 0) {
        self.layoutWidth = max(0, layoutWidth)
        self.layoutHeight = max(0, layoutHeight)
    }
}

struct TimelineGridProfileSelectionRule: Equatable, Sendable {
    let profileID: String
    let minLayoutWidth: CGFloat?
    let maxLayoutWidth: CGFloat?

    func matches(_ viewport: TimelineGridViewport) -> Bool {
        if let minLayoutWidth, viewport.layoutWidth < minLayoutWidth { return false }
        if let maxLayoutWidth, viewport.layoutWidth > maxLayoutWidth { return false }
        return true
    }
}

/// Resolves the active production grid profile from viewport facts. Core owns the
/// profile ladders and camera rebase math; this adapter owns the product rule.
struct TimelineGridProfileResolver: Equatable, Sendable {
    let defaultProfileID: String
    let profiles: [GridLevelProfile]
    let rules: [TimelineGridProfileSelectionRule]

    var defaultProfile: GridLevelProfile {
        guard let profile = profile(id: defaultProfileID) else {
            preconditionFailure("validated grid profile resolver lost its default profile")
        }
        return profile
    }

    func profile(id: String) -> GridLevelProfile? {
        profiles.first { $0.id == id }
    }

    func profile(for viewport: TimelineGridViewport) -> GridLevelProfile {
        for rule in rules where rule.matches(viewport) {
            if let profile = profile(id: rule.profileID) { return profile }
        }
        return defaultProfile
    }
}
