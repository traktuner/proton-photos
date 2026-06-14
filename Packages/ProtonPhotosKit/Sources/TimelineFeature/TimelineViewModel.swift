import Foundation
import PhotosCore
import MediaCache

@MainActor
@Observable
public final class TimelineViewModel {
    public enum State {
        case loading
        case empty
        case loaded([TimelineSection])
        case failed(String)
    }

    public private(set) var state: State = .loading

    private let repository: PhotosRepository
    public let feed: ThumbnailFeed

    public init(repository: PhotosRepository, feed: ThumbnailFeed) {
        self.repository = repository
        self.feed = feed
    }

    public func load() async {
        if case .loaded = state { return }   // load once
        state = .loading
        do {
            let sections = try await repository.loadTimeline()
            state = sections.isEmpty ? .empty : .loaded(sections)
            // Background fill of the whole library (visible cells reprioritise via requestPriority).
            let uids = sections.flatMap { $0.items.map(\.uid) }
            await feed.startPrefetch(uids)
        } catch is CancellationError {
            // ignore
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
