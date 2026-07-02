import XCTest
import SQLite3
@testable import PhotosCore

/// DB v1 reset guard tests for the app-owned `library-v1.sqlite` timeline metadata store.
///
/// Pinned contract:
/// - schema v1 (feature-versioned via `schema_info`) with the hot `photos` table, normalized
///   `photo_tags` / `burst_members` feature tables — never serialized blobs;
/// - deterministic `(t, vol, node)` timeline order across save/load cycles (the DB index, the
///   in-memory comparator, and grid identity must always agree);
/// - generation-based incremental saves: digest no-op short-circuit, `gen` bump per refresh,
///   sweep of rows missing from the latest full enumeration (no `DELETE FROM photos` rewrite);
/// - the ordered load rides `idx_photos_timeline` (no temp b-tree);
/// - purge coverage: sign-out erases the whole per-account library directory, and the legacy
///   `timeline-v3` store names stay covered for stores written by older builds.
///
/// All I/O uses scratch temp directories — never the real user cache/support directories.
final class TimelineMetadataStoreTests: XCTestCase {

    private let uid = "user-DB1"

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineMetadataStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func makeStore(in dir: URL, name: String = "library-v1.sqlite") throws -> (TimelineMetadataStore, URL) {
        let url = dir.appendingPathComponent(name)
        let store = try XCTUnwrap(TimelineMetadataStore(url: url))
        return (store, url)
    }

    private func makeItem(
        vol: String = "vol1",
        node: String,
        t: Double,
        mime: String = "image/jpeg",
        live: Bool = false,
        relvid: String? = nil,
        dur: Double? = nil,
        tags: Set<PhotoTag> = [],
        burst: [String] = []
    ) -> PhotoItem {
        PhotoItem(
            uid: PhotoUID(volumeID: vol, nodeID: node),
            captureTime: Date(timeIntervalSince1970: t),
            mediaType: mime,
            isLivePhoto: live,
            relatedVideoID: relvid,
            durationSeconds: dur,
            tags: tags,
            burstMemberIDs: burst
        )
    }

    /// Reads rows through a separate raw connection so assertions see exactly what is on disk
    /// (normalized rows, not what the store's own decode layer reconstructs).
    private func rawRows(_ dbURL: URL, _ sql: String) -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [[String]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String] = []
            for column in 0 ..< sqlite3_column_count(stmt) {
                row.append(sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? "NULL")
            }
            rows.append(row)
        }
        return rows
    }

    private func rawExec(_ dbURL: URL, _ sql: String) {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { return }
        defer { sqlite3_close(db) }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> (T, Double) {
        let start = Date()
        let value = try body()
        let ms = Date().timeIntervalSince(start) * 1000
        print("[DBMicroPerf] \(label)=\(String(format: "%.2f", ms))ms")
        return (value, ms)
    }

    private func makeSyntheticItem(_ index: Int, tagsOverride: Set<PhotoTag>? = nil) -> PhotoItem {
        let isVideo = index.isMultiple(of: 11)
        let isLive = index.isMultiple(of: 17)
        let node = String(format: "node-%05d", index)
        let tags: Set<PhotoTag>
        if let tagsOverride {
            tags = tagsOverride
        } else if isVideo {
            tags = [.videos]
        } else if index.isMultiple(of: 19) {
            tags = [.favorites]
        } else {
            tags = []
        }
        let burstMembers = index.isMultiple(of: 97)
            ? [String(format: "burst-%05d-a", index), String(format: "burst-%05d-b", index)]
            : []
        return makeItem(
            vol: "vol\(index % 3)",
            node: node,
            t: Double(1_700_000_000 + (index / 4)),
            mime: isVideo ? "video/quicktime" : "image/jpeg",
            live: isLive,
            relvid: isLive ? String(format: "video-%05d", index) : nil,
            dur: isVideo ? Double(30 + (index % 90)) : nil,
            tags: tags,
            burst: burstMembers
        )
    }

    // MARK: - 1. Schema creation + schema_info

    func testSchemaCreationStampsFeatureVersions() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)

        XCTAssertEqual(store.schemaInfoVersions(), ["timeline": 1, "photo_tags": 1, "burst_members": 1])

        let tables = Set(rawRows(url, "SELECT name FROM sqlite_master WHERE type='table';").map { $0[0] })
        XCTAssertTrue(tables.isSuperset(of: ["schema_info", "photos", "photo_tags", "burst_members"]))
        let indexes = Set(rawRows(url, "SELECT name FROM sqlite_master WHERE type='index';").map { $0[0] })
        XCTAssertTrue(indexes.contains("idx_photos_timeline"))
        store.close()
    }

    func testNewerOnDiskSchemaVersionFailsClosedByResetting() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        store.save([makeItem(node: "n1", t: 100)])
        store.close()

        // Simulate a store written by a future build: version above what this build supports.
        rawExec(url, "UPDATE schema_info SET version = 99 WHERE feature = 'timeline';")

        let reopened = try XCTUnwrap(TimelineMetadataStore(url: url))
        XCTAssertEqual(reopened.schemaInfoVersions()["timeline"], 1, "incompatible store must reset to v1")
        XCTAssertEqual(reopened.count(), 0, "reset store starts empty (re-derivable data)")
        reopened.close()
    }

    // MARK: - 2. Stable ordering

    func testEqualCaptureTimeRowsLoadInTimelineOrderAcrossCycles() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)

        // Same capture second everywhere; only (vol, node) breaks the tie. Input is shuffled.
        let expectedOrder = [
            makeItem(vol: "volA", node: "node1", t: 500),
            makeItem(vol: "volA", node: "node9", t: 500),
            makeItem(vol: "volB", node: "node2", t: 500),
            makeItem(vol: "volB", node: "node3", t: 501),
        ]
        store.save([expectedOrder[2], expectedOrder[0], expectedOrder[3], expectedOrder[1]])
        let first = store.load()
        XCTAssertEqual(first, expectedOrder, "load must return (t, vol, node) order")

        // A second save from a differently-shuffled array must not reshuffle equal-t rows.
        store.save([expectedOrder[3], expectedOrder[1], expectedOrder[0], expectedOrder[2]])
        XCTAssertEqual(store.load(), expectedOrder, "order must be stable across save/load cycles")
        store.close()
    }

    func testInMemoryComparatorMatchesDatabaseOrder() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)
        let items = [
            makeItem(vol: "b", node: "a", t: 10),
            makeItem(vol: "a", node: "z", t: 10),
            makeItem(vol: "a", node: "a", t: 11),
            makeItem(vol: "c", node: "c", t: 9),
        ]
        store.save(items)
        XCTAssertEqual(
            store.load(),
            items.sorted(by: TimelineOrder.areInIncreasingOrder),
            "TimelineOrder must be exactly the order the DB index produces"
        )
        store.close()
    }

    // MARK: - 3. Tags normalize + round-trip

    func testTagsNormalizeIntoPhotoTagRowsAndRoundTrip() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)

        let video = makeItem(node: "vid", t: 100, mime: "video/quicktime", dur: 12.5, tags: [.videos, .favorites])
        let plain = makeItem(node: "img", t: 200)
        store.save([video, plain])

        // Normalized rows on disk — one row per (tag, vol, node), no CSV blob anywhere.
        let rows = rawRows(url, "SELECT tag, vol, node FROM photo_tags ORDER BY tag;")
        XCTAssertEqual(rows, [
            [String(PhotoTag.favorites.rawValue), "vol1", "vid"],
            [String(PhotoTag.videos.rawValue), "vol1", "vid"],
        ])
        let photoColumns = rawRows(url, "SELECT name FROM pragma_table_info('photos');").map { $0[0] }
        XCTAssertFalse(photoColumns.contains("tags"), "photos must not carry a serialized tags blob")
        XCTAssertFalse(photoColumns.contains("burst"), "photos must not carry a serialized burst blob")

        let loaded = store.load()
        XCTAssertEqual(loaded, [video, plain])
        XCTAssertEqual(loaded.first?.tags, [.videos, .favorites])
        XCTAssertEqual(loaded.first?.durationSeconds, 12.5)
        store.close()
    }

    // MARK: - 4. Burst members normalize + round-trip

    func testBurstMembersNormalizeIntoRowsAndRoundTripInSequence() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)

        // Presentation order is deliberately NOT sorted — seq must preserve it exactly.
        let members = ["member-c", "member-a", "member-b"]
        let anchor = makeItem(node: "anchor", t: 100, tags: [.bursts], burst: members)
        store.save([anchor])

        let rows = rawRows(url, "SELECT member_node, seq FROM burst_members WHERE anchor_vol='vol1' AND anchor_node='anchor' ORDER BY seq;")
        XCTAssertEqual(rows, [["member-c", "0"], ["member-a", "1"], ["member-b", "2"]])

        for _ in 0 ..< 2 {   // stable across repeated save/load cycles
            let loaded = store.load()
            XCTAssertEqual(loaded.first?.burstMemberIDs, members)
            store.save(loaded)
        }
        store.close()
    }

    // MARK: - 5. No-op short-circuit

    func testIdenticalSaveShortCircuitsWithoutRewritingRows() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        let items = (0 ..< 50).map { makeItem(node: "n\($0)", t: Double(1000 + $0)) }

        let first = store.save(items)
        XCTAssertFalse(first.skippedUnchanged)
        XCTAssertTrue(first.succeeded)
        XCTAssertEqual(first.upsertedRows, 50)
        XCTAssertEqual(first.generation, 1)

        // Identical content in a different arrival order is still a no-op (canonical digest).
        let second = store.save(items.shuffled())
        XCTAssertTrue(second.skippedUnchanged, "unchanged refresh must not rewrite rows")
        XCTAssertEqual(second.upsertedRows, 0)
        XCTAssertEqual(second.generation, 1, "generation must not advance on a skipped save")

        // The skip must survive a cold start: digest is persisted, not process state.
        store.close()
        let reopened = try XCTUnwrap(TimelineMetadataStore(url: url))
        let afterReopen = reopened.save(items)
        XCTAssertTrue(afterReopen.skippedUnchanged, "digest short-circuit must persist across launches")
        XCTAssertEqual(reopened.load(), items.sorted(by: TimelineOrder.areInIncreasingOrder))

        // Any real change breaks the short-circuit again.
        let changed = reopened.save(items + [makeItem(node: "new", t: 2000)])
        XCTAssertFalse(changed.skippedUnchanged)
        XCTAssertTrue(changed.succeeded)
        XCTAssertEqual(changed.upsertedRows, 51)
        reopened.close()
        store.close()
    }

    // MARK: - 6. Generation sweep

    func testGenerationSweepRemovesRowsMissingFromLatestRefresh() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        let a = makeItem(node: "a", t: 100)
        let b = makeItem(node: "b", t: 200, tags: [.videos])
        let c = makeItem(node: "c", t: 300)

        let first = store.save([a, b, c])
        XCTAssertEqual(first.generation, 1)

        let second = store.save([a, c])   // b disappeared from the full enumeration
        XCTAssertFalse(second.skippedUnchanged)
        XCTAssertEqual(second.generation, 2)
        XCTAssertEqual(second.sweptRows, 1, "exactly the vanished row is swept")
        XCTAssertEqual(store.load(), [a, c])

        // Feature tables follow: b's tag rows must not orphan.
        XCTAssertTrue(rawRows(url, "SELECT * FROM photo_tags WHERE node='b';").isEmpty)

        // Surviving rows all carry the current generation.
        let gens = Set(rawRows(url, "SELECT DISTINCT gen FROM photos;").map { $0[0] })
        XCTAssertEqual(gens, ["2"])
        store.close()
    }

    // MARK: - 7. Query plan

    func testTimelineLoadQueryPlanRidesTimelineIndex() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)
        store.save([makeItem(node: "n", t: 1)])

        let plan = store.timelineLoadQueryPlan()
        XCTAssertTrue(plan.contains("idx_photos_timeline"), "ordered load must ride the timeline index; plan: \(plan)")
        XCTAssertFalse(plan.uppercased().contains("TEMP B-TREE"), "no sort pass allowed; plan: \(plan)")
        store.close()
    }

    func testTwentyThousandRowSyntheticSaveLoadSkipAndChangedUpsertGuard() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)

        let items = (0 ..< 20_000).map { makeSyntheticItem($0) }
        let ordered = items.sorted(by: TimelineOrder.areInIncreasingOrder)

        let (firstSave, firstSaveMs) = timed("20k.initialSave") {
            store.save(items)
        }
        XCTAssertTrue(firstSave.succeeded)
        XCTAssertFalse(firstSave.skippedUnchanged)
        XCTAssertEqual(firstSave.generation, 1)
        XCTAssertEqual(firstSave.upsertedRows, 20_000)
        XCTAssertEqual(firstSave.sweptRows, 0)
        XCTAssertEqual(store.count(), 20_000)

        let (loaded, loadMs) = timed("20k.load") {
            store.load()
        }
        XCTAssertEqual(loaded.count, 20_000)
        XCTAssertEqual(loaded.first, ordered.first)
        XCTAssertEqual(loaded.last, ordered.last)
        XCTAssertEqual(loaded, ordered)

        let plan = store.timelineLoadQueryPlan()
        XCTAssertTrue(plan.contains("idx_photos_timeline"), "20k ordered load must ride the timeline index; plan: \(plan)")
        XCTAssertFalse(plan.uppercased().contains("TEMP B-TREE"), "20k load must not sort via temp b-tree; plan: \(plan)")

        let (skipSave, skipMs) = timed("20k.unchangedSkip") {
            store.save(items)
        }
        XCTAssertTrue(skipSave.succeeded)
        XCTAssertTrue(skipSave.skippedUnchanged)
        XCTAssertEqual(skipSave.generation, 1)
        XCTAssertEqual(skipSave.upsertedRows, 0)
        XCTAssertEqual(skipSave.sweptRows, 0)

        let additions = (20_000 ..< 20_025).map { makeSyntheticItem($0, tagsOverride: [.favorites]) }
        let changedItems = Array(items.dropFirst(100)) + additions
        let (changedSave, changedMs) = timed("20k.changedUpsert") {
            store.save(changedItems)
        }
        XCTAssertTrue(changedSave.succeeded)
        XCTAssertFalse(changedSave.skippedUnchanged)
        XCTAssertEqual(changedSave.generation, 2)
        XCTAssertEqual(changedSave.upsertedRows, 19_925)
        XCTAssertEqual(changedSave.sweptRows, 100)
        XCTAssertEqual(store.count(), 19_925)

        let (changedLoaded, changedLoadMs) = timed("20k.changedLoad") {
            store.load()
        }
        XCTAssertEqual(changedLoaded.count, 19_925)
        XCTAssertEqual(changedLoaded, changedItems.sorted(by: TimelineOrder.areInIncreasingOrder))

        print(
            "[DBMicroPerf] 20k.summary initialSaveMs=\(String(format: "%.2f", firstSaveMs)) " +
            "loadMs=\(String(format: "%.2f", loadMs)) " +
            "skipMs=\(String(format: "%.2f", skipMs)) " +
            "changedSaveMs=\(String(format: "%.2f", changedMs)) " +
            "changedLoadMs=\(String(format: "%.2f", changedLoadMs))"
        )
        store.close()
    }

    // MARK: - 8. Purge coverage

    func testPurgeAccountDataRemovesLibraryDatabaseAndSidecars() throws {
        let base = try makeTempDir()
        let accountDir = LibraryDatabaseLocation.prepareAccountDirectory(uid: uid, in: base)

        // Backup exclusion: the store is re-derivable server metadata.
        let resourceValues = try accountDir.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(resourceValues.isExcludedFromBackup, true)

        let store = try XCTUnwrap(TimelineMetadataStore(url: LibraryDatabaseLocation.databaseURL(uid: uid, in: base)))
        store.save([makeItem(node: "n", t: 1)])
        // WAL mode leaves sidecars next to the main file while the connection is open.
        XCTAssertTrue(FileManager.default.fileExists(atPath: LibraryDatabaseLocation.databaseURL(uid: uid, in: base).path))
        store.close()

        XCTAssertTrue(LibraryDatabaseLocation.purgeAccountData(uid: uid, in: base))
        XCTAssertFalse(FileManager.default.fileExists(atPath: accountDir.path), "whole per-account directory must be gone")
        // Another account's directory survives.
        LibraryDatabaseLocation.prepareAccountDirectory(uid: "OTHER", in: base)
        LibraryDatabaseLocation.purgeAccountData(uid: uid, in: base)
        XCTAssertTrue(FileManager.default.fileExists(atPath: LibraryDatabaseLocation.accountDirectory(uid: "OTHER", in: base).path))
    }

    func testLegacyTimelinePurgeRemovesOnlyTimelineV3Files() throws {
        let dir = try makeTempDir()
        for name in SDKMetadataStore.legacyTimelineFileNames(uid: uid) + ["entities.sqlite", "entities.sqlite-wal"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }

        let removed = SDKMetadataStore.purgeLegacyTimelineStore(in: dir, uid: uid)

        XCTAssertEqual(removed, 3, "timeline-v3 main + wal + shm")
        for name in SDKMetadataStore.legacyTimelineFileNames(uid: uid) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        }
        // The SDK's entity store must survive the sign-in legacy cleanup.
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("entities.sqlite").path))
    }

    /// Simulated sign-out: after the two metadata purges (SDK dir + library dir) run — exactly
    /// what `DriveSDKBridge.purgeMetadata` does — NO app-owned account file may survive. A new
    /// store file added without purge coverage fails this walk.
    func testSimulatedSignOutLeavesNoAccountOwnedMetadataFiles() throws {
        let base = try makeTempDir()      // stands in for Application Support
        let sdkDir = try makeTempDir()    // stands in for Caches/ProtonPhotos/sdk

        // Real library store with data (creates library-v1.sqlite + WAL sidecars).
        LibraryDatabaseLocation.prepareAccountDirectory(uid: uid, in: base)
        let store = try XCTUnwrap(TimelineMetadataStore(url: LibraryDatabaseLocation.databaseURL(uid: uid, in: base)))
        store.save([makeItem(node: "n", t: 1, tags: [.videos], burst: ["m"])])
        store.close()
        // SDK-side metadata files, including what an older build may have left behind.
        for name in SDKMetadataStore.metadataFileNames(uid: uid) {
            try Data("x".utf8).write(to: sdkDir.appendingPathComponent(name))
        }

        SDKMetadataStore.purgeMetadata(in: sdkDir, uid: uid)
        LibraryDatabaseLocation.purgeAccountData(uid: uid, in: base)

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: LibraryDatabaseLocation.accountDirectory(uid: uid, in: base).path),
            "library account directory orphaned after sign-out"
        )
        let sdkLeftovers = try FileManager.default.contentsOfDirectory(atPath: sdkDir.path)
        XCTAssertTrue(sdkLeftovers.isEmpty, "orphaned after sign-out: \(sdkLeftovers)")
        let baseLeftovers = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        XCTAssertFalse(baseLeftovers.contains { $0.contains(uid) }, "account-tied files under base: \(baseLeftovers)")
    }

    func testOrphanedLegacyTimelineSweepIgnoresOtherStores() throws {
        let dir = try makeTempDir()
        // Legacy formats from THREE different accounts — the wild state observed after the v1
        // reset shipped: the uid-scoped sign-in cleanup missed accounts that never sign in again.
        let legacy = [
            "timeline-v3-\(uid).sqlite", "timeline-v3-\(uid).sqlite-wal",
            "timeline-v3-OTHER.sqlite", "timeline-v3-OTHER.sqlite-shm",
            "timeline-v2-ANCIENT.json",
        ]
        let bystanders = ["entities.sqlite", "entities.sqlite-wal", "account-users-\(uid).enc"]
        for name in legacy + bystanders { try Data("x".utf8).write(to: dir.appendingPathComponent(name)) }

        let removed = SDKMetadataStore.purgeOrphanedLegacyTimelineStores(in: dir)

        XCTAssertEqual(removed, legacy.count, "every superseded timeline file goes, any account")
        for name in legacy {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        }
        for name in bystanders {
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path), "\(name) must survive")
        }
    }

    // MARK: - 9. Dimensions (photos.w/h)

    private func dims(_ w: Int, _ h: Int) throws -> PhotoPixelDimensions {
        try XCTUnwrap(PhotoPixelDimensions(width: w, height: h))
    }

    func testDimensionsRoundTripAndSurviveReopen() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        let a = makeItem(node: "a", t: 100)
        let b = makeItem(node: "b", t: 200)
        store.save([a, b])

        let size = try dims(320, 240)
        let result = store.updateDimensions([a.uid: size])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.updatedRows, 1)

        // On disk as real columns; undimensioned rows stay NULL (absent from the bulk load).
        XCTAssertEqual(rawRows(url, "SELECT w, h FROM photos WHERE node='a';"), [["320", "240"]])
        XCTAssertEqual(rawRows(url, "SELECT w, h FROM photos WHERE node='b';"), [["NULL", "NULL"]])
        XCTAssertEqual(store.loadDimensions(), [a.uid: size])

        store.close()
        let reopened = try XCTUnwrap(TimelineMetadataStore(url: url))
        XCTAssertEqual(reopened.loadDimensions(), [a.uid: size], "dimensions must survive reopen")
        reopened.close()
    }

    func testTimelineRefreshDoesNotClobberLearnedDimensions() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)
        let a = makeItem(node: "a", t: 100)
        let b = makeItem(node: "b", t: 200)
        store.save([a, b])
        store.updateDimensions([a.uid: try dims(320, 240)])

        // A CHANGED refresh upserts every row (gen bump) — w/h must survive because the timeline
        // upsert deliberately omits them.
        let changed = store.save([a, b, makeItem(node: "c", t: 300)])
        XCTAssertFalse(changed.skippedUnchanged)
        XCTAssertEqual(store.loadDimensions(), [a.uid: try dims(320, 240)])

        // An UNCHANGED refresh short-circuits — dimensions are not part of the timeline digest,
        // so recording them must not break the no-op skip.
        store.updateDimensions([b.uid: try dims(100, 100)])
        let skipped = store.save([a, b, makeItem(node: "c", t: 300)])
        XCTAssertTrue(skipped.skippedUnchanged, "dimension updates must not invalidate the save digest")
        XCTAssertEqual(store.loadDimensions().count, 2)
        store.close()
    }

    func testDimensionUpdateIsNoOpWhenUnchangedOrAlreadyLearned() throws {
        let dir = try makeTempDir()
        let (store, url) = try makeStore(in: dir)
        let a = makeItem(node: "a", t: 100)
        store.save([a])

        XCTAssertEqual(store.updateDimensions([a.uid: try dims(320, 240)]).updatedRows, 1)
        // Same values again → zero writes.
        XCTAssertEqual(store.updateDimensions([a.uid: try dims(320, 240)]).updatedRows, 0)
        // DIFFERENT values in default fill mode → still zero writes (first-seen-wins, so a late
        // thumbnail decode can never clobber previously learned dimensions).
        XCTAssertEqual(store.updateDimensions([a.uid: try dims(999, 111)]).updatedRows, 0)
        XCTAssertEqual(rawRows(url, "SELECT w, h FROM photos WHERE node='a';"), [["320", "240"]])
        store.close()
    }

    func testOverwriteModeReplacesOnlyChangedValues() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)
        let a = makeItem(node: "a", t: 100)
        let b = makeItem(node: "b", t: 200)
        store.save([a, b])
        store.updateDimensions([a.uid: try dims(320, 240), b.uid: try dims(100, 100)])

        // Future true-dimension writer: upgrades a (differs), skips b (identical values).
        let result = store.updateDimensions(
            [a.uid: try dims(4032, 3024), b.uid: try dims(100, 100)],
            overwrite: true
        )
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.updatedRows, 1)
        XCTAssertEqual(store.loadDimensions(), [a.uid: try dims(4032, 3024), b.uid: try dims(100, 100)])
        store.close()
    }

    func testDimensionUpdateIgnoresUnknownRows() throws {
        let dir = try makeTempDir()
        let (store, _) = try makeStore(in: dir)
        store.save([makeItem(node: "a", t: 100)])

        let unknown = PhotoUID(volumeID: "vol1", nodeID: "never-enumerated")
        let result = store.updateDimensions([unknown: try dims(320, 240)])
        XCTAssertTrue(result.succeeded)
        XCTAssertEqual(result.updatedRows, 0, "dimension updates must never invent photo rows")
        XCTAssertEqual(store.count(), 1)
        XCTAssertTrue(store.loadDimensions().isEmpty)
        store.close()
    }
}
