import Foundation
import Network
import Observation

/// The app's single source of online/offline truth (NWPathMonitor). There is no other reachability code; this
/// is purely additive. It drives the offline indicator and lets network-only actions present an honest offline
/// state instead of silently failing. We do NOT infer offline from request failures - those can't be told apart
/// from auth/server errors.
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// True when a usable network path exists. Starts optimistic so the first frame isn't a false "offline".
    private(set) var isOnline = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "me.proton.photos.network-monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.isOnline = online }
        }
        monitor.start(queue: queue)
    }
}
