import Foundation
import Security

/// Device-local installation identity used to distinguish concurrent Proton upload clients. It is
/// not an account credential, never synchronizes through iCloud Keychain, and remains stable across
/// sign-out so the same installation can recover its own interrupted upload drafts.
public struct DeviceIdentityKeychainStore: Sendable {
    private let service: String
    private let account: String

    public init(
        service: String = "me.protonphotos.device-identity",
        account: String = "installation"
    ) {
        self.service = service
        self.account = account
    }

    public func loadOrCreate() -> String {
        if let existing = load() { return existing }

        let generated = UUID().uuidString
        var attributes = baseQuery
        attributes[kSecValueData as String] = Data(generated.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecSuccess { return generated }

        // Another caller may have won the first-write race. Prefer the value that actually became
        // durable; a transient identifier is only the last-resort fallback when Keychain is down.
        return load() ?? generated
    }

    func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
        ]
    }
}
