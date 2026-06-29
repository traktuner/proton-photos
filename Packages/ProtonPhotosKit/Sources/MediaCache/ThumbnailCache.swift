import Foundation
import CryptoKit
import PhotosCore

/// Two-tier thumbnail cache: in-memory (NSCache) backed by an ENCRYPTED on-disk store. Keeps decoded
/// thumbnails resident for smooth scrolling and survives relaunch.
///
/// Security: on-disk blobs are AES-GCM sealed (see `SecureBlobCipher`) with a per-account 256-bit key.
/// Production supplies that key from the already-unlocked Proton session (`configure(accountUID:key:)`) so
/// startup does not need a second cache-key Keychain read; tests and legacy callers can still use
/// `configure(accountUID:)` with an injected `CacheKeyStore`. Plaintext thumbnail/preview bytes are NEVER
/// written to disk; the in-memory tier holds plaintext for the running process only. The cache is usable
/// before sign-in via a process-ephemeral key (nothing readable persists), then account configuration purges
/// any legacy plaintext cache. Reads transparently decrypt; a missing key or a failed authentication tag is a
/// cache MISS (and the corrupt blob is deleted), never a crash.
public actor ThumbnailCache {
    private nonisolated(unsafe) let memory = NSCache<NSString, NSData>()   // NSCache is thread-safe
    /// Encrypted blob directory (`<namespace>.enc`). The legacy plaintext dir (`<namespace>`) is purged.
    private nonisolated let directory: URL
    private nonisolated let legacyPlaintextDir: URL
    private nonisolated let namespace: String
    private nonisolated let derivative: String
    private nonisolated let keyStore: CacheKeyStore
    private nonisolated let crypto: CryptoBox
    /// Filenames proven decryptable this session (so `hasUsableDiskData` is O(1) after the first probe).
    private nonisolated let validated = ValidatedPresence()

    public init(
        namespace: String = "thumbnails",
        derivative: String? = nil,
        keyStore: CacheKeyStore = KeychainCacheKeyStore()
    ) {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProtonPhotos", isDirectory: true)
        self.namespace = namespace
        self.derivative = derivative ?? Self.defaultDerivative(for: namespace)
        self.keyStore = keyStore
        self.legacyPlaintextDir = root.appendingPathComponent(namespace, isDirectory: true)
        self.directory = root.appendingPathComponent("\(namespace).enc", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Secure by default: until account configuration installs the durable per-account key, seal with a
        // process-ephemeral key so nothing readable persists across launches, while in-process round-trips
        // still work (e.g. tests).
        self.crypto = CryptoBox(
            cipher: SecureBlobCipher(key: SymmetricKey(size: .bits256),
                                     namespace: namespace,
                                     accountUID: CryptoBox.ephemeralAccount,
                                     derivative: self.derivative),
            account: CryptoBox.ephemeralAccount
        )
        memory.countLimit = 2000
    }

    // MARK: - Account configuration

    /// Installs the durable per-account encryption key (from the Keychain) and one-time purges any legacy
    /// PLAINTEXT cache written before encryption existed. Call as early as the account UID is known (it is
    /// available at launch from the restored session) and before the grid starts crawling. Synchronous and
    /// idempotent. If the Keychain is unavailable the cache is LOCKED (reads miss, writes drop) rather than
    /// falling back to plaintext.
    public nonisolated func configure(accountUID: String) {
        try? FileManager.default.removeItem(at: legacyPlaintextDir)   // purge pre-encryption plaintext cache
        validated.clearAll()   // account/key change → prior decryptability proofs no longer apply
        guard let key = keyStore.loadOrCreateKey(account: accountUID) else {
            crypto.set(cipher: nil, account: accountUID)       // Keychain unavailable → locked
            return
        }
        crypto.set(
            cipher: SecureBlobCipher(key: key, namespace: namespace, accountUID: accountUID, derivative: derivative),
            account: accountUID
        )
    }

    /// Installs a durable per-account key supplied by the caller. Production derives this from the already
    /// unlocked session secret, avoiding a second Keychain item/read solely for thumbnail cache keys while
    /// keeping blobs undecryptable without access to the session in Keychain.
    public nonisolated func configure(accountUID: String, key: SymmetricKey) {
        try? FileManager.default.removeItem(at: legacyPlaintextDir)
        validated.clearAll()
        crypto.set(
            cipher: SecureBlobCipher(key: key, namespace: namespace, accountUID: accountUID, derivative: derivative),
            account: accountUID
        )
    }

    // MARK: - Reads

    /// Cache lookup (decoded mem → encrypted disk). Never triggers a network load.
    public func data(for uid: PhotoUID) -> Data? {
        let mk = Self.memKey(uid)
        if let cached = memory.object(forKey: mk) { return cached as Data }
        guard let data = diskData(for: uid) else { return nil }
        memory.setObject(data as NSData, forKey: mk)
        return data
    }

    /// Cheap on-disk existence check (no read/decrypt) — for diagnostics/coverage only. Do NOT use this to
    /// gate network fetches: with encrypted blobs a corrupt/tampered/wrong-key file can exist yet be
    /// unreadable. Use `hasUsableDiskData(_:)` for any skip-the-network decision.
    public nonisolated func has(_ uid: PhotoUID) -> Bool {
        let (_, account) = crypto.snapshot()
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent(filename(uid: uid, account: account)).path)
    }

    /// True only when a DECRYPTABLE blob is on disk (the safe "skip the network" predicate). On the first
    /// probe per file it actually opens the blob; a corrupt/tampered/wrong-key blob is DELETED and returns
    /// false (so it re-fetches). Proven-good files are memoized, so subsequent calls are O(1).
    public nonisolated func hasUsableDiskData(_ uid: PhotoUID) -> Bool {
        let (cipher, account) = crypto.snapshot()
        guard let cipher else { return false }   // locked → nothing usable
        let name = filename(uid: uid, account: account)
        if validated.contains(name) { return true }
        let url = directory.appendingPathComponent(name)
        guard let blob = try? Data(contentsOf: url) else { return false }
        guard cipher.open(blob, uid: uid) != nil else {
            try? FileManager.default.removeItem(at: url)   // unreadable → drop so the network path refetches
            validated.remove(name)
            return false
        }
        validated.insert(name)
        return true
    }

    /// Direct disk read + decrypt (no in-memory layer). Returns plaintext bytes, or `nil` on a miss, a
    /// missing key, or an authentication failure (the corrupt blob is then deleted so it re-fetches).
    public nonisolated func diskData(for uid: PhotoUID) -> Data? {
        let (cipher, account) = crypto.snapshot()
        guard let cipher else { return nil }   // locked
        let name = filename(uid: uid, account: account)
        let url = directory.appendingPathComponent(name)
        guard let blob = try? Data(contentsOf: url) else { return nil }
        guard let plaintext = cipher.open(blob, uid: uid) else {
            try? FileManager.default.removeItem(at: url)   // auth failure / corruption → drop & re-fetch later
            validated.remove(name)
            return nil
        }
        validated.insert(name)
        return plaintext
    }

    /// URL of the on-disk ENCRYPTED blob (bytes are ciphertext — not directly decodable).
    public nonisolated func diskURL(for uid: PhotoUID) -> URL {
        let (_, account) = crypto.snapshot()
        return directory.appendingPathComponent(filename(uid: uid, account: account))
    }

    // MARK: - Writes

    public nonisolated func storeToDisk(_ data: Data, for uid: PhotoUID) {
        let (cipher, account) = crypto.snapshot()
        guard let cipher, let sealed = try? cipher.seal(data, uid: uid) else { return }   // locked → drop
        let name = filename(uid: uid, account: account)
        do {
            try sealed.write(to: directory.appendingPathComponent(name), options: .atomic)
            validated.insert(name)   // we just sealed it — it's decryptable
        } catch {
            validated.remove(name)
        }
    }

    public func store(_ data: Data, for uid: PhotoUID) {
        memory.setObject(data as NSData, forKey: Self.memKey(uid))   // RAM holds plaintext for this process
        storeToDisk(data, for: uid)
    }

    // MARK: - LRU size cap (used ONLY by the originals cache; thumbnails/previews stay uncapped & hot-path-free)

    /// Marks a blob as recently used (bumps its modification date) so LRU eviction keeps it. Called on a disk
    /// HIT for the originals cache only — never on the thumbnail/preview scrolling hot path.
    public nonisolated func touch(_ uid: PhotoUID) {
        let (_, account) = crypto.snapshot()
        let url = directory.appendingPathComponent(filename(uid: uid, account: account))
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    /// Evicts the LEAST-recently-used blobs (oldest modification date first) until the directory is at or under
    /// `capBytes`. No-op when already within budget or when `capBytes` is negative (treated as "unbounded" guard).
    public nonisolated func enforceByteCap(_ capBytes: Int64) {
        guard capBytes >= 0 else { return }
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [(url: URL, size: Int64, modified: Date)] = []
        var total: Int64 = 0
        for url in urls {
            let vals = try? url.resourceValues(forKeys: keys)
            let size = Int64(vals?.fileSize ?? 0)
            entries.append((url, size, vals?.contentModificationDate ?? .distantPast))
            total += size
        }
        guard total > capBytes else { return }
        for entry in entries.sorted(by: { $0.modified < $1.modified }) {   // oldest first
            if total <= capBytes { break }
            try? FileManager.default.removeItem(at: entry.url)
            validated.remove(entry.url.lastPathComponent)
            total -= entry.size
        }
    }

    // MARK: - Clearing

    /// Erases the on-disk cache (keeps the account key — re-crawl refills). Used by "Delete Offline Cache".
    public func clear() {
        memory.removeAllObjects()
        validated.clearAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: legacyPlaintextDir)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Sign-out purge: erases blobs AND deletes the account's Keychain key, then re-locks with a fresh
    /// ephemeral key. After this, the prior blobs (even if any survive) are cryptographically unrecoverable.
    public nonisolated func clearAndForgetKey() {
        let (_, account) = crypto.snapshot()
        memory.removeAllObjects()
        validated.clearAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.removeItem(at: legacyPlaintextDir)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        keyStore.deleteKey(account: account)
        crypto.set(
            cipher: SecureBlobCipher(key: SymmetricKey(size: .bits256),
                                     namespace: namespace,
                                     accountUID: CryptoBox.ephemeralAccount,
                                     derivative: derivative),
            account: CryptoBox.ephemeralAccount
        )
    }

    // MARK: - Stats

    public nonisolated func diskCoverage(for uids: [PhotoUID]) -> (present: Int, total: Int, percent: Double) {
        let total = uids.count
        guard total > 0 else { return (0, 0, 1) }
        let present = uids.reduce(0) { $0 + (has($1) ? 1 : 0) }
        return (present, total, Double(present) / Double(total))
    }

    public nonisolated func diskFileCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: directory.path).count) ?? 0
    }

    public nonisolated func diskSizeBytes() -> Int64 {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return urls.reduce(Int64(0)) { total, url in
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return total + Int64(size)
        }
    }

    // MARK: - Keys

    /// Account-scoped, content-hiding filename: SHA-256(namespace ‖ account ‖ volume ‖ node).blob. The node
    /// IDs never appear on the filesystem, and two accounts never collide.
    private nonisolated func filename(uid: PhotoUID, account: String) -> String {
        let material = "\(namespace)\u{1f}\(account)\u{1f}\(uid.volumeID)\u{1f}\(uid.nodeID)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".blob"
    }

    /// In-RAM NSCache key (process-local plaintext tier; not security sensitive).
    private static func memKey(_ uid: PhotoUID) -> NSString {
        "\(uid.volumeID)~\(uid.nodeID)" as NSString
    }

    private static func defaultDerivative(for namespace: String) -> String {
        switch namespace {
        case "thumbnails": return "thumbnail"
        case "previews": return "preview"
        default: return namespace
        }
    }
}

/// Thread-safe holder for the active cipher + account so the cache's many `nonisolated` accessors can read
/// the current crypto context without an actor hop. `configure`/`clearAndForgetKey` swap it atomically.
private final class CryptoBox: @unchecked Sendable {
    static let ephemeralAccount = "(unconfigured)"
    private let lock = NSLock()
    private var cipher: SecureBlobCipher?
    private var account: String

    init(cipher: SecureBlobCipher?, account: String) {
        self.cipher = cipher
        self.account = account
    }

    func snapshot() -> (SecureBlobCipher?, String) { lock.withLock { (cipher, account) } }
    func set(cipher: SecureBlobCipher?, account: String) { lock.withLock { self.cipher = cipher; self.account = account } }
}

/// Thread-safe set of blob filenames proven decryptable this session, so `hasUsableDiskData` only pays the
/// decrypt-probe once per file.
private final class ValidatedPresence: @unchecked Sendable {
    private let lock = NSLock()
    private var good: Set<String> = []
    func contains(_ name: String) -> Bool { lock.withLock { good.contains(name) } }
    func insert(_ name: String) { lock.withLock { _ = good.insert(name) } }
    func remove(_ name: String) { lock.withLock { _ = good.remove(name) } }
    func clearAll() { lock.withLock { good.removeAll() } }
}
