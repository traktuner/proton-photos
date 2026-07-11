import Foundation

/// Stable feature identity shared by capability checks, product access and UI composition.
public struct AppFeatureID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let smartSearch = AppFeatureID(rawValue: "smartSearch")
    public static let peopleRecognition = AppFeatureID(rawValue: "peopleRecognition")
    public static let petRecognition = AppFeatureID(rawValue: "petRecognition")
}

public struct AppCapabilityID: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let neuralEngine = AppCapabilityID(rawValue: "neuralEngine")
    public static let metal3 = AppCapabilityID(rawValue: "metal3")
}

public struct AppProductTier: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let free = AppProductTier(rawValue: "free")
    public static let premium = AppProductTier(rawValue: "premium")
}

public struct AppDeviceCapabilities: Sendable, Equatable {
    public var available: Set<AppCapabilityID>
    public var physicalMemoryBytes: UInt64

    public init(available: Set<AppCapabilityID>, physicalMemoryBytes: UInt64) {
        self.available = available
        self.physicalMemoryBytes = physicalMemoryBytes
    }
}

public struct AppFeatureRequirement: Sendable, Equatable {
    public var requiredCapabilities: Set<AppCapabilityID>
    public var minimumPhysicalMemoryBytes: UInt64
    public var allowedTiers: Set<AppProductTier>

    public init(
        requiredCapabilities: Set<AppCapabilityID> = [],
        minimumPhysicalMemoryBytes: UInt64 = 0,
        allowedTiers: Set<AppProductTier> = [.free, .premium]
    ) {
        self.requiredCapabilities = requiredCapabilities
        self.minimumPhysicalMemoryBytes = minimumPhysicalMemoryBytes
        self.allowedTiers = allowedTiers
    }
}

public enum AppFeatureAvailability: Sendable, Equatable {
    /// Unsupported device/build: omit the feature and its settings entirely.
    case unavailable
    /// Supported but not included in the current product tier: UI may present an upgrade affordance.
    case locked
    case available
}

/// Pure Core evaluator. Platform adapters report capabilities; billing adapters report a tier.
public struct AppFeaturePolicy: Sendable {
    private let requirements: [AppFeatureID: AppFeatureRequirement]

    public init(requirements: [AppFeatureID: AppFeatureRequirement]) {
        self.requirements = requirements
    }

    public func availability(
        of feature: AppFeatureID,
        device: AppDeviceCapabilities,
        tier: AppProductTier
    ) -> AppFeatureAvailability {
        guard let requirement = requirements[feature],
              requirement.requiredCapabilities.isSubset(of: device.available),
              device.physicalMemoryBytes >= requirement.minimumPhysicalMemoryBytes else {
            return .unavailable
        }
        return requirement.allowedTiers.contains(tier) ? .available : .locked
    }

    public static let production = AppFeaturePolicy(requirements: [
        .smartSearch: AppFeatureRequirement(requiredCapabilities: [.neuralEngine]),
        .peopleRecognition: AppFeatureRequirement(
            requiredCapabilities: [.neuralEngine], allowedTiers: [.premium]
        ),
        .petRecognition: AppFeatureRequirement(
            requiredCapabilities: [.neuralEngine], allowedTiers: [.premium]
        ),
    ])
}
