import MediaFeedCore
import MLSearchCore
import PhotosCore

/// Shared Apple-platform image source for semantic indexing.
///
/// It reuses the universal encrypted thumbnail cache and never starts a download. Missing
/// thumbnails remain transient so a later indexing pass can pick them up after normal library
/// prefetch, without ML work competing with the visible grid.
public struct CachedThumbnailMLImageSource: CoreMLImageSource {
    private let load: @Sendable (PhotoUID) async -> CoreMLSourceImage?

    public init(feed: ThumbnailFeedCore) {
        self.load = { uid in
            await feed.backgroundCachedDecoded(for: uid).map {
                CoreMLSourceImage(cgImage: $0.image)
            }
        }
    }

    init(load: @escaping @Sendable (PhotoUID) async -> CoreMLSourceImage?) {
        self.load = load
    }

    public func image(for uid: PhotoUID) async -> CoreMLImageSourceOutcome {
        guard let image = await load(uid) else { return .transientFailure }
        return .image(image)
    }
}
