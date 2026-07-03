#if canImport(UIKit) && !os(watchOS)
import Foundation
import MediaByteCache
import os
import PhotosCore
import UIKit

/// iOS/iPadOS adapter that drives the Core `MemoryPressureGovernor` from platform event SOURCES and wires
/// the app's cache owners in as responders — the mobile half of the governor, mirroring the macOS
/// `AppMemoryPressureCoordinator` exactly in responsibility: Core owns the mechanism and the
/// (pressure, thermal) → tier policy; this file supplies the UIKit events and identity-keyed attachments.
///
/// Event sources:
/// - `DispatchSource.makeMemoryPressureSource` — warning/critical AND the `.normal` recovery event, so
///   budgets grow back once the system relaxes (UIKit's memory warning has no "ended" signal of its own).
/// - `UIApplication.didReceiveMemoryWarningNotification` — latched to `.critical` (purge-now semantics),
///   decaying after a grace interval unless the dispatch source reports recovery earlier.
/// - `ProcessInfo.thermalStateDidChangeNotification` — thermal tiering, same mapping as macOS.
/// - Background/foreground — a backgrounded app sheds to the `.reduced` tier proactively (Apple reclaims
///   backgrounded apps first).
@MainActor
public final class UIKitMemoryPressureCoordinator {
    public static let shared = UIKitMemoryPressureCoordinator()

    private static let logger = Logger(subsystem: "me.protonphotos.ios", category: "MemBudget")
    /// How long a UIKit memory warning keeps the tier latched at `.critical` before conditions are
    /// re-derived from the live sources (the dispatch source's `.normal` event clears it earlier).
    private static let memoryWarningLatchSeconds: Double = 20

    private var source: DispatchSourceMemoryPressure?
    private var sourcesInstalled = false
    private var dispatchPressure: MemoryConditions.Pressure = .normal
    private var memoryWarningLatched = false
    private var warningDecayTask: Task<Void, Never>?
    private var isBackgrounded = false
    /// Identity-keyed live attachments (feed, byte cache, viewer store, grid host): re-attaching the same
    /// object is a no-op, and a genuinely new instance replaces the previous registration, so only the live
    /// owner responds and stale registrations never accumulate across sessions/viewer opens.
    private var attachments: [String: (id: ObjectIdentifier, token: MemoryPressureRegistration)] = [:]

    private init() {}

    /// Install the platform event sources (idempotent — safe to call on every session (re)build) and the
    /// tier-change `[MemBudget]` log line with live headroom + scaled budget ceilings.
    public func install() {
        guard !sourcesInstalled else { return }
        sourcesInstalled = true

        // `.normal` is included so the governor is told when pressure RECOVERS, restoring full budgets.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            let data = source.data
            MainActor.assumeIsolated {
                guard let self else { return }
                if data.contains(.critical) {
                    self.dispatchPressure = .critical
                } else if data.contains(.warning) {
                    self.dispatchPressure = .warning
                } else {
                    self.dispatchPressure = .normal
                    self.clearMemoryWarningLatch()   // the system says recovered → budgets may grow back
                }
                self.publish()
            }
        }
        source.resume()
        self.source = source

        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.latchMemoryWarning() }
        }
        center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.publish() }
        }
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isBackgrounded = true
                self?.publish()
            }
        }
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.isBackgrounded = false
                self?.publish()
            }
        }

        // Production-visible `[MemBudget]` line on every tier change (the governor fans out only on change):
        // tier + live headroom + the scaled RAM ceilings, so a device log answers "did the valve fire, and
        // to what budgets?" without a debug build.
        MemoryPressureGovernor.shared.register { tier in
            Self.logMemBudget(tier)
        }

        publish()   // seed the governor with the current state
    }

    /// Register the live thumbnail feed's RAM tiers (UIImage wrappers + decoded core).
    public func attachFeed(_ feed: UIKitThumbnailFeed) {
        attach(feed, key: "thumbnailFeed") { [weak feed] tier in
            feed?.applyMemoryPressure(scale: tier.budgetScale, purge: tier.requiresImmediatePurge)
        }
    }

    /// Register the live encrypted thumbnail byte cache's in-process plaintext RAM tier.
    public func attachByteCache(_ cache: ThumbnailCache) {
        attach(cache, key: "byteCache") { [weak cache] tier in
            cache?.applyMemoryPressure(scale: tier.budgetScale, purge: tier.requiresImmediatePurge)
        }
    }

    /// Generic identity-keyed attachment for owners this module must not depend on (the viewer display
    /// store, the grid host's texture cache): re-attaching the same object is a no-op; a new instance under
    /// the same key replaces the previous registration. The responder is invoked immediately with the
    /// current tier (governor semantics), so an owner attached under existing pressure starts scaled.
    public func attach(_ owner: AnyObject, key: String, respond: @escaping @MainActor (MemoryBudgetTier) -> Void) {
        let id = ObjectIdentifier(owner)
        if attachments[key]?.id == id { return }
        attachments[key]?.token.end()
        let token = MemoryPressureGovernor.shared.register(respond)
        attachments[key] = (id, token)
    }

    private func latchMemoryWarning() {
        memoryWarningLatched = true
        publish()
        warningDecayTask?.cancel()
        warningDecayTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.memoryWarningLatchSeconds))
            guard !Task.isCancelled else { return }
            self?.memoryWarningLatched = false
            self?.publish()
        }
    }

    private func clearMemoryWarningLatch() {
        warningDecayTask?.cancel()
        warningDecayTask = nil
        memoryWarningLatched = false
    }

    private func publish() {
        let info = ProcessInfo.processInfo
        MemoryPressureGovernor.shared.update(
            UIKitMemoryConditionsPolicy.conditions(
                dispatchSourcePressure: dispatchPressure,
                memoryWarningLatched: memoryWarningLatched,
                isBackgrounded: isBackgrounded,
                thermalState: info.thermalState,
                lowPowerMode: info.isLowPowerModeEnabled
            )
        )
    }

    private static func logMemBudget(_ tier: MemoryBudgetTier) {
        let conditions = MemoryPressureGovernor.shared.conditions
        let mib = 1_048_576
        let headroomMB = UIKitMediaCachePolicy.liveAvailableMemoryBytes().map { Int($0) / mib } ?? -1
        let scale = tier.budgetScale
        let byteMB = Int(Double(UIKitMediaCachePolicy.dataMemoryBudgetBytes()) * scale) / mib
        let decodedMB = Int(Double(UIKitMediaCachePolicy.decodedRAMBudgetBytes()) * scale) / mib
        let wrapperMB = Int(Double(UIKitMediaCachePolicy.wrapperRAMBudgetBytes()) * scale) / mib
        logger.notice("""
        [MemBudget] tier=\(String(describing: tier), privacy: .public) \
        pressure=\(String(describing: conditions.pressure), privacy: .public) \
        thermal=\(String(describing: conditions.thermal), privacy: .public) \
        purge=\(tier.requiresImmediatePurge) headroomMB=\(headroomMB) \
        byteMB=\(byteMB) decodedMB=\(decodedMB) wrapperMB=\(wrapperMB)
        """)
    }
}
#endif
