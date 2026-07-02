import Foundation
import PhotosCore
import MediaCache
import TimelineCore

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
    /// Flat, chronological items of the CURRENTLY active route (whole library for `.all`, else the
    /// filtered tag/album/trash set) - backs selection and the upload-found lookup, not viewer paging.
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

    /// Per-route loaded sections, so REVISITING a filter/album shows its content INSTANTLY (no loading screen)
    /// while a fresh fetch refreshes behind. Session-scoped; the background refetch on every visit self-heals
    /// staleness, so no explicit invalidation is needed. (`.all` has its own on-disk cache via the repository.)
    @ObservationIgnored private var filterCache: [PhotoFilter: [TimelineSection]] = [:]

    /// In-memory snapshot of the `.all` route's sections for THIS session, so returning to All Photos shows
    /// its content instantly from memory (no disk read, no re-dedup) - the counterpart to `filterCache` for
    /// the whole-library route, which otherwise re-materialized from the repository on every revisit. Kept in
    /// sync by `applyAllContent`, `refreshCurrent`, and `remove`.
    @ObservationIgnored private var allRouteSnapshot: [TimelineSection]?

    /// Whether `sections` flattens to exactly `items` (same `PhotoItem`s, same order) WITHOUT allocating the
    /// flattened array - the content-equality that lets an unchanged refresh/revisit skip state reassignment
    /// (no grid rebuild, no month-marker rebuild, no thumbnail-prefetch restart, scroll + selection preserved).
    /// Pure + `nonisolated`, so it is trivially testable and safe to evaluate off the main actor.
    public nonisolated static func timelineContentUnchanged(_ sections: [TimelineSection], vs items: [PhotoItem]) -> Bool {
        var count = 0
        for section in sections { count += section.items.count }
        guard count == items.count else { return false }
        var i = 0
        for section in sections {
            for item in section.items {
                if item != items[i] { return false }
                i += 1
            }
        }
        return true
    }

    /// One line per timeline refresh/revisit outcome (never per frame) + a testable counter. Grep
    /// `[TimelineRefreshPerf]`; `event` is `applied` (content changed → reassign + prefetch), `unchangedSkip`
    /// (identical → no reassignment), or `snapshotHit` (`.all` shown instantly from the session snapshot).
    private func noteRefresh(_ event: String) {
        PhotoDiagnostics.shared.increment("timeline.refresh.\(event)")
        PhotoDiagnostics.shared.emit("TimelineRefreshPerf", [
            "event": event, "filter": Self.describe(filter), "rows": "\(allItems.count)",
        ])
    }

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

    /// Re-runs the CURRENTLY selected filter - wired to the error-state "Retry" button. It must reload THIS
    /// filter, NOT fall back to `.all` (the old bug: retry on a failed Recently-Deleted loaded ALL photos while
    /// the sidebar still pointed at Trash → content/selection mismatch).
    public func retry() async {
        if filter == .all { await loadAll(force: true) } else { await loadFiltered(filter) }
    }

    /// Loads a tag/album/trash filter, showing the `.loading` animation while it fetches (so a route switch never
    /// flashes a black/stale grid). A newer switch mid-flight wins (the `filter == f` guards).
    private func loadFiltered(_ f: PhotoFilter) async {
        // Instant revisit: if this route was loaded earlier this session, show it IMMEDIATELY (no spinner) and
        // refresh behind. Only the very first visit shows the loading animation.
        if let cached = filterCache[f] {
            let items = cached.flatMap(\.items)
            allItems = items
            state = items.isEmpty ? .empty : .loaded(cached)
        } else {
            state = .loading
        }
        do {
            let sections = try await (library?.timeline(filter: f) ?? [])
            guard filter == f else { return }
            filterCache[f] = sections
            let items = sections.flatMap(\.items)
            // Only swap the grid if the content actually changed - otherwise keep the instant view (and the
            // user's scroll position) untouched.
            if items != allItems {
                allItems = items
                state = items.isEmpty ? .empty : .loaded(sections)
                await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
            } else if case .loaded = state {
                // identical to what we already showed from cache - nothing to do
            } else {
                state = items.isEmpty ? .empty : .loaded(sections)   // first load, content equals stale allItems
            }
        } catch is CancellationError {
        } catch {
            guard filter == f else { return }
            // Keep the cached view on a refresh error; surface failure only if we have nothing to show.
            if case .loaded = state {} else { state = .failed(error.localizedDescription) }
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
            // Keep the route's instant-revisit view consistent with the optimistic removal, so returning to
            // it doesn't flash the just-trashed items back in.
            if filter == .all { allRouteSnapshot = sections } else { filterCache[filter] = sections }
        }
    }

    private func loadAll(force: Bool) async {
        if !force, case .loaded = state { return }   // load once

        // Instant: show the in-memory `.all` snapshot captured earlier this session (no disk read, no
        // re-dedup) so a REVISIT never re-materializes the whole library. Only the very first visit / a
        // relaunch falls back to the on-disk cache so there's no "Building your library…" spinner. Either
        // way `applyAllContent` reassigns state ONLY when the content actually differs.
        if let snapshot = allRouteSnapshot {
            noteRefresh("snapshotHit")
            await applyAllContent(snapshot)
        } else {
            let cached = await repository.cachedTimeline()
            // A sidebar switch may have landed WHILE we were fetching. If the active filter is no longer `.all`,
            // BAIL - never clobber the newly-selected route's content with the whole library. This is the
            // "I clicked RAW right after launch but stayed in All Photos" bug: the slow `.all` load used to win.
            // Every `await` below re-checks this so the views stay married to the sidebar selection.
            guard filter == .all else { return }
            if let cached, !cached.isEmpty {
                await applyAllContent(Self.deduplicatedSections(cached))
            } else if case .loaded = state {} else {
                state = .loading
            }
        }

        do {
            let sections = Self.deduplicatedSections(try await repository.loadTimeline())
            guard filter == .all else { return }   // route switched mid-fetch - keep the new route, not All Photos
            // Only swap the grid if the library actually changed - otherwise keep the shown view (and the
            // user's scroll position) untouched.
            await applyAllContent(sections)
        } catch is CancellationError {
            // ignore
        } catch {
            guard filter == .all else { return }
            // Keep showing the cached timeline on a refresh error; surface failure only if we have
            // nothing to show.
            if case .loaded = state {} else { state = .failed(error.localizedDescription) }
        }
    }

    /// Show `.all` content: refresh the session snapshot, and (re)assign `state`/`allItems` + restart the
    /// thumbnail crawl ONLY when the flattened item sequence differs from what is already displayed. A revisit
    /// or behind-the-scenes refresh of an UNCHANGED library therefore does no grid rebuild and no prefetch
    /// restart. The `.loaded`/`.empty` guard still lets the FIRST load settle an empty library off `.loading`.
    private func applyAllContent(_ sections: [TimelineSection]) async {
        allRouteSnapshot = sections
        let settled: Bool
        switch state {
        case .loaded, .empty: settled = true
        default: settled = false
        }
        if settled, Self.timelineContentUnchanged(sections, vs: allItems) {
            noteRefresh("unchangedSkip")
            return
        }
        let items = sections.flatMap(\.items)
        allItems = items
        state = items.isEmpty ? .empty : .loaded(sections)
        noteRefresh("applied")
        await feed.startPrefetch(ThumbnailCrawlOrder.newestToOldest(items))
    }

    private func refreshCurrent(uploadedUID: PhotoUID?) async -> TimelineRefreshResult {
        let start = ContinuousClock.now
        let before = allItems.count
        let f = filter   // the route this refresh is for
        do {
            let sections = Self.deduplicatedSections(try await freshSectionsForCurrentFilter())
            guard filter == f else {   // a sidebar switch landed mid-refresh - don't clobber the new route
                return TimelineRefreshResult(
                    uploadedUID: uploadedUID, foundItem: nil,
                    timelineCountBefore: before, timelineCountAfter: allItems.count,
                    filterDescription: Self.describe(f), elapsedMs: elapsedMilliseconds(since: start),
                    errorMessage: "superseded by route switch"
                )
            }
            // No-op refresh: if the freshly fetched content is identical to what's already shown, do NOT
            // reassign state/allItems, refresh the route cache, or restart the crawl - the grid stays put
            // (scroll + selection preserved). The found-item lookup still runs against the current list.
            if Self.timelineContentUnchanged(sections, vs: allItems) {
                noteRefresh("unchangedSkip")
                let foundItem = uploadedUID.flatMap { uid in allItems.first { $0.uid == uid } }
                return TimelineRefreshResult(
                    uploadedUID: uploadedUID,
                    foundItem: foundItem,
                    timelineCountBefore: before,
                    timelineCountAfter: allItems.count,
                    filterDescription: Self.describe(filter),
                    elapsedMs: elapsedMilliseconds(since: start)
                )
            }
            let items = sections.flatMap(\.items)
            allItems = items
            state = items.isEmpty ? .empty : .loaded(sections)
            if f == .all { allRouteSnapshot = sections } else { filterCache[f] = sections }   // keep the route's instant-revisit view fresh
            noteRefresh("applied")
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
        case .map: return "map"
        }
    }

    private nonisolated func elapsedMilliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: ContinuousClock.now)
        let components = elapsed.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
