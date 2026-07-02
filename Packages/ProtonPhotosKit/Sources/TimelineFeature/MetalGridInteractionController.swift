import AppKit
import PhotosCore
import TimelineCore

/// Routes raw pointer events from the Metal grid into selection ops + viewer opens. A single click
/// selects (never opens); a double click opens the viewer. Hit testing is delegated to the coordinator
/// (point → cell). Pure routing - the selection model + the open action are injected.
@MainActor
final class MetalGridInteractionController {
    private weak var coordinator: MetalGridCoordinator?
    private let selection: MetalGridSelectionController
    /// Opens the viewer for a double-clicked item.
    var onOpen: ((PhotoUID) -> Void)?
    /// Whether the explicit checkmark selection mode is active (single bare click toggles instead of replaces).
    var selectionMode = false

    init(coordinator: MetalGridCoordinator, selection: MetalGridSelectionController) {
        self.coordinator = coordinator
        self.selection = selection
    }

    /// Handle a mouse-down at a CONTENT-space point with its click count + modifiers.
    func handleClick(contentPoint: CGPoint, clickCount: Int, modifiers: GridClickModifiers) {
        guard let coordinator else { return }
        let hit = coordinator.hitTestCell(contentPoint: contentPoint)
        if clickCount >= 2 {
            guard let hit else { return }
            logInteraction(event: "doubleClick", uid: hit.uid, openViewer: true)
            onOpen?(hit.uid)
            return
        }
        guard let hit else {
            selection.clickBackground()
            logInteraction(event: "singleClick", uid: nil, openViewer: false)
            return
        }
        selection.click(flatIndex: hit.flatIndex, uid: hit.uid, orderedUIDs: coordinator.orderedUIDs,
                        modifiers: modifiers, selectionMode: selectionMode)
        logInteraction(event: "singleClick", uid: hit.uid, openViewer: false)
    }

    /// Marquee (drag-rectangle) selection - drag the mouse to draw a selection rectangle instead of ⇧-clicking
    /// each item. `additive` (⇧ at drag start) adds to the existing selection; otherwise the rectangle replaces it.
    func handleMarqueeBegan(additive: Bool) { selection.marqueeBegan(additive: additive) }
    func handleMarqueeChanged(contentRect: CGRect) {
        guard let coordinator else { return }
        selection.marqueeChanged(coordinator.uids(intersecting: contentRect))
    }
    func handleMarqueeEnded() { /* selection is applied live during the drag - nothing to finalize */ }

    private func logInteraction(event: String, uid: PhotoUID?, openViewer: Bool) {
        PhotoDiagnostics.shared.emit("MetalGridInteraction", [
            "event": event,
            "uid": uid.map { "\($0.volumeID)~\($0.nodeID)" } ?? "-",
            "openViewer": "\(openViewer)",
            "selectedCount": "\(selection.selected.count)",
        ])
    }

    /// Translate AppKit modifier flags to the grid's modifier set.
    static func modifiers(from event: NSEvent) -> GridClickModifiers {
        var mods: GridClickModifiers = []
        if event.modifierFlags.contains(.command) { mods.insert(.command) }
        if event.modifierFlags.contains(.shift) { mods.insert(.shift) }
        return mods
    }
}
