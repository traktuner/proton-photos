import Foundation
import Network
import Observation

/// Shared Apple network-path monitor for the app chrome.
///
/// This reports whether the device has a usable network path. It intentionally does not infer Proton server
/// outages from request failures, because those can be auth, quota, server, or transport problems.
@MainActor
@Observable
public final class NetworkMonitor {
    public static let shared = NetworkMonitor()

    /// True when a usable network path exists. Starts optimistic so first paint is not a false offline flash.
    public private(set) var isOnline = true
    /// True briefly after the path recovers from offline to online. Title chrome uses this for a subtle
    /// "connection restored" pulse without each platform view owning its own timer.
    public private(set) var didRecentlyRestoreConnection = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "me.proton.photos.network-monitor")
    private var restoredPulseTask: Task<Void, Never>?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.apply(online: online) }
        }
        monitor.start(queue: queue)
    }

    private func apply(online: Bool) {
        let wasOnline = isOnline
        isOnline = online

        guard online else {
            restoredPulseTask?.cancel()
            didRecentlyRestoreConnection = false
            return
        }

        if !wasOnline {
            restoredPulseTask?.cancel()
            didRecentlyRestoreConnection = true
            restoredPulseTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.6))
                guard !Task.isCancelled else { return }
                didRecentlyRestoreConnection = false
            }
        }
    }
}
