import Foundation

public enum TimelineInitialViewportPlacement: Equatable, Sendable {
    /// Choose the route default from its fill order: the main timeline opens at newest, bounded read-order routes
    /// open at oldest.
    case automatic
    /// Open at the newest end even when the route itself uses read-order top-leading layout.
    case newest
    /// Open at the oldest end even when the route would normally open at newest.
    case oldest
}
