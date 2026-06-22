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

    // MARK: - Memoized section aspect ratios

    @ObservationIgnored private var aspectsCacheVersion = -1
    @ObservationIgnored private var aspectsCacheToken = 0
    @ObservationIgnored private var aspectsCacheValue: [[CGFloat]] = []

    /// Per-section clamped aspect ratios for the justified layout, memoized on (registry version,
    /// section structure). Recomputing this in `TimelineView.body` on every SwiftUI re-render did one
    /// dictionary lookup + string-key allocation PER PHOTO; a sidebar-width drag re-evaluates the body
    /// each tick, so for a large library that 20k-element rebuild ran every frame and starved the main
    /// thread — the grid jumped and the divider stuttered. A window resize changes no SwiftUI state, so
    /// it never paid this, which is exactly why it felt smooth. The cache makes the two paths equal.
    public func sectionAspects(for sections: [TimelineSection], registry: AspectRegistry) -> [[CGFloat]] {
        let token = Self.structureToken(sections)
        if aspectsCacheVersion == registry.version, aspectsCacheToken == token {
            return aspectsCacheValue
        }
        let value = sections.map { section in
            section.items.map { min(max(registry.aspect(for: $0.uid), 0.45), 3.2) }
        }
        aspectsCacheVersion = registry.version
        aspectsCacheToken = token
        aspectsCacheValue = value
        return value
    }

    /// Cheap structural fingerprint (O(#sections), not O(#photos)): section count + per-section counts
    /// + the first/last uid, so a same-count reload with different content still invalidates the cache.
    private static func structureToken(_ sections: [TimelineSection]) -> Int {
        var hasher = Hasher()
        hasher.combine(sections.count)
        for section in sections { hasher.combine(section.items.count) }
        if let first = sections.first?.items.first { hasher.combine(first.uid) }
        if let last = sections.last?.items.last { hasher.combine(last.uid) }
        return hasher.finalize()
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
            await feed.startPrefetch(allItems.map(\.uid))
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

    private func refreshCurrent(uploadedUID: PhotoUID?) async -> TimelineRefreshResult {
        let start = ContinuousClock.now
        let before = allItems.count
        do {
            let sections = Self.deduplicatedSections(try await freshSectionsForCurrentFilter())
            let items = sections.flatMap(\.items)
            allItems = items
            state = items.isEmpty ? .empty : .loaded(sections)
            await feed.startPrefetch(items.map(\.uid))
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
