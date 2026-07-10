import Foundation
import PhotosCore
import SQLite3

/// Persistent backup/sync state (`upload-backup-state-v1.sqlite`). This is a cache/index, not user
/// data: if the schema is from the future or corrupted, resetting only costs another local scan.
public final class UploadBackupStateManifestStore: UploadBackupStateStore, @unchecked Sendable {
    public static let databaseFileName = "upload-backup-state-v1.sqlite"

    private static let schemaVersion = 1
    private var db: OpaquePointer?
    private let lock = NSLock()

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

    public func record(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupAssetRecord? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT resource_count, pending_resources, updated_at
                FROM backup_asset_state
                WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, source.kind.rawValue)
            bindText(stmt, 2, source.identifier)
            bindText(stmt, 3, source.resource.rawValue)
            sqlite3_bind_int64(stmt, 4, revision.rawValue)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return UploadBackupAssetRecord(
                source: source,
                revision: revision,
                resourceCount: Int(sqlite3_column_int(stmt, 0)),
                pendingResourceCount: Int(sqlite3_column_int(stmt, 1)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            )
        }
    }

    public func hasAnyRecord(for source: UploadSourceIdentity) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT 1 FROM backup_asset_state
                WHERE source_kind=? AND source_id=? AND resource=?
                LIMIT 1;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, source.kind.rawValue)
            bindText(stmt, 2, source.identifier)
            bindText(stmt, 3, source.resource.rawValue)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    public func lookupBatch(_ snapshots: [UploadBackupAssetSnapshot]) -> [UploadBackupStateLookup] {
        guard !snapshots.isEmpty else { return [] }
        return lock.withLock {
            var recordStmt: OpaquePointer?
            var anyStmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT resource_count, pending_resources, updated_at
                FROM backup_asset_state
                WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?;
                """,
                -1, &recordStmt, nil
            ) == SQLITE_OK,
            sqlite3_prepare_v2(
                db,
                """
                SELECT 1 FROM backup_asset_state
                WHERE source_kind=? AND source_id=? AND resource=? LIMIT 1;
                """,
                -1, &anyStmt, nil
            ) == SQLITE_OK else {
                sqlite3_finalize(recordStmt)
                sqlite3_finalize(anyStmt)
                return snapshots.map { _ in
                    UploadBackupStateLookup(
                        succeeded: false,
                        directRecord: nil,
                        hasAnyRecord: false,
                        editRecord: nil
                    )
                }
            }
            defer {
                sqlite3_finalize(recordStmt)
                sqlite3_finalize(anyStmt)
            }

            return snapshots.map { snapshot in
                let directResult = readRecord(
                    statement: recordStmt,
                    source: snapshot.source,
                    revision: snapshot.revision
                )
                guard case let .value(direct) = directResult else {
                    return Self.failedLookup
                }

                let hasAny: Bool
                if direct != nil {
                    hasAny = true
                } else {
                    guard case let .value(foundAny) = readAny(statement: anyStmt, source: snapshot.source) else {
                        return Self.failedLookup
                    }
                    hasAny = foundAny
                }

                let editRecord: UploadBackupAssetRecord?
                if case let .revision(editRevision) = snapshot.editRevision {
                    guard case let .value(record) = readRecord(
                        statement: recordStmt,
                        source: snapshot.source,
                        revision: editRevision
                    ) else {
                        return Self.failedLookup
                    }
                    editRecord = record
                } else {
                    editRecord = nil
                }
                return UploadBackupStateLookup(
                    directRecord: direct,
                    hasAnyRecord: hasAny,
                    editRecord: editRecord
                )
            }
        }
    }

    @discardableResult
    public func upsert(_ record: UploadBackupAssetRecord) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bind(record, to: stmt)
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    @discardableResult
    public func upsertBatch(_ records: [UploadBackupAssetRecord]) -> Bool {
        guard !records.isEmpty else { return true }
        return lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_finalize(stmt)
                return false
            }
            defer { sqlite3_finalize(stmt) }
            for record in records {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bind(record, to: stmt)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return false
                }
            }
            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    public func count() -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM backup_asset_state;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    private enum ReadResult<Value> {
        case value(Value)
        case failed
    }

    private static let failedLookup = UploadBackupStateLookup(
        succeeded: false,
        directRecord: nil,
        hasAnyRecord: false,
        editRecord: nil
    )

    private func readRecord(
        statement: OpaquePointer?,
        source: UploadSourceIdentity,
        revision: UploadBackupRevision
    ) -> ReadResult<UploadBackupAssetRecord?> {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        bindText(statement, 1, source.kind.rawValue)
        bindText(statement, 2, source.identifier)
        bindText(statement, 3, source.resource.rawValue)
        sqlite3_bind_int64(statement, 4, revision.rawValue)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return .value(nil) }
        guard result == SQLITE_ROW else { return .failed }
        return .value(UploadBackupAssetRecord(
            source: source,
            revision: revision,
            resourceCount: Int(sqlite3_column_int(statement, 0)),
            pendingResourceCount: Int(sqlite3_column_int(statement, 1)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
        ))
    }

    private func readAny(statement: OpaquePointer?, source: UploadSourceIdentity) -> ReadResult<Bool> {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        bindText(statement, 1, source.kind.rawValue)
        bindText(statement, 2, source.identifier)
        bindText(statement, 3, source.resource.rawValue)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return .value(true) }
        if result == SQLITE_DONE { return .value(false) }
        return .failed
    }

    private static func openVerified(url: URL, policy: LibraryDatabasePolicy) -> OpaquePointer? {
        if let handle = openOnce(url: url, policy: policy) { return handle }
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
        return openOnce(url: url, policy: policy)
    }

    private static let upsertSQL = """
        INSERT INTO backup_asset_state(
          source_kind, source_id, resource, revision_us, resource_count,
          pending_resources, updated_at
        ) VALUES(?,?,?,?,?,?,?)
        ON CONFLICT(source_kind, source_id, resource, revision_us) DO UPDATE SET
          resource_count=excluded.resource_count,
          pending_resources=excluded.pending_resources,
          updated_at=excluded.updated_at;
        """

    private func bind(_ record: UploadBackupAssetRecord, to stmt: OpaquePointer?) {
        bindText(stmt, 1, record.source.kind.rawValue)
        bindText(stmt, 2, record.source.identifier)
        bindText(stmt, 3, record.source.resource.rawValue)
        sqlite3_bind_int64(stmt, 4, record.revision.rawValue)
        sqlite3_bind_int(stmt, 5, Int32(record.resourceCount))
        sqlite3_bind_int(stmt, 6, Int32(record.pendingResourceCount))
        sqlite3_bind_double(stmt, 7, record.updatedAt.timeIntervalSince1970)
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
        CREATE TABLE IF NOT EXISTS backup_state_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS backup_asset_state(
          source_kind       TEXT NOT NULL,
          source_id         TEXT NOT NULL,
          resource          TEXT NOT NULL,
          revision_us       INTEGER NOT NULL,
          resource_count    INTEGER NOT NULL,
          pending_resources INTEGER NOT NULL,
          updated_at        REAL NOT NULL,
          PRIMARY KEY(source_kind, source_id, resource, revision_us)
        );
        CREATE INDEX IF NOT EXISTS backup_asset_state_source_idx
          ON backup_asset_state(source_kind, source_id, resource);
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
        guard sqlite3_prepare_v2(handle, "SELECT value FROM backup_state_info WHERE key='schema';", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        var onDisk: Int?
        if sqlite3_step(stmt) == SQLITE_ROW { onDisk = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
        if let onDisk, onDisk > schemaVersion { return false }
        return sqlite3_exec(
            handle,
            "INSERT INTO backup_state_info(key, value) VALUES('schema', \(schemaVersion)) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            nil, nil, nil
        ) == SQLITE_OK
    }

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }
}
