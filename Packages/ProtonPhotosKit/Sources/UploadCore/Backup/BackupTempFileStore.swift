import Foundation

/// Bounded, crash-safe temp storage for exported backup resources (PhotoKit originals are
/// materialized here before hashing/upload). Platform-neutral Foundation only.
///
/// Safety model:
/// - files are written under a `.partial` name and only renamed on `commit`, so a crash can
///   never leave a half-written file that looks complete,
/// - `sweep()` (call at controller start, when no run is active) deletes everything - every
///   temp file is re-derivable from the library, so the sweep can be total,
/// - `reserve` enforces the disk budget BEFORE bytes are written: the store's own footprint
///   stays under `maximumBytes`, and the volume must keep `minimumFreeBytes` plus twice the
///   expected file size free. Exceeding the budget throws `BackupTempFileError.diskBudgetExceeded`,
///   which callers treat as retryable (park + backoff), never as data loss.
public final class BackupTempFileStore: @unchecked Sendable {

    public enum BackupTempFileError: Error, Equatable {
        case diskBudgetExceeded
    }

    public let directory: URL
    /// Cap for the store's own on-disk footprint.
    public let maximumBytes: Int64
    /// Free space the volume must retain beyond the file being written.
    public let minimumFreeBytes: Int64

    private let lock = NSLock()
    private let fileManager = FileManager.default

    public init(
        directory: URL,
        maximumBytes: Int64 = 2 << 30,          // 2 GiB
        minimumFreeBytes: Int64 = 1 << 30       // 1 GiB
    ) {
        self.directory = directory
        self.maximumBytes = max(1, maximumBytes)
        self.minimumFreeBytes = max(0, minimumFreeBytes)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Deletes every temp file (partial or committed). Call only while no run is active - all
    /// contents are re-derivable exports.
    public func sweep() {
        lock.withLock {
            guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for url in entries { try? fileManager.removeItem(at: url) }
        }
    }

    /// Reserves a unique `.partial` destination for an export of roughly `expectedBytes`.
    /// The caller streams into the returned URL, then calls `commit` (or `discard`).
    public func reserve(filename: String, expectedBytes: Int64) throws -> URL {
        try lock.withLock {
            let expected = max(0, expectedBytes)
            if usedBytesLocked() + expected > maximumBytes {
                throw BackupTempFileError.diskBudgetExceeded
            }
            if let free = freeBytes(), free < minimumFreeBytes + expected * 2 {
                throw BackupTempFileError.diskBudgetExceeded
            }
            let safeName = filename.replacingOccurrences(of: "/", with: "_")
            return directory.appendingPathComponent("\(UUID().uuidString)-\(safeName).partial")
        }
    }

    /// Promotes a fully-written `.partial` file to its final name and returns the final URL.
    public func commit(_ partialURL: URL) throws -> URL {
        try lock.withLock {
            let finalURL = URL(fileURLWithPath: String(partialURL.path.dropLast(".partial".count)))
            try? fileManager.removeItem(at: finalURL)
            try fileManager.moveItem(at: partialURL, to: finalURL)
            return finalURL
        }
    }

    public func discard(_ url: URL) {
        lock.withLock { try? fileManager.removeItem(at: url) }
    }

    public func usedBytes() -> Int64 {
        lock.withLock { usedBytesLocked() }
    }

    private func usedBytesLocked() -> Int64 {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return entries.reduce(into: Int64(0)) { total, url in
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    private func freeBytes() -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
