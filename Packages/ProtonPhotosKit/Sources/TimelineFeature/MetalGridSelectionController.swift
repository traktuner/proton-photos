import Foundation
import PhotosCore

/// Production selection model for the Metal grid: applies Apple-Photos pointer semantics (single click
/// replaces, ⌘ toggles, ⇧ range-selects from the anchor) over the flat library order. Pure + testable;
/// the selected set survives scroll because it lives here (the renderer just draws an outline for every
/// resident UID in the set), never in any cell view.
@MainActor
final class MetalGridSelectionController {
    private(set) var selected: Set<PhotoUID> = []
    /// The flat index of the last replace/toggle click — the origin for a subsequent ⇧-range select.
    private(set) var anchorIndex: Int?

    /// Called whenever the selection changes (drives the toolbar count + the coordinator outline).
    var onChange: ((Set<PhotoUID>) -> Void)?

    func clear() {
        guard !selected.isEmpty || anchorIndex != nil else { return }
        selected.removeAll()
        anchorIndex = nil
        onChange?(selected)
    }

    /// Apply a single click on the item at `flatIndex` (`uid`), using the modifier-driven decision.
    func click(flatIndex: Int, uid: PhotoUID, orderedUIDs: [PhotoUID], modifiers: GridClickModifiers, selectionMode: Bool) {
        let decision = GridInteractionPolicy.decision(click: .single, modifiers: modifiers, selectionMode: selectionMode)
        switch decision.selection {
        case .replace:
            selected = [uid]
            anchorIndex = flatIndex
        case .toggle:
            if selected.contains(uid) { selected.remove(uid) } else { selected.insert(uid) }
            anchorIndex = flatIndex
        case .range:
            if let anchor = anchorIndex, anchor >= 0, anchor < orderedUIDs.count, flatIndex >= 0, flatIndex < orderedUIDs.count {
                let lo = min(anchor, flatIndex), hi = max(anchor, flatIndex)
                selected = Set(orderedUIDs[lo ... hi])
            } else {
                selected = [uid]
                anchorIndex = flatIndex
            }
        case .none:
            break
        }
        onChange?(selected)
    }

    /// A click on empty space (gap) clears the selection (Apple-Photos behavior).
    func clickBackground() { clear() }

    // MARK: Marquee (drag-rectangle) selection — replaces ⇧-click for multi-select.

    /// The selection that existed when the drag began — the base a ⇧-drag ADDS to. A plain drag starts from empty.
    private var marqueeBase: Set<PhotoUID> = []

    /// Begin a marquee drag. `additive` (⇧ held at drag start) keeps the existing selection and adds to it;
    /// otherwise the drag REPLACES the selection with whatever the rectangle covers.
    func marqueeBegan(additive: Bool) { marqueeBase = additive ? selected : [] }

    /// Update the marquee selection to the cells currently under the rectangle (`uids`), unioned with the
    /// drag-start base. Equality-guarded so an unchanged drag step doesn't churn the renderer.
    func marqueeChanged(_ uids: Set<PhotoUID>) {
        let new = marqueeBase.union(uids)
        guard new != selected else { return }
        selected = new
        onChange?(selected)
    }
}
