import Foundation
import PhotosCore
import SQLite3

/// Persistent local photo-library catalog (`photo-library-catalog-v1.sqlite`). Like the other
/// backup stores this is a cache/index, not user data: a future/corrupt schema resets to empty and
/// costs only another local scan. One row per asset `localIdentifier`; resources ride in a single
/// JSON column so a new resource role never needs a migration.
public final class PhotoLibraryCatalogManifestStore: PhotoLibraryCatalogStore, @unchecked Sendable {
    public static let databaseFileName = "photo-library-catalog-v1.sqlite"

    private static let schemaVersion = 1
    private static let completedFullScanKey = "completed_full_scan"
    private var db: OpaquePointer?
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = Self.openVerified(url: url, policy: policy) else { return nil }
        db = handle
    }

    deinit { close() }

    public func close() {
        lock.withLock {
            guard db != nil else { return }
            sqlite3_exec(db, "PRAGMA optimize;", nil, nil, nil)
            sqlite3_close(db)
            db = nil
        }
    }

    public func entry(for localIdentifier: String) -> PhotoLibraryCatalogEntry? {
        lock.withLock { readEntry(localIdentifier) }
    }

    public func classify(_ entry: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange {
        lock.withLock { classify(existing: readEntry(entry.localIdentifier), incoming: entry) }
    }

    @discardableResult
    public func upsert(_ entry: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange {
        lock.withLock { writeEntry(entry) }
    }

    @discardableResult
    public func upsertBatch(_ entries: [PhotoLibraryCatalogEntry]) -> [PhotoLibraryCatalogChange] {
        guard !entries.isEmpty else { return [] }
        return lock.withLock {
            sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
            let changes = entries.map { writeEntry($0) }
            if sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            }
            return changes
        }
    }

    @discardableResult
    public func markRemoved(_ identifiers: [String], removedAt: Date) -> Int {
        let present = identifiers.filter { !$0.isEmpty }
        guard !present.isEmpty else { return 0 }
        return lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                UPDATE photo_catalog SET is_removed=1, removed_at=?
                WHERE local_id=? AND is_removed=0;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            var changed = 0
            sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
            for id in present {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_double(stmt, 1, removedAt.timeIntervalSince1970)
                bindText(stmt, 2, id)
                if sqlite3_step(stmt) == SQLITE_DONE { changed += Int(sqlite3_changes(db)) }
            }
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
            return changed
        }
    }

    @discardableResult
    public func sweepRemoved(notSeenAfter cutoff: Date, removedAt: Date) -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                UPDATE photo_catalog SET is_removed=1, removed_at=?
                WHERE is_removed=0 AND last_seen_at < ?;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, removedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    public func snapshot() -> PhotoLibraryCatalogSnapshot {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT is_removed, COUNT(*) FROM photo_catalog GROUP BY is_removed;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return PhotoLibraryCatalogSnapshot() }
            defer { sqlite3_finalize(stmt) }
            var snapshot = PhotoLibraryCatalogSnapshot()
            while sqlite3_step(stmt) == SQLITE_ROW {
                let removed = sqlite3_column_int(stmt, 0) != 0
                let count = Int(sqlite3_column_int(stmt, 1))
                snapshot.total += count
                if removed { snapshot.removed += count } else { snapshot.present += count }
            }
            return snapshot
        }
    }

    public func count() -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM photo_catalog;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    /// True only after a full-library scan finished successfully at least once. A PhotoKit
    /// persistent-change token can exist before our own catalog is complete; this marker prevents
    /// the first real backup pass from mistaking "changed since token" for "entire library known".
    public func hasCompletedFullScan() -> Bool {
        lock.withLock { readInfoValue(Self.completedFullScanKey) == 1 }
    }

    /// Called only after the full scan and its catalog writes finished without throwing/canceling.
    public func markFullScanCompleted() {
        lock.withLock { writeInfoValue(Self.completedFullScanKey, 1) }
    }

    // MARK: - Read/write helpers (must be called under `lock`)

    private func classify(existing: PhotoLibraryCatalogEntry?, incoming: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange {
        guard let existing else { return .inserted }
        if existing.isRemoved { return .changed }
        return existing.matchesContent(of: incoming) ? .unchanged : .changed
    }

    private func writeEntry(_ entry: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange {
        let existing = readEntry(entry.localIdentifier)
        let change = classify(existing: existing, incoming: entry)
        let resourcesJSON = (try? encoder.encode(entry.resources)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO photo_catalog(
              local_id, creation_date, modification_date, pixel_width, pixel_height,
              duration_seconds, media_kind, is_live_photo, resources_json,
              content_fingerprint, metadata_revision, first_seen_at, last_seen_at,
              is_removed, removed_at
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,0,NULL)
            ON CONFLICT(local_id) DO UPDATE SET
              creation_date=excluded.creation_date,
              modification_date=excluded.modification_date,
              pixel_width=excluded.pixel_width,
              pixel_height=excluded.pixel_height,
              duration_seconds=excluded.duration_seconds,
              media_kind=excluded.media_kind,
              is_live_photo=excluded.is_live_photo,
              resources_json=excluded.resources_json,
              content_fingerprint=excluded.content_fingerprint,
              metadata_revision=excluded.metadata_revision,
              last_seen_at=excluded.last_seen_at,
              is_removed=0,
              removed_at=NULL;
            """,
            -1, &stmt, nil
        ) == SQLITE_OK else { return change }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, entry.localIdentifier)
        bindNullableDate(stmt, 2, entry.creationDate)
        bindNullableDate(stmt, 3, entry.modificationDate)
        sqlite3_bind_int(stmt, 4, Int32(entry.pixelWidth))
        sqlite3_bind_int(stmt, 5, Int32(entry.pixelHeight))
        sqlite3_bind_double(stmt, 6, entry.durationSeconds)
        bindText(stmt, 7, entry.mediaKind.rawValue)
        sqlite3_bind_int(stmt, 8, entry.isLivePhoto ? 1 : 0)
        bindText(stmt, 9, resourcesJSON)
        sqlite3_bind_int64(stmt, 10, entry.contentFingerprint)
        sqlite3_bind_int64(stmt, 11, entry.metadataRevision)
        sqlite3_bind_double(stmt, 12, entry.firstSeenAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 13, entry.lastSeenAt.timeIntervalSince1970)
        _ = sqlite3_step(stmt)
        return change
    }

    private func readEntry(_ localIdentifier: String) -> PhotoLibraryCatalogEntry? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            SELECT creation_date, modification_date, pixel_width, pixel_height, duration_seconds,
                   media_kind, is_live_photo, resources_json, content_fingerprint, metadata_revision,
                   first_seen_at, last_seen_at, is_removed, removed_at
            FROM photo_catalog WHERE local_id=?;
            """,
            -1, &stmt, nil
        ) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, localIdentifier)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        let resources: [PhotoLibraryCatalogResource] = columnText(stmt, 7)
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? decoder.decode([PhotoLibraryCatalogResource].self, from: $0) } ?? []
        let mediaKind = columnText(stmt, 5).flatMap { PhotoLibraryCatalogMediaKind(rawValue: $0) } ?? .image
        return PhotoLibraryCatalogEntry(
            localIdentifier: localIdentifier,
            creationDate: columnDate(stmt, 0),
            modificationDate: columnDate(stmt, 1),
            pixelWidth: Int(sqlite3_column_int(stmt, 2)),
            pixelHeight: Int(sqlite3_column_int(stmt, 3)),
            durationSeconds: sqlite3_column_double(stmt, 4),
            mediaKind: mediaKind,
            isLivePhoto: sqlite3_column_int(stmt, 6) != 0,
            resources: resources,
            contentFingerprint: sqlite3_column_int64(stmt, 8),
            metadataRevision: sqlite3_column_int64(stmt, 9),
            firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10)),
            lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11)),
            isRemoved: sqlite3_column_int(stmt, 12) != 0,
            removedAt: columnDate(stmt, 13)
        )
    }

    private func readInfoValue(_ key: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM photo_catalog_info WHERE key=?;", -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func writeInfoValue(_ key: String, _ value: Int) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT INTO photo_catalog_info(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            -1, &stmt, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        sqlite3_bind_int(stmt, 2, Int32(value))
        _ = sqlite3_step(stmt)
    }

    // MARK: - Open / schema (mirrors the other backup stores)

    private static func openVerified(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        if let handle = openOnce(url: url, policy: policy) { return handle }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
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
        CREATE TABLE IF NOT EXISTS photo_catalog_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS photo_catalog(
          local_id            TEXT PRIMARY KEY,
          creation_date       REAL,
          modification_date   REAL,
          pixel_width         INTEGER NOT NULL,
          pixel_height        INTEGER NOT NULL,
          duration_seconds    REAL NOT NULL,
          media_kind          TEXT NOT NULL,
          is_live_photo       INTEGER NOT NULL,
          resources_json      TEXT NOT NULL,
          content_fingerprint INTEGER NOT NULL,
          metadata_revision   INTEGER NOT NULL,
          first_seen_at       REAL NOT NULL,
          last_seen_at        REAL NOT NULL,
          is_removed          INTEGER NOT NULL,
          removed_at          REAL
        );
        CREATE INDEX IF NOT EXISTS photo_catalog_sweep_idx ON photo_catalog(is_removed, last_seen_at);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK,
              verifyAndStampVersion(handle) else {
            sqlite3_close(handle)
            return nil
        }
        return handle
    }

    private static func verifyAndStampVersion(_ handle: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT value FROM photo_catalog_info WHERE key='schema';", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        var onDisk: Int?
        if sqlite3_step(stmt) == SQLITE_ROW { onDisk = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
        if let onDisk, onDisk > schemaVersion { return false }
        return sqlite3_exec(
            handle,
            "INSERT INTO photo_catalog_info(key, value) VALUES('schema', \(schemaVersion)) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            nil, nil, nil
        ) == SQLITE_OK
    }

    // MARK: - Bind/column helpers

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func bindNullableDate(_ stmt: OpaquePointer?, _ index: Int32, _ date: Date?) {
        if let date {
            sqlite3_bind_double(stmt, index, date.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL, let text = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: text)
    }

    private func columnDate(_ stmt: OpaquePointer?, _ index: Int32) -> Date? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: sqlite3_column_double(stmt, index))
    }
}
