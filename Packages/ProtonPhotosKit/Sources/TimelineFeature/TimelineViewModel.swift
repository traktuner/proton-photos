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
    private let library: PhotoLibraryProvider?
    public let feed: ThumbnailFeed

    /// The active filter/album. `.all` is the whole library (fast SDK path); others use direct REST.
    public private(set) var filter: PhotoFilter = .all

    public init(repository: PhotosRepository, feed: ThumbnailFeed, library: PhotoLibraryProvider? = nil) {
        self.repository = repository
        self.library = library
        self.feed = feed
    }

    /// Switches what the grid shows. `.all` reuses the cached/SDK timeline; tag & album views load
    /// from the direct endpoints. No-op if already showing that filter.
    public func select(_ newFilter: PhotoFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        if newFilter == .all {
            // loadAll serves the cached full library instantly (no "Building…" flash).
            await loadAll(force: true)
            return
        }
        // Stale-while-revalidate: keep the current grid on screen while the filtered set loads, then
        // swap — no loader flash, no blank grid.
        do {
            let sections = try await (library?.timeline(filter: newFilter) ?? [])
            // Guard against a stale switch (user clicked another filter meanwhile).
            guard filter == newFilter else { return }
            let items = sections.flatMap(\.items)
            allItems = items
            state = items.isEmpty ? .empty : .loaded(sections)
            await feed.startPrefetch(items.map(\.uid))
        } catch is CancellationError {
        } catch {
            // Surface the error — the user explicitly switched filter, so silently keeping the old
            // grid (which read as "nothing happens" for Recently Deleted) is worse than showing why.
            guard filter == newFilter else { return }
            state = .failed(error.localizedDescription)
        }
    }

    public func load() async {
        await loadAll(force: false)
    }

    /// Optimistically drops items from the current grid (after trashing / restoring) without a reload.
    public func remove(_ uids: Set<PhotoUID>) {
        guard !uids.isEmpty else { return }
        allItems.removeAll { uids.contains($0.uid) }
        if case .loaded(var sections) = state {
            for i in sections.indices { sections[i].items.removeAll { uids.contains($0.uid) } }
            sections.removeAll { $0.items.isEmpty }
            state = sections.isEmpty ? .empty : .loaded(sections)
        }
    }

    private func loadAll(force: Bool) async {
        if !force, case .loaded = state { return }   // load once

        // Instant: show the last-known timeline from disk so there's no "Building your library…"
        // spinner on relaunch. The fresh enumeration below then refreshes it in the background.
        if let cached = await repository.cachedTimeline(), !cached.isEmpty {
            allItems = cached.flatMap(\.items)
            state = .loaded(cached)
            await feed.startPrefetch(allItems.map(\.uid))
        } else {
            state = .loading
        }

        do {
            let sections = try await repository.loadTimeline()
            let fresh = sections.flatMap(\.items)
            // Only swap the grid if the library actually changed — otherwise keep the cached view
            // (and the user's scroll position) untouched.
            if fresh != allItems {
                allItems = fresh
                state = sections.isEmpty ? .empty : .loaded(sections)
                await feed.startPrefetch(allItems.map(\.uid))
            }
        } catch is CancellationError {
            // ignore
        } catch {
            // Keep showing the cached timeline on a refresh error; surface failure only if we have
            // nothing to show.
            if case .loaded = state {} else { state = .failed(error.localizedDescription) }
        }
    }
}
