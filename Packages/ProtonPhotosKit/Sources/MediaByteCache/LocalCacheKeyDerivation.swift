import CryptoKit
import Foundation

/// Deterministic per-account key derivation for encrypted local media derivatives.
///
/// The key material comes from the already-restored Proton session secret; platform apps pass the resulting
/// key into `ThumbnailCache.configure(accountUID:key:)`. Keeping this in the cache core avoids duplicating
/// crypto policy in AppKit/UIKit shells while preserving platform-owned storage roots and budgets.
public enum LocalCacheKeyDerivation {
    public static func thumbnailPreviewCacheKey(accountUID: String, keyPassword: String) -> SymmetricKey {
        let input = SymmetricKey(data: Data(keyPassword.utf8))
        let salt = Data("ProtonPhotos.local-cache.v1.\(accountUID)".utf8)
        let info = Data("thumbnail-preview-cache".utf8)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: input, salt: salt, info: info, outputByteCount: 32)
    }
}
