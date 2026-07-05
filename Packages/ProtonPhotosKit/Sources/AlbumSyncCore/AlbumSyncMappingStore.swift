import Foundation
import PhotosCore
import SQLite3

/// Persistent local-album → Proton-album mapping (`album-sync-mapping-v1.sqlite`). Lives in the
/// per-account data directory next to the upload manifest, so the sign-out purge covers it.
///
/// This is NOT a rebuildable cache: losing a mapping means the next sync would go through the
/// name-conflict flow again (never silent attach-by-name). The schema therefore only fail-closed
/// resets when it comes from a NEWER build, same as the other per-account stores.
///
/// Stores ids, titles, and counts - never photo names, hashes, or key material. Thread-safe via an
/// internal lock (UI thread reads, sync runner writes).
public final class AlbumSyncMappingStore: @unchecked Sendable {

    public static let databaseFileName = "album-sync-mapping-v1.sqlite"

    private var db: OpaquePointer?
    private let lock = NSLock()
    private static let schemaVersion = 1

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative) {
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

    // MARK: Open / schema

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
        sqlite3_exec(handle, "PRAGMA journal_size_limit=\(policy.journalSizeLimitBytes);", nil, nil, nil)

        let schema = """
        CREATE TABLE IF NOT EXISTS mapping_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS album_sync_mapping(
          local_album_id  TEXT PRIMARY KEY,
          remote_album_id TEXT NOT NULL,
          title           TEXT NOT NULL,
          mode            TEXT NOT NULL,
          created_at      REAL NOT NULL,
          last_synced_at  REAL,
          last_attached   INTEGER NOT NULL DEFAULT 0,
          last_failed     INTEGER NOT NULL DEFAULT 0
        );
        CREATE TABLE IF NOT EXISTS album_sync_selection(
          local_album_id  TEXT PRIMARY KEY,
          title           TEXT NOT NULL,
          added_at        REAL NOT NULL
        );
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
        guard sqlite3_prepare_v2(handle, "SELECT value FROM mapping_info WHERE key='schema';", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        var onDisk: Int?
        if sqlite3_step(stmt) == SQLITE_ROW { onDisk = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
        if let onDisk, onDisk > schemaVersion { return false }
        return sqlite3_exec(
            handle,
            "INSERT INTO mapping_info(key, value) VALUES('schema', \(schemaVersion)) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            nil, nil, nil
        ) == SQLITE_OK
    }

    // MARK: API

    public func mapping(localAlbumID: String) -> AlbumSyncMapping? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT local_album_id, remote_album_id, title, mode, created_at, last_synced_at, last_attached, last_failed "
                    + "FROM album_sync_mapping WHERE local_album_id=?;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, localAlbumID, -1, Self.transient)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return Self.rowToMapping(stmt)
        }
    }

    public func allMappings() -> [AlbumSyncMapping] {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT local_album_id, remote_album_id, title, mode, created_at, last_synced_at, last_attached, last_failed "
                    + "FROM album_sync_mapping ORDER BY title;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var result: [AlbumSyncMapping] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let mapping = Self.rowToMapping(stmt) { result.append(mapping) }
            }
            return result
        }
    }

    public func upsert(_ mapping: AlbumSyncMapping) {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                INSERT INTO album_sync_mapping
                  (local_album_id, remote_album_id, title, mode, created_at, last_synced_at, last_attached, last_failed)
                VALUES (?,?,?,?,?,?,?,?)
                ON CONFLICT(local_album_id) DO UPDATE SET
                  remote_album_id=excluded.remote_album_id, title=excluded.title, mode=excluded.mode,
                  last_synced_at=excluded.last_synced_at, last_attached=excluded.last_attached,
                  last_failed=excluded.last_failed;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, mapping.localAlbumID, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, mapping.remoteAlbumID, -1, Self.transient)
            sqlite3_bind_text(stmt, 3, mapping.title, -1, Self.transient)
            sqlite3_bind_text(stmt, 4, mapping.mode.rawValue, -1, Self.transient)
            sqlite3_bind_double(stmt, 5, mapping.createdAt.timeIntervalSinceReferenceDate)
            if let synced = mapping.lastSyncedAt {
                sqlite3_bind_double(stmt, 6, synced.timeIntervalSinceReferenceDate)
            } else {
                sqlite3_bind_null(stmt, 6)
            }
            sqlite3_bind_int64(stmt, 7, Int64(mapping.lastAttachedCount))
            sqlite3_bind_int64(stmt, 8, Int64(mapping.lastFailedCount))
            _ = sqlite3_step(stmt)
        }
    }

    public func removeMapping(localAlbumID: String) {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM album_sync_mapping WHERE local_album_id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, localAlbumID, -1, Self.transient)
            _ = sqlite3_step(stmt)
        }
    }

    // MARK: Selection (which local albums the user chose to sync)

    /// Deselecting an album removes ONLY the selection row - the album mapping stays, so
    /// re-selecting later reuses the same Proton album without a name-conflict round.
    public func selections() -> [AlbumSyncSelection] {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT local_album_id, title, added_at FROM album_sync_selection ORDER BY title;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var result: [AlbumSyncSelection] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let id = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
                      let title = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }) else { continue }
                result.append(AlbumSyncSelection(
                    localAlbumID: id,
                    title: title,
                    addedAt: Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 2))
                ))
            }
            return result
        }
    }

    public func addSelection(_ selection: AlbumSyncSelection) {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "INSERT INTO album_sync_selection(local_album_id, title, added_at) VALUES (?,?,?) "
                    + "ON CONFLICT(local_album_id) DO UPDATE SET title=excluded.title;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, selection.localAlbumID, -1, Self.transient)
            sqlite3_bind_text(stmt, 2, selection.title, -1, Self.transient)
            sqlite3_bind_double(stmt, 3, selection.addedAt.timeIntervalSinceReferenceDate)
            _ = sqlite3_step(stmt)
        }
    }

    public func removeSelection(localAlbumID: String) {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "DELETE FROM album_sync_selection WHERE local_album_id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, localAlbumID, -1, Self.transient)
            _ = sqlite3_step(stmt)
        }
    }

    // MARK: Row mapping

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func rowToMapping(_ stmt: OpaquePointer?) -> AlbumSyncMapping? {
        guard let local = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }),
              let remote = sqlite3_column_text(stmt, 1).map({ String(cString: $0) }),
              let title = sqlite3_column_text(stmt, 2).map({ String(cString: $0) }),
              let modeRaw = sqlite3_column_text(stmt, 3).map({ String(cString: $0) }),
              let mode = AlbumSyncMode(rawValue: modeRaw) else {
            return nil
        }
        let created = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 4))
        let synced: Date? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
            ? nil : Date(timeIntervalSinceReferenceDate: sqlite3_column_double(stmt, 5))
        return AlbumSyncMapping(
            localAlbumID: local,
            remoteAlbumID: remote,
            title: title,
            mode: mode,
            createdAt: created,
            lastSyncedAt: synced,
            lastAttachedCount: Int(sqlite3_column_int64(stmt, 6)),
            lastFailedCount: Int(sqlite3_column_int64(stmt, 7))
        )
    }
}
