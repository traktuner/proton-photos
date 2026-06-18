import Foundation

public enum GridClickType: Sendable, Equatable {
    case single
    case double
}

public struct GridInteractionDecision: Sendable, Equatable {
    public let togglesSelection: Bool
    public let opensViewer: Bool

    public init(togglesSelection: Bool, opensViewer: Bool) {
        self.togglesSelection = togglesSelection
        self.opensViewer = opensViewer
    }
}

public enum GridInteractionPolicy {
    public static func decision(click: GridClickType, selectionMode: Bool) -> GridInteractionDecision {
        switch (click, selectionMode) {
        case (.single, true):
            return GridInteractionDecision(togglesSelection: true, opensViewer: false)
        case (.single, false):
            return GridInteractionDecision(togglesSelection: false, opensViewer: false)
        case (.double, true):
            return GridInteractionDecision(togglesSelection: false, opensViewer: false)
        case (.double, false):
            return GridInteractionDecision(togglesSelection: false, opensViewer: true)
        }
    }
}
