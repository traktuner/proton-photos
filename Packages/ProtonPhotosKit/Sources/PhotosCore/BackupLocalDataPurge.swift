import Foundation

/// Sign-out master reset for local, on-disk account data.
///
/// A backup of highly sensitive photos must leave NOTHING derived from the library behind after a
/// logout, and stale per-account containers must never accumulate (each re-login otherwise starts a
/// fresh empty backup state and re-verifies the whole library from scratch). This removes every
/// `ProtonPhotos` data root — all per-account containers (backup queue / state / dedup manifest /
/// photo-library catalog, and the timeline library) plus the derived on-disk caches.
///
/// Contract: idempotent (missing paths are ignored), generic (no per-account knowledge — it clears
/// ALL accounts, which is what a sign-out wants), and platform-agnostic — iOS and macOS call this
/// exact code. Call it SYNCHRONOUSLY on the main actor during teardown so it completes before any
/// re-login can recreate a container (an async purge could delete a freshly signed-in account's data).
public enum BackupLocalDataPurge {
    private static let pendingKey = "backup.pendingSignOutPurge.v1"

    /// Arm the purge. Call this ONLY from an explicit user sign-out — NEVER from generic session
    /// teardown, which also fires on transient token re-checks; purging then would wipe a live backup
    /// on a momentary auth blip. Armed as a persisted flag so a crash mid-logout still purges at the
    /// next launch.
    public static func requestPurgeOnSignOut(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: pendingKey)
    }

    /// Disarm a pending purge. Call on a successful sign-IN so a stale armed flag (e.g. a sign-out
    /// that never completed its teardown) can never purge a now-active account on a later transient
    /// session re-check.
    public static func cancelPurgeRequest(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: pendingKey)
    }

    /// If a sign-out purge is armed, run it now and disarm. Idempotent and safe to call from both the
    /// post-teardown path (stores already closed) and at launch (before any store opens). Returns
    /// whether a purge actually ran.
    @discardableResult
    public static func purgeIfSignOutRequested(defaults: UserDefaults = .standard, roots: [URL]? = nil) -> Bool {
        guard defaults.bool(forKey: pendingKey) else { return false }
        purgeAllLocalAccountData(roots: roots ?? localDataRoots())
        defaults.removeObject(forKey: pendingKey)
        return true
    }

    /// The on-disk roots that hold account data or caches derived from it. `Application Support` holds
    /// the durable account containers; `Caches` holds regenerable thumbnail/byte caches.
    public static func localDataRoots() -> [URL] {
        let fm = FileManager.default
        return [FileManager.SearchPathDirectory.applicationSupportDirectory, .cachesDirectory]
            .compactMap { fm.urls(for: $0, in: .userDomainMask).first }
            .map { $0.appendingPathComponent("ProtonPhotos", isDirectory: true) }
    }

    /// Removes every local `ProtonPhotos` root. Best-effort per root so one failure never blocks the
    /// rest. Returns how many roots actually existed and were removed (for logging/verification).
    @discardableResult
    public static func purgeAllLocalAccountData(roots: [URL]? = nil) -> Int {
        let fm = FileManager.default
        var removed = 0
        for root in (roots ?? localDataRoots()) where fm.fileExists(atPath: root.path) {
            if (try? fm.removeItem(at: root)) != nil { removed += 1 }
        }
        return removed
    }
}
