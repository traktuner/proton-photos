import Foundation
import PhotosCore

/// Two-tier thumbnail cache: in-memory (NSCache) backed by an on-disk store.
/// Keeps decoded thumbnails resident for smooth scrolling and survives relaunch.
public actor ThumbnailCache {
    private let memory = NSCache<NSString, NSData>()
    private let directory: URL
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

    private static func key(_ uid: PhotoUID) -> String {
        "\(uid.volumeID)~\(uid.nodeID)".replacingOccurrences(of: "/", with: "_")
    }
}
