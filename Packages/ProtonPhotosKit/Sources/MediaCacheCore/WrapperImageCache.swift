import Foundation

/// Cost-bounded platform-image wrapper cache with coordinated memory-pressure semantics - the ONE
/// implementation of the "`NSCache` of `UIImage`/`NSImage` wrappers over the decoded core tier" that the
/// AppKit and UIKit feed adapters (and the iOS viewer display cache) previously each hand-rolled.
///
/// Generic over the wrapped object so the pressure/purge behavior is unit-testable on every platform with a
/// plain dummy class - no UIKit/AppKit needed. Wrappers are always rebuildable (from the decoded tier or a
/// re-decode), so nothing is ever lost by scaling or purging this cache.
public final class WrapperImageCache<Image: AnyObject>: @unchecked Sendable {
    private let cache = NSCache<NSString, Image>()
    /// Nominal cost budget, retained so a memory-pressure scale can be restored to full with `scale: 1.0`.
    public let nominalCostLimitBytes: Int

    public init(countLimit: Int, costLimitBytes: Int) {
        nominalCostLimitBytes = max(1, costLimitBytes)
        cache.countLimit = max(0, countLimit)
        cache.totalCostLimit = nominalCostLimitBytes
    }

    public func image(forKey key: NSString) -> Image? {
        cache.object(forKey: key)
    }

    public func set(_ image: Image, forKey key: NSString, cost: Int) {
        cache.setObject(image, forKey: key, cost: max(0, cost))
    }

    public func remove(forKey key: NSString) {
        cache.removeObject(forKey: key)
    }

    public func removeAll() {
        cache.removeAllObjects()
    }

    /// Governor-driven memory-pressure response: `scale` lowers the cost limit future insertions are bounded
    /// by (restore with `1.0`); `purge` drops everything held now. Thread-safe (`NSCache`), no actor hop.
    public func applyMemoryPressure(scale: Double, purge: Bool) {
        let clamped = min(1, max(0, scale))
        cache.totalCostLimit = max(1, Int(Double(nominalCostLimitBytes) * clamped))
        if purge { cache.removeAllObjects() }
    }

    /// Set an explicit cost limit (bytes). Owners with a "keep exactly the essential entry" purge use this
    /// to floor the scaled limit at that entry's cost, so the kept entry is never evicted by the new limit.
    public func setCostLimit(_ bytes: Int) {
        cache.totalCostLimit = max(1, bytes)
    }

    /// Purge everything EXCEPT the given key - the viewer's "drop non-visible pages, keep the on-screen one"
    /// purge. `NSCache` cannot enumerate, so the kept entry is snapshotted and re-inserted after the wipe.
    public func purge(keeping key: NSString?, keptCost: Int = 0) {
        let kept = key.flatMap { cache.object(forKey: $0) }
        cache.removeAllObjects()
        if let kept, let key {
            cache.setObject(kept, forKey: key, cost: max(0, keptCost))
        }
    }

    /// The cost limit currently in force (nominal × the last pressure scale) - for tests and diagnostics.
    public var currentCostLimitBytes: Int {
        cache.totalCostLimit
    }
}
