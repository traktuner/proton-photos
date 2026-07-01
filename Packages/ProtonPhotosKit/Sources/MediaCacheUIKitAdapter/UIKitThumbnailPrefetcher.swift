#if canImport(UIKit)
import Foundation
import PhotosCore

public actor UIKitThumbnailPrefetcher {
    private let feed: UIKitThumbnailFeed
    private var enabled = true

    public init(feed: UIKitThumbnailFeed) {
        self.feed = feed
    }

    public func start(requests: [ThumbnailRequest]) async {
        guard enabled else { return }
        await feed.startPrefetch(requests.map(\.uid))
    }

    public func start(uids: [PhotoUID]) async {
        guard enabled else { return }
        await feed.startPrefetch(uids)
    }

    public func setEnabled(_ enabled: Bool) async {
        self.enabled = enabled
        await feed.setPrefetchEnabled(enabled)
    }

    public func pause() async {
        await feed.pausePrefetch()
    }

    public func resume() async {
        guard enabled else { return }
        await feed.resumePrefetch()
    }

    public func status() async -> UIKitThumbnailFeed.PrefetchStatus {
        await feed.prefetchStatus()
    }
}
#endif
