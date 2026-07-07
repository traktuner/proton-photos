import AppKit
import Foundation
import MediaCacheAppKitAdapter
import PhotoViewerFeature
import PhotosCore

/// macOS adapter that drives the Core `MemoryPressureGovernor` from platform event SOURCES and wires
/// the app's cache owners in as responders.
///
/// This is the platform half of the governor: Core owns the mechanism and the (pressure, thermal) →
/// tier policy; this file supplies macOS's events (`DispatchSource` memory pressure + `ProcessInfo`
/// thermal / Low Power Mode) and lets the tier fan out to the concrete caches. It mirrors how
/// `AppKitMetalGridTexturePolicy` supplies macOS texture budgets. An iOS adapter would feed the SAME
/// governor from `UIApplication.didReceiveMemoryWarning` + the thermal notification - the responders
/// and policy do not change.
///
/// Apple references:
/// - `DispatchSource.makeMemoryPressureSource` - elevated pressure means "reduce future cache sizes",
///   not "discard now": https://developer.apple.com/documentation/dispatch/dispatchsource/makememorypressuresource(eventmask:queue:)
/// - `ProcessInfo.thermalState` mitigations (defer prefetch at `.fair`, shed at `.serious`):
///   https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum
@MainActor
final class AppMemoryPressureCoordinator {
    static let shared = AppMemoryPressureCoordinator()

    private var source: DispatchSourceMemoryPressure?
    private var sourcesInstalled = false
    private var staticRespondersRegistered = false
    private var pressure: MemoryConditions.Pressure = .normal
    private var feedRegistration: (id: ObjectIdentifier, token: MemoryPressureRegistration)?

    private init() {}

    /// Install the platform event sources and register the app-lifetime cache owners. Idempotent - safe
    /// to call on every backend (re)build.
    func install() {
        registerStaticResponders()
        guard !sourcesInstalled else { return }
        sourcesInstalled = true

        // `.normal` is included so the governor is told when pressure RECOVERS, restoring full budgets.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            let data = source.data
            MainActor.assumeIsolated {
                guard let self else { return }
                self.pressure = data.contains(.critical) ? .critical
                    : (data.contains(.warning) ? .warning : .normal)
                self.publish()
            }
        }
        source.resume()
        self.source = source

        NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }

        publish()   // seed the governor with the current state
    }

    /// Register a thumbnail feed's RAM tiers. SwiftUI can re-create the feed, so this is keyed by
    /// identity: re-attaching the same stable feed is a no-op, and a genuinely new feed replaces the
    /// previous registration so only the live feed responds.
    func attachFeed(_ feed: ThumbnailFeed) {
        let id = ObjectIdentifier(feed)
        if feedRegistration?.id == id { return }
        feedRegistration?.token.end()
        let token = MemoryPressureGovernor.shared.register { [weak feed] tier in
            feed?.applyMemoryPressure(scale: tier.budgetScale, purge: tier.requiresImmediatePurge)
        }
        feedRegistration = (id, token)
    }

    private func registerStaticResponders() {
        guard !staticRespondersRegistered else { return }
        staticRespondersRegistered = true
        let governor = MemoryPressureGovernor.shared
        // Viewer full-resolution cache (static, shared across viewer instances) - the single most
        // jetsam-prone RAM consumer.
        governor.register { tier in
            PhotoViewerModel.applyMemoryPressure(scale: tier.budgetScale, purge: tier.requiresImmediatePurge)
        }
        // Encrypted thumbnail byte cache (in-process plaintext RAM tier) - app-lifetime singleton.
        let byteCache = OfflineLibraryManager.shared.cache
        governor.register { tier in
            byteCache.applyMemoryPressure(scale: tier.budgetScale, purge: tier.requiresImmediatePurge)
        }
    }

    private func publish() {
        let info = ProcessInfo.processInfo
        MemoryPressureGovernor.shared.update(
            MemoryConditions(
                pressure: pressure,
                thermal: Self.thermal(info.thermalState),
                lowPowerMode: info.isLowPowerModeEnabled
            )
        )
    }

    private static func thermal(_ state: ProcessInfo.ThermalState) -> MemoryConditions.Thermal {
        switch state {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .serious
        }
    }
}
