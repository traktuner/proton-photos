import Foundation

/// A fully-authenticated Proton session obtained via the web-link (session fork) flow.
public struct ProtonSession: Codable, Sendable, Equatable {
    public let uid: String
    public var accessToken: String
    public var refreshToken: String
    /// Mailbox/key password (decrypted from the fork payload). Unlocks the user's PGP keys.
    public let keyPassword: String

    public init(uid: String, accessToken: String, refreshToken: String, keyPassword: String) {
        self.uid = uid
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.keyPassword = keyPassword
    }
}

/// Persists the session (tokens + key password) in the macOS Keychain.
public struct SessionKeychainStore: Sendable {
    private let service: String
    private let account: String

    public init(service: String = "me.protonphotos.mac.session", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func load() -> ProtonSession? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ProtonSession.self, from: data)
    }

    public func save(_ session: ProtonSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
