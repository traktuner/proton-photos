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
    /// Flat, chronological list of every photo — used so the viewer can page through the whole
    /// library, not just the day that was tapped.
    public private(set) var allItems: [PhotoItem] = []

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
            allItems = sections.flatMap(\.items)
            state = sections.isEmpty ? .empty : .loaded(sections)
            // Background fill of the whole library (visible cells reprioritise via requestPriority).
            await feed.startPrefetch(allItems.map(\.uid))
        } catch is CancellationError {
            // ignore
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
