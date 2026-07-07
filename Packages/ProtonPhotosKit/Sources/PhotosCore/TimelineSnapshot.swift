import Foundation

/// An immutable, flattened + ordered view of a timeline, with a uid→index map built in the SAME pass.
///
/// Platform hosts previously did `sections.flatMap(\.items).sorted(by: TimelineOrder.areInIncreasingOrder)`
/// inline on the main actor, then paid a second O(n) `firstIndex(of:)`/`filter` on every open/share/trash.
/// This type does the flatten+sort ONCE (off the main actor - it is pure and `Sendable`, so a caller builds
/// it in a detached task and publishes only the finished value), and answers open/share lookups in O(1)/
/// O(k log k) from the prebuilt index instead of rescanning the whole library.
///
/// Ordering is exactly the shared `TimelineOrder` total order (capture time ascending, ties broken by
/// volume then node id), so it is deterministic and identical to the previous inline sort.
public struct TimelineSnapshot: Sendable {
    /// The flattened items in timeline order.
    public let items: [PhotoItem]
    /// uid → position in `items`. First occurrence wins if a uid somehow appears twice.
    private let indexByUID: [PhotoUID: Int]

    /// The empty snapshot (no items) - the initial state before any timeline has loaded.
    public init() {
        items = []
        indexByUID = [:]
    }

    /// Flatten + sort `sections` into the canonical timeline order and index them. Pure; safe to run off the
    /// main actor. `TimelineSection`/`PhotoItem` are `Sendable`, so the sections can cross the actor boundary.
    public init(sections: [TimelineSection]) {
        self.init(orderedItems: sections.flatMap(\.items).sorted(by: TimelineOrder.areInIncreasingOrder))
    }

    /// Build directly from already-ordered items (used by `removingItems` and tests). The caller guarantees
    /// `orderedItems` is in `TimelineOrder`; this only builds the index.
    public init(orderedItems: [PhotoItem]) {
        items = orderedItems
        var map = [PhotoUID: Int](minimumCapacity: orderedItems.count)
        for (position, item) in orderedItems.enumerated() where map[item.uid] == nil {
            map[item.uid] = position
        }
        indexByUID = map
    }

    public var isEmpty: Bool { items.isEmpty }
    public var count: Int { items.count }

    /// Position of `uid` in `items`, or nil. O(1).
    public func index(of uid: PhotoUID) -> Int? { indexByUID[uid] }

    /// The item for `uid`, or nil. O(1).
    public func item(for uid: PhotoUID) -> PhotoItem? { indexByUID[uid].map { items[$0] } }

    /// The items whose uid is in `uids`, in timeline order - for share/export of a selection. O(k log k) in
    /// the selection size, never an O(n) scan of the whole library.
    public func items(withUIDs uids: Set<PhotoUID>) -> [PhotoItem] {
        uids.compactMap { indexByUID[$0] }.sorted().map { items[$0] }
    }

    /// A new snapshot without `uids` (trash), preserving order and rebuilding the index. Returns `self`
    /// unchanged when nothing is removed.
    public func removingItems(withUIDs uids: Set<PhotoUID>) -> TimelineSnapshot {
        guard !uids.isEmpty else { return self }
        return TimelineSnapshot(orderedItems: items.filter { !uids.contains($0.uid) })
    }
}

extension TimelineSnapshot: Equatable {
    /// Equal when the ordered items match - the index is a pure function of them, so it is not compared
    /// (avoids walking a large dictionary).
    public static func == (lhs: TimelineSnapshot, rhs: TimelineSnapshot) -> Bool {
        lhs.items == rhs.items
    }
}
