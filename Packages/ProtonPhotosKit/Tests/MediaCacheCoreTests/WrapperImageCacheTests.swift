import Foundation
import Testing
@testable import MediaCacheCore

/// Deterministic tests for the shared wrapper-image cache pressure semantics (used by the AppKit + UIKit
/// thumbnail feeds and the iOS viewer display cache). Only deterministic `NSCache` behavior is asserted -
/// explicit limit changes and purges, never its internal lazy eviction heuristics.
@Suite struct WrapperImageCacheTests {
    private final class Wrapped {
        let id: Int
        init(_ id: Int) { self.id = id }
    }

    @Test func pressureScaleLowersAndRestoresTheCostLimit() {
        let cache = WrapperImageCache<Wrapped>(countLimit: 8, costLimitBytes: 1_000)
        #expect(cache.currentCostLimitBytes == 1_000)

        cache.applyMemoryPressure(scale: 0.5, purge: false)
        #expect(cache.currentCostLimitBytes == 500)

        cache.applyMemoryPressure(scale: 0.0, purge: false)
        #expect(cache.currentCostLimitBytes == 1)   // never zero — NSCache treats 0 as "no limit"

        cache.applyMemoryPressure(scale: 1.0, purge: false)
        #expect(cache.currentCostLimitBytes == 1_000)

        cache.applyMemoryPressure(scale: 7.0, purge: false)   // clamped
        #expect(cache.currentCostLimitBytes == 1_000)
    }

    @Test func purgeDropsHeldEntriesButScaleAloneDoesNot() {
        let cache = WrapperImageCache<Wrapped>(countLimit: 8, costLimitBytes: 1_000_000)
        cache.set(Wrapped(1), forKey: "a", cost: 10)
        cache.set(Wrapped(2), forKey: "b", cost: 10)
        #expect(cache.image(forKey: "a") != nil)

        cache.applyMemoryPressure(scale: 0.5, purge: false)   // "reduce future budgets" semantic
        #expect(cache.image(forKey: "a") != nil)
        #expect(cache.image(forKey: "b") != nil)

        cache.applyMemoryPressure(scale: 0.0, purge: true)    // critical semantic: drop now
        #expect(cache.image(forKey: "a") == nil)
        #expect(cache.image(forKey: "b") == nil)
    }

    @Test func purgeKeepingRetainsOnlyTheKeptEntry() {
        let cache = WrapperImageCache<Wrapped>(countLimit: 8, costLimitBytes: 1_000_000)
        cache.set(Wrapped(1), forKey: "visible", cost: 10)
        cache.set(Wrapped(2), forKey: "offscreen-1", cost: 10)
        cache.set(Wrapped(3), forKey: "offscreen-2", cost: 10)

        cache.purge(keeping: "visible", keptCost: 10)
        #expect(cache.image(forKey: "visible")?.id == 1)
        #expect(cache.image(forKey: "offscreen-1") == nil)
        #expect(cache.image(forKey: "offscreen-2") == nil)

        cache.purge(keeping: nil)
        #expect(cache.image(forKey: "visible") == nil)
    }
}
