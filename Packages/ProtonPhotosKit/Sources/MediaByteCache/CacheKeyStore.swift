import Foundation
import CryptoKit
import Security

/// Persists the per-account cache MainKey (the AES-256 key that encrypts the thumbnail/preview cache).
/// Abstracted so production uses the Apple platform Keychain and tests can inject an in-memory double — the cache
/// never depends on the Keychain being reachable in a unit test.
public protocol CacheKeyStore: Sendable {
    /// The key for `account`, minting + persisting a fresh random 256-bit key on first use. Returns `nil`
    /// only when the backing store is unavailable (e.g. Keychain locked/denied) — the caller then treats
    /// the cache as locked (every read is a miss, every write is dropped), never crashes.
    func loadOrCreateKey(account: String) -> SymmetricKey?

    /// The existing key for `account`, or `nil` if none is stored (without creating one). For probing.
    func existingKey(account: String) -> SymmetricKey?

    /// Removes the account's key (sign-out / delete cache). After this, prior blobs are undecryptable.
    func deleteKey(account: String)
}

/// Keychain-backed cache key store.
///
/// • One generic-password item per account. The default service keeps the original macOS cache-key namespace for
///   migration-free compatibility; callers may inject a different service for a future account-wide namespace.
/// • `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — readable only while the device is unlocked, and
///   NEVER migrated to another device or included in an unencrypted backup.
/// • `kSecAttrSynchronizable` is deliberately NOT set — the key must not sync to iCloud Keychain.
/// The key value is 32 random bytes from the system CSPRNG. The key is never logged.
public struct KeychainCacheKeyStore: CacheKeyStore {
    private let service: String

    public init(service: String = "me.protonphotos.mac.cachekey") {
        self.service = service
    }

    public func loadOrCreateKey(account: String) -> SymmetricKey? {
        if let existing = existingKey(account: account) { return existing }

        var keyData = Data(count: 32)
        let status = keyData.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { return nil }

        var attrs = baseQuery(account: account)
        attrs[kSecValueData as String] = keyData
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let add = SecItemAdd(attrs as CFDictionary, nil)
        if add == errSecSuccess {
            return SymmetricKey(data: keyData)
        }
        if add == errSecDuplicateItem {
            // Raced with another writer — read the winner back.
            return existingKey(account: account)
        }
        return nil
    }

    public func existingKey(account: String) -> SymmetricKey? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, data.count == 32 else { return nil }
        return SymmetricKey(data: data)
    }

    public func deleteKey(account: String) {
        SecItemDelete(baseQuery(account: account) as CFDictionary)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
