import Foundation
import PhotosCore
import SQLite3

/// Persistent sync work queue (`upload-backup-sync-queue-v1.sqlite`). The queue stores source
/// identities and revisions, not temporary export URLs; platform adapters rematerialize resources
/// when work resumes after a launch, background wake, or extension invocation.
public final class UploadBackupSyncQueueManifestStore: UploadBackupSyncQueueStore, @unchecked Sendable {
    public static let databaseFileName = "upload-backup-sync-queue-v1.sqlite"

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

    public func upsert(_ entry: UploadBackupSyncQueueEntry) {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                INSERT INTO backup_sync_queue(
                  source_kind, source_id, resource, revision_us, original_filename,
                  byte_count, state, attempts, last_error, updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(source_kind, source_id, resource, revision_us) DO UPDATE SET
                  original_filename=excluded.original_filename,
                  byte_count=excluded.byte_count,
                  state=excluded.state,
                  attempts=excluded.attempts,
                  last_error=excluded.last_error,
                  updated_at=excluded.updated_at;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bind(entry, to: stmt)
            _ = sqlite3_step(stmt)
        }
    }

    public func entry(for source: UploadSourceIdentity, revision: UploadBackupRevision) -> UploadBackupSyncQueueEntry? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT original_filename, byte_count, state, attempts, last_error, updated_at
                FROM backup_sync_queue
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
            return row(stmt, source: source, revision: revision)
        }
    }

    public func nextRunnable(limit: Int) -> [UploadBackupSyncQueueEntry] {
        let clampedLimit = max(1, limit)
        return lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count,
                       state, attempts, last_error, updated_at
                FROM backup_sync_queue
                WHERE state IN ('discovered', 'queuedForUpload')
                ORDER BY revision_us DESC, updated_at ASC
                LIMIT ?;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(clampedLimit))
            var entries: [UploadBackupSyncQueueEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else { continue }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3))
                entries.append(row(stmt, source: source, revision: revision, offset: 4))
            }
            return entries
        }
    }

    public func claimRunnable(limit: Int, claimedAt: Date) -> [UploadBackupSyncQueueEntry] {
        let clampedLimit = max(1, limit)
        return lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return [] }
            var selected: [UploadBackupSyncQueueEntry] = []
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count,
                       state, attempts, last_error, updated_at
                FROM backup_sync_queue
                WHERE state IN ('discovered', 'queuedForUpload')
                  AND updated_at <= ?
                ORDER BY revision_us DESC, updated_at ASC
                LIMIT ?;
                """,
                -1, &selectStmt, nil
            ) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return []
            }
            sqlite3_bind_double(selectStmt, 1, claimedAt.timeIntervalSince1970)
            sqlite3_bind_int(selectStmt, 2, Int32(clampedLimit))
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                guard let source = sourceFromColumns(selectStmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else { continue }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(selectStmt, 3))
                selected.append(row(selectStmt, source: source, revision: revision, offset: 4))
            }
            sqlite3_finalize(selectStmt)

            guard !selected.isEmpty else {
                sqlite3_exec(db, "COMMIT;", nil, nil, nil)
                return []
            }

            var updateStmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                UPDATE backup_sync_queue
                SET state='checking', updated_at=?
                WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?
                  AND state IN ('discovered', 'queuedForUpload');
                """,
                -1, &updateStmt, nil
            ) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return []
            }
            defer { sqlite3_finalize(updateStmt) }

            var claimed: [UploadBackupSyncQueueEntry] = []
            for entry in selected {
                sqlite3_reset(updateStmt)
                sqlite3_clear_bindings(updateStmt)
                sqlite3_bind_double(updateStmt, 1, claimedAt.timeIntervalSince1970)
                bindText(updateStmt, 2, entry.source.kind.rawValue)
                bindText(updateStmt, 3, entry.source.identifier)
                bindText(updateStmt, 4, entry.source.resource.rawValue)
                sqlite3_bind_int64(updateStmt, 5, entry.revision.rawValue)
                if sqlite3_step(updateStmt) == SQLITE_DONE, sqlite3_changes(db) > 0 {
                    claimed.append(entry)
                }
            }

            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return []
            }
            return claimed
        }
    }

    public func entries(
        in state: UploadBackupSyncQueueState,
        updatedBefore: Date,
        limit: Int
    ) -> [UploadBackupSyncQueueEntry] {
        let clampedLimit = max(1, limit)
        return lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT source_kind, source_id, resource, revision_us, original_filename, byte_count,
                       state, attempts, last_error, updated_at
                FROM backup_sync_queue
                WHERE state = ? AND updated_at < ?
                ORDER BY revision_us DESC, updated_at ASC
                LIMIT ?;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, state.rawValue)
            sqlite3_bind_double(stmt, 2, updatedBefore.timeIntervalSince1970)
            sqlite3_bind_int(stmt, 3, Int32(clampedLimit))
            var entries: [UploadBackupSyncQueueEntry] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let source = sourceFromColumns(stmt, kindColumn: 0, idColumn: 1, resourceColumn: 2) else { continue }
                let revision = UploadBackupRevision(rawValue: sqlite3_column_int64(stmt, 3))
                entries.append(row(stmt, source: source, revision: revision, offset: 4))
            }
            return entries
        }
    }

    @discardableResult
    public func requeueStaleActive(before cutoff: Date, updatedAt: Date) -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                UPDATE backup_sync_queue SET
                  state = CASE state
                    WHEN 'checking' THEN 'discovered'
                    WHEN 'hashing' THEN 'discovered'
                    WHEN 'duplicateChecking' THEN 'discovered'
                    WHEN 'uploading' THEN 'queuedForUpload'
                    WHEN 'finalizing' THEN 'queuedForUpload'
                    ELSE state
                  END,
                  updated_at = ?
                WHERE updated_at < ?
                  AND state IN ('checking', 'hashing', 'duplicateChecking', 'uploading', 'finalizing');
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, updatedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    /// Resets every parked `.failed` row back to runnable with a fresh retry budget. Called when
    /// the user explicitly asks to back up again (or re-enables backup), so a manual "back up now"
    /// actually retries the items behind a "needs attention" state instead of being a no-op.
    @discardableResult
    public func requeueFailed(updatedAt: Date) -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                UPDATE backup_sync_queue
                SET state = 'discovered', attempts = 0, last_error = NULL, updated_at = ?
                WHERE state = 'failed';
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, updatedAt.timeIntervalSince1970)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return 0 }
            return Int(sqlite3_changes(db))
        }
    }

    public func updateState(
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        state: UploadBackupSyncQueueState,
        attempts: Int?,
        lastError: String?,
        updatedAt: Date
    ) {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                UPDATE backup_sync_queue SET
                  state=?,
                  attempts=COALESCE(?, attempts),
                  last_error=?,
                  updated_at=?
                WHERE source_kind=? AND source_id=? AND resource=? AND revision_us=?;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, state.rawValue)
            if let attempts {
                sqlite3_bind_int(stmt, 2, Int32(max(0, attempts)))
            } else {
                sqlite3_bind_null(stmt, 2)
            }
            bindNullableText(stmt, 3, lastError)
            sqlite3_bind_double(stmt, 4, updatedAt.timeIntervalSince1970)
            bindText(stmt, 5, source.kind.rawValue)
            bindText(stmt, 6, source.identifier)
            bindText(stmt, 7, source.resource.rawValue)
            sqlite3_bind_int64(stmt, 8, revision.rawValue)
            _ = sqlite3_step(stmt)
        }
    }

    public func summary() -> UploadBackupSyncQueueSummary {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT state, COUNT(*) FROM backup_sync_queue GROUP BY state;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return UploadBackupSyncQueueSummary() }
            defer { sqlite3_finalize(stmt) }
            var summary = UploadBackupSyncQueueSummary()
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let raw = columnText(stmt, 0),
                      let state = UploadBackupSyncQueueState(rawValue: raw) else { continue }
                summary.include(state, count: Int(sqlite3_column_int(stmt, 1)))
            }
            return summary
        }
    }

    public func count() -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM backup_sync_queue;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

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
        CREATE TABLE IF NOT EXISTS backup_sync_queue_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS backup_sync_queue(
          source_kind       TEXT NOT NULL,
          source_id         TEXT NOT NULL,
          resource          TEXT NOT NULL,
          revision_us       INTEGER NOT NULL,
          original_filename TEXT NOT NULL,
          byte_count        INTEGER,
          state             TEXT NOT NULL,
          attempts          INTEGER NOT NULL,
          last_error        TEXT,
          updated_at        REAL NOT NULL,
          PRIMARY KEY(source_kind, source_id, resource, revision_us)
        );
        CREATE INDEX IF NOT EXISTS backup_sync_queue_runnable_idx
          ON backup_sync_queue(state, updated_at);
        CREATE INDEX IF NOT EXISTS backup_sync_queue_priority_idx
          ON backup_sync_queue(state, revision_us DESC);
        CREATE INDEX IF NOT EXISTS backup_sync_queue_source_idx
          ON backup_sync_queue(source_kind, source_id, resource);
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
        guard sqlite3_prepare_v2(handle, "SELECT value FROM backup_sync_queue_info WHERE key='schema';", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        var onDisk: Int?
        if sqlite3_step(stmt) == SQLITE_ROW { onDisk = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
        if let onDisk, onDisk > schemaVersion { return false }
        return sqlite3_exec(
            handle,
            "INSERT INTO backup_sync_queue_info(key, value) VALUES('schema', \(schemaVersion)) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            nil, nil, nil
        ) == SQLITE_OK
    }

    private func bind(_ entry: UploadBackupSyncQueueEntry, to stmt: OpaquePointer?) {
        bindText(stmt, 1, entry.source.kind.rawValue)
        bindText(stmt, 2, entry.source.identifier)
        bindText(stmt, 3, entry.source.resource.rawValue)
        sqlite3_bind_int64(stmt, 4, entry.revision.rawValue)
        bindText(stmt, 5, entry.originalFilename)
        if let byteCount = entry.byteCount {
            sqlite3_bind_int64(stmt, 6, byteCount)
        } else {
            sqlite3_bind_null(stmt, 6)
        }
        bindText(stmt, 7, entry.state.rawValue)
        sqlite3_bind_int(stmt, 8, Int32(entry.attempts))
        bindNullableText(stmt, 9, entry.lastError)
        sqlite3_bind_double(stmt, 10, entry.updatedAt.timeIntervalSince1970)
    }

    private func row(
        _ stmt: OpaquePointer?,
        source: UploadSourceIdentity,
        revision: UploadBackupRevision,
        offset: Int32 = 0
    ) -> UploadBackupSyncQueueEntry {
        UploadBackupSyncQueueEntry(
            source: source,
            revision: revision,
            originalFilename: columnText(stmt, offset) ?? "",
            byteCount: sqlite3_column_type(stmt, offset + 1) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, offset + 1),
            state: UploadBackupSyncQueueState(rawValue: columnText(stmt, offset + 2) ?? "") ?? .failed,
            attempts: Int(sqlite3_column_int(stmt, offset + 3)),
            lastError: columnText(stmt, offset + 4),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, offset + 5))
        )
    }

    private func sourceFromColumns(
        _ stmt: OpaquePointer?,
        kindColumn: Int32,
        idColumn: Int32,
        resourceColumn: Int32
    ) -> UploadSourceIdentity? {
        guard let kindRaw = columnText(stmt, kindColumn),
              let kind = UploadSourceIdentity.Kind(rawValue: kindRaw),
              let id = columnText(stmt, idColumn),
              let resourceRaw = columnText(stmt, resourceColumn) else {
            return nil
        }
        let resource = UploadSourceIdentity.Resource(rawValue: resourceRaw)
        return UploadSourceIdentity(kind: kind, identifier: id, resource: resource)
    }

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func bindNullableText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let text = sqlite3_column_text(stmt, index) else {
            return nil
        }
        return String(cString: text)
    }
}
