package struct GridTextureStreamingWindow<ID: Hashable & Sendable>: Equatable, Sendable {
    package let priority: [ID]
    package let pinned: Set<ID>

    package init(priority: [ID], pinned: Set<ID>) {
        self.priority = priority
        self.pinned = pinned
    }
}

package enum GridTextureStreamingPolicy {
    /// Visible-first, duplicate-free streaming window. Near-viewport overscan is pinned too so a small
    /// scroll reversal can reuse resident textures instead of evicting and uploading them again.
    ///
    /// Pinning is clamped to the first `maxPinned` items in priority order (visible first, then nearest
    /// overscan): pinned entries are exempt from eviction, so an unclamped pin set at dense zoom levels
    /// (viewport + 2×overscan can exceed the whole texture budget) would make residency unbounded. Items
    /// beyond the clamp stay in `priority` - they may still upload when the budget has room, but they
    /// remain evictable.
    package static func window<ID: Hashable & Sendable>(
        visibleIDs: [ID],
        overscanIDs: [ID],
        maxPinned: Int,
        pinOverscan: Bool = true
    ) -> GridTextureStreamingWindow<ID> {
        var seen = Set<ID>()
        var priority: [ID] = []
        priority.reserveCapacity(visibleIDs.count + overscanIDs.count)
        for id in visibleIDs + overscanIDs where seen.insert(id).inserted {
            priority.append(id)
        }
        let pinnedLimit = pinOverscan ? maxPinned : min(maxPinned, visibleIDs.count)
        let pinned = priority.count <= pinnedLimit ? seen : Set(priority.prefix(max(0, pinnedLimit)))
        return GridTextureStreamingWindow(priority: priority, pinned: pinned)
    }
}
