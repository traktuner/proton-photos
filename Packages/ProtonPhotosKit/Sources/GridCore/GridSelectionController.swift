package enum GridSelectionCommand: Sendable, Equatable {
    case none
    case replace
    case toggle
    case range
}

/// Platform-neutral selection state for a flat grid order. Platform adapters decide how pointer, touch,
/// keyboard, or checkmark-mode input maps into `GridSelectionCommand`; this type only mutates selection.
package struct GridSelectionController<ID: Hashable & Sendable>: Equatable, Sendable {
    package private(set) var selected: Set<ID> = []
    package private(set) var anchorIndex: Int?

    private var marqueeBase: Set<ID> = []

    package init() {}

    package mutating func clear() -> Bool {
        guard !selected.isEmpty || anchorIndex != nil else { return false }
        selected.removeAll()
        anchorIndex = nil
        marqueeBase.removeAll()
        return true
    }

    package mutating func apply(
        _ command: GridSelectionCommand,
        flatIndex: Int,
        id: ID,
        orderedIDs: [ID]
    ) {
        switch command {
        case .replace:
            selected = [id]
            anchorIndex = flatIndex
        case .toggle:
            if selected.contains(id) {
                selected.remove(id)
            } else {
                selected.insert(id)
            }
            anchorIndex = flatIndex
        case .range:
            if let anchor = anchorIndex,
               anchor >= 0,
               anchor < orderedIDs.count,
               flatIndex >= 0,
               flatIndex < orderedIDs.count {
                let lo = min(anchor, flatIndex)
                let hi = max(anchor, flatIndex)
                selected = Set(orderedIDs[lo ... hi])
            } else {
                selected = [id]
                anchorIndex = flatIndex
            }
        case .none:
            break
        }
    }

    package mutating func marqueeBegan(additive: Bool) {
        marqueeBase = additive ? selected : []
    }

    package mutating func marqueeChanged(_ ids: Set<ID>) -> Bool {
        let newSelection = marqueeBase.union(ids)
        guard newSelection != selected else { return false }
        selected = newSelection
        return true
    }
}
