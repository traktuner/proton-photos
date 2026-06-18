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
        #if DEBUG
        // Dev: read the plaintext file FIRST and skip the Keychain entirely. The Keychain ACL is
        // bound to the app's code signature, which changes on every local rebuild — so touching the
        // Keychain would pop a "ProtonPhotos was modified" prompt on every launch. The file keeps the
        // session across rebuilds with no prompt.
        if let url = devFileURL, let data = try? Data(contentsOf: url),
           let session = try? JSONDecoder().decode(ProtonSession.self, from: data) {
            return session
        }
        #endif
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
           let data = item as? Data,
           let session = try? JSONDecoder().decode(ProtonSession.self, from: data) {
            return session
        }
        return nil
    }

    public func save(_ session: ProtonSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        #if DEBUG
        // Dev: persist to the file only — never write to the Keychain (see load()).
        if let url = devFileURL {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
        return
        #else
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attrs as CFDictionary, nil)
        #endif
    }

    public func clear() {
        #if DEBUG
        if let url = devFileURL { try? FileManager.default.removeItem(at: url) }
        #else
        SecItemDelete(baseQuery as CFDictionary)
        #endif
    }

    #if DEBUG
    private var devFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ProtonPhotos/dev-session.json")
    }
    #endif

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
