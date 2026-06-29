import Foundation
import PhotosCore
import MediaCache

public struct TimelineRefreshResult: Sendable, Equatable {
    public let uploadedUID: PhotoUID?
    public let foundItem: PhotoItem?
    public let timelineCountBefore: Int
    public let timelineCountAfter: Int
    public let filterDescription: String
    public let elapsedMs: Double
    public let errorMessage: String?

    public var found: Bool { foundItem != nil }

    public init(
        uploadedUID: PhotoUID?,
        foundItem: PhotoItem?,
        timelineCountBefore: Int,
        timelineCountAfter: Int,
        filterDescription: String,
        elapsedMs: Double,
        errorMessage: String? = nil
    ) {
        self.uploadedUID = uploadedUID
        self.foundItem = foundItem
        self.timelineCountBefore = timelineCountBefore
        self.timelineCountAfter = timelineCountAfter
        self.filterDescription = filterDescription
        self.elapsedMs = elapsedMs
        self.errorMessage = errorMessage
    }
}

public struct TimelineRefreshRetrySchedule: Sendable, Equatable {
    public let delays: [Duration]

    public init(delays: [Duration]) {
        self.delays = delays
    }

    /// Immediate refresh, then bounded eventual-consistency retries. Total wait: 30 seconds.
    public static let uploadDefault = TimelineRefreshRetrySchedule(
        delays: [.zero, .seconds(1), .seconds(3), .seconds(8), .seconds(18)]
    )
}

struct TimelineVisibleContent {
    let sections: [TimelineSection]
    let items: [PhotoItem]
    let monthMarkers: [TimelineDateMarker]
    let hasSearchQuery: Bool

    var isEmptySearchResult: Bool {
        sections.isEmpty && hasSearchQuery
    }
}

@MainActor
@Observable
public final class TimelineViewModel {
    public enum State {
        case loading
        case empty
        case loaded([TimelineSection])
        case failed(String)
    }

    public private(set) var state: State = .loading {
        didSet { invalidateVisibleContentCache(bumpGeneration: true) }
    }
    /// Flat, chronological list of every photo — used so the viewer can page through the whole
    /// library, not just the day that was tapped.
    public private(set) var allItems: [PhotoItem] = []

    private let repository: PhotosRepository
    private let library: PhotoLibraryProvider?
    public let feed: ThumbnailFeed

    /// The active filter/album. `.all` is the whole library (fast SDK path); others use direct REST.
    public private(set) var filter: PhotoFilter = .all {
        didSet { invalidateVisibleContentCache() }
    }

    public init(repository: PhotosRepository, feed: ThumbnailFeed, library: PhotoLibraryProvider? = nil) {
        self.repository = repository
        self.library = library
        self.feed = feed
    }

    // MARK: - Memoized visible timeline content

    @ObservationIgnored private var visibleContentGeneration = 0
    @ObservationIgnored private var visibleContentCacheKey: VisibleContentCacheKey?
    @ObservationIgnored private var visibleContentCacheValue: TimelineVisibleContent?

    func visibleContent(searchText: String, favoriteUIDs: Set<PhotoUID>, includeMonthMarkers: Bool) -> TimelineVisibleContent {
        let context = TimelineSearchContext(activeFilter: filter, favoriteUIDs: favoriteUIDs)
        let key = VisibleContentCacheKey(
            generation: visibleContentGeneration,
            searchText: searchText,
            context: context,
            includeMonthMarkers: includeMonthMarkers
        )
        if visibleContentCacheKey == key, let visibleContentCacheValue {
            return visibleContentCacheValue
        }

        guard case .loaded(let sections) = state else {
            let value = TimelineVisibleContent(
                sections: [],
                items: [],
                monthMarkers: [],
                hasSearchQuery: !TimelineSearchQuery(searchText).isEmpty
            )
            visibleContentCacheKey = key
            visibleContentCacheValue = value
            return value
        }

        let visibleSections = TimelineSearch.filter(sections, query: searchText, context: context)
        let visibleItems = visibleSections.flatMap(\.items)
        let monthMarkers = includeMonthMarkers
            ? MetalGridProductionAdapter.dateMarkers(sections: visibleSections, granularity: .month)
            : []
        let value = TimelineVisibleContent(
            sections: visibleSections,
            items: visibleItems,
            monthMarkers: monthMarkers,
            hasSearchQuery: !TimelineSearchQuery(searchText).isEmpty
        )
        visibleContentCacheKey = key
        visibleContentCacheValue = value
        return value
    }

    private func invalidateVisibleContentCache(bumpGeneration: Bool = false) {
        if bumpGeneration { visibleContentGeneration &+= 1 }
        visibleContentCacheKey = nil
        visibleContentCacheValue = nil
    }

    private struct VisibleContentCacheKey: Equatable {
        let generation: Int
        let searchText: String
        let context: TimelineSearchContext
        let includeMonthMarkers: Bool
    }

    /// Switches what the grid shows. `.all` reuses the cached/SDK timeline; tag & album views load
    /// from the direct endpoints. No-op if already showing that filter.
    public func select(_ newFilter: PhotoFilter) async {
        guard newFilter != filter else { return }
        filter = newFilter
        if newFilter == .all {
            await loadAll(force: true)   // cached full library, instant
        } else {
            await loadFiltered(newFilter)
        }
    }

    /// Re-runs the CURRENTLY selected filter — wired to the error-state "Retry" button. It must reload THIS
    /// filter, NOT fall back to `.all` (the old bug: retry on a failed Recently-Deleted loaded ALL photos while
    /// the sidebar still pointed at Trash → content/selection mismatch).
    public func retry() async {
        if filter == .all { await loadAll(force: true) } else { await loadFiltered(filter) }
    }

    /// Loads a tag/album/trash filter, showing the `.loading` animation while it fetches (so a route switch never
    /// flashes a black/stale grid). A newer switch mid-flight wins (the `filter == f` guards).
    private func loadFiltered(_ f: PhotoFilter) async {
        state = .loading
        do {
            let sections = try await (library?.timeline(filter: f) ?? [])
            guard filter == f else { return }
            let items = sections.flatMap(\.items)
            allItems = items
            state = items.isEmpty ? .empty : .loaded(sections)
            await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
        } catch is CancellationError {
        } catch {
            guard filter == f else { return }
            state = .failed(error.localizedDescription)
        }
    }

    public func load() async {
        await loadAll(force: false)
    }

    /// Manual user-triggered reload of the currently visible library/filter.
    @discardableResult
    public func refreshLibrary() async -> TimelineRefreshResult {
        await refreshCurrent(uploadedUID: nil)
    }

    /// Reloads the current timeline after an upload and warms the new UID's thumbnail cache if known.
    @discardableResult
    public func refreshAfterUpload(uploadedUID: PhotoUID?) async -> TimelineRefreshResult {
        let result = await refreshCurrent(uploadedUID: uploadedUID)
        if let uploadedUID {
            await feed.requestPriority(uploadedUID, priority: .visibleNow)
            _ = await feed.warmDecoded([uploadedUID], limit: 1)
        }
        return result
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
            let deduped = Self.deduplicatedSections(cached)
            allItems = deduped.flatMap(\.items)
            state = .loaded(deduped)
            await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(allItems))
        } else {
            state = .loading
        }

        do {
            let sections = Self.deduplicatedSections(try await repository.loadTimeline())
            let fresh = sections.flatMap(\.items)
            // Only swap the grid if the library actually changed — otherwise keep the cached view
            // (and the user's scroll position) untouched.
            if fresh != allItems {
                allItems = fresh
                state = sections.isEmpty ? .empty : .loaded(sections)
                await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(allItems))
            }
        } catch is CancellationError {
            // ignore
        } catch {
            // Keep showing the cached timeline on a refresh error; surface failure only if we have
            // nothing to show.
            if case .loaded = state {} else { state = .failed(error.localizedDescription) }
        }
    }

    private func refreshCurrent(uploadedUID: PhotoUID?) async -> TimelineRefreshResult {
        let start = ContinuousClock.now
        let before = allItems.count
        do {
            let sections = Self.deduplicatedSections(try await freshSectionsForCurrentFilter())
            let items = sections.flatMap(\.items)
            allItems = items
            state = items.isEmpty ? .empty : .loaded(sections)
            await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
            let foundItem = uploadedUID.flatMap { uid in items.first { $0.uid == uid } }
            return TimelineRefreshResult(
                uploadedUID: uploadedUID,
                foundItem: foundItem,
                timelineCountBefore: before,
                timelineCountAfter: items.count,
                filterDescription: Self.describe(filter),
                elapsedMs: elapsedMilliseconds(since: start)
            )
        } catch is CancellationError {
            return TimelineRefreshResult(
                uploadedUID: uploadedUID,
                foundItem: nil,
                timelineCountBefore: before,
                timelineCountAfter: allItems.count,
                filterDescription: Self.describe(filter),
                elapsedMs: elapsedMilliseconds(since: start),
                errorMessage: "cancelled"
            )
        } catch {
            if case .loaded = state {} else { state = .failed(error.localizedDescription) }
            return TimelineRefreshResult(
                uploadedUID: uploadedUID,
                foundItem: nil,
                timelineCountBefore: before,
                timelineCountAfter: allItems.count,
                filterDescription: Self.describe(filter),
                elapsedMs: elapsedMilliseconds(since: start),
                errorMessage: error.localizedDescription
            )
        }
    }

    private func freshSectionsForCurrentFilter() async throws -> [TimelineSection] {
        switch filter {
        case .all:
            return try await repository.loadTimeline()
        default:
            guard let library else { return [] }
            return try await library.timeline(filter: filter)
        }
    }

    public nonisolated static func deduplicatedSections(_ sections: [TimelineSection]) -> [TimelineSection] {
        var seen = Set<PhotoUID>()
        return sections.compactMap { section in
            let items = section.items.filter { seen.insert($0.uid).inserted }
            guard !items.isEmpty else { return nil }
            return TimelineSection(id: section.id, date: section.date, title: section.title, items: items)
        }
    }

    private nonisolated static func describe(_ filter: PhotoFilter) -> String {
        switch filter {
        case .all: return "all"
        case .tag(let tag): return "tag:\(tag.title)"
        case .album(let id, let title): return "album:\(title):\(id)"
        case .trash: return "trash"
        }
    }

    private nonisolated func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock.now)
        let components = elapsed.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
