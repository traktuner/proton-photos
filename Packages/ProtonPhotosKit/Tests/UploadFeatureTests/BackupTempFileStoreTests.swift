import Foundation
import XCTest
@testable import UploadCore

final class BackupTempFileStoreTests: XCTestCase {

    private final class CapacityProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int64
        private var calls = 0

        init(_ value: Int64) { self.value = value }

        func read(_ url: URL) -> Int64? {
            lock.withLock {
                calls += 1
                return value
            }
        }

        var callCount: Int { lock.withLock { calls } }
    }

    private final class TestNow: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_700_000_000)

        var now: Date { lock.withLock { value } }
        func advance(_ seconds: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(seconds) }
        }
    }

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-temp-store-tests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testReserveCommitLifecycle() throws {
        let store = BackupTempFileStore(directory: directory)
        let partial = try store.reserve(filename: "IMG_1.HEIC", expectedBytes: 4)
        XCTAssertTrue(partial.lastPathComponent.hasSuffix(".partial"),
                      "in-flight exports must be journaled as partial")
        try Data("abcd".utf8).write(to: partial)

        let final = try store.commit(partial)
        XCTAssertFalse(final.lastPathComponent.hasSuffix(".partial"))
        XCTAssertEqual(try Data(contentsOf: final), Data("abcd".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    func testSweepClearsPartialsAndCommittedFiles() throws {
        let store = BackupTempFileStore(directory: directory)
        let partial = try store.reserve(filename: "a.jpg", expectedBytes: 1)
        try Data("x".utf8).write(to: partial)
        let committed = try store.commit(try writeReserved(store, name: "b.jpg"))

        store.sweep()

        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: committed.path))
        XCTAssertEqual(store.usedBytes(), 0)
    }

    func testDiskBudgetIsEnforcedBeforeBytesAreWritten() throws {
        let store = BackupTempFileStore(directory: directory, maximumBytes: 10)
        let first = try store.reserve(filename: "small.jpg", expectedBytes: 6)
        try Data(repeating: 0, count: 6).write(to: first)

        XCTAssertThrowsError(try store.reserve(filename: "big.jpg", expectedBytes: 6)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }
        // Freeing space unblocks the budget.
        store.discard(first)
        XCTAssertNoThrow(try store.reserve(filename: "big.jpg", expectedBytes: 6))
    }

    func testUnknownPhotoKitSizeIsEnforcedAsChunksArrive() throws {
        let store = BackupTempFileStore(directory: directory, maximumBytes: 10, minimumFreeBytes: 0)
        let partial = try store.reserve(filename: "photo.heic", expectedBytes: 0)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        let handle = try FileHandle(forWritingTo: partial)
        defer { try? handle.close() }

        try store.recordWrite(to: partial, byteCount: 6)
        try handle.write(contentsOf: Data(repeating: 1, count: 6))
        XCTAssertThrowsError(try store.recordWrite(to: partial, byteCount: 5)) { error in
            XCTAssertEqual(error as? BackupTempFileStore.BackupTempFileError, .diskBudgetExceeded)
        }
        XCTAssertEqual(store.usedBytes(), 6)
    }

    func testFreeCapacityProbeIsSampledInsteadOfCalledForEveryChunk() throws {
        let capacity = CapacityProbe(8 << 30)
        let clock = TestNow()
        let store = BackupTempFileStore(
            directory: directory,
            maximumBytes: 2 << 30,
            minimumFreeBytes: 1 << 30,
            availableCapacity: capacity.read,
            now: { clock.now }
        )
        let partial = try store.reserve(filename: "large.mov", expectedBytes: 0)
        XCTAssertEqual(capacity.callCount, 1)

        for _ in 0..<100 {
            try store.recordWrite(to: partial, byteCount: 64 << 10)
        }
        XCTAssertEqual(capacity.callCount, 1, "small PhotoKit chunks must not issue one volume query each")

        clock.advance(1)
        try store.recordWrite(to: partial, byteCount: 64 << 10)
        XCTAssertEqual(capacity.callCount, 2, "the sample must still refresh promptly for external disk use")
    }

    private func writeReserved(_ store: BackupTempFileStore, name: String) throws -> URL {
        let url = try store.reserve(filename: name, expectedBytes: 1)
        try Data("y".utf8).write(to: url)
        return url
    }
}
