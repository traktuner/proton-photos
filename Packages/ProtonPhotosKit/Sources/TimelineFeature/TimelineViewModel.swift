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

    private var flatUIDs: [PhotoUID] = []
    private var indexByUID: [PhotoUID: Int] = [:]
    private var latestVisibleIndex = 0
    private var focusTask: Task<Void, Never>?

    public init(repository: PhotosRepository, feed: ThumbnailFeed) {
        self.repository = repository
        self.feed = feed
    }

    /// Called as cells appear. Coalesces scroll position and tells the feed to prioritise the
    /// on-screen window plus a look-ahead buffer, so a far jump loads instantly.
    public func cellAppeared(_ uid: PhotoUID) {
        guard let index = indexByUID[uid] else { return }
        latestVisibleIndex = index
        focusTask?.cancel()
        focusTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self, !Task.isCancelled else { return }
            let center = self.latestVisibleIndex
            let start = max(0, center - 40)
            let end = min(self.flatUIDs.count, center + 240)
            guard start < end else { return }
            await self.feed.focus(Array(self.flatUIDs[start ..< end]))
        }
    }

    public func load() async {
        if case .loaded = state { return }   // load once
        state = .loading
        do {
            let sections = try await repository.loadTimeline()
            state = sections.isEmpty ? .empty : .loaded(sections)
            // Index the flat order for scroll-based prioritisation, then start prefetch.
            flatUIDs = sections.flatMap { $0.items.map(\.uid) }
            indexByUID = Dictionary(uniqueKeysWithValues: flatUIDs.enumerated().map { ($1, $0) })
            await feed.startPrefetch(flatUIDs)
        } catch is CancellationError {
            // ignore
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
