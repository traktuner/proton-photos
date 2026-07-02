import Foundation
import CryptoKit
import SQLite3

// MARK: - Timeline ordering

/// The canonical timeline total order: `(captureTime, volumeID, nodeID)` ascending. This is the
/// SAME order the database index `idx_photos_timeline(t, vol, node)` produces, so in-memory sorts,
/// persisted rows, and grid identity agree deterministically across launches, devices, and
/// platforms. String keys compare as UTF-8 bytes (SQLite's BINARY collation), and capture times
/// compare in the `timeIntervalSince1970` projection that is actually stored in the `t` column -
/// never diverge from either, or equal-time rows can silently swap grid positions between runs.
public enum TimelineOrder {
    public static func areInIncreasingOrder(_ a: PhotoItem, _ b: PhotoItem) -> Bool {
        let ta = a.captureTime.timeIntervalSince1970
        let tb = b.captureTime.timeIntervalSince1970
        if ta != tb { return ta < tb }
        let vol = compareUTF8(a.uid.volumeID, b.uid.volumeID)
        if vol != 0 { return vol < 0 }
        return compareUTF8(a.uid.nodeID, b.uid.nodeID) < 0
    }

    /// memcmp-style UTF-8 byte comparison, matching SQLite's BINARY TEXT collation. Swift's
    /// `String <` is Unicode-canonical and could disagree on non-ASCII input.
    private static func compareUTF8(_ a: String, _ b: String) -> Int {
        if a.utf8.lexicographicallyPrecedes(b.utf8) { return -1 }
        if b.utf8.lexicographicallyPrecedes(a.utf8) { return 1 }
        return 0
    }
}

// MARK: - Platform policy

/// SQLite tuning injected by the platform adapter - Core ships only a conservative cross-platform
/// default. macOS may raise mmap/cache generously; iOS/iPadOS must stay small: mmap I/O errors
/// surface as SIGBUS (not `SQLITE_IOERR`, see sqlite.org/mmap.html) and mapped pages count against
/// the jetsam budget, so the desktop numbers must never become Core defaults (same rule as
/// `GridTextureBudget`).
public struct LibraryDatabasePolicy: Sendable, Equatable {
    /// `PRAGMA mmap_size` in bytes. 0 disables memory-mapped I/O.
    public let mmapBytes: Int
    /// `PRAGMA cache_size` page-cache budget in KiB (applied as a negative pragma value).
    public let cacheSizeKiB: Int
    /// `PRAGMA busy_timeout` in milliseconds.
    public let busyTimeoutMs: Int
    /// Upper bound SQLite should keep for the WAL sidecar after checkpoints.
    public let journalSizeLimitBytes: Int
    /// Successful saves touching at least this many rows trigger a truncating WAL checkpoint.
    public let walCheckpointRowThreshold: Int

    public init(
        mmapBytes: Int,
        cacheSizeKiB: Int,
        busyTimeoutMs: Int,
        journalSizeLimitBytes: Int = 16 * 1024 * 1024,
        walCheckpointRowThreshold: Int = 10_000
    ) {
        self.mmapBytes = mmapBytes
        self.cacheSizeKiB = cacheSizeKiB
        self.busyTimeoutMs = busyTimeoutMs
        self.journalSizeLimitBytes = max(0, journalSizeLimitBytes)
        self.walCheckpointRowThreshold = max(0, walCheckpointRowThreshold)
    }

    /// Safe on the lowest supported iPhone/iPad class; platform adapters opt UP from here.
    public static let conservative = LibraryDatabasePolicy(mmapBytes: 0, cacheSizeKiB: 2_048, busyTimeoutMs: 3_000)
}

// MARK: - On-disk location

/// Path policy for the app-owned per-account library database:
/// `Application Support/ProtonPhotos/<uid>/library-v1.sqlite`. Application Support (not Caches -
/// iOS may purge Caches under storage pressure) with backup exclusion (the contents are
/// re-derivable from the server). The whole `<uid>` directory is account-scoped, so sign-out purge
/// removes the directory wholesale - any future side database added next to `library-v1.sqlite`
/// is automatically covered.
public enum LibraryDatabaseLocation {
    public static let databaseFileName = "library-v1.sqlite"

    /// Main file plus the WAL sidecars - the three must be treated as one unit for purge/backup.
    public static func databaseFileNames() -> [String] {
        [databaseFileName, databaseFileName + "-wal", databaseFileName + "-shm"]
    }

    public static func defaultBaseDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }

    public static func accountDirectory(uid: String, in base: URL = defaultBaseDirectory()) -> URL {
        base.appendingPathComponent("ProtonPhotos", isDirectory: true)
            .appendingPathComponent(uid, isDirectory: true)
    }

    public static func databaseURL(uid: String, in base: URL = defaultBaseDirectory()) -> URL {
        accountDirectory(uid: uid, in: base).appendingPathComponent(databaseFileName)
    }

    /// Creates the account directory and marks it backup-excluded (re-derivable server data).
    @discardableResult
    public static func prepareAccountDirectory(uid: String, in base: URL = defaultBaseDirectory()) -> URL {
        var directory = accountDirectory(uid: uid, in: base)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        return directory
    }

    /// Sign-out / master-reset: removes the whole per-account library directory (database, WAL
    /// sidecars, and anything a future feature parked next to them). Returns whether the
    /// directory existed.
    @discardableResult
    public static func purgeAccountData(uid: String, in base: URL = defaultBaseDirectory()) -> Bool {
        let directory = accountDirectory(uid: uid, in: base)
        guard FileManager.default.fileExists(atPath: directory.path) else { return false }
        return (try? FileManager.default.removeItem(at: directory)) != nil
    }
}

// MARK: - Save result

/// Structural outcome of a `TimelineMetadataStore.updateDimensions` batch.
public struct TimelineDimensionUpdateResult: Sendable, Equatable {
    /// Rows actually written (unchanged / already-dimensioned / unknown rows count as 0).
    public let updatedRows: Int
    /// False when the transaction failed and was rolled back.
    public let succeeded: Bool
}

/// Structural outcome of a `TimelineMetadataStore.save` - tests and `[DBHealth]` logging assert on
/// this instead of on flaky timings.
public struct TimelineSaveResult: Sendable, Equatable {
    /// The incoming timeline's digest matched the persisted one - nothing was written.
    public let skippedUnchanged: Bool
    /// Refresh generation stamped on this save (unchanged when skipped).
    public let generation: Int
    /// Rows actually written by the upsert - inserts plus real content updates, NOT unchanged
    /// survivors (0 when skipped). This is the O(changes) signal the guard tests assert on.
    public let upsertedRows: Int
    /// Rows removed by the anti-join sweep because they vanished from this full enumeration.
    public let sweptRows: Int
    /// False when the transaction failed and was rolled back.
    public let succeeded: Bool
}

// MARK: - Store

/// App-owned SQLite timeline metadata store (schema v1). UI-free, SDK-free, platform-universal:
/// raw SQLite C API over `Foundation` + Core value types only, with platform tuning injected via
/// `LibraryDatabasePolicy`.
///
/// Schema rules (see docs + PERF_DB_METAL_AUDIT_2026-07-01.md §5):
/// - `photos` is the hot path and carries ONLY what the timeline needs; feature data lives in
///   feature-owned tables (`photo_tags`, `burst_members`) - never serialized blobs.
/// - Timeline order is `(t, vol, node)` everywhere; `idx_photos_timeline` serves the ordered scan.
/// - Saves are O(changes): a digest no-op short-circuit skips unchanged refreshes; a changed
///   refresh upserts only rows whose content actually differs and anti-joins the enumerated key
///   set to sweep vanished rows - never a full-table rewrite.
/// - `schema_info` versions each feature's tables explicitly; an unknown newer version fails
///   closed by resetting the (re-derivable) database rather than guessing.
///
/// Not `Sendable` by design: single-owner, held inside one actor (the app's SDK bridge).
public final class TimelineMetadataStore {
    private var db: OpaquePointer?
    private let policy: LibraryDatabasePolicy
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)   // SQLITE_TRANSIENT

    /// Feature schema versions this build understands. Bump a feature's number alongside its
    /// migration; an on-disk version above the supported one resets the store (fail closed).
    private static let supportedFeatureVersions: [String: Int] = [
        "timeline": 1,
        "photo_tags": 1,
        "burst_members": 1,
    ]

    private static let metaDigestKey = "timeline.digest"
    private static let metaGenerationKey = "timeline.generation"

    /// Name of the connection-scoped TEMP scratch table that holds the current enumeration's keys
    /// for the incremental save's anti-join sweep (see `ensureIncomingKeyTable`).
    private static let incomingKeyTable = "save_incoming_keys"

    /// Single source of truth for the ordered hot-path scan - the query-plan guard test explains
    /// exactly this statement, so plan and load can never drift apart.
    private static let timelineLoadSQL =
        "SELECT vol, node, t, mime, live, relvid, dur FROM photos ORDER BY t, vol, node;"

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative) {
        let setupStart = Date()
        guard let handle = Self.openVerified(url: url, policy: policy) else { return nil }
        db = handle
        self.policy = policy
        PhotoDiagnostics.shared.recordDBQuery(
            queryName: "library.sqlite.setup",
            durationMs: Date().timeIntervalSince(setupStart) * 1000,
            rowsReturned: 0
        )
    }

    deinit { close() }

    /// Runs `PRAGMA optimize` (cheap, recommended by SQLite on connection close) and closes.
    public func close() {
        guard db != nil else { return }
        sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
        sqlite3_close(db)
        db = nil
    }

    // MARK: Open / schema

    private static func openVerified(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        if let handle = openOnce(url: url, policy: policy) { return handle }
        // Incompatible (from-the-future or corrupt) store: it is re-derivable server metadata, so
        // fail closed by resetting the files and building schema v1 fresh.
        destroyDatabaseFiles(at: url)
        return openOnce(url: url, policy: policy)
    }

    private static func openOnce(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA busy_timeout=\(policy.busyTimeoutMs);", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA cache_size=-\(max(0, policy.cacheSizeKiB));", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA mmap_size=\(max(0, policy.mmapBytes));", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA journal_size_limit=\(policy.journalSizeLimitBytes);", nil, nil, nil)

        let schema = """
        CREATE TABLE IF NOT EXISTS schema_info(feature TEXT PRIMARY KEY, version INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS photos(
          vol TEXT NOT NULL,
          node TEXT NOT NULL,
          t REAL NOT NULL,
          mime TEXT NOT NULL DEFAULT 'image/jpeg',
          live INTEGER NOT NULL DEFAULT 0,
          relvid TEXT,
          w INTEGER,
          h INTEGER,
          dur REAL,
          PRIMARY KEY (vol, node)
        );
        CREATE INDEX IF NOT EXISTS idx_photos_timeline ON photos(t, vol, node);
        CREATE TABLE IF NOT EXISTS photo_tags(
          vol TEXT NOT NULL,
          node TEXT NOT NULL,
          tag INTEGER NOT NULL,
          PRIMARY KEY (tag, vol, node)
        );
        CREATE TABLE IF NOT EXISTS burst_members(
          anchor_vol TEXT NOT NULL,
          anchor_node TEXT NOT NULL,
          member_node TEXT NOT NULL,
          seq INTEGER NOT NULL,
          PRIMARY KEY (anchor_vol, anchor_node, seq)
        );
        CREATE TABLE IF NOT EXISTS store_meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK,
              verifyAndStampFeatureVersions(handle) else {
            sqlite3_close(handle)
            return nil
        }
        return handle
    }

    /// True when every known feature's on-disk version is at most the supported one (stamping
    /// absent rows at the current version); false - reset required - when the store comes from a
    /// newer build.
    private static func verifyAndStampFeatureVersions(_ handle: OpaquePointer?) -> Bool {
        var onDisk: [String: Int] = [:]
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT feature, version FROM schema_info;", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let feature = sqlite3_column_text(stmt, 0) {
                onDisk[String(cString: feature)] = Int(sqlite3_column_int(stmt, 1))
            }
        }
        sqlite3_finalize(stmt)

        for (feature, supported) in supportedFeatureVersions {
            if let version = onDisk[feature], version > supported { return false }
        }

        var upsert: OpaquePointer?
        guard sqlite3_prepare_v2(
            handle,
            "INSERT INTO schema_info(feature, version) VALUES(?, ?) ON CONFLICT(feature) DO UPDATE SET version=excluded.version;",
            -1, &upsert, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(upsert) }
        for (feature, version) in supportedFeatureVersions {
            sqlite3_reset(upsert)
            sqlite3_bind_text(upsert, 1, feature, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(upsert, 2, Int32(version))
            guard sqlite3_step(upsert) == SQLITE_DONE else { return false }
        }
        return true
    }

    private static func destroyDatabaseFiles(at url: URL) {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    // MARK: Load

    /// Cheap indexed count for the cache-status surface.
    public func count() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM photos;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Ordered timeline load. The hot path is one indexed scan of `photos`; tags and burst
    /// membership are reconstructed from their feature tables with one full pass each (dictionary
    /// join in memory - no per-row queries, no blob decoding).
    public func load() -> [PhotoItem] {
        PhotoPerformanceSignposts.database.interval("db.load") {
            loadInstrumented()
        }
    }

    private func loadInstrumented() -> [PhotoItem] {
        let start = Date()
        let tags = loadTags()
        let bursts = loadBurstMembers()

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, Self.timelineLoadSQL, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var items: [PhotoItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let volC = sqlite3_column_text(stmt, 0), let nodeC = sqlite3_column_text(stmt, 1) else { continue }
            let uid = PhotoUID(volumeID: String(cString: volC), nodeID: String(cString: nodeC))
            let mime = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "image/jpeg"
            let relvid = sqlite3_column_text(stmt, 5).map { String(cString: $0) }
            let dur = sqlite3_column_type(stmt, 6) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 6)
            items.append(PhotoItem(
                uid: uid,
                captureTime: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                mediaType: mime,
                isLivePhoto: sqlite3_column_int(stmt, 4) != 0,
                relatedVideoID: relvid,
                durationSeconds: dur,
                tags: tags[uid] ?? [],
                burstMemberIDs: bursts[uid] ?? []
            ))
        }
        PhotoDiagnostics.shared.recordDBQuery(
            queryName: "timeline.load.orderedByTimelineIndex",
            durationMs: Date().timeIntervalSince(start) * 1000,
            rowsReturned: items.count
        )
        return items
    }

    private func loadTags() -> [PhotoUID: Set<PhotoTag>] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT vol, node, tag FROM photo_tags;", -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        var result: [PhotoUID: Set<PhotoTag>] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let volC = sqlite3_column_text(stmt, 0), let nodeC = sqlite3_column_text(stmt, 1),
                  let tag = PhotoTag(rawValue: Int(sqlite3_column_int(stmt, 2))) else { continue }
            result[PhotoUID(volumeID: String(cString: volC), nodeID: String(cString: nodeC)), default: []].insert(tag)
        }
        return result
    }

    private func loadBurstMembers() -> [PhotoUID: [String]] {
        var stmt: OpaquePointer?
        let sql = "SELECT anchor_vol, anchor_node, member_node FROM burst_members ORDER BY anchor_vol, anchor_node, seq;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var result: [PhotoUID: [String]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let volC = sqlite3_column_text(stmt, 0), let nodeC = sqlite3_column_text(stmt, 1),
                  let memberC = sqlite3_column_text(stmt, 2) else { continue }
            result[PhotoUID(volumeID: String(cString: volC), nodeID: String(cString: nodeC)), default: []]
                .append(String(cString: memberC))
        }
        return result
    }

    // MARK: Save

    /// Incremental, O(changes) save of a FULL timeline enumeration.
    ///
    /// 1. No-op short-circuit: a deterministic digest of the (canonically ordered) input is
    ///    compared against the persisted one - an unchanged refresh writes nothing at all.
    /// 2. Otherwise each incoming row is upserted with a NULL-safe change guard, so only rows whose
    ///    persisted fields actually differ are written; unchanged survivors are left untouched (no
    ///    page churn, no WAL frames). Rows the enumeration no longer contains are removed by an
    ///    anti-join against the recorded key set. There is deliberately no full-table rewrite.
    ///
    /// The `generation` counter still advances once per changed save (diagnostics only - it no
    /// longer stamps rows). `w`/`h` (learned dimensions) are never referenced by the upsert, so a
    /// future dimension writer's values survive every refresh.
    @discardableResult
    public func save(_ items: [PhotoItem]) -> TimelineSaveResult {
        PhotoPerformanceSignposts.database.interval("db.save") {
            saveInstrumented(items)
        }
    }

    @discardableResult
    private func saveInstrumented(_ items: [PhotoItem]) -> TimelineSaveResult {
        let start = Date()
        // Canonical order: identical input sets digest identically regardless of arrival order,
        // and rows persist in exactly the order load() returns them. The enumeration feeding save
        // is normally already in timeline order, so an O(n) precheck skips a redundant full sort.
        let ordered = Self.isTimelineOrdered(items) ? items : items.sorted(by: TimelineOrder.areInIncreasingOrder)
        let digest = Self.timelineDigest(of: ordered)
        let generation = readMetaInt(Self.metaGenerationKey) ?? 0

        if digest == readMeta(Self.metaDigestKey) {
            PhotoDiagnostics.shared.recordDBQuery(
                queryName: "timeline.save.skippedUnchanged",
                durationMs: Date().timeIntervalSince(start) * 1000,
                rowsReturned: 0
            )
            return TimelineSaveResult(
                skippedUnchanged: true, generation: generation, upsertedRows: 0, sweptRows: 0, succeeded: true
            )
        }

        let newGeneration = generation + 1
        // The anti-join sweep reads from a connection-scoped scratch key set; make sure it exists
        // before opening the write transaction (its DDL lives in the TEMP store, off the WAL).
        guard ensureIncomingKeyTable(),
              sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            return TimelineSaveResult(
                skippedUnchanged: false, generation: generation, upsertedRows: 0, sweptRows: 0, succeeded: false
            )
        }

        var upserted = 0
        var swept = 0
        let ok: Bool = {
            // Record every incoming key, then upsert only the rows whose persisted content actually
            // changed (unchanged rows write nothing - no page churn, no WAL frames).
            guard sqlite3_exec(db, "DELETE FROM \(Self.incomingKeyTable);", nil, nil, nil) == SQLITE_OK,
                  upsertChangedPhotos(ordered, upserted: &upserted) else { return false }
            // Sweep: delete exactly the rows this full enumeration no longer contains (an anti-join
            // against the recorded key set), instead of rewriting every surviving row per refresh.
            guard sqlite3_exec(
                db,
                "DELETE FROM photos WHERE NOT EXISTS " +
                "(SELECT 1 FROM \(Self.incomingKeyTable) k WHERE k.vol = photos.vol AND k.node = photos.node);",
                nil, nil, nil
            ) == SQLITE_OK else { return false }
            swept = Int(sqlite3_changes(db))
            guard rewriteTags(ordered), rewriteBurstMembers(ordered) else { return false }
            guard writeMeta(Self.metaDigestKey, digest),
                  writeMeta(Self.metaGenerationKey, String(newGeneration)) else { return false }
            return true
        }()

        guard ok, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            PhotoDiagnostics.shared.recordDBQuery(
                queryName: "timeline.save.failedRolledBack",
                durationMs: Date().timeIntervalSince(start) * 1000,
                rowsReturned: 0
            )
            return TimelineSaveResult(
                skippedUnchanged: false, generation: generation, upsertedRows: 0, sweptRows: 0, succeeded: false
            )
        }

        PhotoDiagnostics.shared.recordDBQuery(
            queryName: "timeline.save.incrementalUpsert",
            durationMs: Date().timeIntervalSince(start) * 1000,
            rowsReturned: upserted
        )
        checkpointWALIfNeeded(rowWrites: upserted + swept)
        return TimelineSaveResult(
            skippedUnchanged: false, generation: newGeneration, upsertedRows: upserted, sweptRows: swept, succeeded: true
        )
    }

    private func checkpointWALIfNeeded(rowWrites: Int) {
        guard policy.walCheckpointRowThreshold > 0,
              rowWrites >= policy.walCheckpointRowThreshold else { return }
        let start = Date()
        let ok = sqlite3_exec(db, "PRAGMA wal_checkpoint(TRUNCATE);", nil, nil, nil) == SQLITE_OK
        PhotoDiagnostics.shared.recordDBQuery(
            queryName: ok ? "timeline.save.walCheckpoint" : "timeline.save.walCheckpointFailed",
            durationMs: Date().timeIntervalSince(start) * 1000,
            rowsReturned: rowWrites
        )
    }

    /// Incremental upsert of the ordered enumeration. Two things happen per row: the `(vol, node)`
    /// key is recorded in the scratch set (for the anti-join sweep), and the row is upserted with a
    /// NULL-safe `IS NOT` change guard so a row whose persisted fields are unchanged writes nothing
    /// at all. `upserted` accumulates `sqlite3_changes` (0 for an unchanged row, 1 for an insert or
    /// a real update), so it reports rows *actually written*, not rows visited. `w`/`h` are never
    /// referenced, so a refresh never clobbers learned dimensions.
    private func upsertChangedPhotos(_ items: [PhotoItem], upserted: inout Int) -> Bool {
        var keyStmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "INSERT OR IGNORE INTO \(Self.incomingKeyTable)(vol, node) VALUES(?, ?);", -1, &keyStmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(keyStmt) }

        var stmt: OpaquePointer?
        let sql = """
        INSERT INTO photos(vol, node, t, mime, live, relvid, dur) VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(vol, node) DO UPDATE SET
          t=excluded.t, mime=excluded.mime, live=excluded.live, relvid=excluded.relvid, dur=excluded.dur
        WHERE t IS NOT excluded.t OR mime IS NOT excluded.mime OR live IS NOT excluded.live
           OR relvid IS NOT excluded.relvid OR dur IS NOT excluded.dur;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for item in items {
            sqlite3_reset(keyStmt)
            sqlite3_bind_text(keyStmt, 1, item.uid.volumeID, -1, transient)
            sqlite3_bind_text(keyStmt, 2, item.uid.nodeID, -1, transient)
            guard sqlite3_step(keyStmt) == SQLITE_DONE else { return false }

            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, item.uid.volumeID, -1, transient)
            sqlite3_bind_text(stmt, 2, item.uid.nodeID, -1, transient)
            sqlite3_bind_double(stmt, 3, item.captureTime.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 4, item.mediaType, -1, transient)
            sqlite3_bind_int(stmt, 5, item.isLivePhoto ? 1 : 0)
            if let rel = item.relatedVideoID { sqlite3_bind_text(stmt, 6, rel, -1, transient) }
            else { sqlite3_bind_null(stmt, 6) }
            if let dur = item.durationSeconds { sqlite3_bind_double(stmt, 7, dur) }
            else { sqlite3_bind_null(stmt, 7) }
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            upserted += Int(sqlite3_changes(db))
        }
        return true
    }

    /// Connection-scoped scratch table holding the current enumeration's `(vol, node)` keys - it
    /// backs the incremental save's anti-join sweep. It lives in SQLite's TEMP store, so filling it
    /// never appends to the durable WAL; `WITHOUT ROWID` + the composite PK give the anti-join a
    /// covering index and make duplicate keys in one enumeration a harmless no-op (`INSERT OR IGNORE`).
    private func ensureIncomingKeyTable() -> Bool {
        sqlite3_exec(
            db,
            "CREATE TEMP TABLE IF NOT EXISTS \(Self.incomingKeyTable)" +
            "(vol TEXT NOT NULL, node TEXT NOT NULL, PRIMARY KEY(vol, node)) WITHOUT ROWID;",
            nil, nil, nil
        ) == SQLITE_OK
    }

    /// True when `items` is already in canonical `(t, vol, node)` order - the common case, because
    /// the enumeration feeding `save` is pre-sorted by the bridge. Lets `save` skip a redundant
    /// O(n log n) resort via an O(n) scan; any out-of-order input falls back to a full sort.
    private static func isTimelineOrdered(_ items: [PhotoItem]) -> Bool {
        var index = 1
        while index < items.count {
            if TimelineOrder.areInIncreasingOrder(items[index], items[index - 1]) { return false }
            index += 1
        }
        return true
    }

    /// Feature tables are rewritten wholesale inside the save transaction. Their row counts scale
    /// with tagged/burst items (a small fraction of the library), not with library size - the
    /// digest short-circuit already spares the common unchanged refresh entirely.
    private func rewriteTags(_ items: [PhotoItem]) -> Bool {
        guard sqlite3_exec(db, "DELETE FROM photo_tags;", nil, nil, nil) == SQLITE_OK else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO photo_tags(vol, node, tag) VALUES(?,?,?);", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        for item in items where !item.tags.isEmpty {
            for tag in item.tags.map(\.rawValue).sorted() {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, item.uid.volumeID, -1, transient)
                sqlite3_bind_text(stmt, 2, item.uid.nodeID, -1, transient)
                sqlite3_bind_int(stmt, 3, Int32(tag))
                guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            }
        }
        return true
    }

    private func rewriteBurstMembers(_ items: [PhotoItem]) -> Bool {
        guard sqlite3_exec(db, "DELETE FROM burst_members;", nil, nil, nil) == SQLITE_OK else { return false }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO burst_members(anchor_vol, anchor_node, member_node, seq) VALUES(?,?,?,?);"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for item in items where !item.burstMemberIDs.isEmpty {
            for (seq, member) in item.burstMemberIDs.enumerated() {
                sqlite3_reset(stmt)
                sqlite3_bind_text(stmt, 1, item.uid.volumeID, -1, transient)
                sqlite3_bind_text(stmt, 2, item.uid.nodeID, -1, transient)
                sqlite3_bind_text(stmt, 3, member, -1, transient)
                sqlite3_bind_int(stmt, 4, Int32(seq))
                guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
            }
        }
        return true
    }

    // MARK: Dimensions

    /// Batched write of learned dimensions into `photos.w`/`photos.h`, independent of timeline
    /// saves: dimensions arrive from decode/metadata paths on their own schedule and are
    /// deliberately NOT part of the timeline digest, so recording them never invalidates the
    /// no-op save short-circuit - and a timeline refresh never touches `w`/`h` (its upsert omits
    /// them), so learned values survive every refresh.
    ///
    /// Default (`overwrite: false`) is first-seen-wins: only rows with NULL dimensions are
    /// filled. That keeps thumbnail-scale dimensions from clobbering true dimensions a future
    /// metadata writer may have stored. `overwrite: true` is that future writer's mode - it
    /// rewrites rows whose values actually differ (NULL-safe compare), so an unchanged batch is
    /// still a no-op. Rows for unknown `(vol, node)` keys are ignored, never invented.
    @discardableResult
    public func updateDimensions(
        _ batch: [PhotoUID: PhotoPixelDimensions],
        overwrite: Bool = false
    ) -> TimelineDimensionUpdateResult {
        guard !batch.isEmpty else { return TimelineDimensionUpdateResult(updatedRows: 0, succeeded: true) }
        let start = Date()
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            return TimelineDimensionUpdateResult(updatedRows: 0, succeeded: false)
        }
        // `IS NOT` is SQLite's NULL-safe inequality; the guards make every re-run a zero-write no-op.
        let sql = overwrite
            ? "UPDATE photos SET w=?1, h=?2 WHERE vol=?3 AND node=?4 AND (w IS NOT ?1 OR h IS NOT ?2);"
            : "UPDATE photos SET w=?1, h=?2 WHERE vol=?3 AND node=?4 AND w IS NULL AND h IS NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return TimelineDimensionUpdateResult(updatedRows: 0, succeeded: false)
        }
        defer { sqlite3_finalize(stmt) }

        var updated = 0
        for (uid, dimensions) in batch {
            sqlite3_reset(stmt)
            sqlite3_bind_int(stmt, 1, Int32(dimensions.width))
            sqlite3_bind_int(stmt, 2, Int32(dimensions.height))
            sqlite3_bind_text(stmt, 3, uid.volumeID, -1, transient)
            sqlite3_bind_text(stmt, 4, uid.nodeID, -1, transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return TimelineDimensionUpdateResult(updatedRows: 0, succeeded: false)
            }
            updated += Int(sqlite3_changes(db))
        }
        guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return TimelineDimensionUpdateResult(updatedRows: 0, succeeded: false)
        }
        PhotoDiagnostics.shared.recordDBQuery(
            queryName: "timeline.dimensions.update",
            durationMs: Date().timeIntervalSince(start) * 1000,
            rowsReturned: updated
        )
        return TimelineDimensionUpdateResult(updatedRows: updated, succeeded: true)
    }

    /// Bulk dictionary read of every known dimension - one pass, for grid/timeline planning to
    /// consume alongside `load()` instead of a separate aspect file. Rows without learned
    /// dimensions are simply absent.
    public func loadDimensions() -> [PhotoUID: PhotoPixelDimensions] {
        let start = Date()
        var stmt: OpaquePointer?
        let sql = "SELECT vol, node, w, h FROM photos WHERE w IS NOT NULL AND h IS NOT NULL;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        var result: [PhotoUID: PhotoPixelDimensions] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let volC = sqlite3_column_text(stmt, 0), let nodeC = sqlite3_column_text(stmt, 1),
                  let dimensions = PhotoPixelDimensions(
                      width: Int(sqlite3_column_int(stmt, 2)),
                      height: Int(sqlite3_column_int(stmt, 3))
                  ) else { continue }
            result[PhotoUID(volumeID: String(cString: volC), nodeID: String(cString: nodeC))] = dimensions
        }
        PhotoDiagnostics.shared.recordDBQuery(
            queryName: "timeline.dimensions.load",
            durationMs: Date().timeIntervalSince(start) * 1000,
            rowsReturned: result.count
        )
        return result
    }

    // MARK: Digest

    /// Deterministic SHA-256 over the canonically ordered rows' persisted fields. Doubles hash by
    /// exact bit pattern (little-endian) so the digest is identical across platforms; field and
    /// record separators keep the encoding unambiguous.
    private static func timelineDigest(of ordered: [PhotoItem]) -> String {
        var hasher = SHA256()
        func feed(_ string: String) {
            hasher.update(data: Data(string.utf8))
            hasher.update(data: Data([0x1F]))
        }
        func feed(_ double: Double) {
            withUnsafeBytes(of: double.bitPattern.littleEndian) { hasher.update(bufferPointer: $0) }
            hasher.update(data: Data([0x1F]))
        }
        for item in ordered {
            feed(item.uid.volumeID)
            feed(item.uid.nodeID)
            feed(item.captureTime.timeIntervalSince1970)
            feed(item.mediaType)
            feed(item.isLivePhoto ? "1" : "0")
            feed(item.relatedVideoID ?? "")
            if let dur = item.durationSeconds { feed(dur) } else { feed("") }
            feed(item.tags.map(\.rawValue).sorted().map(String.init).joined(separator: ","))
            feed(item.burstMemberIDs.joined(separator: ","))
            hasher.update(data: Data([0x1E]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: store_meta

    private func readMeta(_ key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM store_meta WHERE key = ?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let value = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: value)
    }

    private func readMetaInt(_ key: String) -> Int? {
        readMeta(key).flatMap(Int.init)
    }

    private func writeMeta(_ key: String, _ value: String) -> Bool {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO store_meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, transient)
        sqlite3_bind_text(stmt, 2, value, -1, transient)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    // MARK: Test seams (internal)

    /// EXPLAIN QUERY PLAN of the exact hot-path load statement - the guard test asserts it rides
    /// `idx_photos_timeline` with no temp b-tree. Internal: reachable via `@testable import`.
    func timelineLoadQueryPlan() -> String {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "EXPLAIN QUERY PLAN " + Self.timelineLoadSQL, -1, &stmt, nil) == SQLITE_OK else {
            return ""
        }
        defer { sqlite3_finalize(stmt) }
        var lines: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let detail = sqlite3_column_text(stmt, 3) { lines.append(String(cString: detail)) }
        }
        return lines.joined(separator: " | ")
    }

    /// On-disk `schema_info` rows. Internal test seam.
    func schemaInfoVersions() -> [String: Int] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT feature, version FROM schema_info;", -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        var result: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let feature = sqlite3_column_text(stmt, 0) {
                result[String(cString: feature)] = Int(sqlite3_column_int(stmt, 1))
            }
        }
        return result
    }
}
