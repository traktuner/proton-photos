import Foundation
import PhotosCore

/// Bounded, crash-safe temp storage for exported backup resources (PhotoKit originals are
/// materialized here before hashing/upload). Platform-neutral Foundation only.
///
/// Safety model:
/// - files are written under a `.partial` name and only renamed on `commit`, so a crash can
///   never leave a half-written file that looks complete,
/// - `sweep()` (call at controller start, when no run is active) deletes everything - every
///   temp file is re-derivable from the library, so the sweep can be total,
/// - reservations and streamed writes enforce the disk budget. Sources with a public byte count can
///   reserve it up front; sources such as PhotoKit account each chunk before writing it. Exceeding
///   the budget throws `BackupTempFileError.diskBudgetExceeded`, which callers treat as retryable.
public final class BackupTempFileStore: @unchecked Sendable {

    public enum BackupTempFileError: Error, Equatable, LocalizedError {
        case diskBudgetExceeded

        public var errorDescription: String? {
            switch self {
            case .diskBudgetExceeded:
                return L10n.string("backup.error_low_space")
            }
        }
    }

    public let directory: URL
    /// Cap for the store's own on-disk footprint.
    public let maximumBytes: Int64
    /// Free space the volume must retain beyond the file being written.
    public let minimumFreeBytes: Int64

    private let lock = NSLock()
    private let fileManager = FileManager.default
    private let availableCapacity: @Sendable (URL) -> Int64?
    private let now: @Sendable () -> Date
    private struct Reservation {
        var expectedBytes: Int64
        var writtenBytes: Int64
    }
    private var reservations: [URL: Reservation] = [:]
    private struct CapacitySample {
        var availableBytes: Int64
        var sampledAt: Date
        var accountedWrites: Int64
    }
    private var capacitySample: CapacitySample?
    private static let capacityResampleBytes: Int64 = 16 << 20
    private static let capacityResampleInterval: TimeInterval = 0.5

    public convenience init(
        directory: URL,
        maximumBytes: Int64 = 2 << 30,          // 2 GiB
        minimumFreeBytes: Int64 = 1 << 30       // 1 GiB
    ) {
        self.init(
            directory: directory,
            maximumBytes: maximumBytes,
            minimumFreeBytes: minimumFreeBytes,
            availableCapacity: { url in
                let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                return values?.volumeAvailableCapacityForImportantUsage
            },
            now: { Date() }
        )
    }

    init(
        directory: URL,
        maximumBytes: Int64,
        minimumFreeBytes: Int64,
        availableCapacity: @Sendable @escaping (URL) -> Int64?,
        now: @Sendable @escaping () -> Date
    ) {
        self.directory = directory
        self.maximumBytes = max(1, maximumBytes)
        self.minimumFreeBytes = max(0, minimumFreeBytes)
        self.availableCapacity = availableCapacity
        self.now = now
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Deletes every temp file (partial or committed). Call only while no run is active - all
    /// contents are re-derivable exports.
    public func sweep() {
        lock.withLock {
            guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
            for url in entries { try? fileManager.removeItem(at: url) }
            reservations.removeAll(keepingCapacity: true)
            capacitySample = nil
        }
    }

    /// Reserves a unique `.partial` destination for an export of roughly `expectedBytes`.
    /// The caller streams into the returned URL, then calls `commit` (or `discard`).
    public func reserve(filename: String, expectedBytes: Int64) throws -> URL {
        try lock.withLock {
            let expected = max(0, expectedBytes)
            if max(usedBytesLocked(), reservedBytesLocked()) + expected > maximumBytes {
                throw BackupTempFileError.diskBudgetExceeded
            }
            if let free = sampledFreeBytesLocked(forceRefresh: true), free < minimumFreeBytes + expected * 2 {
                throw BackupTempFileError.diskBudgetExceeded
            }
            let safeName = filename.replacingOccurrences(of: "/", with: "_")
            let url = directory.appendingPathComponent("\(UUID().uuidString)-\(safeName).partial")
            reservations[url] = Reservation(expectedBytes: expected, writtenBytes: 0)
            return url
        }
    }

    /// Accounts a source chunk before it reaches disk. This is the public-API-safe budget path for
    /// PhotoKit, whose resource length is not exposed by a supported API.
    public func recordWrite(to url: URL, byteCount: Int) throws {
        guard byteCount > 0 else { return }
        try lock.withLock {
            guard var reservation = reservations[url] else {
                throw BackupTempFileError.diskBudgetExceeded
            }
            let increment = Int64(byteCount)
            let previousAllocation = max(reservation.expectedBytes, reservation.writtenBytes)
            let nextWritten = reservation.writtenBytes + increment
            let nextAllocation = max(reservation.expectedBytes, nextWritten)
            let totalAllocation = reservedBytesLocked() - previousAllocation + nextAllocation
            guard totalAllocation <= maximumBytes else {
                throw BackupTempFileError.diskBudgetExceeded
            }
            if let free = sampledFreeBytesLocked(forceRefresh: false), free < minimumFreeBytes + increment {
                throw BackupTempFileError.diskBudgetExceeded
            }
            reservation.writtenBytes = nextWritten
            reservations[url] = reservation
            if capacitySample != nil { capacitySample!.accountedWrites += increment }
        }
    }

    /// Promotes a fully-written `.partial` file to its final name and returns the final URL.
    public func commit(_ partialURL: URL) throws -> URL {
        try lock.withLock {
            let finalURL = URL(fileURLWithPath: String(partialURL.path.dropLast(".partial".count)))
            try? fileManager.removeItem(at: finalURL)
            try fileManager.moveItem(at: partialURL, to: finalURL)
            if let reservation = reservations.removeValue(forKey: partialURL) {
                reservations[finalURL] = reservation
            }
            return finalURL
        }
    }

    public func discard(_ url: URL) {
        lock.withLock {
            reservations.removeValue(forKey: url)
            try? fileManager.removeItem(at: url)
        }
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

    private func reservedBytesLocked() -> Int64 {
        reservations.values.reduce(into: 0) { total, reservation in
            total += max(reservation.expectedBytes, reservation.writtenBytes)
        }
    }

    private func sampledFreeBytesLocked(forceRefresh: Bool) -> Int64? {
        let currentTime = now()
        let shouldRefresh = forceRefresh
            || capacitySample == nil
            || capacitySample!.accountedWrites >= Self.capacityResampleBytes
            || currentTime.timeIntervalSince(capacitySample!.sampledAt) >= Self.capacityResampleInterval
        if shouldRefresh {
            guard let fresh = availableCapacity(directory) else {
                capacitySample = nil
                return nil
            }
            capacitySample = CapacitySample(availableBytes: fresh, sampledAt: currentTime, accountedWrites: 0)
        }
        guard let capacitySample else { return nil }
        return max(0, capacitySample.availableBytes - capacitySample.accountedWrites)
    }
}
