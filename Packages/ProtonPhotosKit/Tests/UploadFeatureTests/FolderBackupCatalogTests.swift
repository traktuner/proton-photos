import Foundation
import XCTest
@testable import UploadCore

final class FolderBackupCatalogTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-backup-catalog-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func collect(_ catalog: FolderBackupCatalog) async throws -> [UploadBackupAssetCandidate] {
        var out: [UploadBackupAssetCandidate] = []
        for try await candidate in catalog.candidates() { out.append(candidate) }
        return out
    }

    func testStreamsSupportedMediaInDeterministicOrderWithOriginalNames() async throws {
        let sub = tempDir.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("b".utf8).write(to: tempDir.appendingPathComponent("b.jpg"))
        try Data("aaaa".utf8).write(to: tempDir.appendingPathComponent("A.PNG"))
        try Data("v".utf8).write(to: sub.appendingPathComponent("clip.mov"))
        try Data("no".utf8).write(to: tempDir.appendingPathComponent("notes.txt"))
        try Data("h".utf8).write(to: tempDir.appendingPathComponent(".hidden.jpg"))

        let candidates = try await collect(FolderBackupCatalog(folder: tempDir))

        XCTAssertEqual(candidates.map(\.originalFilename), ["A.PNG", "b.jpg", "clip.mov"],
                       "order must be the enumerator's deterministic path sort; unsupported and hidden files are excluded")
        XCTAssertEqual(candidates.map(\.byteCount), [4, 1, 1])
        for candidate in candidates {
            XCTAssertEqual(candidate.snapshot.source.kind, .fileURL)
            XCTAssertEqual(candidate.snapshot.source.resource, .primary)
            XCTAssertEqual(candidate.snapshot.resourceCount, 1)
            XCTAssertEqual(candidate.snapshot.editRevision, .unavailable,
                           "mutable file sources must never claim trusted edit evidence")
        }
    }

    func testRevisionTracksModificationTime() async throws {
        let file = tempDir.appendingPathComponent("shot.heic")
        try Data("x".utf8).write(to: file)
        let modified = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)

        let candidates = try await collect(FolderBackupCatalog(folder: tempDir))

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].snapshot.revision, UploadBackupRevision(date: modified))
    }

    func testEmptyOrMissingFolderYieldsNothing() async throws {
        let empty = try await collect(FolderBackupCatalog(folder: tempDir))
        XCTAssertTrue(empty.isEmpty)

        let missing = try await collect(FolderBackupCatalog(folder: tempDir.appendingPathComponent("nope")))
        XCTAssertTrue(missing.isEmpty)
    }
}
