import Foundation

// MARK: - Adapter-fed signals

/// System conditions that drive cache-budget coordination. Core NEVER reads `ProcessInfo`,
/// `DispatchSource`, or `os_proc_available_memory` directly - a platform adapter observes those and
/// pushes plain values in here, exactly like `LibraryDatabasePolicy`/`GridTextureBudget` inject
/// platform numbers. That keeps the mechanism testable and identical across macOS/iOS/iPadOS.
public struct MemoryConditions: Sendable, Equatable {
    /// Coarse memory-pressure level. On macOS the adapter maps `DispatchSource` memory-pressure
    /// events; on iOS/iPadOS it maps `didReceiveMemoryWarning` (→ `.critical`, purge-now semantics).
    public enum Pressure: Sendable, Equatable { case normal, warning, critical }
    /// Thermal state, mirrored from `ProcessInfo.thermalState` by the adapter (never read in Core).
    public enum Thermal: Sendable, Equatable { case nominal, fair, serious, critical }

    public var pressure: Pressure
    public var thermal: Thermal
    /// Carried for completeness and for the crawl/prefetch governor to read - deliberately does NOT
    /// shrink caches (that would force re-decodes and cost *more* energy, defeating Low Power Mode).
    public var lowPowerMode: Bool

    public init(pressure: Pressure = .normal, thermal: Thermal = .nominal, lowPowerMode: Bool = false) {
        self.pressure = pressure
        self.thermal = thermal
        self.lowPowerMode = lowPowerMode
    }
}

// MARK: - Coordinated budget tier

/// The coordinated footprint tier the governor resolves from the current conditions. Cache owners
/// map this to their own numbers (a fraction of their nominal budget, and whether to purge now) -
/// Core names no bytes, so platform budgets stay in adapters.
public enum MemoryBudgetTier: Int, Sendable, Comparable, CaseIterable {
    /// Full budgets, nothing purged.
    case normal = 0
    /// Lower FUTURE budgets without a hard purge - the `DispatchSource` elevated-pressure semantic
    /// ("reduce future cache sizes", per dispatch/source.h) and Apple's thermal `.serious` guidance.
    case reduced = 1
    /// Lowest budgets AND immediate release of non-essential holdings - the UIKit
    /// `didReceiveMemoryWarning` / `DispatchSource` critical semantic (purge now).
    case minimal = 2

    public static func < (lhs: MemoryBudgetTier, rhs: MemoryBudgetTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Fraction of an owner's nominal RAM/GPU budget to keep at this tier. Owners multiply their own
    /// budget by this; `0` means "keep only what is currently essential" (e.g. visible textures).
    public var budgetScale: Double {
        switch self {
        case .normal: return 1.0
        case .reduced: return 0.5
        case .minimal: return 0.0
        }
    }

    /// Whether owners should immediately drop non-essential holdings, versus only lowering the
    /// budget that future insertions are bounded by.
    public var requiresImmediatePurge: Bool { self == .minimal }
}

/// Pure, platform-free policy mapping adapter-fed conditions to a coordinated tier. Testable in
/// isolation; the only place the (pressure, thermal) → tier decision lives.
public enum MemoryBudgetPolicy {
    public static func tier(for conditions: MemoryConditions) -> MemoryBudgetTier {
        if conditions.pressure == .critical || conditions.thermal == .critical { return .minimal }
        if conditions.pressure == .warning || conditions.thermal == .serious { return .reduced }
        // `.fair` thermal and Low Power Mode intentionally do NOT shrink caches (Apple's `.fair`
        // mitigation is "defer prefetching", a crawl concern; shrinking caches would only add
        // re-decode work). They remain visible via `MemoryPressureGovernor.conditions`.
        return .normal
    }
}

// MARK: - Responder

/// A cache owner that rescales its footprint in response to a coordinated tier. Owners that live on
/// their own actor bridge to this from a `@MainActor` registration closure (`Task { await … }`); the
/// governor never assumes an owner's isolation. Owners may also skip the protocol and register a raw
/// closure - both funnel to the same fan-out.
public protocol MemoryPressureResponder: AnyObject {
    @MainActor func respondToMemoryBudget(_ tier: MemoryBudgetTier)
}

/// Handle to a governor registration. Registration is fire-and-forget - the governor holds the
/// responder for the session (app caches live that long), and discarding this handle keeps the
/// responder registered. Call `end()` to remove it explicitly (used by tests and transient owners).
public final class MemoryPressureRegistration {
    private var cancel: (() -> Void)?
    init(cancel: @escaping () -> Void) { self.cancel = cancel }
    /// Remove this responder from the governor. Idempotent.
    public func end() { cancel?(); cancel = nil }
}

// MARK: - Governor

/// Core-owned coordination mechanism. Adapters push `MemoryConditions`; the governor resolves the
/// tier via `MemoryBudgetPolicy` and, only when the tier actually changes, fans out to every
/// registered responder. State lives on the main actor (the adapter hops here from its dispatch
/// queue), matching the app's other event sources (`NetworkMonitor`).
///
/// It holds no platform code and no cache references itself - the app composition root registers
/// each cache owner, so the same governor serves macOS today and iOS/iPadOS when their adapters land.
@MainActor
public final class MemoryPressureGovernor {
    /// Process-wide instance the app wires its caches into. Tests construct their own with `init()`.
    public static let shared = MemoryPressureGovernor()

    public private(set) var conditions = MemoryConditions()
    public private(set) var tier: MemoryBudgetTier = .normal

    private final class Box { let handler: @MainActor (MemoryBudgetTier) -> Void
        init(_ handler: @escaping @MainActor (MemoryBudgetTier) -> Void) { self.handler = handler } }
    private var responders: [Box] = []

    public init() {}

    /// Number of registered responders - for the "all cache owners registered" guard test.
    public var responderCount: Int { responders.count }

    /// Register a raw handler. It is invoked immediately with the current tier so a responder that
    /// joins under existing pressure starts in the right state, then on every subsequent tier change.
    @discardableResult
    public func register(_ handler: @escaping @MainActor (MemoryBudgetTier) -> Void) -> MemoryPressureRegistration {
        let box = Box(handler)
        responders.append(box)
        handler(tier)
        return MemoryPressureRegistration { [weak self, weak box] in
            guard let self, let box else { return }
            self.responders.removeAll { $0 === box }
        }
    }

    /// Register a typed responder (convenience over `register(_:)`).
    @discardableResult
    public func register(_ responder: MemoryPressureResponder) -> MemoryPressureRegistration {
        register { [weak responder] tier in responder?.respondToMemoryBudget(tier) }
    }

    /// Adapter entry point: push the latest observed conditions. Fans out only on a tier change, so
    /// repeated identical signals are free and responders are never redundantly churned.
    public func update(_ conditions: MemoryConditions) {
        self.conditions = conditions
        let resolved = MemoryBudgetPolicy.tier(for: conditions)
        guard resolved != tier else { return }
        tier = resolved
        for responder in responders { responder.handler(resolved) }
    }
}
