import Foundation
import PhotosCore

/// Platform-neutral thermal pressure level. Platform adapters map their OS signal
/// (`ProcessInfo.thermalState` on both Apple platforms) into this so the throttle table
/// lives once in core.
public enum BackupThermalLevel: Int, Sendable, Comparable, Equatable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: BackupThermalLevel, rhs: BackupThermalLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The environment signals that throttle backup work. Platform layers fill these from
/// ProcessInfo/NWPathMonitor equivalents; core never reads OS state itself.
public struct BackupThrottleInputs: Sendable, Equatable {
    public var thermalLevel: BackupThermalLevel
    public var isLowPowerMode: Bool
    /// False when there is currently no usable network path. The runner waits without spending an
    /// item's retry budget and resumes from the durable queue as soon as the path returns.
    public var isNetworkAvailable: Bool
    /// Low Data Mode / constrained path - treat like low power.
    public var isNetworkConstrained: Bool
    /// Cellular/hotspot - keep going, but single-file.
    public var isNetworkExpensive: Bool

    public init(
        thermalLevel: BackupThermalLevel = .nominal,
        isLowPowerMode: Bool = false,
        isNetworkAvailable: Bool = true,
        isNetworkConstrained: Bool = false,
        isNetworkExpensive: Bool = false
    ) {
        self.thermalLevel = thermalLevel
        self.isLowPowerMode = isLowPowerMode
        self.isNetworkAvailable = isNetworkAvailable
        self.isNetworkConstrained = isNetworkConstrained
        self.isNetworkExpensive = isNetworkExpensive
    }

    public static let unconstrained = BackupThrottleInputs()
}

/// One shared concurrency table for backup sync: inputs → how many items may be in flight.
/// `0` means "pause until conditions improve" - the runner idles without failing anything.
public struct BackupThrottlePolicy: Sendable, Equatable {
    /// Concurrent items under unconstrained conditions. Backup is network/latency-bound (each item
    /// makes server dedup round-trips), not CPU-bound, so several in flight raises throughput roughly
    /// linearly; the workload governor still clamps this down under thermal pressure, Low Power Mode,
    /// or a constrained network. Shared by every backup flow (photo library, folders, albums) on all
    /// platforms so behaviour stays identical.
    public var baseConcurrency: Int
    public var governor: LibraryWorkloadGovernorPolicy

    public init(baseConcurrency: Int = 6, governor: LibraryWorkloadGovernorPolicy = LibraryWorkloadGovernorPolicy()) {
        self.baseConcurrency = max(1, baseConcurrency)
        self.governor = governor
    }

    public func maxConcurrentItems(for inputs: BackupThrottleInputs) -> Int {
        guard inputs.isNetworkAvailable else { return 0 }
        return governor.budget(
            for: .userInitiatedBackup,
            signals: LibraryWorkloadSignals(
                thermalLevel: inputs.thermalLevel.libraryLevel,
                isLowPowerMode: inputs.isLowPowerMode,
                isNetworkConstrained: inputs.isNetworkConstrained,
                isNetworkExpensive: inputs.isNetworkExpensive,
                hasActiveUserInitiatedTransfer: true
            ),
            baseConcurrency: baseConcurrency
        ).maxConcurrentItems
    }
}

private extension BackupThermalLevel {
    var libraryLevel: LibraryThermalLevel {
        switch self {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        }
    }
}
