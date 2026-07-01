import Foundation

/// Learned pixel dimensions of a photo. Non-secret local metadata (same sensitivity class as the
/// capture time / MIME already persisted in `library-v1.sqlite`).
///
/// The values may be THUMBNAIL-SCALE: the thumbnail feed records the decoded thumbnail's pixel
/// size, which preserves the aspect ratio but not the original's absolute resolution. Consumers
/// that need layout/aspect information can rely on `aspectRatio`; consumers that need true pixel
/// counts must use `PhotoMetadata` (server xattr) — a future writer may upgrade rows to true
/// dimensions via `TimelineMetadataStore.updateDimensions(_:overwrite: true)`.
public struct PhotoPixelDimensions: Hashable, Sendable, Codable {
    public let width: Int
    public let height: Int

    /// Fails on non-positive input so an invalid decode can never poison the store.
    public init?(width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }

    public var aspectRatio: Double { Double(width) / Double(height) }
}

/// Persistence seam for learned dimensions. Implemented by the app's backend bridge over
/// `TimelineMetadataStore.updateDimensions`; injected into `PhotoDimensionCoalescer` so the
/// thumbnail feeds stay storage-agnostic.
public protocol PhotoDimensionRecording: Sendable {
    /// Persists a batch of learned dimensions. First-seen-wins at the store layer: rows that
    /// already carry dimensions are left untouched, so thumbnail-scale values can never clobber
    /// true dimensions written later.
    func recordDimensions(_ batch: [PhotoUID: PhotoPixelDimensions]) async
}

/// Coalesces per-decode dimension callbacks into batched store writes.
///
/// The thumbnail feeds fire `record` once per decoded image — during a fast scroll or the
/// background crawl that is hundreds of callbacks per second, and re-decodes of evicted
/// thumbnails repeat for UIDs already seen. This actor dedupes per session, buffers, and flushes
/// one batch after `flushDelay`, so the store sees a handful of small transactions instead of
/// per-decode writes — and never any DB work on the caller's (render/decode) path.
public actor PhotoDimensionCoalescer {
    private let store: any PhotoDimensionRecording
    private let flushDelay: Duration
    private var pending: [PhotoUID: PhotoPixelDimensions] = [:]
    /// UIDs already flushed this session — re-decodes of the same photo are dropped here instead
    /// of re-hitting the store (where they would be a no-op anyway).
    private var recorded: Set<PhotoUID> = []
    private var flushTask: Task<Void, Never>?

    public init(store: any PhotoDimensionRecording, flushDelay: Duration = .seconds(2)) {
        self.store = store
        self.flushDelay = flushDelay
    }

    /// Called from the feeds' decode callback (any executor). Cheap: hops onto the actor and
    /// returns; invalid sizes are dropped.
    public nonisolated func record(_ uid: PhotoUID, width: Int, height: Int) {
        guard let dimensions = PhotoPixelDimensions(width: width, height: height) else { return }
        Task { await self.ingest(uid, dimensions) }
    }

    private func ingest(_ uid: PhotoUID, _ dimensions: PhotoPixelDimensions) {
        guard !recorded.contains(uid), pending[uid] == nil else { return }
        pending[uid] = dimensions
        guard flushTask == nil else { return }
        flushTask = Task {
            try? await Task.sleep(for: flushDelay)
            await self.flush()
        }
    }

    /// Flushes immediately — for app teardown and tests.
    public func flushNow() async {
        flushTask?.cancel()
        await flush()
    }

    private func flush() async {
        flushTask = nil
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll()
        recorded.formUnion(batch.keys)
        await store.recordDimensions(batch)
    }
}
