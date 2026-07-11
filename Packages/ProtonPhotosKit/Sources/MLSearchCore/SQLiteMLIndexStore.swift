import Foundation
import PhotosCore
import SQLite3

/// Local derived index with WAL, batched transactions and authenticated vector encryption.
/// Corrupt or wrong-key rows are ignored and can be rebuilt from the media cache.
///
/// Rows persist vectors as IEEE-754 binary16 (`MLFloat16Codec`): half the disk footprint and
/// read/write I/O of Float32 at ~2^-11 relative precision — far below ranking noise for
/// normalized CLIP-family embeddings. The in-memory scoring block stays Float32; widening
/// happens once, streamed, on block load. A `user_version` mismatch resets the ML-only schema
/// (vectors are derived data, rebuilt from the media cache — no migration machinery).
public final class SQLiteMLIndexStore: MLIndexStore, @unchecked Sendable {
    public static let databaseFileName = "ml-search-index-v1.sqlite"

    /// v3: vector blobs switched from Float32 to binary16 rows (clean reset, no migration).
    private static let schemaVersion: Int32 = 3
    private static let membershipChunkSize = 200
    /// The one precision this build writes and reads. Rows with any other precision are
    /// invisible (skipped by the epoch-read predicate), never misinterpreted.
    private static let precision = MLEmbeddingPrecision.float16

    private var db: OpaquePointer?
    private let lock = NSLock()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let cipher: any MLVectorCipher

    public init?(url: URL, policy: LibraryDatabasePolicy = .conservative, cipher: any MLVectorCipher) {
        self.cipher = cipher
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
        var changedDescriptors: Set<MLModelDescriptor> = []
        var transactionFailed = false

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
            var clearFailureStmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "DELETE FROM ml_failures WHERE model_identifier=? AND model_version=? AND volume_id=? AND node_id=?;",
                -1, &clearFailureStmt, nil
            ) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                failed = records.count
                return
            }
            defer { sqlite3_finalize(clearFailureStmt) }

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
                bindText(stmt, 6, Self.precision.rawValue)
                let plaintext = MLFloat16Codec.encodeLittleEndian(record.vector)
                let ciphertext: Data
                do {
                    ciphertext = try cipher.seal(
                        plaintext,
                        context: MLVectorCipherContext(uid: record.uid, descriptor: record.descriptor)
                    )
                } catch {
                    failed += 1
                    continue
                }
                _ = ciphertext.withUnsafeBytes { buffer in
                    sqlite3_bind_blob(stmt, 7, buffer.baseAddress, Int32(buffer.count), transient)
                }
                if let captureTime = record.captureTime {
                    sqlite3_bind_double(stmt, 8, captureTime.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 8)
                }
                sqlite3_bind_double(stmt, 9, record.timestamp.timeIntervalSince1970)

                if sqlite3_step(stmt) == SQLITE_DONE {
                    // OR IGNORE: 0 changes means the unique key already existed (first write wins).
                    if sqlite3_changes(db) > 0 {
                        indexed += 1
                        changedDescriptors.insert(record.descriptor)
                    } else {
                        skipped += 1
                    }
                    sqlite3_reset(clearFailureStmt)
                    sqlite3_clear_bindings(clearFailureStmt)
                    bindText(clearFailureStmt, 1, record.descriptor.identifier)
                    sqlite3_bind_int64(clearFailureStmt, 2, Int64(record.descriptor.version))
                    bindText(clearFailureStmt, 3, record.uid.volumeID)
                    bindText(clearFailureStmt, 4, record.uid.nodeID)
                    guard sqlite3_step(clearFailureStmt) == SQLITE_DONE else {
                        transactionFailed = true
                        break
                    }
                } else {
                    failed += 1
                }
            }
            if !transactionFailed {
                for descriptor in changedDescriptors where !bumpGenerationLocked(for: descriptor) {
                    transactionFailed = true
                    break
                }
            }
            if transactionFailed || sqlite3_exec(db, "COMMIT;", nil, nil, nil) != SQLITE_OK {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                indexed = 0
                skipped = 0
                failed = records.count - rejected
            }
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
        remove(uids: [uid], descriptor: descriptor)
    }

    public func remove(uids: [PhotoUID], descriptor: MLModelDescriptor) {
        guard !uids.isEmpty else { return }
        lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return }
            var embeddingStmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "DELETE FROM ml_embeddings WHERE model_identifier=? AND model_version=? AND volume_id=? AND node_id=?;",
                -1, &embeddingStmt, nil
            ) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return
            }
            defer { sqlite3_finalize(embeddingStmt) }
            var failureStmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "DELETE FROM ml_failures WHERE model_identifier=? AND model_version=? AND volume_id=? AND node_id=?;",
                -1, &failureStmt, nil
            ) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return
            }
            defer { sqlite3_finalize(failureStmt) }

            var vectorsChanged = false
            for uid in Set(uids) {
                sqlite3_reset(embeddingStmt)
                sqlite3_clear_bindings(embeddingStmt)
                bindDescriptor(embeddingStmt, descriptor)
                bindText(embeddingStmt, 3, uid.volumeID)
                bindText(embeddingStmt, 4, uid.nodeID)
                guard sqlite3_step(embeddingStmt) == SQLITE_DONE else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return
                }
                vectorsChanged = sqlite3_changes(db) > 0 || vectorsChanged

                sqlite3_reset(failureStmt)
                sqlite3_clear_bindings(failureStmt)
                bindDescriptor(failureStmt, descriptor)
                bindText(failureStmt, 3, uid.volumeID)
                bindText(failureStmt, 4, uid.nodeID)
                guard sqlite3_step(failureStmt) == SQLITE_DONE else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return
                }
            }

            guard (!vectorsChanged || bumpGenerationLocked(for: descriptor)),
                  sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return
            }
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
            if sqlite3_step(stmt) == SQLITE_DONE, sqlite3_changes(db) > 0 {
                bumpGenerationLocked(for: descriptor)
            }
            deleteFailuresLocked(for: descriptor)
        }
    }

    // MARK: - Membership / coverage

    public func contains(uid: PhotoUID, descriptor: MLModelDescriptor) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT 1 FROM ml_embeddings
                WHERE model_identifier=? AND model_version=?
                  AND embedding_dimension=? AND embedding_precision=?
                  AND volume_id=? AND node_id=? LIMIT 1;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindEpochRead(stmt, descriptor)
            bindText(stmt, 5, uid.volumeID)
            bindText(stmt, 6, uid.nodeID)
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
                      AND embedding_dimension=? AND embedding_precision=?
                      AND (volume_id, node_id) IN (VALUES \(placeholders));
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK else { continue }
                defer { sqlite3_finalize(stmt) }
                bindEpochRead(stmt, descriptor)
                var index: Int32 = 5
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
                  AND embedding_dimension=? AND embedding_precision=?
                ORDER BY volume_id, node_id;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindEpochRead(stmt, descriptor)
            var uids: [PhotoUID] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                uids.append(PhotoUID(volumeID: columnText(stmt, 0), nodeID: columnText(stmt, 1)))
            }
            return uids
        }
    }

    public func allTrackedUIDs(for descriptor: MLModelDescriptor) -> [PhotoUID] {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT volume_id, node_id FROM ml_embeddings
                WHERE model_identifier=? AND model_version=?
                  AND embedding_dimension=? AND embedding_precision=?
                UNION
                SELECT volume_id, node_id FROM ml_failures
                WHERE model_identifier=? AND model_version=?
                ORDER BY volume_id, node_id;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindEpochRead(stmt, descriptor)
            bindText(stmt, 5, descriptor.identifier)
            sqlite3_bind_int64(stmt, 6, Int64(descriptor.version))
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

    public func generation(for descriptor: MLModelDescriptor) -> UInt64 {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT generation FROM ml_epoch_state WHERE model_identifier=? AND model_version=?;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            bindDescriptor(stmt, descriptor)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return UInt64(max(0, sqlite3_column_int64(stmt, 0)))
        }
    }

    @discardableResult
    public func recordFailures(_ records: [MLIndexFailureRecord]) -> Bool {
        guard !records.isEmpty else { return true }
        return lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                INSERT INTO ml_failures(
                  volume_id, node_id, model_identifier, model_version,
                  kind, reason, attempts, updated_at
                )
                SELECT ?,?,?,?,?,?,?,?
                WHERE NOT EXISTS(
                  SELECT 1 FROM ml_embeddings
                  WHERE model_identifier=? AND model_version=? AND volume_id=? AND node_id=?
                )
                ON CONFLICT(model_identifier, model_version, volume_id, node_id) DO UPDATE SET
                  kind=excluded.kind,
                  reason=excluded.reason,
                  attempts=excluded.attempts,
                  updated_at=excluded.updated_at;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            defer { sqlite3_finalize(stmt) }

            for record in records {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bindText(stmt, 1, record.uid.volumeID)
                bindText(stmt, 2, record.uid.nodeID)
                bindText(stmt, 3, record.descriptor.identifier)
                sqlite3_bind_int64(stmt, 4, Int64(record.descriptor.version))
                bindText(stmt, 5, record.kind.rawValue)
                if let reason = record.reason { bindText(stmt, 6, reason) } else { sqlite3_bind_null(stmt, 6) }
                sqlite3_bind_int64(stmt, 7, Int64(record.attempts))
                sqlite3_bind_double(stmt, 8, record.updatedAt.timeIntervalSince1970)
                bindText(stmt, 9, record.descriptor.identifier)
                sqlite3_bind_int64(stmt, 10, Int64(record.descriptor.version))
                bindText(stmt, 11, record.uid.volumeID)
                bindText(stmt, 12, record.uid.nodeID)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                    return false
                }
            }
            return sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK
        }
    }

    public func failureRecords(
        for descriptor: MLModelDescriptor,
        from uids: [PhotoUID]
    ) -> [PhotoUID: MLIndexFailureRecord] {
        guard !uids.isEmpty else { return [:] }
        return lock.withLock {
            var found: [PhotoUID: MLIndexFailureRecord] = [:]
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
                    SELECT volume_id, node_id, kind, reason, attempts, updated_at
                    FROM ml_failures
                    WHERE model_identifier=? AND model_version=?
                      AND (volume_id, node_id) IN (VALUES \(placeholders));
                    """,
                    -1, &stmt, nil
                ) == SQLITE_OK else { continue }
                bindDescriptor(stmt, descriptor)
                var index: Int32 = 3
                for uid in chunk {
                    bindText(stmt, index, uid.volumeID)
                    bindText(stmt, index + 1, uid.nodeID)
                    index += 2
                }
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let uid = PhotoUID(volumeID: columnText(stmt, 0), nodeID: columnText(stmt, 1))
                    guard let kind = MLIndexFailureKind(rawValue: columnText(stmt, 2)) else { continue }
                    let reason = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : columnText(stmt, 3)
                    found[uid] = MLIndexFailureRecord(
                        uid: uid,
                        descriptor: descriptor,
                        kind: kind,
                        reason: reason,
                        attempts: Int(sqlite3_column_int64(stmt, 4)),
                        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                    )
                }
                sqlite3_finalize(stmt)
            }
            return found
        }
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
            bindEpochRead(stmt, descriptor)

            var records: [MLEmbeddingRecord] = []
            var invalidUIDs: Set<PhotoUID> = []
            let expectedBytes = descriptor.embeddingDimension * MLFloat16Codec.bytesPerElement
            let expectedSealedBytes = cipher.sealedByteCount(forPlaintextByteCount: expectedBytes)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let uid = PhotoUID(volumeID: columnText(stmt, 0), nodeID: columnText(stmt, 1))
                let encryptedBytes = Int(sqlite3_column_bytes(stmt, 2))
                guard encryptedBytes > 0, let blob = sqlite3_column_blob(stmt, 2) else {
                    invalidUIDs.insert(uid)
                    continue
                }
                // Byte-count validation BEFORE any decryption: a truncated/corrupt blob is
                // skipped for the cost of a length compare, never a crypto operation.
                if let expectedSealedBytes, encryptedBytes != expectedSealedBytes {
                    invalidUIDs.insert(uid)
                    continue
                }
                let ciphertext = Data(bytes: blob, count: encryptedBytes)
                let context = MLVectorCipherContext(uid: uid, descriptor: descriptor)
                guard let plaintext = try? cipher.open(ciphertext, context: context),
                      let vector = plaintext.withUnsafeBytes({
                          MLFloat16Codec.decodeLittleEndian($0, dimension: descriptor.embeddingDimension)
                      }) else {
                    invalidUIDs.insert(uid)
                    continue
                }
                let captureTime: Date? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                records.append(MLEmbeddingRecord(
                    uid: context.uid,
                    descriptor: descriptor,
                    vector: vector,
                    timestamp: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                    captureTime: captureTime
                ))
            }
            sqlite3_finalize(stmt)
            deleteInvalidRowsLocked(invalidUIDs, descriptor: descriptor)
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
            bindEpochRead(stmt, descriptor)

            var invalidUIDs: Set<PhotoUID> = []
            let expectedBytes = descriptor.embeddingDimension * MLFloat16Codec.bytesPerElement
            let expectedSealedBytes = cipher.sealedByteCount(forPlaintextByteCount: expectedBytes)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let uid = PhotoUID(volumeID: columnText(stmt, 0), nodeID: columnText(stmt, 1))
                let encryptedBytes = Int(sqlite3_column_bytes(stmt, 2))
                guard encryptedBytes > 0, let blob = sqlite3_column_blob(stmt, 2) else {
                    invalidUIDs.insert(uid)
                    continue
                }
                // Length check before decryption — corrupt rows never cost a crypto pass.
                if let expectedSealedBytes, encryptedBytes != expectedSealedBytes {
                    invalidUIDs.insert(uid)
                    continue
                }
                let ciphertext = Data(bytes: blob, count: encryptedBytes)
                let context = MLVectorCipherContext(uid: uid, descriptor: descriptor)
                guard let plaintext = try? cipher.open(ciphertext, context: context),
                      plaintext.count == expectedBytes else {
                    invalidUIDs.insert(uid)
                    continue
                }
                // Widen binary16 → Float32 straight into the packed scoring buffer.
                _ = plaintext.withUnsafeBytes { raw in
                    block.append(uid: uid, rawLittleEndianFloat16: raw)
                }
            }
            sqlite3_finalize(stmt)
            deleteInvalidRowsLocked(invalidUIDs, descriptor: descriptor)
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
        CREATE TABLE IF NOT EXISTS ml_failures(
          volume_id        TEXT NOT NULL,
          node_id          TEXT NOT NULL,
          model_identifier TEXT NOT NULL,
          model_version    INTEGER NOT NULL,
          kind             TEXT NOT NULL,
          reason           TEXT,
          attempts         INTEGER NOT NULL,
          updated_at       REAL NOT NULL,
          PRIMARY KEY(model_identifier, model_version, volume_id, node_id)
        ) WITHOUT ROWID;
        CREATE TABLE IF NOT EXISTS ml_epoch_state(
          model_identifier TEXT NOT NULL,
          model_version    INTEGER NOT NULL,
          generation       INTEGER NOT NULL,
          PRIMARY KEY(model_identifier, model_version)
        ) WITHOUT ROWID;
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
            """
            SELECT COUNT(*) FROM ml_embeddings
            WHERE model_identifier=? AND model_version=?
              AND embedding_dimension=? AND embedding_precision=?;
            """,
            -1, &stmt, nil
        ) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        bindEpochRead(stmt, descriptor)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func deleteInvalidRowsLocked(_ uids: Set<PhotoUID>, descriptor: MLModelDescriptor) {
        guard !uids.isEmpty,
              sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "DELETE FROM ml_embeddings WHERE model_identifier=? AND model_version=? AND volume_id=? AND node_id=?;",
            -1, &stmt, nil
        ) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return
        }
        defer { sqlite3_finalize(stmt) }

        var deleted = false
        for uid in uids {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindDescriptor(stmt, descriptor)
            bindText(stmt, 3, uid.volumeID)
            bindText(stmt, 4, uid.nodeID)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return
            }
            deleted = deleted || sqlite3_changes(db) > 0
        }
        guard !deleted || bumpGenerationLocked(for: descriptor),
              sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            return
        }
    }

    @discardableResult
    private func bumpGenerationLocked(for descriptor: MLModelDescriptor) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO ml_epoch_state(model_identifier, model_version, generation)
            VALUES(?,?,1)
            ON CONFLICT(model_identifier, model_version) DO UPDATE SET generation=generation+1;
            """,
            -1, &stmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindDescriptor(stmt, descriptor)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func deleteFailuresLocked(for descriptor: MLModelDescriptor) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "DELETE FROM ml_failures WHERE model_identifier=? AND model_version=?;",
            -1, &stmt, nil
        ) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindDescriptor(stmt, descriptor)
        _ = sqlite3_step(stmt)
    }

    private func bindDescriptor(_ stmt: OpaquePointer?, _ descriptor: MLModelDescriptor) {
        bindText(stmt, 1, descriptor.identifier)
        sqlite3_bind_int64(stmt, 2, Int64(descriptor.version))
    }

    private func bindEpochRead(_ stmt: OpaquePointer?, _ descriptor: MLModelDescriptor) {
        bindDescriptor(stmt, descriptor)
        sqlite3_bind_int64(stmt, 3, Int64(descriptor.embeddingDimension))
        bindText(stmt, 4, Self.precision.rawValue)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String {
        guard let cString = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: cString)
    }
}
