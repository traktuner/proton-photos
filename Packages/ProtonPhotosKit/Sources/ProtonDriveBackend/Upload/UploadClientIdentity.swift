import CryptoKit
import Foundation

/// Proton's upload client identity is per account and installation, not merely per account. Keeping
/// devices distinct lets the backend tell another device's live draft from this installation's own
/// interrupted draft while exposing neither raw identifier.
enum UploadClientIdentity {
    static func make(accountUID: String, deviceIdentifier: String, prefix: String = platformPrefix) -> String {
        let digest = SHA256.hash(data: Data((accountUID + deviceIdentifier).utf8))
        return prefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    private static var platformPrefix: String {
        #if os(macOS)
        "macOS_"
        #elseif os(iOS)
        "iOS_"
        #else
        "apple_"
        #endif
    }
}
