import Foundation

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
    /// Low Data Mode / constrained path - treat like low power.
    public var isNetworkConstrained: Bool
    /// Cellular/hotspot - keep going, but single-file.
    public var isNetworkExpensive: Bool

    public init(
        thermalLevel: BackupThermalLevel = .nominal,
        isLowPowerMode: Bool = false,
        isNetworkConstrained: Bool = false,
        isNetworkExpensive: Bool = false
    ) {
        self.thermalLevel = thermalLevel
        self.isLowPowerMode = isLowPowerMode
        self.isNetworkConstrained = isNetworkConstrained
        self.isNetworkExpensive = isNetworkExpensive
    }

    public static let unconstrained = BackupThrottleInputs()
}

/// One shared concurrency table for backup sync: inputs → how many items may be in flight.
/// `0` means "pause until conditions improve" - the runner idles without failing anything.
public struct BackupThrottlePolicy: Sendable, Equatable {
    /// Concurrent items under unconstrained conditions. Conservative by design: backup runs
    /// beside a live UI on old hardware; two in-flight items keep the pipe busy without
    /// competing with the grid for I/O.
    public var baseConcurrency: Int

    public init(baseConcurrency: Int = 2) {
        self.baseConcurrency = max(1, baseConcurrency)
    }

    public func maxConcurrentItems(for inputs: BackupThrottleInputs) -> Int {
        if inputs.thermalLevel == .critical { return 0 }
        if inputs.thermalLevel == .serious || inputs.isLowPowerMode
            || inputs.isNetworkConstrained || inputs.isNetworkExpensive {
            return 1
        }
        return baseConcurrency
    }
}
