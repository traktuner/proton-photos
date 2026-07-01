import Foundation
import PhotosCore

public actor ThumbnailPrefetcher {
    private let feed: ThumbnailFeed
    private var enabled = true

    public init(feed: ThumbnailFeed) {
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

    public func status() async -> ThumbnailFeed.PrefetchStatus {
        await feed.prefetchStatus()
    }
}
