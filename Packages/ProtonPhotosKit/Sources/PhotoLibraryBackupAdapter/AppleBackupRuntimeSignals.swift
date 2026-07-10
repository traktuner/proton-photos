import Foundation
import Network
import UploadCore

/// Shared Apple runtime signals for every PhotoKit-backed upload flow. The policy stays in Core;
/// this adapter only translates public OS state into its platform-neutral input.
final class BackupNetworkPathMonitor: @unchecked Sendable {
    static let shared = BackupNetworkPathMonitor()

    struct Snapshot {
        var isAvailable = true
        var isConstrained = false
        var isExpensive = false
    }

    private let lock = NSLock()
    private var state = Snapshot()
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "me.protonphotos.backup-network-path", qos: .utility)

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.lock.withLock {
                self?.state = Snapshot(
                    isAvailable: path.status == .satisfied,
                    isConstrained: path.isConstrained,
                    isExpensive: path.isExpensive
                )
            }
        }
        monitor.start(queue: queue)
    }

    var snapshot: Snapshot { lock.withLock { state } }
}

enum AppleBackupRuntimeSignals {
    static func current() -> BackupThrottleInputs {
        let process = ProcessInfo.processInfo
        let thermal: BackupThermalLevel = switch process.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
        let network = BackupNetworkPathMonitor.shared.snapshot
        return BackupThrottleInputs(
            thermalLevel: thermal,
            isLowPowerMode: process.isLowPowerModeEnabled,
            isNetworkAvailable: network.isAvailable,
            isNetworkConstrained: network.isConstrained,
            isNetworkExpensive: network.isExpensive
        )
    }
}
