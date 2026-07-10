#if DEBUG
import Foundation
import PhotosCore

/// Aggregates PhotoKit identity reads so a large first backup can be diagnosed without emitting one
/// log entry per asset. One lock acquisition per completed resource is negligible next to reading and
/// hashing the original bytes; no work is compiled into release builds.
final class PhotoLibraryBackupPerformanceReporter: @unchecked Sendable {
    static let shared = PhotoLibraryBackupPerformanceReporter()

    private struct Window {
        var startedAt: Date?
        var finishedAt: Date?
        var resources = 0
        var bytes: Int64 = 0
        var summedDuration: TimeInterval = 0
        var slowestDuration: TimeInterval = 0
        var readsOverTenSeconds = 0
    }

    private let lock = NSLock()
    private var window = Window()

    private init() {}

    func recordIdentityRead(byteCount: Int64, startedAt: Date, finishedAt: Date) {
        let payload = lock.withLock { () -> [String: String]? in
            let duration = max(0, finishedAt.timeIntervalSince(startedAt))
            window.startedAt = min(window.startedAt ?? startedAt, startedAt)
            window.finishedAt = max(window.finishedAt ?? finishedAt, finishedAt)
            window.resources += 1
            window.bytes += max(0, byteCount)
            window.summedDuration += duration
            window.slowestDuration = max(window.slowestDuration, duration)
            if duration >= 10 { window.readsOverTenSeconds += 1 }

            let wallTime = max(0, (window.finishedAt ?? finishedAt).timeIntervalSince(window.startedAt ?? startedAt))
            guard window.resources >= 100 || wallTime >= 60 else { return nil }

            let megabytes = Double(window.bytes) / 1_048_576
            let fields = [
                "step": "identityReadWindow",
                "resources": String(window.resources),
                "mb": String(format: "%.1f", megabytes),
                "wall_ms": String(format: "%.0f", wallTime * 1_000),
                "resource_ms": String(format: "%.0f", window.summedDuration * 1_000),
                "items_s": wallTime > 0 ? String(format: "%.2f", Double(window.resources) / wallTime) : "-",
                "mb_s": wallTime > 0 ? String(format: "%.1f", megabytes / wallTime) : "-",
                "slowest_ms": String(format: "%.0f", window.slowestDuration * 1_000),
                "over_10s": String(window.readsOverTenSeconds),
            ]
            window = Window()
            return fields
        }
        if let payload {
            PhotoDiagnostics.shared.emit("BackupPerf", payload)
        }
    }
}
#endif
