import Foundation
import CryptoKit
import Testing
import PhotosCore
@testable import MediaCache

/// Test double for the cache key store — deterministic, no Keychain. `available: false` models a
/// locked/denied Keychain (every key lookup fails).
final class MemoryCacheKeyStore: CacheKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: SymmetricKey] = [:]
    private let available: Bool

    init(available: Bool = true) { self.available = available }

    func loadOrCreateKey(account: String) -> SymmetricKey? {
        guard available else { return nil }
        return lock.withLock {
            if let k = keys[account] { return k }
            let k = SymmetricKey(size: .bits256)
            keys[account] = k
            return k
        }
    }

    func existingKey(account: String) -> SymmetricKey? { lock.withLock { keys[account] } }
    func deleteKey(account: String) { lock.withLock { _ = keys.removeValue(forKey: account) } }
}

@Suite("Secure thumbnail cache")
struct SecureThumbnailCacheTests {
    private static let pngSignature = Data([0x89, 0x50, 0x4E, 0x47])   // "\x89PNG"

    private func png() -> Data {
        // A real-ish PNG so the signature check is meaningful.
        var d = Self.pngSignature
        d.append(Data([0x0D, 0x0A, 0x1A, 0x0A]))
        d.append(Data((0 ..< 512).map { UInt8($0 % 251) }))
        return d
    }

    private func uniqueNamespace() -> String { "sec-\(UUID().uuidString)" }
    private func uid(_ id: String = "node-1") -> PhotoUID { PhotoUID(volumeID: "vol-1", nodeID: id) }
    private func fileSize(_ url: URL) -> Int64 {
        Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }

    // MARK: - On-disk encryption

    @Test func encryptedBlobHasNoPlaintext() throws {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), keyStore: MemoryCacheKeyStore())
        cache.configure(accountUID: "acct-A")
        let plaintext = png()
        cache.storeToDisk(plaintext, for: uid())

        let blob = try Data(contentsOf: cache.diskURL(for: uid()))
        #expect(!blob.isEmpty)
        #expect(blob != plaintext)
        #expect(blob.range(of: plaintext) == nil)              // ciphertext doesn't embed the input
        #expect(blob.range(of: Self.pngSignature) == nil)      // not even the PNG header leaks
        #expect(blob.count >= plaintext.count + 12 + 16)        // nonce(12) + ct + tag(16)
        #expect(cache.diskData(for: uid()) == plaintext)        // and it round-trips
    }

    @Test func freshNoncePerBlob() throws {
        let cipher = SecureBlobCipher(key: SymmetricKey(size: .bits256), namespace: "thumbnails", accountUID: "A", derivative: "thumbnail")
        let p = png()
        let a = try cipher.seal(p, uid: uid())
        let b = try cipher.seal(p, uid: uid())
        #expect(a != b)                                         // random nonce → different ciphertext each time
        #expect(cipher.open(a, uid: uid()) == p)
        #expect(cipher.open(b, uid: uid()) == p)
    }

    // MARK: - AAD / key binding

    @Test func wrongContextFailsDecrypt() throws {
        let key = SymmetricKey(size: .bits256)
        let cipher = SecureBlobCipher(key: key, namespace: "thumbnails", accountUID: "A", derivative: "thumbnail")
        let sealed = try cipher.seal(png(), uid: uid("n1"))

        #expect(cipher.open(sealed, uid: uid("n1")) == png())   // correct context

        let wrongAccount = SecureBlobCipher(key: key, namespace: "thumbnails", accountUID: "B", derivative: "thumbnail")
        let wrongNamespace = SecureBlobCipher(key: key, namespace: "previews", accountUID: "A", derivative: "thumbnail")
        let wrongDerivative = SecureBlobCipher(key: key, namespace: "thumbnails", accountUID: "A", derivative: "preview")
        let wrongKey = SecureBlobCipher(key: SymmetricKey(size: .bits256), namespace: "thumbnails", accountUID: "A", derivative: "thumbnail")

        #expect(wrongAccount.open(sealed, uid: uid("n1")) == nil)     // wrong account UID in AAD
        #expect(wrongNamespace.open(sealed, uid: uid("n1")) == nil)   // wrong namespace in AAD
        #expect(wrongDerivative.open(sealed, uid: uid("n1")) == nil)  // wrong derivative type in AAD
        #expect(wrongKey.open(sealed, uid: uid("n1")) == nil)         // wrong key
        #expect(cipher.open(sealed, uid: uid("n2")) == nil)          // wrong node id in AAD
    }

    @Test func differentAccountCannotReadCacheBlob() {
        let store = MemoryCacheKeyStore()
        let ns = uniqueNamespace()
        let cache = ThumbnailCache(namespace: ns, keyStore: store)
        cache.configure(accountUID: "acct-A")
        cache.storeToDisk(png(), for: uid())
        #expect(cache.diskData(for: uid()) == png())

        // Re-key the same on-disk store for a different account → the first account's blob is unreadable.
        cache.configure(accountUID: "acct-B")
        #expect(cache.has(uid()) == false)              // account-scoped filename → not even found
        #expect(cache.diskData(for: uid()) == nil)
    }

    // MARK: - Failure modes

    @Test func missingKeyIsCacheMissNotCrash() {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), keyStore: MemoryCacheKeyStore(available: false))
        cache.configure(accountUID: "acct-A")           // Keychain unavailable → locked
        cache.storeToDisk(png(), for: uid())            // dropped (no-op)
        #expect(cache.has(uid()) == false)
        #expect(cache.diskData(for: uid()) == nil)      // miss, not a crash
    }

    @Test func hasUsableDiskDataRejectsAndDeletesCorruptBlob() throws {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), keyStore: MemoryCacheKeyStore())
        cache.configure(accountUID: "acct-A")
        // A corrupt blob written directly (not via storeToDisk → not pre-validated), as from a prior launch.
        try Data(repeating: 0x09, count: 64).write(to: cache.diskURL(for: uid()))
        #expect(cache.has(uid()) == true)                      // file exists
        #expect(cache.hasUsableDiskData(uid()) == false)       // but not decryptable → not "usable"
        #expect(FileManager.default.fileExists(atPath: cache.diskURL(for: uid()).path) == false)  // and deleted

        // A freshly sealed blob IS usable.
        cache.storeToDisk(png(), for: uid())
        #expect(cache.hasUsableDiskData(uid()) == true)
    }

    @Test func corruptBlobIsMissAndDeleted() throws {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), keyStore: MemoryCacheKeyStore())
        cache.configure(accountUID: "acct-A")
        cache.storeToDisk(png(), for: uid())
        let url = cache.diskURL(for: uid())
        try Data([1, 2, 3, 4, 5, 6, 7, 8]).write(to: url)   // tamper → fails the GCM tag
        #expect(cache.diskData(for: uid()) == nil)          // auth failure → miss
        #expect(FileManager.default.fileExists(atPath: url.path) == false)   // and the corrupt blob is deleted
    }

    // MARK: - Sign-out / purge / legacy

    @Test func signOutRemovesBlobsAndKey() {
        let store = MemoryCacheKeyStore()
        let cache = ThumbnailCache(namespace: uniqueNamespace(), keyStore: store)
        cache.configure(accountUID: "acct-A")
        cache.storeToDisk(png(), for: uid())
        #expect(cache.has(uid()) == true)
        #expect(store.existingKey(account: "acct-A") != nil)

        cache.clearAndForgetKey()
        #expect(cache.has(uid()) == false)                          // blobs gone
        #expect(store.existingKey(account: "acct-A") == nil)        // account key gone
    }

    @Test func configuredCacheSurvivesAcrossInstances() {
        // Relaunch simulation: a brand-new cache instance over the same dir + same per-account Keychain key
        // must read the prior instance's blobs. (Regression guard: the production feed must use the SHARED
        // configured cache, not a throwaway ThumbnailCache() that stays on a per-process ephemeral key.)
        let store = MemoryCacheKeyStore()
        let ns = uniqueNamespace()
        let first = ThumbnailCache(namespace: ns, keyStore: store)
        first.configure(accountUID: "acct-A")
        first.storeToDisk(png(), for: uid())

        let relaunched = ThumbnailCache(namespace: ns, keyStore: store)
        relaunched.configure(accountUID: "acct-A")
        #expect(relaunched.has(uid()) == true)
        #expect(relaunched.diskData(for: uid()) == png())
    }

    @Test func originalsCacheUsesDerivativeSpecificEncryptionContext() {
        // Originals/previews/thumbnails may share the same account key source, but their AAD must stay
        // derivative-bound: an original blob is not a valid thumbnail blob and vice versa.
        let store = MemoryCacheKeyStore()
        let ns = uniqueNamespace()
        let original = ThumbnailCache(namespace: ns, derivative: "original", keyStore: store)
        let thumbnail = ThumbnailCache(namespace: ns, derivative: "thumbnail", keyStore: store)
        original.configure(accountUID: "acct-A")
        thumbnail.configure(accountUID: "acct-A")

        original.storeToDisk(png(), for: uid())

        #expect(original.diskData(for: uid()) == png())
        #expect(thumbnail.diskData(for: uid()) == nil)
    }

    @Test func originalsLRUCapEvictsOldestBlobFirst() throws {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), derivative: "original", keyStore: MemoryCacheKeyStore())
        cache.configure(accountUID: "acct-A")
        let old = uid("old")
        let keepA = uid("keep-a")
        let keepB = uid("keep-b")

        cache.storeToDisk(Data(repeating: 0x11, count: 300), for: old)
        cache.storeToDisk(Data(repeating: 0x22, count: 300), for: keepA)
        cache.storeToDisk(Data(repeating: 0x33, count: 300), for: keepB)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)],
                                              ofItemAtPath: cache.diskURL(for: old).path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)],
                                              ofItemAtPath: cache.diskURL(for: keepA).path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3)],
                                              ofItemAtPath: cache.diskURL(for: keepB).path)

        let cap = fileSize(cache.diskURL(for: keepA)) + fileSize(cache.diskURL(for: keepB)) + 1
        cache.enforceByteCap(cap)

        #expect(cache.diskData(for: old) == nil)
        #expect(cache.diskData(for: keepA) != nil)
        #expect(cache.diskData(for: keepB) != nil)
    }

    @Test func originalsTouchKeepsRecentlyUsedBlobDuringCapEnforcement() throws {
        let cache = ThumbnailCache(namespace: uniqueNamespace(), derivative: "original", keyStore: MemoryCacheKeyStore())
        cache.configure(accountUID: "acct-A")
        let old = uid("old")
        let recentlyUsed = uid("recent")

        cache.storeToDisk(Data(repeating: 0x44, count: 300), for: old)
        cache.storeToDisk(Data(repeating: 0x55, count: 300), for: recentlyUsed)
        let staleDate = Date(timeIntervalSince1970: 10)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: cache.diskURL(for: old).path)
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: cache.diskURL(for: recentlyUsed).path)

        cache.touch(recentlyUsed)
        let cap = fileSize(cache.diskURL(for: recentlyUsed)) + 1
        cache.enforceByteCap(cap)

        #expect(cache.diskData(for: old) == nil)
        #expect(cache.diskData(for: recentlyUsed) != nil)
    }

    @Test func unconfiguredInstanceCannotReadConfiguredBlobs() {
        // Documents the regression class the wiring bug caused: an UNCONFIGURED cache (ephemeral key,
        // "(unconfigured)" account) cannot read a configured cache's blobs — so a feed built with an
        // unconfigured cache would re-crawl everything every launch.
        let store = MemoryCacheKeyStore()
        let ns = uniqueNamespace()
        let configured = ThumbnailCache(namespace: ns, keyStore: store)
        configured.configure(accountUID: "acct-A")
        configured.storeToDisk(png(), for: uid())

        let unconfigured = ThumbnailCache(namespace: ns, keyStore: store)
        #expect(unconfigured.diskData(for: uid()) == nil)
    }

    @Test func legacyPlaintextCacheIsPurgedOnConfigure() throws {
        let ns = uniqueNamespace()
        let legacyDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProtonPhotos", isDirectory: true)
            .appendingPathComponent(ns, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        // A pre-encryption PLAINTEXT thumbnail sitting in the old cache directory.
        try png().write(to: legacyDir.appendingPathComponent("vol-1~node-1"))
        #expect(FileManager.default.fileExists(atPath: legacyDir.path))

        let cache = ThumbnailCache(namespace: ns, keyStore: MemoryCacheKeyStore())
        cache.configure(accountUID: "acct-A")                       // must purge the legacy plaintext dir
        #expect(FileManager.default.fileExists(atPath: legacyDir.path) == false)
    }
}
