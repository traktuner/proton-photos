import Foundation
import PhotosCore

/// Pure merge of the iOS/iPadOS platform signals into the Core `MemoryConditions` the shared
/// `MemoryPressureGovernor` consumes. Kept UIKit-free (and compiled on every platform) so the
/// signal → conditions decision is unit-testable under plain `swift test`; the UIKit-guarded
/// coordinator only observes the OS events and feeds them through here.
///
/// Semantics:
/// - A latched `didReceiveMemoryWarning` or a `DispatchSource` critical event → `.critical`
///   (the governor's `.minimal` tier: purge non-essential holdings now).
/// - A `DispatchSource` warning OR being backgrounded → `.warning` (the `.reduced` tier: halve
///   future budgets — Apple reclaims backgrounded apps first, so backgrounding sheds proactively).
/// - Otherwise `.normal` (full budgets).
public enum UIKitMemoryConditionsPolicy {
    public static func conditions(
        dispatchSourcePressure: MemoryConditions.Pressure,
        memoryWarningLatched: Bool,
        isBackgrounded: Bool,
        thermalState: ProcessInfo.ThermalState,
        lowPowerMode: Bool
    ) -> MemoryConditions {
        let pressure: MemoryConditions.Pressure
        if memoryWarningLatched || dispatchSourcePressure == .critical {
            pressure = .critical
        } else if dispatchSourcePressure == .warning || isBackgrounded {
            pressure = .warning
        } else {
            pressure = .normal
        }
        return MemoryConditions(
            pressure: pressure,
            thermal: thermal(thermalState),
            lowPowerMode: lowPowerMode
        )
    }

    /// `ProcessInfo.ThermalState` → the Core thermal enum (identical mapping to the macOS adapter).
    public static func thermal(_ state: ProcessInfo.ThermalState) -> MemoryConditions.Thermal {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
}
