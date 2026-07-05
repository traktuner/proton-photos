import Foundation
import XCTest
@testable import UploadCore

final class BackupTempFileStoreTests: XCTestCase {

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

    private func writeReserved(_ store: BackupTempFileStore, name: String) throws -> URL {
        let url = try store.reserve(filename: name, expectedBytes: 1)
        try Data("y".utf8).write(to: url)
        return url
    }
}
