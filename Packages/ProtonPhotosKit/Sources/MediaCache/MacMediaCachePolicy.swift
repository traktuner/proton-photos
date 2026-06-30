import Foundation

public enum MacMediaCachePolicy {
    public static func thumbnailByteCacheConfiguration() -> ThumbnailCacheConfiguration {
        ThumbnailCacheConfiguration(dataMemoryBudgetBytes: dataMemoryBudgetBytes())
    }

    /// RAM budget for compressed decrypted thumbnail/preview bytes. This mirrors the previous macOS behavior
    /// while keeping hardware sizing policy outside `MediaByteCache`.
    public static func dataMemoryBudgetBytes() -> Int {
        let physical = Double(ProcessInfo.processInfo.physicalMemory)
        let floor = 64.0 * 1024 * 1024
        let ceiling = 2.0 * 1024 * 1024 * 1024
        return Int(min(max(physical * 0.02, floor), ceiling))
    }
}
