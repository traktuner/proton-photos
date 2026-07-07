import Foundation
import MediaByteCache
#if os(iOS) || os(tvOS) || os(visionOS)
import os
#endif

/// The coarse iOS/iPadOS device memory class. Budgets are keyed on this (plus surface class and the runtime
/// pressure tier) - never on device names/models, so future hardware inherits sane behavior automatically.
public enum UIKitDeviceMemoryClass: String, Sendable {
    /// ≤ ~4 GB devices - the conservative baseline (5-year-old iPhone class). Foreground jetsam headroom is
    /// tight here, so the decoded-thumbnail budget uses a lower fraction and a hard ceiling.
    case constrained
    /// ≥ 6 GB devices - proportional budgets scale with physical memory as before.
    case standard
}

/// iOS/iPadOS cache budget policy. This file is deliberately compilable on every platform (it touches no
/// UIKit symbol) so the budget math stays unit-testable under plain `swift test`; only the UIKit-guarded
/// adapter files consume it on device.
public enum UIKitMediaCachePolicy {
    public static func thumbnailByteCacheConfiguration() -> ThumbnailCacheConfiguration {
        ThumbnailCacheConfiguration(dataMemoryBudgetBytes: dataMemoryBudgetBytes())
    }

    /// Compressed thumbnail byte RAM budget for iOS/iPadOS.
    ///
    /// This is deliberately lower than the AppKit policy. Mobile hosts can still keep hot bytes in memory, but
    /// the universal cache core must not inherit desktop RAM assumptions.
    public static func dataMemoryBudgetBytes(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        boundedBudget(physicalMemory: physicalMemory, fraction: 0.01, floorMiB: 32, ceilingMiB: 512)
    }

    /// The device memory class boundary: physical memory at or below ~4.5 GiB is `constrained`. iOS reports
    /// slightly less than the marketing size (a "4 GB" iPhone reports ~3.7-4.0 GiB), so the threshold carries
    /// headroom above 4 GiB without ever capturing a 6 GB device.
    public static func memoryClass(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> UIKitDeviceMemoryClass {
        physicalMemory <= UInt64(4.5 * 1024 * 1024 * 1024) ? .constrained : .standard
    }

    /// Decoded thumbnail RAM budget (the DOMINANT grid-hot cache).
    ///
    /// Memory-class curve: `constrained` (≤4 GB) devices use 5.5% with a hard 224 MiB ceiling - a 4 GB iPhone
    /// lands at ~200-224 MiB instead of the old flat 8% (~328 MiB), keeping grid-hot RAM inside a safe
    /// jetsam envelope. `standard` (≥6 GB) devices keep the proportional 8% (96 MiB…1 GiB) behavior.
    ///
    /// `availableMemoryBytes` is the dynamic headroom input (`os_proc_available_memory()` on device, injected
    /// in tests): the budget never exceeds half the currently-available process memory (floored at 96 MiB), so
    /// an app launching into an already-pressured system does not size its caches as if the RAM were free.
    public static func decodedRAMBudgetBytes(
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        availableMemoryBytes: UInt64? = liveAvailableMemoryBytes()
    ) -> Int {
        let curve: Int
        switch memoryClass(physicalMemory: physicalMemory) {
        case .constrained:
            curve = boundedBudget(physicalMemory: physicalMemory, fraction: 0.055, floorMiB: 96, ceilingMiB: 224)
        case .standard:
            curve = boundedBudget(physicalMemory: physicalMemory, fraction: 0.08, floorMiB: 96, ceilingMiB: 1024)
        }
        guard let available = availableMemoryBytes, available > 0 else { return curve }
        let headroomCap = max(Int(96 * 1024 * 1024), Int(available / 2))
        return min(curve, headroomCap)
    }

    public static func wrapperRAMBudgetBytes(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        boundedBudget(physicalMemory: physicalMemory, fraction: 0.0025, floorMiB: 8, ceilingMiB: 48)
    }

    public static func downloadConcurrencyLimit(activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        min(max(2, activeProcessorCount / 2), 6)
    }

    public static func maxConcurrentDecodes(activeProcessorCount: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        min(max(1, activeProcessorCount / 2), 4)
    }

    /// Live process memory headroom (`os_proc_available_memory`), or nil where the API does not exist
    /// (macOS test hosts) or reports nothing useful. Kept as a tiny seam so budget tests inject values
    /// instead of depending on the machine running them.
    public static func liveAvailableMemoryBytes() -> UInt64? {
        #if os(iOS) || os(tvOS) || os(visionOS)
        let available = os_proc_available_memory()
        return available > 0 ? UInt64(available) : nil
        #else
        return nil
        #endif
    }

    private static func boundedBudget(
        physicalMemory: UInt64,
        fraction: Double,
        floorMiB: Double,
        ceilingMiB: Double
    ) -> Int {
        let physical = Double(physicalMemory)
        let floor = floorMiB * 1024 * 1024
        let ceiling = ceilingMiB * 1024 * 1024
        return Int(min(max(physical * fraction, floor), ceiling))
    }
}
