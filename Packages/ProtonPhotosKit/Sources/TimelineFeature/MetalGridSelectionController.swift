import PhotosCore
import GridCore

/// Production selection adapter for the Metal grid: maps Apple-Photos pointer semantics (single click
/// replaces, ⌘ toggles, ⇧ range-selects from the anchor) into the platform-neutral GridCore selection
/// controller. The selected set survives scroll because it lives here, never in any cell view.
@MainActor
final class MetalGridSelectionController {
    private var core = GridSelectionController<PhotoUID>()

    var selected: Set<PhotoUID> { core.selected }
    /// The flat index of the last replace/toggle click — the origin for a subsequent ⇧-range select.
    var anchorIndex: Int? { core.anchorIndex }

    /// Called whenever the selection changes (drives the toolbar count + the coordinator outline).
    var onChange: ((Set<PhotoUID>) -> Void)?

    func clear() {
        guard core.clear() else { return }
        onChange?(selected)
    }

    /// Apply a single click on the item at `flatIndex` (`uid`), using the modifier-driven decision.
    func click(flatIndex: Int, uid: PhotoUID, orderedUIDs: [PhotoUID], modifiers: GridClickModifiers, selectionMode: Bool) {
        let decision = GridInteractionPolicy.decision(click: .single, modifiers: modifiers, selectionMode: selectionMode)
        core.apply(GridSelectionCommand(decision.selection), flatIndex: flatIndex, id: uid, orderedIDs: orderedUIDs)
        onChange?(selected)
    }

    /// A click on empty space (gap) clears the selection (Apple-Photos behavior).
    func clickBackground() { clear() }

    // MARK: Marquee (drag-rectangle) selection — replaces ⇧-click for multi-select.

    /// Begin a marquee drag. `additive` (⇧ held at drag start) keeps the existing selection and adds to it;
    /// otherwise the drag REPLACES the selection with whatever the rectangle covers.
    func marqueeBegan(additive: Bool) { core.marqueeBegan(additive: additive) }

    /// Update the marquee selection to the cells currently under the rectangle (`uids`), unioned with the
    /// drag-start base. Equality-guarded so an unchanged drag step doesn't churn the renderer.
    func marqueeChanged(_ uids: Set<PhotoUID>) {
        guard core.marqueeChanged(uids) else { return }
        onChange?(selected)
    }
}

private extension GridSelectionCommand {
    init(_ operation: GridSelectionOp) {
        switch operation {
        case .none: self = .none
        case .replace: self = .replace
        case .toggle: self = .toggle
        case .range: self = .range
        }
    }
}
