import CryptoKit
import Foundation
import SQLite3
import XCTest
import PhotosCore
@testable import UploadCore

/// Streaming SHA-1 + persistent identity manifest: the semantics-free half of the dedupe pipeline.
final class UploadIdentityManifestTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("upload-identity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeFile(_ name: String, _ data: Data) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - Streaming SHA-1

    func testSHA1MatchesKnownVector() throws {
        // FIPS 180 test vector: SHA1("abc") = a9993e364706816aba3e25717850c26c9cd0d89d.
        let url = try writeFile("abc.bin", Data("abc".utf8))
        XCTAssertEqual(try UploadContentSHA1.hexDigest(ofFileAt: url), "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    func testSHA1OfEmptyFile() throws {
        let url = try writeFile("empty.bin", Data())
        XCTAssertEqual(try UploadContentSHA1.hexDigest(ofFileAt: url), "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    func testSHA1StreamsLargeFileAcrossChunkBoundaries() throws {
        // 5 MiB of patterned bytes with a tiny 4 KiB buffer: exercises many chunk iterations and
        // non-aligned tails. Reference digest via CryptoKit's one-shot API.
        var data = Data(capacity: 5 * 1024 * 1024 + 3)
        var byte: UInt8 = 0
        for _ in 0 ..< (5 * 1024 * 1024 + 3) {
            data.append(byte)
            byte = byte &+ 7
        }
        let url = try writeFile("large.bin", data)
        let expected = UploadContentSHA1.hexString(digest: Data(Insecure.SHA1.hash(data: data)))
        XCTAssertEqual(try UploadContentSHA1.hexDigest(ofFileAt: url, bufferSize: 4096), expected)
    }

    func testSHA1MissingFileThrows() {
        let url = tempDir.appendingPathComponent("does-not-exist.bin")
        XCTAssertThrowsError(try UploadContentSHA1.hexDigest(ofFileAt: url))
    }

    func testSHA1HonoursTaskCancellationBetweenChunks() async throws {
        var data = Data(capacity: 2 * 1024 * 1024)
        for i in 0 ..< (2 * 1024 * 1024) { data.append(UInt8(truncatingIfNeeded: i)) }
        let url = try writeFile("cancel.bin", data)

        let task = Task {
            try UploadContentSHA1.digest(ofFileAt: url, bufferSize: 1024)
        }
        task.cancel()
        do {
            _ = try await task.value
            // A very fast machine may finish the first chunk check before the cancel lands - but a
            // pre-cancelled task must throw on the FIRST checkCancellation, so reaching here means
            // cancellation was ignored.
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        }
    }

    func testAccumulatorMatchesOneShotDigest() {
        let chunks = [Data("proton".utf8), Data(" ".utf8), Data("photos".utf8)]
        let accumulator = UploadSHA1Accumulator()
        for chunk in chunks { accumulator.update(chunk) }
        let whole = chunks.reduce(Data(), +)
        let expected = UploadContentSHA1.hexString(digest: Data(Insecure.SHA1.hash(data: whole)))
        XCTAssertEqual(accumulator.finalizeHexDigest(), expected)
    }

    // MARK: - Manifest store

    private func makeStore() throws -> UploadIdentityManifestStore {
        try XCTUnwrap(UploadIdentityManifestStore(
            url: tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        ))
    }

    private func makeRecord(
        identifier: String = "/photos/IMG_0001.HEIC",
        filename: String = "IMG_0001.HEIC",
        size: Int64 = 1234,
        mtime: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> UploadIdentityRecord {
        UploadIdentityRecord(
            source: UploadSourceIdentity(kind: .fileURL, identifier: identifier),
            filename: filename,
            correctedName: filename,
            fileSize: size,
            modificationDate: mtime,
            sha1Hex: "a9993e364706816aba3e25717850c26c9cd0d89d",
            nameHash: "namehash-1",
            contentHash: "contenthash-1",
            hashKeyEpoch: "epoch-1",
            remoteVolumeID: nil,
            remoteLinkID: nil,
            outcome: nil,
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100)
        )
    }

    func testTrustedContentLookupFiltersOutcomesAndSurvivesReopen() throws {
        var store = try makeStore()

        var uploaded = makeRecord(identifier: "/sync1/a.heic")
        uploaded.remoteVolumeID = "vol-1"
        uploaded.remoteLinkID = "link-1"
        uploaded.outcome = UploadIdentityManifestStore.Outcome.uploaded.rawValue
        store.upsert(uploaded)

        var trashed = makeRecord(identifier: "/sync1/trashed.heic")
        trashed.contentHash = "contenthash-trashed"
        trashed.remoteLinkID = "link-t"
        trashed.outcome = UploadIdentityManifestStore.Outcome.duplicateTrashed.rawValue
        store.upsert(trashed)

        var linkless = makeRecord(identifier: "/sync1/linkless.heic")
        linkless.contentHash = "contenthash-linkless"
        linkless.outcome = UploadIdentityManifestStore.Outcome.uploaded.rawValue
        store.upsert(linkless)

        XCTAssertEqual(store.trustedRecord(contentHash: "contenthash-1", hashKeyEpoch: "epoch-1")?.remoteLinkID, "link-1")
        XCTAssertNil(store.trustedRecord(contentHash: "contenthash-1", hashKeyEpoch: "epoch-2"),
                     "a different hash-key epoch must never match")
        XCTAssertNil(store.trustedRecord(contentHash: "contenthash-trashed", hashKeyEpoch: "epoch-1"),
                     "trashed outcomes are not proof of backup")
        XCTAssertNil(store.trustedRecord(contentHash: "contenthash-linkless", hashKeyEpoch: "epoch-1"),
                     "rows without a remote link are not trustworthy")

        // Reopen: the row and the additive index survive.
        store.close()
        store = try makeStore()
        XCTAssertEqual(store.trustedRecord(contentHash: "contenthash-1", hashKeyEpoch: "epoch-1")?.remoteLinkID, "link-1")

        var handle: OpaquePointer?
        let path = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName).path
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "PRAGMA index_list('upload_identity');", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var indexNames: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1) { indexNames.append(String(cString: name)) }
        }
        XCTAssertTrue(indexNames.contains("upload_identity_content_idx"),
                      "the content lookup must be index-backed, found: \(indexNames)")
    }

    func testUpsertAndFetchRoundTrip() throws {
        let store = try makeStore()
        let record = makeRecord()
        store.upsert(record)
        let fetched = store.record(for: record.source)
        XCTAssertEqual(fetched, record)
        XCTAssertEqual(store.count(), 1)
    }

    func testMissReturnsNil() throws {
        let store = try makeStore()
        XCTAssertNil(store.record(for: UploadSourceIdentity(kind: .fileURL, identifier: "/nope")))
    }

    func testUpsertOverwritesExistingRow() throws {
        let store = try makeStore()
        var record = makeRecord()
        store.upsert(record)
        record.sha1Hex = "ffffffffffffffffffffffffffffffffffffffff"
        record.outcome = UploadIdentityManifestStore.Outcome.uploaded.rawValue
        record.remoteVolumeID = "vol1"
        record.remoteLinkID = "link1"
        store.upsert(record)
        XCTAssertEqual(store.record(for: record.source), record)
        XCTAssertEqual(store.count(), 1)
    }

    func testPersistsAcrossReopen() throws {
        let url = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        let record = makeRecord()
        do {
            let store = try XCTUnwrap(UploadIdentityManifestStore(url: url))
            store.upsert(record)
            store.close()
        }
        let reopened = try XCTUnwrap(UploadIdentityManifestStore(url: url))
        XCTAssertEqual(reopened.record(for: record.source), record)
    }

    func testNewerSchemaFailsClosedByResetting() throws {
        let url = tempDir.appendingPathComponent(UploadIdentityManifestStore.databaseFileName)
        do {
            let store = try XCTUnwrap(UploadIdentityManifestStore(url: url))
            store.upsert(makeRecord())
            store.close()
        }
        // Stamp a from-the-future schema version directly.
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE manifest_info SET value=99 WHERE key='schema';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)

        let reopened = try XCTUnwrap(UploadIdentityManifestStore(url: url))
        XCTAssertEqual(reopened.count(), 0, "a newer on-disk schema must reset the (rehashable) manifest")
    }

    // MARK: - Cache validity policy

    private func descriptor(
        identifier: String = "/photos/IMG_0001.HEIC",
        filename: String = "IMG_0001.HEIC",
        size: Int64 = 1234,
        mtime: Date = Date(timeIntervalSince1970: 1_700_000_000)
    ) -> UploadResourceDescriptor {
        UploadResourceDescriptor(
            source: UploadSourceIdentity(kind: .fileURL, identifier: identifier),
            fileURL: URL(fileURLWithPath: identifier),
            filename: filename,
            fileSize: size,
            modificationDate: mtime
        )
    }

    func testRecordValidWhenNothingChanged() {
        XCTAssertTrue(makeRecord().isValid(for: descriptor()))
    }

    func testRecordInvalidWhenSizeChanged() {
        XCTAssertFalse(makeRecord().isValid(for: descriptor(size: 1235)))
    }

    func testRecordInvalidWhenModificationDateChanged() {
        XCTAssertFalse(makeRecord().isValid(for: descriptor(mtime: Date(timeIntervalSince1970: 1_700_000_001))))
    }

    func testRecordInvalidWhenFilenameChanged() {
        XCTAssertFalse(makeRecord().isValid(for: descriptor(filename: "IMG_0002.HEIC")))
    }

    func testRecordInvalidWhenSourceIdentifierChanged() {
        XCTAssertFalse(makeRecord().isValid(for: descriptor(identifier: "/photos/other.HEIC")))
    }
}
