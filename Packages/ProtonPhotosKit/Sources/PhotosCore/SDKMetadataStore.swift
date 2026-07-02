import Foundation

/// The Drive SDK's on-disk **metadata** SQLite stores. They hold non-secret node metadata (IDs,
/// capture time, MIME, live-photo flag) for a fast offline cold start - no plaintext media,
/// filenames, GPS, or key material. Even though they're non-secret, they tie a body of library
/// structure to the signed-in account, so a FULL sign-out / master-reset must erase them
/// (security follow-up #2). The encrypted thumbnail/preview/originals caches, the streamed video
/// blocks, and the encrypted account-data cache are erased by their own paths - this type owns
/// *only* the metadata SQLite files, so the purge stays scoped and testable in one place.
public enum SDKMetadataStore {
    /// File names of the metadata stores for `uid`, including the SQLite `-wal` / `-shm` sidecars
    /// (WAL mode leaves them next to the main file): the account-shared `entities.sqlite` and the
    /// LEGACY per-account `timeline-v3-<uid>.sqlite` (superseded by the app-owned
    /// `library-v1.sqlite` under `LibraryDatabaseLocation`, which sign-out purges separately via
    /// `LibraryDatabaseLocation.purgeAccountData`; the legacy names stay listed here so stores
    /// written by older builds keep being erased).
    public static func metadataFileNames(uid: String) -> [String] {
        ["entities.sqlite", "timeline-v3-\(uid).sqlite"].flatMap { base in
            [base, base + "-wal", base + "-shm"]
        }
    }

    /// File names of ONLY the legacy `timeline-v3-<uid>.sqlite` store (+ WAL sidecars) - used for
    /// the best-effort cleanup at sign-in after the v1 reset, which must NOT touch the SDK's
    /// `entities.sqlite` in the same directory.
    public static func legacyTimelineFileNames(uid: String) -> [String] {
        let base = "timeline-v3-\(uid).sqlite"
        return [base, base + "-wal", base + "-shm"]
    }

    /// Best-effort delete of the superseded timeline-v3 store for `uid` under `directory`.
    /// Returns the number of files actually removed.
    @discardableResult
    public static func purgeLegacyTimelineStore(in directory: URL, uid: String) -> Int {
        let fm = FileManager.default
        var removed = 0
        for name in legacyTimelineFileNames(uid: uid) {
            let url = directory.appendingPathComponent(name)
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// Filename prefixes of ALL superseded timeline cache formats, any account: `timeline-v2-*`
    /// (JSON) and `timeline-v3-*` (SQLite + WAL sidecars). No supported build reads either format
    /// anymore, so they are safe to sweep wholesale.
    public static let legacyTimelinePrefixes = ["timeline-v2-", "timeline-v3-"]

    /// Best-effort sweep of every superseded timeline cache file under `directory`, REGARDLESS of
    /// account. The per-uid cleanup above runs at sign-in for the current account, but stores left
    /// by accounts that signed in on older builds (and will never sign in again) would otherwise
    /// linger as orphans - observed in the wild as `timeline-v3-<other-uid>.sqlite` plus a
    /// `timeline-v2-*.json`. Leaves everything else (entities.sqlite, account caches) untouched.
    /// Returns the number of files removed.
    @discardableResult
    public static func purgeOrphanedLegacyTimelineStores(in directory: URL) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return 0 }
        var removed = 0
        for name in names where legacyTimelinePrefixes.contains(where: name.hasPrefix) {
            if (try? fm.removeItem(at: directory.appendingPathComponent(name))) != nil { removed += 1 }
        }
        return removed
    }

    /// Best-effort delete of every metadata file for `uid` under `directory`. Returns the number of
    /// files actually removed (i.e. that existed), so a caller or test can confirm the purge ran.
    /// Files belonging to other accounts, the encrypted caches, and the account-data cache that live
    /// in the same directory are left untouched.
    @discardableResult
    public static func purgeMetadata(in directory: URL, uid: String) -> Int {
        let fm = FileManager.default
        var removed = 0
        for name in metadataFileNames(uid: uid) {
            let url = directory.appendingPathComponent(name)
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
