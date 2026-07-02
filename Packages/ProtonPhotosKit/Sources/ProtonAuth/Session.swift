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

/// Persists the session (tokens + key password) in the platform Keychain.
public struct SessionKeychainStore: Sendable {
    private let service: String
    private let account: String

    public init(service: String = Self.defaultService, account: String = "default") {
        self.service = service
        self.account = account
    }

    public static var defaultService: String {
        #if os(iOS)
        "me.protonphotos.ios.session"
        #elseif os(macOS)
        "me.protonphotos.mac.session"
        #else
        "me.protonphotos.session"
        #endif
    }

    public func load() -> ProtonSession? {
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
        removeLegacyDevSessionFile()
        SecItemDelete(baseQuery as CFDictionary)
        var attrs = baseQuery
        attrs[kSecValueData as String] = data
        // Device-local, only while unlocked, never synced to iCloud or restored to another device.
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(attrs as CFDictionary, nil)
    }

    public func clear() {
        removeLegacyDevSessionFile()
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// One-time cleanup for builds that may have used the old DEBUG-only file escape hatch.
    private func removeLegacyDevSessionFile() {
        guard let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("ProtonPhotos/dev-session.json")
        else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
