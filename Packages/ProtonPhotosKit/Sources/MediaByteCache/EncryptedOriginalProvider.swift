import Foundation
import PhotosCore

/// Cache policy for ``EncryptedOriginalProvider``. Separated from the cache instance so the same
/// encrypted store can back both a *persisting* consumer (the fullscreen viewer, which should seed
/// the cache the first time an original is decrypted) and a *read-only* consumer (export/share, which
/// reuses whatever the viewer already cached but must not itself grow the cache - mirroring macOS
/// `MainView.fetchOriginal`, which only ever READS the offline cache).
public struct OriginalsCachePolicy: Sendable, Equatable {
    /// Whether a network download (cache miss) is sealed into the encrypted cache afterwards.
    public var storeOnMiss: Bool
    /// LRU byte cap enforced right after a store (nil = don't enforce here; the owner may cap elsewhere).
    public var capBytes: Int64?

    public init(storeOnMiss: Bool, capBytes: Int64? = nil) {
        self.storeOnMiss = storeOnMiss
        self.capBytes = capBytes
    }

    /// Viewer policy: seed the cache on first decrypt, then keep it under `capBytes`.
    public static func persisting(capBytes: Int64?) -> OriginalsCachePolicy {
        OriginalsCachePolicy(storeOnMiss: true, capBytes: capBytes)
    }

    /// Export/share policy: reuse the cache if warm, but never grow it.
    public static let readOnly = OriginalsCachePolicy(storeOnMiss: false, capBytes: nil)
}

/// The ONE shared "get decrypted original bytes, reusing the encrypted offline cache" path, used by
/// the viewer and export on BOTH iOS and macOS. Before this existed the read-before-network + store +
/// LRU logic was duplicated and diverged: macOS had it (App/MainView.fetchOriginal + the AppKit
/// viewer), while iOS hit `FullMediaProvider.originalData` directly with only a RAM cache - so a
/// just-viewed original was re-downloaded for share/export, and decrypted originals were never held in
/// the E2EE-safe encrypted cache on iOS at all.
///
/// Contract:
/// - **Cache hit** returns the cached plaintext and bumps its LRU marker, WITHOUT touching
///   ``FullMediaProvider/originalData(for:onProgress:)`` (no redundant network/decrypt).
/// - **Cache miss** downloads via the provider (forwarding real byte progress), then - only when the
///   policy persists - seals the bytes into the encrypted cache and enforces the byte cap.
/// - All disk read/decrypt/seal work runs OFF the calling actor (`Task.detached`), so a main-actor
///   caller never blocks on AES-GCM or file I/O.
/// - Returns raw `Data`; decoding to a platform image stays in each platform's UI layer, so this type
///   is platform-UI-free and lives next to the cache it drives.
public struct EncryptedOriginalProvider: Sendable {
    private let media: any FullMediaProvider
    private let cache: ThumbnailCache?
    private let policy: OriginalsCachePolicy

    /// - Parameters:
    ///   - media: the backend original-bytes source (never re-implement block download/decrypt).
    ///   - cache: the encrypted originals cache, or `nil` to disable caching entirely (always downloads).
    ///   - policy: whether a miss is persisted and the LRU cap to enforce afterwards.
    public init(media: any FullMediaProvider, cache: ThumbnailCache?, policy: OriginalsCachePolicy) {
        self.media = media
        self.cache = cache
        self.policy = policy
    }

    /// Decrypted original bytes, cache-first. See the type contract above.
    public func originalData(
        for uid: PhotoUID,
        onProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> Data {
        if let cache {
            // Encrypted read + AES-GCM decrypt off the caller's actor; bump LRU on a hit.
            let cached = await Task.detached(priority: .userInitiated) { () -> Data? in
                guard let data = cache.diskData(for: uid) else { return nil }
                cache.touch(uid)
                return data
            }.value
            if let cached {
                onProgress(1)                 // a warm hit "completes" immediately for progress UIs
                return cached
            }
        }

        // Miss → network original with real byte progress. NEVER reached on a hit.
        let data = try await media.originalData(for: uid, onProgress: onProgress)

        if let cache, policy.storeOnMiss {
            let cap = policy.capBytes
            // Seal + write + LRU-cap off the caller's actor.
            await Task.detached(priority: .utility) {
                cache.storeToDisk(data, for: uid)
                if let cap { cache.enforceByteCap(cap) }
            }.value
        }
        return data
    }
}
