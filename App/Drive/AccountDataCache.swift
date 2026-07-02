import Foundation
import CryptoKit

/// Encrypted on-disk cache of the account data (`/core/v4/users` + `/core/v4/addresses`) needed to build the
/// Drive crypto + SDK account client. It exists so the app can COLD-START OFFLINE: when those two GETs can't be
/// fetched, `DriveSDKBridge.init` rebuilds the (pure) crypto from this cache instead of failing the whole
/// library - which then makes the already-offline-capable SQLite timeline + encrypted thumbnail caches reachable.
///
/// Encrypted at rest with AES-GCM under a key derived from the session `keyPassword` (HKDF-SHA256) - the same
/// approach as the thumbnail/preview cache - so nothing usable persists without the user's secret. (The user-key
/// blobs are PGP-locked by the mailbox passphrase anyway; this is belt-and-suspenders + consistency.)
enum AccountDataCache {
    private static func dir() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProtonPhotos/sdk", isDirectory: true)
        try? FileManager.default.createDirectory(at: caches, withIntermediateDirectories: true)
        return caches
    }

    private static func file(uid: String, kind: String) -> URL {
        dir().appendingPathComponent("account-\(kind)-\(uid).enc")
    }

    private static func key(uid: String, keyPassword: String) -> SymmetricKey {
        let input = SymmetricKey(data: Data(keyPassword.utf8))
        let salt = Data("ProtonPhotos.account-cache.v1.\(uid)".utf8)
        let info = Data("account-data-cache".utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: info, outputByteCount: 32)
    }

    /// Persists the two raw JSON responses, AES-GCM sealed. Best-effort (a write failure just means the next
    /// offline cold start falls back to `.failed`, exactly as today).
    static func save(users: Data, addresses: Data, uid: String, keyPassword: String) {
        let k = key(uid: uid, keyPassword: keyPassword)
        seal(users, to: file(uid: uid, kind: "users"), using: k)
        seal(addresses, to: file(uid: uid, kind: "addresses"), using: k)
    }

    /// The cached raw JSON, or nil if absent / undecryptable (wrong key / corruption / missing).
    static func load(uid: String, keyPassword: String) -> (users: Data, addresses: Data)? {
        let k = key(uid: uid, keyPassword: keyPassword)
        guard let u = open(file(uid: uid, kind: "users"), using: k),
              let a = open(file(uid: uid, kind: "addresses"), using: k) else { return nil }
        return (u, a)
    }

    /// Erases the cached account blobs (wired to sign-out + "delete cache").
    static func clear(uid: String) {
        try? FileManager.default.removeItem(at: file(uid: uid, kind: "users"))
        try? FileManager.default.removeItem(at: file(uid: uid, kind: "addresses"))
    }

    private static func seal(_ data: Data, to url: URL, using key: SymmetricKey) {
        guard let sealed = try? AES.GCM.seal(data, using: key).combined else { return }
        try? sealed.write(to: url, options: .atomic)
    }

    private static func open(_ url: URL, using key: SymmetricKey) -> Data? {
        guard let blob = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return plain
    }
}
