import Foundation
import PhotosCore
import SQLite3

/// App-owned SQLite manifest of upload identities (`upload-manifest-v1.sqlite`): the persistence
/// behind "don't rehash unchanged files" and "remember known duplicates across runs". Lives next
/// to `library-v1.sqlite` in the per-account directory, so sign-out purge covers it wholesale
/// (`LibraryDatabaseLocation.purgeAccountData` removes the directory).
///
/// Same platform posture as `TimelineMetadataStore`: raw system SQLite (WAL), platform tuning
/// injected via `LibraryDatabasePolicy`, fail-closed reset when the on-disk schema comes from a
/// newer build (the manifest is a pure cache - resetting only costs rehashing).
///
/// Stores names, sizes, dates and hex hashes - never file contents. Thread-safe via an internal
/// lock: the upload queue hits it from concurrent per-item tasks.
public final class UploadIdentityManifestStore: UploadIdentityStore, @unchecked Sendable {

    public static let databaseFileName = "upload-manifest-v1.sqlite"

    /// Persisted `outcome` values. Raw strings (not the decision enum) so the schema never has to
    /// migrate when decision cases evolve; unknown values are simply treated as "no decision".
    public enum Outcome: String, Sendable {
        /// We uploaded this resource ourselves; `remote_vol`/`remote_link` identify the node.
        case uploaded
        /// The server reported an ACTIVE duplicate for this exact identity.
        case duplicateActive
        /// The server reported the identity as trashed - skipped, user deleted it intentionally.
        case duplicateTrashed
    }

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
        // From-the-future or corrupt: the manifest is a rehashable cache, so reset it.
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
        CREATE TABLE IF NOT EXISTS manifest_info(key TEXT PRIMARY KEY, value INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS upload_identity(
          source_kind   TEXT NOT NULL,
          source_id     TEXT NOT NULL,
          resource      TEXT NOT NULL,
          filename      TEXT NOT NULL,
          corrected     TEXT NOT NULL,
          size          INTEGER NOT NULL,
          mtime         REAL NOT NULL,
          sha1_hex      TEXT NOT NULL,
          name_hash     TEXT NOT NULL,
          content_hash  TEXT NOT NULL,
          key_epoch     TEXT NOT NULL,
          remote_vol    TEXT,
          remote_link   TEXT,
          outcome       TEXT,
          updated_at    REAL NOT NULL,
          PRIMARY KEY (source_kind, source_id, resource)
        );
        CREATE INDEX IF NOT EXISTS upload_identity_content_idx
          ON upload_identity(content_hash, key_epoch);
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
        guard sqlite3_prepare_v2(handle, "SELECT value FROM manifest_info WHERE key='schema';", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        var onDisk: Int?
        if sqlite3_step(stmt) == SQLITE_ROW { onDisk = Int(sqlite3_column_int(stmt, 0)) }
        sqlite3_finalize(stmt)
        if let onDisk, onDisk > schemaVersion { return false }
        return sqlite3_exec(
            handle,
            "INSERT INTO manifest_info(key, value) VALUES('schema', \(schemaVersion)) "
                + "ON CONFLICT(key) DO UPDATE SET value=excluded.value;",
            nil, nil, nil
        ) == SQLITE_OK
    }

    // MARK: UploadIdentityStore

    public func record(for source: UploadSourceIdentity) -> UploadIdentityRecord? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT filename, corrected, size, mtime, sha1_hex, name_hash, content_hash,
                       key_epoch, remote_vol, remote_link, outcome, updated_at
                FROM upload_identity WHERE source_kind=? AND source_id=? AND resource=?;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, source.kind.rawValue)
            bindText(stmt, 2, source.identifier)
            bindText(stmt, 3, source.resource.rawValue)
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return UploadIdentityRecord(
                source: source,
                filename: columnText(stmt, 0) ?? "",
                correctedName: columnText(stmt, 1) ?? "",
                fileSize: sqlite3_column_int64(stmt, 2),
                modificationDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                sha1Hex: columnText(stmt, 4) ?? "",
                nameHash: columnText(stmt, 5) ?? "",
                contentHash: columnText(stmt, 6) ?? "",
                hashKeyEpoch: columnText(stmt, 7) ?? "",
                remoteVolumeID: columnText(stmt, 8),
                remoteLinkID: columnText(stmt, 9),
                outcome: columnText(stmt, 10),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 11))
            )
        }
    }

    public func trustedRecord(contentHash: String, hashKeyEpoch: String) -> UploadIdentityRecord? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT source_kind, source_id, resource, filename, corrected, size, mtime,
                       sha1_hex, name_hash, remote_vol, remote_link, outcome, updated_at
                FROM upload_identity
                WHERE content_hash=? AND key_epoch=?
                  AND remote_link IS NOT NULL
                  AND outcome IN ('uploaded', 'duplicateActive')
                LIMIT 1;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, contentHash)
            bindText(stmt, 2, hashKeyEpoch)
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let kindRaw = columnText(stmt, 0),
                  let kind = UploadSourceIdentity.Kind(rawValue: kindRaw),
                  let identifier = columnText(stmt, 1),
                  let resourceRaw = columnText(stmt, 2),
                  let resource = UploadSourceIdentity.Resource(rawValue: resourceRaw) else {
                return nil
            }
            return UploadIdentityRecord(
                source: UploadSourceIdentity(kind: kind, identifier: identifier, resource: resource),
                filename: columnText(stmt, 3) ?? "",
                correctedName: columnText(stmt, 4) ?? "",
                fileSize: sqlite3_column_int64(stmt, 5),
                modificationDate: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6)),
                sha1Hex: columnText(stmt, 7) ?? "",
                nameHash: columnText(stmt, 8) ?? "",
                contentHash: contentHash,
                hashKeyEpoch: hashKeyEpoch,
                remoteVolumeID: columnText(stmt, 9),
                remoteLinkID: columnText(stmt, 10),
                outcome: columnText(stmt, 11),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
            )
        }
    }

    public func upsert(_ record: UploadIdentityRecord) {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                INSERT INTO upload_identity(
                  source_kind, source_id, resource, filename, corrected, size, mtime,
                  sha1_hex, name_hash, content_hash, key_epoch, remote_vol, remote_link,
                  outcome, updated_at
                ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(source_kind, source_id, resource) DO UPDATE SET
                  filename=excluded.filename, corrected=excluded.corrected, size=excluded.size,
                  mtime=excluded.mtime, sha1_hex=excluded.sha1_hex, name_hash=excluded.name_hash,
                  content_hash=excluded.content_hash, key_epoch=excluded.key_epoch,
                  remote_vol=excluded.remote_vol, remote_link=excluded.remote_link,
                  outcome=excluded.outcome, updated_at=excluded.updated_at;
                """,
                -1, &stmt, nil
            ) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, record.source.kind.rawValue)
            bindText(stmt, 2, record.source.identifier)
            bindText(stmt, 3, record.source.resource.rawValue)
            bindText(stmt, 4, record.filename)
            bindText(stmt, 5, record.correctedName)
            sqlite3_bind_int64(stmt, 6, record.fileSize)
            sqlite3_bind_double(stmt, 7, record.modificationDate.timeIntervalSince1970)
            bindText(stmt, 8, record.sha1Hex)
            bindText(stmt, 9, record.nameHash)
            bindText(stmt, 10, record.contentHash)
            bindText(stmt, 11, record.hashKeyEpoch)
            bindOptionalText(stmt, 12, record.remoteVolumeID)
            bindOptionalText(stmt, 13, record.remoteLinkID)
            bindOptionalText(stmt, 14, record.outcome)
            sqlite3_bind_double(stmt, 15, record.updatedAt.timeIntervalSince1970)
            _ = sqlite3_step(stmt)
        }
    }

    /// Row count - surfaced for tests and a future cache-status UI.
    public func count() -> Int {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM upload_identity;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
        }
    }

    // MARK: Column/bind helpers

    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)   // SQLITE_TRANSIENT

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: text)
    }
}
