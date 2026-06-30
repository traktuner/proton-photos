import Foundation
import CryptoKit
import PhotosCore

/// Encrypted-at-rest persistence for the whole-library GPS index (one AES-GCM blob).
///
/// GPS is sensitive PII, so it follows the same E2EE-at-rest rule as the thumbnail caches: the decrypted
/// coordinates live ONLY in RAM (`PhotoLocationIndex`); on disk the file is `nonce ‖ ciphertext ‖ tag`,
/// undecryptable without the per-account cache key (the same key the thumbnail/preview/originals caches
/// use). The AAD binds the blob to the account + a format version, so it can't be moved between accounts
/// and an old format is rejected (→ empty load, re-crawl). Erased on sign-out (`clear()`).
///
/// Platform-agnostic (Foundation + CryptoKit) — reused as-is by a future iOS/iPad build.
public final class PhotoLocationStore: @unchecked Sendable {
    /// Bump when the on-disk format changes (older blobs then fail AAD and are dropped + re-crawled).
    private static let version = 1

    private let directory: URL
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var accountUID: String?

    public init(directory: URL = PhotoLocationStore.defaultDirectory) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProtonPhotos/locations", isDirectory: true)
    }

    private var fileURL: URL { directory.appendingPathComponent("locations.v\(Self.version).enc") }

    /// Install the per-account key (same key the media caches use). Until configured, load/save are no-ops.
    public func configure(accountUID: String, key: SymmetricKey) {
        lock.withLock { self.accountUID = accountUID; self.key = key }
    }

    /// Persist the full coordinate set (encrypted, atomic). Best-effort — a failure just means the next
    /// launch re-crawls the gap, never a crash or a plaintext write.
    public func save(_ coordinates: [PhotoCoordinate]) {
        guard let (key, account) = credentials(),
              let plain = try? JSONEncoder().encode(coordinates),
              let sealed = try? AES.GCM.seal(plain, using: key, authenticating: aad(account)).combined
        else { return }
        try? sealed.write(to: fileURL, options: .atomic)
    }

    /// Decrypt the persisted coordinates (empty if none / wrong key / tampered / old format).
    public func load() -> [PhotoCoordinate] {
        guard let (key, account) = credentials(),
              let blob = try? Data(contentsOf: fileURL),
              let box = try? AES.GCM.SealedBox(combined: blob),
              let plain = try? AES.GCM.open(box, using: key, authenticating: aad(account)),
              let coords = try? JSONDecoder().decode([PhotoCoordinate].self, from: plain)
        else { return [] }
        return coords
    }

    /// Sign-out / master reset: erase the encrypted index and forget the key.
    public func clear() {
        lock.withLock { key = nil; accountUID = nil }
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func credentials() -> (SymmetricKey, String)? {
        lock.withLock {
            guard let key, let accountUID else { return nil }
            return (key, accountUID)
        }
    }

    private func aad(_ account: String) -> Data {
        Data("protonphotos.locations.v\(Self.version)|acct=\(account)".utf8)
    }
}
