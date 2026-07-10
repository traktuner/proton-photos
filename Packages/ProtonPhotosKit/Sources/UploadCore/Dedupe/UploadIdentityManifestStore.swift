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
public final class UploadIdentityManifestStore: UploadIdentityStore, UploadRemoteContentIndexStore, @unchecked Sendable {

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
    private static let schemaVersion = 4

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
        CREATE TABLE IF NOT EXISTS remote_content_index(
          key_epoch     TEXT NOT NULL,
          content_hash  TEXT NOT NULL,
          remote_link   TEXT NOT NULL,
          PRIMARY KEY (key_epoch, content_hash, remote_link)
        );
        CREATE INDEX IF NOT EXISTS remote_content_index_lookup_idx
          ON remote_content_index(key_epoch, content_hash);
        CREATE TABLE IF NOT EXISTS remote_content_unresolved(
          key_epoch     TEXT NOT NULL,
          remote_link   TEXT NOT NULL,
          PRIMARY KEY (key_epoch, remote_link)
        );
        CREATE TABLE IF NOT EXISTS remote_content_index_checkpoint(
          key_epoch     TEXT PRIMARY KEY,
          event_id      TEXT NOT NULL,
          refreshed_at  REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS remote_asset_index(
          key_epoch      TEXT NOT NULL,
          external_id    TEXT NOT NULL,
          revision_us    INTEGER NOT NULL,
          resource_count INTEGER NOT NULL,
          primary_link   TEXT NOT NULL,
          PRIMARY KEY (key_epoch, external_id, revision_us)
        );
        CREATE INDEX IF NOT EXISTS remote_asset_index_lookup_idx
          ON remote_asset_index(key_epoch, external_id, revision_us);
        CREATE TABLE IF NOT EXISTS remote_asset_index_link(
          key_epoch   TEXT NOT NULL,
          external_id TEXT NOT NULL,
          revision_us INTEGER NOT NULL,
          remote_link TEXT NOT NULL,
          PRIMARY KEY (key_epoch, external_id, revision_us, remote_link)
        );
        CREATE INDEX IF NOT EXISTS remote_asset_index_link_lookup_idx
          ON remote_asset_index_link(key_epoch, remote_link);
        CREATE TABLE IF NOT EXISTS remote_asset_index_checkpoint(
          key_epoch    TEXT PRIMARY KEY,
          event_id     TEXT NOT NULL,
          refreshed_at REAL NOT NULL
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
                  let resourceRaw = columnText(stmt, 2) else {
                return nil
            }
            let resource = UploadSourceIdentity.Resource(rawValue: resourceRaw)
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

    @discardableResult
    public func upsert(_ record: UploadIdentityRecord) -> Bool {
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
            ) == SQLITE_OK else { return false }
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
            return sqlite3_step(stmt) == SQLITE_DONE
        }
    }

    // MARK: UploadRemoteContentIndexStore

    public func remoteContentRecord(
        contentHash: String,
        hashKeyEpoch: String
    ) -> UploadRemoteContentIndexRecord? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT remote_link FROM remote_content_index WHERE key_epoch=? AND content_hash=? LIMIT 1;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, hashKeyEpoch)
            bindText(stmt, 2, contentHash)
            guard sqlite3_step(stmt) == SQLITE_ROW, let remoteLinkID = columnText(stmt, 0) else { return nil }
            return UploadRemoteContentIndexRecord(
                contentHash: contentHash,
                hashKeyEpoch: hashKeyEpoch,
                remoteLinkID: remoteLinkID
            )
        }
    }

    public func remoteContentIndexCheckpoint(
        hashKeyEpoch: String
    ) -> UploadRemoteContentIndexCheckpoint? {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT event_id, refreshed_at FROM remote_content_index_checkpoint WHERE key_epoch=?;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, hashKeyEpoch)
            guard sqlite3_step(stmt) == SQLITE_ROW, let eventID = columnText(stmt, 0) else { return nil }
            return UploadRemoteContentIndexCheckpoint(
                eventID: eventID,
                refreshedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            )
        }
    }

    public func hasRemoteAssetIndexCheckpoint(hashKeyEpoch: String) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT 1 FROM remote_asset_index_checkpoint WHERE key_epoch=? LIMIT 1;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return false }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, hashKeyEpoch)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    public func remoteAssetRecords(
        for identities: [UploadBackupExternalIdentity],
        hashKeyEpoch: String
    ) -> [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] {
        guard !identities.isEmpty else { return [:] }
        return lock.withLock {
            var recordStmt: OpaquePointer?
            var linksStmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                """
                SELECT resource_count, primary_link FROM remote_asset_index
                WHERE key_epoch=? AND external_id=? AND revision_us=?;
                """,
                -1, &recordStmt, nil
            ) == SQLITE_OK,
            sqlite3_prepare_v2(
                db,
                """
                SELECT remote_link FROM remote_asset_index_link
                WHERE key_epoch=? AND external_id=? AND revision_us=? ORDER BY remote_link;
                """,
                -1, &linksStmt, nil
            ) == SQLITE_OK else {
                sqlite3_finalize(recordStmt)
                sqlite3_finalize(linksStmt)
                return [:]
            }
            defer {
                sqlite3_finalize(recordStmt)
                sqlite3_finalize(linksStmt)
            }

            var result: [UploadBackupExternalIdentity: UploadRemoteAssetIndexRecord] = [:]
            result.reserveCapacity(identities.count)
            for identity in Set(identities) {
                sqlite3_reset(recordStmt)
                sqlite3_clear_bindings(recordStmt)
                bindText(recordStmt, 1, hashKeyEpoch)
                bindText(recordStmt, 2, identity.identifier)
                sqlite3_bind_int64(recordStmt, 3, identity.revision.rawValue)
                guard sqlite3_step(recordStmt) == SQLITE_ROW else { continue }
                let resourceCount = Int(sqlite3_column_int(recordStmt, 0))
                guard let primaryLink = columnText(recordStmt, 1) else { continue }

                sqlite3_reset(linksStmt)
                sqlite3_clear_bindings(linksStmt)
                bindText(linksStmt, 1, hashKeyEpoch)
                bindText(linksStmt, 2, identity.identifier)
                sqlite3_bind_int64(linksStmt, 3, identity.revision.rawValue)
                var links: [String] = []
                while sqlite3_step(linksStmt) == SQLITE_ROW {
                    if let link = columnText(linksStmt, 0) { links.append(link) }
                }
                guard links.count == resourceCount, links.contains(primaryLink) else { continue }
                links.removeAll { $0 == primaryLink }
                links.insert(primaryLink, at: 0)
                result[identity] = UploadRemoteAssetIndexRecord(
                    externalIdentity: identity,
                    resourceCount: resourceCount,
                    remoteLinkIDs: links,
                    hashKeyEpoch: hashKeyEpoch
                )
            }
            return result
        }
    }

    public func hasUnresolvedRemoteContent(hashKeyEpoch: String) -> Bool {
        lock.withLock {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "SELECT 1 FROM remote_content_unresolved WHERE key_epoch=? LIMIT 1;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return true }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, hashKeyEpoch)
            return sqlite3_step(stmt) == SQLITE_ROW
        }
    }

    @discardableResult
    public func replaceRemoteContentIndex(
        _ records: [UploadRemoteContentIndexRecord],
        remoteAssetRecords: [UploadRemoteAssetIndexRecord] = [],
        unresolvedRemoteLinkIDs: [String],
        hashKeyEpoch: String,
        checkpoint: UploadRemoteContentIndexCheckpoint
    ) -> Bool {
        guard records.allSatisfy({ $0.hashKeyEpoch == hashKeyEpoch }),
              remoteAssetRecords.allSatisfy({ $0.hashKeyEpoch == hashKeyEpoch }) else { return false }
        return lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            var deleteStmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "DELETE FROM remote_content_index WHERE key_epoch=?;",
                -1, &deleteStmt, nil
            ) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            bindText(deleteStmt, 1, hashKeyEpoch)
            let didDelete = sqlite3_step(deleteStmt) == SQLITE_DONE
            sqlite3_finalize(deleteStmt)

            var deleteUnresolved: OpaquePointer?
            guard didDelete, sqlite3_prepare_v2(
                db,
                "DELETE FROM remote_content_unresolved WHERE key_epoch=?;",
                -1, &deleteUnresolved, nil
            ) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            bindText(deleteUnresolved, 1, hashKeyEpoch)
            let didDeleteUnresolved = sqlite3_step(deleteUnresolved) == SQLITE_DONE
            sqlite3_finalize(deleteUnresolved)

            let didWrite = didDeleteUnresolved
                && deleteRemoteAssetEpochLocked(hashKeyEpoch: hashKeyEpoch)
                && writeRemoteContentRecordsLocked(records)
                && writeRemoteAssetRecordsLocked(remoteAssetRecords)
                && writeUnresolvedRemoteLinksLocked(
                    unresolvedRemoteLinkIDs,
                    hashKeyEpoch: hashKeyEpoch
                )
                && writeRemoteContentCheckpointLocked(checkpoint, hashKeyEpoch: hashKeyEpoch)
                && writeRemoteAssetCheckpointLocked(checkpoint, hashKeyEpoch: hashKeyEpoch)
            guard didWrite, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func applyRemoteContentIndexChanges(
        upserting records: [UploadRemoteContentIndexRecord],
        upsertingRemoteAssetRecords: [UploadRemoteAssetIndexRecord] = [],
        unresolvedRemoteLinkIDs: [String],
        removingRemoteLinkIDs: [String],
        hashKeyEpoch: String,
        checkpoint: UploadRemoteContentIndexCheckpoint
    ) -> Bool {
        guard records.allSatisfy({ $0.hashKeyEpoch == hashKeyEpoch }),
              upsertingRemoteAssetRecords.allSatisfy({ $0.hashKeyEpoch == hashKeyEpoch }) else { return false }
        return lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            let didDelete = deleteRemoteContentLinksLocked(
                removingRemoteLinkIDs,
                hashKeyEpoch: hashKeyEpoch
            ) && invalidateRemoteAssetRecordsLocked(
                touching: removingRemoteLinkIDs,
                hashKeyEpoch: hashKeyEpoch
            )
            let didWrite = didDelete
                && writeRemoteContentRecordsLocked(records)
                && writeRemoteAssetRecordsLocked(upsertingRemoteAssetRecords)
                && writeUnresolvedRemoteLinksLocked(
                    unresolvedRemoteLinkIDs,
                    hashKeyEpoch: hashKeyEpoch
                )
                && writeRemoteContentCheckpointLocked(checkpoint, hashKeyEpoch: hashKeyEpoch)
                && writeRemoteAssetCheckpointLocked(checkpoint, hashKeyEpoch: hashKeyEpoch)
            guard didWrite, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
        }
    }

    @discardableResult
    public func upsertRemoteContentRecord(_ record: UploadRemoteContentIndexRecord) -> Bool {
        lock.withLock {
            guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else { return false }
            let didDelete = deleteUnresolvedRemoteLinksLocked(
                [record.remoteLinkID],
                hashKeyEpoch: record.hashKeyEpoch
            )
            let didWrite = didDelete && writeRemoteContentRecordsLocked([record])
            guard didWrite, sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
                return false
            }
            return true
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

    private func writeRemoteContentRecordsLocked(_ records: [UploadRemoteContentIndexRecord]) -> Bool {
        guard !records.isEmpty else { return true }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO remote_content_index(key_epoch, content_hash, remote_link) VALUES(?,?,?);",
            -1, &stmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for record in records {
            guard !record.hashKeyEpoch.isEmpty, !record.contentHash.isEmpty, !record.remoteLinkID.isEmpty else {
                return false
            }
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, record.hashKeyEpoch)
            bindText(stmt, 2, record.contentHash)
            bindText(stmt, 3, record.remoteLinkID)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private func deleteRemoteAssetEpochLocked(hashKeyEpoch: String) -> Bool {
        for table in ["remote_asset_index_link", "remote_asset_index", "remote_asset_index_checkpoint"] {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(
                db,
                "DELETE FROM \(table) WHERE key_epoch=?;",
                -1, &stmt, nil
            ) == SQLITE_OK else { return false }
            bindText(stmt, 1, hashKeyEpoch)
            let succeeded = sqlite3_step(stmt) == SQLITE_DONE
            sqlite3_finalize(stmt)
            guard succeeded else { return false }
        }
        return true
    }

    private func writeRemoteAssetRecordsLocked(_ records: [UploadRemoteAssetIndexRecord]) -> Bool {
        guard !records.isEmpty else { return true }
        var recordStmt: OpaquePointer?
        var deleteLinksStmt: OpaquePointer?
        var linkStmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT OR REPLACE INTO remote_asset_index(
              key_epoch, external_id, revision_us, resource_count, primary_link
            ) VALUES(?,?,?,?,?);
            """,
            -1, &recordStmt, nil
        ) == SQLITE_OK,
        sqlite3_prepare_v2(
            db,
            "DELETE FROM remote_asset_index_link WHERE key_epoch=? AND external_id=? AND revision_us=?;",
            -1, &deleteLinksStmt, nil
        ) == SQLITE_OK,
        sqlite3_prepare_v2(
            db,
            """
            INSERT OR REPLACE INTO remote_asset_index_link(
              key_epoch, external_id, revision_us, remote_link
            ) VALUES(?,?,?,?);
            """,
            -1, &linkStmt, nil
        ) == SQLITE_OK else {
            sqlite3_finalize(recordStmt)
            sqlite3_finalize(deleteLinksStmt)
            sqlite3_finalize(linkStmt)
            return false
        }
        defer {
            sqlite3_finalize(recordStmt)
            sqlite3_finalize(deleteLinksStmt)
            sqlite3_finalize(linkStmt)
        }

        for record in records {
            let links = Array(Set(record.remoteLinkIDs.filter { !$0.isEmpty })).sorted()
            guard !record.hashKeyEpoch.isEmpty,
                  !record.externalIdentity.identifier.isEmpty,
                  links.count == record.resourceCount,
                  let primaryLink = record.remoteLinkIDs.first,
                  links.contains(primaryLink) else { return false }

            sqlite3_reset(deleteLinksStmt)
            sqlite3_clear_bindings(deleteLinksStmt)
            bindText(deleteLinksStmt, 1, record.hashKeyEpoch)
            bindText(deleteLinksStmt, 2, record.externalIdentity.identifier)
            sqlite3_bind_int64(deleteLinksStmt, 3, record.externalIdentity.revision.rawValue)
            guard sqlite3_step(deleteLinksStmt) == SQLITE_DONE else { return false }

            sqlite3_reset(recordStmt)
            sqlite3_clear_bindings(recordStmt)
            bindText(recordStmt, 1, record.hashKeyEpoch)
            bindText(recordStmt, 2, record.externalIdentity.identifier)
            sqlite3_bind_int64(recordStmt, 3, record.externalIdentity.revision.rawValue)
            sqlite3_bind_int(recordStmt, 4, Int32(record.resourceCount))
            bindText(recordStmt, 5, primaryLink)
            guard sqlite3_step(recordStmt) == SQLITE_DONE else { return false }

            for link in links {
                sqlite3_reset(linkStmt)
                sqlite3_clear_bindings(linkStmt)
                bindText(linkStmt, 1, record.hashKeyEpoch)
                bindText(linkStmt, 2, record.externalIdentity.identifier)
                sqlite3_bind_int64(linkStmt, 3, record.externalIdentity.revision.rawValue)
                bindText(linkStmt, 4, link)
                guard sqlite3_step(linkStmt) == SQLITE_DONE else { return false }
            }
        }
        return true
    }

    private func invalidateRemoteAssetRecordsLocked(
        touching linkIDs: [String],
        hashKeyEpoch: String
    ) -> Bool {
        let unique = Set(linkIDs.filter { !$0.isEmpty })
        guard !unique.isEmpty else { return true }
        var deleteProofStmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            DELETE FROM remote_asset_index
            WHERE key_epoch=? AND EXISTS(
              SELECT 1 FROM remote_asset_index_link AS links
              WHERE links.key_epoch=remote_asset_index.key_epoch
                AND links.external_id=remote_asset_index.external_id
                AND links.revision_us=remote_asset_index.revision_us
                AND links.remote_link=?
            );
            """,
            -1, &deleteProofStmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(deleteProofStmt) }
        for linkID in unique {
            sqlite3_reset(deleteProofStmt)
            sqlite3_clear_bindings(deleteProofStmt)
            bindText(deleteProofStmt, 1, hashKeyEpoch)
            bindText(deleteProofStmt, 2, linkID)
            guard sqlite3_step(deleteProofStmt) == SQLITE_DONE else { return false }
        }

        var deleteOrphansStmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            DELETE FROM remote_asset_index_link
            WHERE key_epoch=? AND NOT EXISTS(
              SELECT 1 FROM remote_asset_index AS asset
              WHERE asset.key_epoch=remote_asset_index_link.key_epoch
                AND asset.external_id=remote_asset_index_link.external_id
                AND asset.revision_us=remote_asset_index_link.revision_us
            );
            """,
            -1, &deleteOrphansStmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(deleteOrphansStmt) }
        bindText(deleteOrphansStmt, 1, hashKeyEpoch)
        return sqlite3_step(deleteOrphansStmt) == SQLITE_DONE
    }

    private func deleteRemoteContentLinksLocked(_ linkIDs: [String], hashKeyEpoch: String) -> Bool {
        let unique = Set(linkIDs.filter { !$0.isEmpty })
        guard !unique.isEmpty else { return true }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "DELETE FROM remote_content_index WHERE key_epoch=? AND remote_link=?;",
            -1, &stmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for linkID in unique {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, hashKeyEpoch)
            bindText(stmt, 2, linkID)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return deleteUnresolvedRemoteLinksLocked(Array(unique), hashKeyEpoch: hashKeyEpoch)
    }

    private func writeUnresolvedRemoteLinksLocked(
        _ linkIDs: [String],
        hashKeyEpoch: String
    ) -> Bool {
        let unique = Set(linkIDs.filter { !$0.isEmpty })
        guard !unique.isEmpty else { return true }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "INSERT OR REPLACE INTO remote_content_unresolved(key_epoch, remote_link) VALUES(?,?);",
            -1, &stmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for linkID in unique {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, hashKeyEpoch)
            bindText(stmt, 2, linkID)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private func deleteUnresolvedRemoteLinksLocked(
        _ linkIDs: [String],
        hashKeyEpoch: String
    ) -> Bool {
        let unique = Set(linkIDs.filter { !$0.isEmpty })
        guard !unique.isEmpty else { return true }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "DELETE FROM remote_content_unresolved WHERE key_epoch=? AND remote_link=?;",
            -1, &stmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        for linkID in unique {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, hashKeyEpoch)
            bindText(stmt, 2, linkID)
            guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        }
        return true
    }

    private func writeRemoteContentCheckpointLocked(
        _ checkpoint: UploadRemoteContentIndexCheckpoint,
        hashKeyEpoch: String
    ) -> Bool {
        guard !hashKeyEpoch.isEmpty, !checkpoint.eventID.isEmpty else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO remote_content_index_checkpoint(key_epoch, event_id, refreshed_at)
            VALUES(?,?,?) ON CONFLICT(key_epoch) DO UPDATE SET
              event_id=excluded.event_id, refreshed_at=excluded.refreshed_at;
            """,
            -1, &stmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hashKeyEpoch)
        bindText(stmt, 2, checkpoint.eventID)
        sqlite3_bind_double(stmt, 3, checkpoint.refreshedAt.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_DONE
    }

    private func writeRemoteAssetCheckpointLocked(
        _ checkpoint: UploadRemoteContentIndexCheckpoint,
        hashKeyEpoch: String
    ) -> Bool {
        guard !hashKeyEpoch.isEmpty, !checkpoint.eventID.isEmpty else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            """
            INSERT INTO remote_asset_index_checkpoint(key_epoch, event_id, refreshed_at)
            VALUES(?,?,?) ON CONFLICT(key_epoch) DO UPDATE SET
              event_id=excluded.event_id, refreshed_at=excluded.refreshed_at;
            """,
            -1, &stmt, nil
        ) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, hashKeyEpoch)
        bindText(stmt, 2, checkpoint.eventID)
        sqlite3_bind_double(stmt, 3, checkpoint.refreshedAt.timeIntervalSince1970)
        return sqlite3_step(stmt) == SQLITE_DONE
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
