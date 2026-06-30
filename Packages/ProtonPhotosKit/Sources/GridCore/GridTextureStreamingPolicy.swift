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
    package static func window<ID: Hashable & Sendable>(
        visibleIDs: [ID],
        overscanIDs: [ID]
    ) -> GridTextureStreamingWindow<ID> {
        var seen = Set<ID>()
        var priority: [ID] = []
        priority.reserveCapacity(visibleIDs.count + overscanIDs.count)
        for id in visibleIDs + overscanIDs where seen.insert(id).inserted {
            priority.append(id)
        }
        return GridTextureStreamingWindow(priority: priority, pinned: seen)
    }
}
