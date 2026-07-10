import Foundation

/// Platform-neutral pressure level used by shared background-work policy. Platform adapters map
/// ProcessInfo / OS signals into this value; Core policy stays independent from UIKit/AppKit.
public enum LibraryThermalLevel: Int, Sendable, Comparable, Equatable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: LibraryThermalLevel, rhs: LibraryThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum LibraryWorkloadKind: Sendable, Equatable {
    case visibleMedia
    case userInitiatedBackup
    case backgroundThumbnailCrawl
    case backgroundLocationCrawl
}

public struct LibraryWorkloadSignals: Sendable, Equatable {
    public var thermalLevel: LibraryThermalLevel
    public var isLowPowerMode: Bool
    public var isNetworkConstrained: Bool
    public var isNetworkExpensive: Bool
    public var hasVisibleMediaDemand: Bool
    public var hasActiveUserInitiatedTransfer: Bool

    public init(
        thermalLevel: LibraryThermalLevel = .nominal,
        isLowPowerMode: Bool = false,
        isNetworkConstrained: Bool = false,
        isNetworkExpensive: Bool = false,
        hasVisibleMediaDemand: Bool = false,
        hasActiveUserInitiatedTransfer: Bool = false
    ) {
        self.thermalLevel = thermalLevel
        self.isLowPowerMode = isLowPowerMode
        self.isNetworkConstrained = isNetworkConstrained
        self.isNetworkExpensive = isNetworkExpensive
        self.hasVisibleMediaDemand = hasVisibleMediaDemand
        self.hasActiveUserInitiatedTransfer = hasActiveUserInitiatedTransfer
    }

    public static let unconstrained = LibraryWorkloadSignals()
}

public struct LibraryWorkloadBudget: Sendable, Equatable {
    public var maxConcurrentItems: Int
    public var shouldYield: Bool
    public var allowsNetwork: Bool

    public init(maxConcurrentItems: Int, shouldYield: Bool = false, allowsNetwork: Bool = true) {
        self.maxConcurrentItems = max(0, maxConcurrentItems)
        self.shouldYield = shouldYield
        self.allowsNetwork = allowsNetwork
    }
}

/// Single shared policy for non-visible library work. It does not start, stop, or serialize jobs;
/// it only returns a small budget so feature code remains idempotent and independently resumable.
public struct LibraryWorkloadGovernorPolicy: Sendable, Equatable {
    public init() {}

    public func budget(
        for workload: LibraryWorkloadKind,
        signals: LibraryWorkloadSignals = .unconstrained,
        baseConcurrency: Int = 1
    ) -> LibraryWorkloadBudget {
        let base = max(1, baseConcurrency)

        // Deferrable crawls stop at critical pressure. User-initiated backup remains runnable, but
        // its branch below reduces concurrency in line with Apple's thermal guidance.
        if signals.thermalLevel == .critical && workload != .userInitiatedBackup {
            return workload == .visibleMedia
                ? LibraryWorkloadBudget(maxConcurrentItems: 1)
                : LibraryWorkloadBudget(maxConcurrentItems: 0, shouldYield: true)
        }

        switch workload {
        case .visibleMedia:
            return LibraryWorkloadBudget(maxConcurrentItems: base)

        case .userInitiatedBackup:
            if signals.isLowPowerMode || signals.isNetworkConstrained || signals.isNetworkExpensive {
                return LibraryWorkloadBudget(maxConcurrentItems: 1)
            }
            switch signals.thermalLevel {
            case .nominal, .fair:
                return LibraryWorkloadBudget(maxConcurrentItems: base)
            case .serious:
                return LibraryWorkloadBudget(maxConcurrentItems: min(base, 2))
            case .critical:
                return LibraryWorkloadBudget(maxConcurrentItems: 1)
            }

        case .backgroundThumbnailCrawl:
            if signals.hasVisibleMediaDemand {
                return LibraryWorkloadBudget(maxConcurrentItems: 0, shouldYield: true)
            }
            if signals.hasActiveUserInitiatedTransfer || signals.thermalLevel >= .serious || signals.isLowPowerMode {
                return LibraryWorkloadBudget(maxConcurrentItems: 1)
            }
            return LibraryWorkloadBudget(maxConcurrentItems: base)

        case .backgroundLocationCrawl:
            if signals.hasVisibleMediaDemand || signals.hasActiveUserInitiatedTransfer
                || signals.thermalLevel >= .serious || signals.isLowPowerMode {
                return LibraryWorkloadBudget(maxConcurrentItems: 0, shouldYield: true)
            }
            return LibraryWorkloadBudget(maxConcurrentItems: 1)
        }
    }
}
