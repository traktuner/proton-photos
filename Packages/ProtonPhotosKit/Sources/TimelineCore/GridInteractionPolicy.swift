import Foundation

public enum GridClickType: Sendable, Equatable {
    case single
    case double
}

/// Modifier keys held during a grid click - drives whether a single click replaces, toggles, or
/// range-extends the selection (Apple-Photos behavior).
public struct GridClickModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = GridClickModifiers(rawValue: 1 << 0)
    public static let shift = GridClickModifiers(rawValue: 1 << 1)
}

public enum GridSelectionOp: Sendable, Equatable {
    case none
    case replace   // select only this item, clearing the rest
    case toggle    // add/remove this item from the selection (⌘-click)
    case range     // select the span anchor…this item (⇧-click)
}

public struct GridInteractionDecision: Sendable, Equatable {
    public let selection: GridSelectionOp
    public let opensViewer: Bool

    public init(selection: GridSelectionOp, opensViewer: Bool) {
        self.selection = selection
        self.opensViewer = opensViewer
    }
}

/// Pure decision table for grid pointer interactions. Selection is ALWAYS available now (no explicit
/// "select mode" required): a single click selects, ⌘ toggles, ⇧ range-selects, and a double click
/// opens the viewer. `selectionMode` (the explicit checkmark flow) only changes a bare single click
/// from `.replace` to `.toggle` so the toolbar multi-select keeps working.
public enum GridInteractionPolicy {
    public static func decision(
        click: GridClickType,
        modifiers: GridClickModifiers = [],
        selectionMode: Bool = false
    ) -> GridInteractionDecision {
        switch click {
        case .double:
            return GridInteractionDecision(selection: .none, opensViewer: true)
        case .single:
            if modifiers.contains(.command) {
                return GridInteractionDecision(selection: .toggle, opensViewer: false)
            }
            if modifiers.contains(.shift) {
                return GridInteractionDecision(selection: .range, opensViewer: false)
            }
            if selectionMode {
                return GridInteractionDecision(selection: .toggle, opensViewer: false)
            }
            return GridInteractionDecision(selection: .replace, opensViewer: false)
        }
    }
}
