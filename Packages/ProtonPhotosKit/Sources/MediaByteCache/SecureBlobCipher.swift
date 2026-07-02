import Foundation
import CryptoKit
import PhotosCore

/// Authenticated encryption for a single cache blob (one thumbnail/preview) using CryptoKit AES-GCM.
///
/// Every blob is sealed with a FRESH random 96-bit nonce (CryptoKit's default when no nonce is supplied)
/// and bound to Associated Authenticated Data (AAD) describing exactly where it belongs:
///   cache namespace | cache version | account UID | volume ID | node ID | derivative type
/// The AAD is authenticated but NOT stored in the blob - decryption only succeeds when the reader
/// reconstructs the identical context. So a blob cannot be moved between accounts, namespaces, derivative
/// types, or photos: a mismatch fails the GCM tag check and reads as a cache miss, never as wrong bytes.
///
/// On-disk layout is `SealedBox.combined` = nonce (12) ‖ ciphertext ‖ tag (16). No plaintext, no key, and
/// no key-derived value is ever written. Production derives the key from the restored Proton session secret;
/// `KeychainCacheKeyStore` remains available for tests/legacy callers.
public struct SecureBlobCipher: Sendable {
    /// Bump when the on-disk format or AAD construction changes (old blobs then fail AAD and are purged).
    public static let version = 1

    private let key: SymmetricKey
    private let namespace: String
    private let accountUID: String
    private let derivative: String

    public init(key: SymmetricKey, namespace: String, accountUID: String, derivative: String) {
        self.key = key
        self.namespace = namespace
        self.accountUID = accountUID
        self.derivative = derivative
    }

    /// Seal plaintext for `uid`. Returns `nonce ‖ ciphertext ‖ tag`. Throws only on a CryptoKit failure
    /// (effectively never for valid inputs).
    public func seal(_ plaintext: Data, uid: PhotoUID) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key, authenticating: associatedData(for: uid))
        guard let combined = box.combined else { throw SecureBlobCipherError.sealFailed }
        return combined
    }

    /// Open a `nonce ‖ ciphertext ‖ tag` blob for `uid`. Returns `nil` on ANY failure (truncated blob,
    /// wrong key, wrong account/namespace/derivative/uid, tampered bytes) - the caller treats `nil` as a
    /// cache miss and deletes the corrupt blob. Never throws.
    public func open(_ blob: Data, uid: PhotoUID) -> Data? {
        guard let box = try? AES.GCM.SealedBox(combined: blob) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: associatedData(for: uid))
    }

    /// The authenticated context for a blob. Length-delimited with a field that cannot appear in the
    /// values (the components are opaque IDs / fixed strings) so distinct contexts can't alias.
    private func associatedData(for uid: PhotoUID) -> Data {
        let fields = [
            "ns=\(namespace)",
            "v=\(Self.version)",
            "acct=\(accountUID)",
            "vol=\(uid.volumeID)",
            "node=\(uid.nodeID)",
            "deriv=\(derivative)",
        ]
        return Data(fields.joined(separator: "\u{1f}").utf8)   // U+001F unit separator
    }
}

public enum SecureBlobCipherError: Error { case sealFailed }
