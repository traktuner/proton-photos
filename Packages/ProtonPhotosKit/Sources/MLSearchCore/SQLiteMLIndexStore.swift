import Foundation
import PhotosCore
import SQLite3

/// Persistent, local-only embedding store (`ml-search-index-v1.sqlite`).
///
/// This is a derived index, not user data: if the schema is from the future or the file is
/// corrupted, resetting only costs a local re-index (the library of record is the server).
/// Follows the repo's raw-sqlite store pattern (`UploadBackupStateManifestStore`): WAL,
/// `LibraryDatabasePolicy`-injected PRAGMAs, `NSLock`-serialized handle, delete-and-recreate
/// on open failure, `PRAGMA optimize` on close.
///
/// ## Layout
/// Rowid table (blobs stay out of the index B-tree) + one UNIQUE index in
/// `(model_identifier, model_version, volume_id, node_id)` order. That single index serves:
/// first-write-wins enforcement (`INSERT OR IGNORE`), per-key membership, per-epoch
/// count/list/stream (all descriptor-prefixed) — without touching vector pages.
///
/// ## Write path
/// One `BEGIN IMMEDIATE … COMMIT` transaction per `upsert` batch, one prepared statement
/// reused across records, no per-record fsync (`synchronous=NORMAL` + WAL).
///
/// ## Vector format
/// Raw little-endian `Float32` blob (native layout on all Apple targets), tagged with
/// `embedding_precision` so fp16/int8 rows can coexist later without schema churn. Readers
/// skip rows whose precision or dimension they don't understand.
public final class SQLiteMLIndexStore: MLIndexStore, @unchecked Sendable {
    public static let databaseFileName = "ml-search-index-v1.sqlite"

    private static let schemaVersion: Int32 = 1
    private static let membershipChunkSize = 200

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    // MARK: - Writes

    @discardableResult
    public func upsert(_ records: [MLEmbeddingRecord]) -> MLIndexBatchReport {
        guard !records.isEmpty else { return MLIndexBatchReport() }
        var indexed = 0
        var skipped = 0
        var rejected = 0
        var failed = 0

        lock.withLock {
            guard db != nil, sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
                failed = records.count
                return
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                INSERT OR IGNORE INTO ml_embeddings(
                  volume_id, node_id, model_identifier, model_version,
                  embedding_dimension, embedding_precision, vector, capture_time, indexed_at
                ) VALUES(?,?,?,?,?,?,?,?,?);
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                failed = records.count
                return
            }
            defer { sqlite3_finalize(stmt) }

            for record in records {
                guard record.isDimensionConsistent else {
                    rejected += 1
                    continue
                }
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, record.uid.volumeID)
                bindText(stmt, 2, record.uid.nodeID)
                bindText(stmt, 3, record.descriptor.identifier)
                sqlite3_bind_int64(stmt, 4, Int64(record.descriptor.version))
                sqlite3_bind_int64(stmt, 5, Int64(record.descriptor.embeddingDimension))
                bindText(stmt, 6, MLEmbeddingPrecision.float32.rawValue)
                record.vector.withUnsafeBufferPointer { buffer in
                    sqlite3_bind_blob(stmt, 7, buffer.baseAddress, Int32(buffer.count * MemoryLayout<Float32>.size), transient)
                }
                if let captureTime = record.captureTime {
                    sqlite3_bind_double(stmt, 8, captureTime.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 8)
                }
                sqlite3_bind_double(stmt, 9, record.timestamp.timeIntervalSince1970)

                if sqlite3_step(stmt) == SQLITE_DONE {
                    // OR IGNORE: 0 changes means the unique key already existed (first write wins).
                    if sqlite3_changes(db) > 0 { indexed += 1 } else { skipped += 1 }
                } else {
                    failed += 1
                }
            }
            sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        }

        return MLIndexBatchReport(
            total: records.count,
            indexed: indexed,
            skippedAlreadyIndexed: skipped,
            permanentFailure: rejected,
            transientFailure: failed
        )
    }

    public func remove(uid: PhotoUID, descriptor: MLModelDescriptor) {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "DELETE FROM ml_embeddings WHERE model_identifier=? AND model_version=? AND volume_id=? AND node_id=?;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindDescriptor(stmt, descriptor)
            bindText(stmt, 3, uid.volumeID)
            bindText(stmt, 4, uid.nodeID)
            _ = sqlite3_step(stmt)
        }
    }

    public func removeAll(for descriptor: MLModelDescriptor) {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "DELETE FROM ml_embeddings WHERE model_identifier=? AND model_version=?;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindDescriptor(stmt, descriptor)
            _ = sqlite3_step(stmt)
        }
    }

    // MARK: - Membership / coverage

    public func contains(uid: PhotoUID, descriptor: MLModelDescriptor) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT 1 FROM ml_embeddings WHERE model_identifier=? AND model_version=? AND volume_id=? AND node_id=? LIMIT 1;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindDescriptor(stmt, descriptor)
            bindText(stmt, 3, uid.volumeID)
            bindText(stmt, 4, uid.nodeID)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    public func indexedUIDs(for descriptor: MLModelDescriptor, from uids: [PhotoUID]) -> Set<PhotoUID> {
        guard !uids.isEmpty else { return [] }
        var found: Set<PhotoUID> = []
        lock.withLock {
            // Chunked row-value IN so a 100k+ membership check never builds one giant
            // statement and never loads vectors (index-only lookup).
            var start = 0
            while start < uids.count {
                let end = min(start + Self.membershipChunkSize, uids.count)
                let chunk = uids[start..<end]
                start = end

                let placeholders = Array(repeating: "(?,?)", count: chunk.count).joined(separator: ",")
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(
                    db,
                    """
                    SELECT volume_id, node_id FROM ml_embeddings
                    WHERE model_identifier=? AND model_version=?
                      AND (volume_id, node_id) IN (VALUES \(placeholders));
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK else { continue }
                defer { sqlite3_finalize(stmt) }
                bindDescriptor(stmt, descriptor)
                var index: Int32 = 3
                for uid in chunk {
                    bindText(stmt, index, uid.volumeID)
                    bindText(stmt, index + 1, uid.nodeID)
                    index += 2
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    found.insert(PhotoUID(volumeID: columnText(stmt, 0), nodeID: columnText(stmt, 1)))
                }
            }
        }
        return found
    }

    public func allIndexedUIDs(for descriptor: MLModelDescriptor) -> [PhotoUID] {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT volume_id, node_id FROM ml_embeddings
                WHERE model_identifier=? AND model_version=?
                ORDER BY volume_id, node_id;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindDescriptor(stmt, descriptor)
            var uids: [PhotoUID] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                uids.append(PhotoUID(volumeID: columnText(stmt, 0), nodeID: columnText(stmt, 1)))
            }
            return uids
        }
    }

    public func count(for descriptor: MLModelDescriptor) -> Int {
        lock.withLock { countLocked(for: descriptor) }
    }

    // MARK: - Reads

    public func allRecords(for descriptor: MLModelDescriptor) -> [MLEmbeddingRecord] {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT volume_id, node_id, vector, indexed_at, capture_time FROM ml_embeddings
                WHERE model_identifier=? AND model_version=? AND embedding_dimension=? AND embedding_precision=?
                ORDER BY volume_id, node_id;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindEpochRead(stmt, descriptor)

            var records: [MLEmbeddingRecord] = []
            let expectedBytes = descriptor.embeddingDimension * MemoryLayout<Float32>.size
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard Int(sqlite3_column_bytes(stmt, 2)) == expectedBytes,
                      let blob = sqlite3_column_blob(stmt, 2) else { continue }
                let raw = UnsafeRawBufferPointer(start: blob, count: expectedBytes)
                let captureTime: Date? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                records.append(MLEmbeddingRecord(
                    uid: PhotoUID(volumeID: columnText(stmt, 0), nodeID: columnText(stmt, 1)),
                    descriptor: descriptor,
                    vector: ContiguousArray(raw.bindMemory(to: Float32.self)),
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    captureTime: captureTime
                ))
            }
            return records
        }
    }

    /// Streams rows straight from disk into one packed buffer — no per-record arrays, no
    /// intermediate `MLEmbeddingRecord`s. This is the query-path load for large epochs.
    public func vectorBlock(for descriptor: MLModelDescriptor) -> MLVectorBlock {
        lock.withLock {
            var block = MLVectorBlock(descriptor: descriptor)
            block.reserveCapacity(countLocked(for: descriptor))

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT volume_id, node_id, vector FROM ml_embeddings
                WHERE model_identifier=? AND model_version=? AND embedding_dimension=? AND embedding_precision=?
                ORDER BY volume_id, node_id;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return block }
            defer { sqlite3_finalize(stmt) }
            bindEpochRead(stmt, descriptor)

            let expectedBytes = descriptor.embeddingDimension * MemoryLayout<Float32>.size
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard Int(sqlite3_column_bytes(stmt, 2)) == expectedBytes,
                      let blob = sqlite3_column_blob(stmt, 2) else { continue }
                block.append(
                    uid: PhotoUID(volumeID: columnText(stmt, 0), nodeID: columnText(stmt, 1)),
                    rawLittleEndianFloat32: UnsafeRawBufferPointer(start: blob, count: expectedBytes)
                )
            }
            return block
        }
    }

    // MARK: - Open / schema

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
        CREATE TABLE IF NOT EXISTS ml_embeddings(
          volume_id           TEXT NOT NULL,
          node_id             TEXT NOT NULL,
          model_identifier    TEXT NOT NULL,
          model_version       INTEGER NOT NULL,
          embedding_dimension INTEGER NOT NULL,
          embedding_precision TEXT NOT NULL,
          vector              BLOB NOT NULL,
          capture_time        REAL,
          indexed_at          REAL NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS ml_embeddings_key
          ON ml_embeddings(model_identifier, model_version, volume_id, node_id);
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
        guard sqlite3_prepare_v2(handle, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        let version = sqlite3_column_int(stmt, 0)
        if version == 0 {
            return sqlite3_exec(handle, "PRAGMA user_version=\(schemaVersion);", nil, nil, nil) == SQLITE_OK
        }
        return version == schemaVersion
    }

    // MARK: - Helpers (lock held)

    private func countLocked(for descriptor: MLModelDescriptor) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT COUNT(*) FROM ml_embeddings WHERE model_identifier=? AND model_version=?;",
            -1, &stmt, nil
        ) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindDescriptor(stmt, descriptor)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func bindDescriptor(_ stmt: OpaquePointer?, _ descriptor: MLModelDescriptor) {
        bindText(stmt, 1, descriptor.identifier)
        sqlite3_bind_int64(stmt, 2, Int64(descriptor.version))
    }

    private func bindEpochRead(_ stmt: OpaquePointer?, _ descriptor: MLModelDescriptor) {
        bindDescriptor(stmt, descriptor)
        sqlite3_bind_int64(stmt, 3, Int64(descriptor.embeddingDimension))
        bindText(stmt, 4, MLEmbeddingPrecision.float32.rawValue)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }
}
