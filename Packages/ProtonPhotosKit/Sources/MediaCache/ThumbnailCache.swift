import Foundation
import PhotosCore

/// Two-tier thumbnail cache: in-memory (NSCache) backed by an on-disk store.
/// Keeps decoded thumbnails resident for smooth scrolling and survives relaunch.
public actor ThumbnailCache {
    private let memory = NSCache<NSString, NSData>()
    private nonisolated let directory: URL
    private let fileManager = FileManager.default

    public init(namespace: String = "thumbnails") {
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("ProtonPhotos/\(namespace)", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.countLimit = 2000
    }

    public func data(for uid: PhotoUID) -> Data? {
        let key = Self.key(uid)
        if let cached = memory.object(forKey: key as NSString) { return cached as Data }
        let url = directory.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: url) else { return nil }
        memory.setObject(data as NSData, forKey: key as NSString)
        return data
    }

    /// Cheap on-disk existence check (no read/decode) — used to skip already-fetched thumbnails.
    /// `nonisolated`: touches only the immutable `directory` and the global file manager.
    public nonisolated func has(_ uid: PhotoUID) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(Self.key(uid)).path)
    }

    /// Direct disk read/write (no in-memory layer). `nonisolated` so the thumbnail feed, which has
    /// its own decoded-image cache, can use these without actor hops.
    public nonisolated func diskData(for uid: PhotoUID) -> Data? {
        try? Data(contentsOf: directory.appendingPathComponent(Self.key(uid)))
    }

    public nonisolated func diskURL(for uid: PhotoUID) -> URL {
        directory.appendingPathComponent(Self.key(uid))
    }

    public nonisolated func storeToDisk(_ data: Data, for uid: PhotoUID) {
        try? data.write(to: directory.appendingPathComponent(Self.key(uid)), options: .atomic)
    }

    public func store(_ data: Data, for uid: PhotoUID) {
        let key = Self.key(uid)
        memory.setObject(data as NSData, forKey: key as NSString)
        try? data.write(to: directory.appendingPathComponent(key), options: .atomic)
    }

    public func clear() {
        memory.removeAllObjects()
        try? fileManager.removeItem(at: directory)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

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

    private static func key(_ uid: PhotoUID) -> String {
        "\(uid.volumeID)~\(uid.nodeID)".replacingOccurrences(of: "/", with: "_")
    }
}
