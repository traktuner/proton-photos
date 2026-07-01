import CoreGraphics
import GridCore

/// The adapter-facing description of the grid surface available to the timeline.
/// It deliberately describes viewport facts, not platform or device families.
package struct TimelineGridViewport: Equatable, Sendable {
    package let layoutWidth: CGFloat
    package let layoutHeight: CGFloat

    package init(layoutWidth: CGFloat, layoutHeight: CGFloat = 0) {
        self.layoutWidth = max(0, layoutWidth)
        self.layoutHeight = max(0, layoutHeight)
    }
}

package struct TimelineGridProfileSelectionRule: Equatable, Sendable {
    package let profileID: String
    package let minLayoutWidth: CGFloat?
    package let maxLayoutWidth: CGFloat?

    package init(profileID: String, minLayoutWidth: CGFloat?, maxLayoutWidth: CGFloat?) {
        self.profileID = profileID
        self.minLayoutWidth = minLayoutWidth
        self.maxLayoutWidth = maxLayoutWidth
    }

    package func matches(_ viewport: TimelineGridViewport) -> Bool {
        if let minLayoutWidth, viewport.layoutWidth < minLayoutWidth { return false }
        if let maxLayoutWidth, viewport.layoutWidth > maxLayoutWidth { return false }
        return true
    }
}

/// Resolves the active production grid profile from viewport facts. Core owns the
/// profile ladders and camera rebase math; this adapter owns the product rule.
package struct TimelineGridProfileResolver: Equatable, Sendable {
    package let defaultProfileID: String
    package let profiles: [GridLevelProfile]
    package let rules: [TimelineGridProfileSelectionRule]

    package init(defaultProfileID: String, profiles: [GridLevelProfile], rules: [TimelineGridProfileSelectionRule]) {
        self.defaultProfileID = defaultProfileID
        self.profiles = profiles
        self.rules = rules
    }

    package var defaultProfile: GridLevelProfile {
        guard let profile = profile(id: defaultProfileID) else {
            preconditionFailure("validated grid profile resolver lost its default profile")
        }
        return profile
    }

    package func profile(id: String) -> GridLevelProfile? {
        profiles.first { $0.id == id }
    }

    package func profile(for viewport: TimelineGridViewport) -> GridLevelProfile {
        for rule in rules where rule.matches(viewport) {
            if let profile = profile(id: rule.profileID) { return profile }
        }
        return defaultProfile
    }
}
