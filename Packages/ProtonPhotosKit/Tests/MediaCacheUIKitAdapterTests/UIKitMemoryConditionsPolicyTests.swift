import Foundation
import Testing
import PhotosCore
@testable import MediaCacheUIKitAdapter

/// Locks the iOS signal → `MemoryConditions` merge and proves a simulated memory warning reaches
/// registered responders through the shared governor EXACTLY once per tier change (repeated identical
/// signals never re-fan-out), with recovery restoring full budgets.
@Suite struct UIKitMemoryConditionsPolicyTests {
    private func merged(
        dispatch: MemoryConditions.Pressure = .normal,
        warned: Bool = false,
        background: Bool = false,
        thermal: ProcessInfo.ThermalState = .nominal,
        lowPower: Bool = false
    ) -> MemoryConditions {
        UIKitMemoryConditionsPolicy.conditions(
            dispatchSourcePressure: dispatch,
            memoryWarningLatched: warned,
            isBackgrounded: background,
            thermalState: thermal,
            lowPowerMode: lowPower
        )
    }

    // MARK: - Signal merge

    @Test func memoryWarningAndDispatchCriticalBothMapToCritical() {
        #expect(merged(warned: true).pressure == .critical)
        #expect(merged(dispatch: .critical).pressure == .critical)
        // A latched warning wins even while backgrounded or under a lesser dispatch level.
        #expect(merged(dispatch: .warning, warned: true, background: true).pressure == .critical)
    }

    @Test func dispatchWarningOrBackgroundingMapToWarning() {
        #expect(merged(dispatch: .warning).pressure == .warning)
        #expect(merged(background: true).pressure == .warning)
        #expect(merged(dispatch: .warning, background: true).pressure == .warning)
    }

    @Test func quietForegroundIsNormalAndThermalPassesThrough() {
        let quiet = merged()
        #expect(quiet.pressure == .normal)
        #expect(quiet.thermal == .nominal)
        #expect(merged(thermal: .fair).thermal == .fair)
        #expect(merged(thermal: .serious).thermal == .serious)
        #expect(merged(thermal: .critical).thermal == .critical)
        #expect(merged(lowPower: true).lowPowerMode)
    }

    @Test func tiersResolveFromMergedConditionsLikeTheSharedPolicy() {
        // The merged conditions drive the SAME Core policy macOS uses: warning → reduced, critical → minimal.
        #expect(MemoryBudgetPolicy.tier(for: merged()) == .normal)
        #expect(MemoryBudgetPolicy.tier(for: merged(background: true)) == .reduced)
        #expect(MemoryBudgetPolicy.tier(for: merged(warned: true)) == .minimal)
        #expect(MemoryBudgetPolicy.tier(for: merged(thermal: .serious)) == .reduced)
    }

    // MARK: - Fan-out through the shared governor

    @Test @MainActor func simulatedMemoryWarningReachesRespondersExactlyOncePerTierChange() {
        let governor = MemoryPressureGovernor()
        var received: [MemoryBudgetTier] = []
        var purges = 0
        governor.register { tier in
            received.append(tier)
            if tier.requiresImmediatePurge { purges += 1 }
        }
        #expect(received == [.normal])   // registration seeds the current tier

        // Simulated `didReceiveMemoryWarning`: latch → critical → .minimal, delivered exactly once…
        let warned = merged(warned: true)
        governor.update(warned)
        governor.update(warned)   // duplicate identical signal → no re-fan-out
        #expect(purges == 1)
        #expect(received == [.normal, .minimal])

        // …and recovery (latch cleared) restores full budgets, again exactly once.
        governor.update(merged())
        governor.update(merged())
        #expect(received == [.normal, .minimal, .normal])
    }
}
