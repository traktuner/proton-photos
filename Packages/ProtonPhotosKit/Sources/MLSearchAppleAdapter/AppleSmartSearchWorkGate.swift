import Foundation
import MediaFeedCore
import MLSearchCore
import PhotosCore

/// Synchronous indexing gate over the shared workload governor.
///
/// Thermal and low-power signals are read synchronously from `ProcessInfo`. Visible thumbnail
/// demand lives on the feed actor, so the gate keeps a short-lived cached sample that its own
/// queries refresh in the background — indexing is checked at asset boundaries, so the sample
/// is at most one embed plus the refresh interval stale, and no polling runs while idle.
public final class AppleSmartSearchWorkGate: @unchecked Sendable {
    private let feed: ThumbnailFeedCore
    private let hostPermitsIndexing: @Sendable () -> Bool
    private let governor = LibraryWorkloadGovernorPolicy()
    private let lock = NSLock()
    private var cachedVisibleDemand = false
    private var lastRefresh: ContinuousClock.Instant?
    private var refreshInFlight = false
    private let refreshInterval: Duration

    public init(
        feed: ThumbnailFeedCore,
        refreshInterval: Duration = .milliseconds(500),
        hostPermitsIndexing: @escaping @Sendable () -> Bool = { true }
    ) {
        self.feed = feed
        self.refreshInterval = refreshInterval
        self.hostPermitsIndexing = hostPermitsIndexing
    }

    public func permitsIndexing() -> Bool {
        guard hostPermitsIndexing() else { return false }
        refreshVisibleDemandIfStale()

        let info = ProcessInfo.processInfo
        let signals = LibraryWorkloadSignals(
            thermalLevel: Self.thermalLevel(info.thermalState),
            isLowPowerMode: info.isLowPowerModeEnabled,
            hasVisibleMediaDemand: lock.withLock { cachedVisibleDemand }
        )
        return !governor.budget(for: .backgroundSemanticIndexing, signals: signals).shouldYield
    }

    private func refreshVisibleDemandIfStale() {
        let shouldRefresh: Bool = lock.withLock {
            if refreshInFlight { return false }
            if let lastRefresh, ContinuousClock.now - lastRefresh < refreshInterval { return false }
            refreshInFlight = true
            return true
        }
        guard shouldRefresh else { return }
        let feed = self.feed
        Task(priority: .utility) { [weak self] in
            let demand = await feed.hasVisibleThumbnailPressure()
            guard let self else { return }
            self.lock.withLock {
                self.cachedVisibleDemand = demand
                self.lastRefresh = ContinuousClock.now
                self.refreshInFlight = false
            }
        }
    }

    private static func thermalLevel(_ state: ProcessInfo.ThermalState) -> LibraryThermalLevel {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
}
