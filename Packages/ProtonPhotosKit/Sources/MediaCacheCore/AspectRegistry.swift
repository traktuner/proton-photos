import Foundation
import Observation
import PhotosCore

/// Stores per-photo aspect ratios (width / height) so the timeline can lay out a justified,
/// aspect-preserving grid like Apple Photos. The Proton timeline doesn't expose dimensions, so we
/// learn them from thumbnails as they decode, coalesce updates, and persist them across launches
/// (after the first view a section no longer reflows).
@MainActor
@Observable
public final class AspectRegistry {
    /// Bumped when aspects change so dependent layout recomputes (coalesced).
    public private(set) var version = 0

    private var aspects: [String: CGFloat] = [:]
    private var pending: [String: CGFloat] = [:]
    private var flushScheduled = false
    private let url: URL

    public init(namespace: String = "aspects") {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("ProtonPhotos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("\(namespace).json")
        if let data = try? Data(contentsOf: url),
           let dict = try? JSONDecoder().decode([String: CGFloat].self, from: data) {
            aspects = dict
        }
    }

    /// Aspect ratio for a photo; defaults to square until its thumbnail has been seen.
    public func aspect(for uid: PhotoUID) -> CGFloat {
        aspects[Self.key(uid)] ?? 1
    }

    /// Called (off the main actor, from the thumbnail feed) when a thumbnail's size is known.
    public nonisolated func record(_ uid: PhotoUID, aspect: CGFloat) {
        guard aspect > 0, aspect.isFinite else { return }
        Task { @MainActor in self.ingest(Self.key(uid), aspect) }
    }

    private func ingest(_ key: String, _ aspect: CGFloat) {
        guard aspects[key] == nil, pending[key] == nil else { return }
        pending[key] = aspect
        guard !flushScheduled else { return }
        flushScheduled = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            for (k, v) in pending { aspects[k] = v }
            pending.removeAll()
            flushScheduled = false
            version &+= 1
            persist()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(aspects) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func key(_ uid: PhotoUID) -> String { "\(uid.volumeID)~\(uid.nodeID)" }
}
