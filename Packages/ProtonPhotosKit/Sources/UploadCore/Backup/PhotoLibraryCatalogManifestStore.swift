import Foundation
import PhotosCore
import SQLite3

/// Persistent local photo-library catalog (`photo-library-catalog-v1.sqlite`). Like the other
/// backup stores this is a cache/index, not user data: a future/corrupt schema resets to empty and
/// costs only another local scan. One row per asset `localIdentifier`; resources ride in a single
/// JSON column so a new resource role never needs a migration.
public final class PhotoLibraryCatalogManifestStore: PhotoLibraryCatalogStore, @unchecked Sendable {
    public static let databaseFileName = "photo-library-catalog-v1.sqlite"

    private static let schemaVersion = 3
    private static let completedFullScanKey = "completed_full_scan"
    private static let fullScanEpochStartKey = "full_scan_epoch_start"
    private static let fullScanCursorKey = "full_scan_cursor"
    private static let fullScanSnapshotReadyKey = "full_scan_snapshot_ready"
    private var db: OpaquePointer?
    private var operationFailed = false
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let handle = Self.openVerified(url: url, policy: policy) else { return nil }
        db = handle
    }

    deinit { close() }

    public func isOperational() -> Bool {
        lock.withLock {
            guard db != nil, !operationFailed else { return false }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT 1;", -1, &stmt, nil) == SQLITE_OK else {
                operationFailed = true
                return false
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                operationFailed = true
                return false
            }
            return true
        }
    }

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

    public func presentEntries(afterLocalIdentifier: String?, limit: Int) -> [PhotoLibraryCatalogEntry] {
        let clampedLimit = max(1, limit)
        return lock.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(
                db,
                """
                SELECT local_id, cloud_id, creation_date, modification_date, pixel_width, pixel_height,
                       duration_seconds, media_kind, is_live_photo, resources_json, content_fingerprint,
                       metadata_revision, first_seen_at, last_seen_at, is_removed, removed_at
                FROM photo_catalog
                WHERE is_removed=0 AND (? IS NULL OR local_id>?)
                ORDER BY local_id LIMIT ?;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK) else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindOptionalText(stmt, 1, afterLocalIdentifier)
            bindOptionalText(stmt, 2, afterLocalIdentifier)
            sqlite3_bind_int(stmt, 3, Int32(clampedLimit))
            var entries: [PhotoLibraryCatalogEntry] = []
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let entry = decodeEntry(stmt, localIdentifierColumn: 0, valueOffset: 1) else {
                    operationFailed = true
                    return []
                }
                entries.append(entry)
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else { return [] }
            return entries
        }
    }

    public func classify(_ entry: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange {
        classifyBatch([entry]).first ?? .changed
    }

    public func classifyBatch(_ entries: [PhotoLibraryCatalogEntry]) -> [PhotoLibraryCatalogChange] {
        guard !entries.isEmpty else { return [] }
        return lock.withLock { classifyBatchLocked(entries) }
    }

    @discardableResult
    public func upsert(_ entry: PhotoLibraryCatalogEntry) -> PhotoLibraryCatalogChange {
        lock.withLock {
            let change = classifyBatchLocked([entry]).first ?? .changed
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK) else {
                return change
            }
            defer { sqlite3_finalize(stmt) }
            _ = requireOperational(persist(entry, using: stmt))
            return change
        }
    }

    @discardableResult
    public func upsertBatch(_ entries: [PhotoLibraryCatalogEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        return lock.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(db, Self.upsertSQL, -1, &stmt, nil) == SQLITE_OK) else {
                return false
            }
            defer { sqlite3_finalize(stmt) }
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            var didPersist = true
            for entry in entries {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                guard requireOperational(persist(entry, using: stmt)) else {
                    didPersist = false
                    break
                }
            }
            guard didPersist,
                  requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func markRemoved(
        _ identifiers: [String],
        removedAt: Date
    ) -> PhotoLibraryCatalogMutationResult {
        let present = identifiers.filter { !$0.isEmpty }
        guard !present.isEmpty else {
            return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: true)
        }
        return lock.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(
                db,
                """
                UPDATE photo_catalog SET is_removed=1, removed_at=?
                WHERE local_id=? AND is_removed=0;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK) else {
                return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
            }
            defer { sqlite3_finalize(stmt) }
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
            }
            var changed = 0
            for id in present {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_double(stmt, 1, removedAt.timeIntervalSince1970)
                bindText(stmt, 2, id)
                guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
                }
                changed += Int(sqlite3_changes(db))
            }
            guard requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
            }
            return PhotoLibraryCatalogMutationResult(affectedRows: changed, succeeded: true)
        }
    }

    @discardableResult
    public func sweepRemoved(
        notSeenAfter cutoff: Date,
        removedAt: Date
    ) -> PhotoLibraryCatalogMutationResult {
        lock.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(
                db,
                """
                UPDATE photo_catalog SET is_removed=1, removed_at=?
                WHERE is_removed=0 AND last_seen_at < ?;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK) else {
                return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_double(stmt, 1, removedAt.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, cutoff.timeIntervalSince1970)
            guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else {
                return PhotoLibraryCatalogMutationResult(affectedRows: 0, succeeded: false)
            }
            return PhotoLibraryCatalogMutationResult(
                affectedRows: Int(sqlite3_changes(db)),
                succeeded: true
            )
        }
    }

    public func snapshot() -> PhotoLibraryCatalogSnapshot {
        lock.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(
                db,
                "SELECT is_removed, COUNT(*) FROM photo_catalog GROUP BY is_removed;",
                -1, &stmt, nil
            ) == SQLITE_OK) else { return PhotoLibraryCatalogSnapshot() }
            defer { sqlite3_finalize(stmt) }
            var snapshot = PhotoLibraryCatalogSnapshot()
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                let removed = sqlite3_column_int(stmt, 0) != 0
                let count = Int(sqlite3_column_int(stmt, 1))
                snapshot.total += count
                if removed { snapshot.removed += count } else { snapshot.present += count }
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else { return PhotoLibraryCatalogSnapshot() }
            return snapshot
        }
    }

    public func count() -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(
                sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM photo_catalog;", -1, &stmt, nil) == SQLITE_OK
            ) else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard requireOperational(sqlite3_step(stmt) == SQLITE_ROW) else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    /// True only after a full-library scan finished successfully at least once. A PhotoKit
    /// persistent-change token can exist before our own catalog is complete; this marker prevents
    /// the first real backup pass from mistaking "changed since token" for "entire library known".
    public func hasCompletedFullScan() -> Bool {
        lock.withLock { readInfoValue(Self.completedFullScanKey) == 1 }
    }

    public func fullScanProgress() -> PhotoLibraryFullScanProgress? {
        lock.withLock {
            guard readInfoValue(Self.fullScanSnapshotReadyKey) == 1,
                  let bits = readInfoValue64(Self.fullScanEpochStartKey) else { return nil }
            let epochStart = Date(timeIntervalSince1970: Double(bitPattern: UInt64(bitPattern: bits)))
            let cursor = Int(readInfoValue64(Self.fullScanCursorKey) ?? 0)
            return PhotoLibraryFullScanProgress(epochStart: epochStart, cursor: max(0, cursor))
        }
    }

    @discardableResult
    public func recordFullScanProgress(_ progress: PhotoLibraryFullScanProgress) -> Bool {
        lock.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite = writeInfoValue64(
                Self.fullScanEpochStartKey,
                Int64(bitPattern: progress.epochStart.timeIntervalSince1970.bitPattern)
            ) && writeInfoValue64(Self.fullScanCursorKey, Int64(progress.cursor))
            guard didWrite,
                  requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    /// Marks the full scan complete and clears the in-progress epoch. Called by the sync driver only
    /// when a scan actually reaches the end of the library (across however many resumed runs).
    @discardableResult
    public func completeFullScan() -> Bool {
        lock.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite = writeInfoValue(Self.completedFullScanKey, 1)
                && deleteInfoValue(Self.fullScanEpochStartKey)
                && deleteInfoValue(Self.fullScanCursorKey)
                && deleteInfoValue(Self.fullScanSnapshotReadyKey)
                && requireOperational(
                    sqlite3_exec(db, "DELETE FROM photo_full_scan_snapshot;", nil, nil, nil) == SQLITE_OK
                )
            guard didWrite,
                  requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func clearFullScanResumePoint() -> Bool {
        lock.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite = deleteInfoValue(Self.fullScanEpochStartKey)
                && deleteInfoValue(Self.fullScanCursorKey)
                && deleteInfoValue(Self.fullScanSnapshotReadyKey)
                && requireOperational(
                    sqlite3_exec(db, "DELETE FROM photo_full_scan_snapshot;", nil, nil, nil) == SQLITE_OK
                )
            guard didWrite,
                  requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func beginFullScanSnapshot(epochStart: Date) -> Bool {
        lock.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite = requireOperational(
                sqlite3_exec(db, "DELETE FROM photo_full_scan_snapshot;", nil, nil, nil) == SQLITE_OK
            )
                && writeInfoValue64(
                    Self.fullScanEpochStartKey,
                    Int64(bitPattern: epochStart.timeIntervalSince1970.bitPattern)
                )
                && writeInfoValue64(Self.fullScanCursorKey, 0)
                && writeInfoValue(Self.fullScanSnapshotReadyKey, 0)
            guard didWrite,
                  requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func appendFullScanSnapshotIdentifiers(_ identifiers: [String]) -> Bool {
        let present = identifiers.filter { !$0.isEmpty }
        guard present.count == identifiers.count else { return false }
        guard !present.isEmpty else { return true }
        return lock.withLock {
            var nextPosition = fullScanSnapshotCountLocked()
            guard !operationFailed else { return false }
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(
                db,
                "INSERT INTO photo_full_scan_snapshot(position, local_id) VALUES(?, ?);",
                -1, &stmt, nil
            ) == SQLITE_OK) else { return false }
            defer { sqlite3_finalize(stmt) }
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            var didWrite = true
            for identifier in present {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_int64(stmt, 1, Int64(nextPosition))
                bindText(stmt, 2, identifier)
                guard requireOperational(sqlite3_step(stmt) == SQLITE_DONE) else {
                    didWrite = false
                    break
                }
                nextPosition += 1
            }
            guard didWrite,
                  requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func finishFullScanSnapshot() -> Bool {
        lock.withLock {
            guard requireOperational(sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK) else {
                return false
            }
            let didWrite = writeInfoValue64(Self.fullScanCursorKey, 0)
                && writeInfoValue(Self.fullScanSnapshotReadyKey, 1)
            guard didWrite,
                  requireOperational(sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK) else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    public func fullScanSnapshotIdentifiers(startingAt position: Int, limit: Int) -> [String] {
        lock.withLock {
            var stmt: OpaquePointer?
            guard requireOperational(sqlite3_prepare_v2(
                db,
                "SELECT local_id FROM photo_full_scan_snapshot WHERE position>=? ORDER BY position LIMIT ?;",
                -1, &stmt, nil
            ) == SQLITE_OK) else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(max(0, position)))
            sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))
            var identifiers: [String] = []
            identifiers.reserveCapacity(max(1, limit))
            var stepResult = sqlite3_step(stmt)
            while stepResult == SQLITE_ROW {
                guard let identifier = columnText(stmt, 0) else {
                    operationFailed = true
                    return []
                }
                identifiers.append(identifier)
                stepResult = sqlite3_step(stmt)
            }
            guard requireOperational(stepResult == SQLITE_DONE) else { return [] }
            return identifiers
        }
    }

    public func fullScanSnapshotCount() -> Int {
        lock.withLock { fullScanSnapshotCountLocked() }
    }

    private func fullScanSnapshotCountLocked() -> Int {
        var stmt: OpaquePointer?
        guard requireOperational(
            sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM photo_full_scan_snapshot;", -1, &stmt, nil) == SQLITE_OK
        ) else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        guard requireOperational(sqlite3_step(stmt) == SQLITE_ROW) else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    // MARK: - Read/write helpers (must be called under `lock`)

    private func classifyBatchLocked(_ entries: [PhotoLibraryCatalogEntry]) -> [PhotoLibraryCatalogChange] {
        var stmt: OpaquePointer?
        guard requireOperational(sqlite3_prepare_v2(
            db,
            "SELECT content_fingerprint, metadata_revision, is_removed FROM photo_catalog WHERE local_id=?;",
            -1, &stmt, nil
        ) == SQLITE_OK) else {
            return Array(repeating: .changed, count: entries.count)
        }
        defer { sqlite3_finalize(stmt) }

        return entries.map { entry in
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, entry.localIdentifier)
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return .inserted }
            guard result == SQLITE_ROW else {
                operationFailed = true
                return .changed
            }
            if sqlite3_column_int(stmt, 2) != 0 { return .changed }
            return sqlite3_column_int64(stmt, 0) == entry.contentFingerprint
                && sqlite3_column_int64(stmt, 1) == entry.metadataRevision
                ? .unchanged
                : .changed
        }
    }

    private static let upsertSQL = """
        INSERT INTO photo_catalog(
          local_id, cloud_id, creation_date, modification_date, pixel_width, pixel_height,
          duration_seconds, media_kind, is_live_photo, resources_json,
          content_fingerprint, metadata_revision, first_seen_at, last_seen_at,
          is_removed, removed_at
        ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,0,NULL)
        ON CONFLICT(local_id) DO UPDATE SET
          cloud_id=COALESCE(excluded.cloud_id, photo_catalog.cloud_id),
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
        """

    private func persist(_ entry: PhotoLibraryCatalogEntry, using stmt: OpaquePointer?) -> Bool {
        let resourcesJSON = (try? encoder.encode(entry.resources)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        bindText(stmt, 1, entry.localIdentifier)
        bindOptionalText(stmt, 2, entry.cloudIdentifier)
        bindNullableDate(stmt, 3, entry.creationDate)
        bindNullableDate(stmt, 4, entry.modificationDate)
        sqlite3_bind_int(stmt, 5, Int32(entry.pixelWidth))
        sqlite3_bind_int(stmt, 6, Int32(entry.pixelHeight))
        sqlite3_bind_double(stmt, 7, entry.durationSeconds)
        bindText(stmt, 8, entry.mediaKind.rawValue)
        sqlite3_bind_int(stmt, 9, entry.isLivePhoto ? 1 : 0)
        bindText(stmt, 10, resourcesJSON)
        sqlite3_bind_int64(stmt, 11, entry.contentFingerprint)
        sqlite3_bind_int64(stmt, 12, entry.metadataRevision)
        sqlite3_bind_double(stmt, 13, entry.firstSeenAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 14, entry.lastSeenAt.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func readEntry(_ localIdentifier: String) -> PhotoLibraryCatalogEntry? {
        var stmt: OpaquePointer?
        guard requireOperational(sqlite3_prepare_v2(
            db,
            """
            SELECT cloud_id, creation_date, modification_date, pixel_width, pixel_height, duration_seconds,
                   media_kind, is_live_photo, resources_json, content_fingerprint, metadata_revision,
                   first_seen_at, last_seen_at, is_removed, removed_at
            FROM photo_catalog WHERE local_id=?;
            """,
            -1, &stmt, nil
        ) == SQLITE_OK) else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, localIdentifier)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard requireOperational(result == SQLITE_ROW) else { return nil }

        return decodeEntry(stmt, localIdentifier: localIdentifier, valueOffset: 0)
    }

    private func decodeEntry(
        _ stmt: OpaquePointer?,
        localIdentifierColumn: Int32? = nil,
        localIdentifier: String? = nil,
        valueOffset: Int32
    ) -> PhotoLibraryCatalogEntry? {
        guard let resolvedIdentifier = localIdentifier
            ?? localIdentifierColumn.flatMap({ columnText(stmt, $0) }) else { return nil }
        guard let resourcesText = columnText(stmt, valueOffset + 8),
              let resourcesData = resourcesText.data(using: .utf8),
              let resources = try? decoder.decode([PhotoLibraryCatalogResource].self, from: resourcesData),
              let mediaKindRaw = columnText(stmt, valueOffset + 6),
              let mediaKind = PhotoLibraryCatalogMediaKind(rawValue: mediaKindRaw) else {
            operationFailed = true
            return nil
        }
        return PhotoLibraryCatalogEntry(
            localIdentifier: resolvedIdentifier,
            cloudIdentifier: columnText(stmt, valueOffset),
            creationDate: columnDate(stmt, valueOffset + 1),
            modificationDate: columnDate(stmt, valueOffset + 2),
            pixelWidth: Int(sqlite3_column_int(stmt, valueOffset + 3)),
            pixelHeight: Int(sqlite3_column_int(stmt, valueOffset + 4)),
            durationSeconds: sqlite3_column_double(stmt, valueOffset + 5),
            mediaKind: mediaKind,
            isLivePhoto: sqlite3_column_int(stmt, valueOffset + 7) != 0,
            resources: resources,
            contentFingerprint: sqlite3_column_int64(stmt, valueOffset + 9),
            metadataRevision: sqlite3_column_int64(stmt, valueOffset + 10),
            firstSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, valueOffset + 11)),
            lastSeenAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, valueOffset + 12)),
            isRemoved: sqlite3_column_int(stmt, valueOffset + 13) != 0,
            removedAt: columnDate(stmt, valueOffset + 14)
        )
    }

    private func readInfoValue(_ key: String) -> Int? {
        var stmt: OpaquePointer?
        guard requireOperational(
            sqlite3_prepare_v2(db, "SELECT value FROM photo_catalog_info WHERE key=?;", -1, &stmt, nil) == SQLITE_OK
        ) else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard requireOperational(result == SQLITE_ROW) else { return nil }
        return Int(sqlite3_column_int(stmt, 0))
    }

    @discardableResult
    private func writeInfoValue(_ key: String, _ value: Int) -> Bool {
        var stmt: OpaquePointer?
        guard requireOperational(sqlite3_prepare_v2(
            db,
            "INSERT INTO photo_catalog_info(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            -1, &stmt, nil
        ) == SQLITE_OK) else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        sqlite3_bind_int(stmt, 2, Int32(value))
        return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
    }

    // 64-bit info values (the `value` column is INTEGER = 64-bit in SQLite). Used for the resumable
    // full-scan cursor and for the epoch-start instant stored as the exact bit pattern of its Double.
    private func readInfoValue64(_ key: String) -> Int64? {
        var stmt: OpaquePointer?
        guard requireOperational(
            sqlite3_prepare_v2(db, "SELECT value FROM photo_catalog_info WHERE key=?;", -1, &stmt, nil) == SQLITE_OK
        ) else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        let result = sqlite3_step(stmt)
        if result == SQLITE_DONE { return nil }
        guard requireOperational(result == SQLITE_ROW) else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    @discardableResult
    private func writeInfoValue64(_ key: String, _ value: Int64) -> Bool {
        var stmt: OpaquePointer?
        guard requireOperational(sqlite3_prepare_v2(
            db,
            "INSERT INTO photo_catalog_info(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            -1, &stmt, nil
        ) == SQLITE_OK) else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        sqlite3_bind_int64(stmt, 2, value)
        return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
    }

    @discardableResult
    private func deleteInfoValue(_ key: String) -> Bool {
        var stmt: OpaquePointer?
        guard requireOperational(
            sqlite3_prepare_v2(db, "DELETE FROM photo_catalog_info WHERE key=?;", -1, &stmt, nil) == SQLITE_OK
        ) else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, key)
        return requireOperational(sqlite3_step(stmt) == SQLITE_DONE)
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
          cloud_id            TEXT,
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
        CREATE TABLE IF NOT EXISTS photo_full_scan_snapshot(
          position INTEGER PRIMARY KEY,
          local_id TEXT NOT NULL
        );
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK,
              ensureCloudIdentifierColumn(handle),
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

    private static func ensureCloudIdentifierColumn(_ handle: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA table_info(photo_catalog);", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        var found = false
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(stmt, 1), String(cString: name) == "cloud_id" {
                found = true
                break
            }
        }
        sqlite3_finalize(stmt)
        return found || sqlite3_exec(
            handle,
            "ALTER TABLE photo_catalog ADD COLUMN cloud_id TEXT;",
            nil, nil, nil
        ) == SQLITE_OK
    }

    // MARK: - Bind/column helpers

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            bindText(stmt, index, value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
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

    @discardableResult
    private func requireOperational(_ condition: Bool) -> Bool {
        if !condition { operationFailed = true }
        return condition
    }
}
