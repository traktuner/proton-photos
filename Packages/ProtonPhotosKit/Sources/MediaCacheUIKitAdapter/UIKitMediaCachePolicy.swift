#if canImport(UIKit)
import Foundation
import MediaByteCache

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

    public static func decodedRAMBudgetBytes(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int {
        boundedBudget(physicalMemory: physicalMemory, fraction: 0.08, floorMiB: 96, ceilingMiB: 1024)
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
#endif
