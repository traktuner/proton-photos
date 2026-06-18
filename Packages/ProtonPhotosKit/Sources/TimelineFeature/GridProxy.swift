import Foundation
import PhotosCore

/// Lets the SwiftUI layer query the grid for a photo's on-screen cell frame (for the shared-element
/// zoom transition) and scroll a photo into view. The coordinator fills these closures in; they
/// return frames in the grid's own top-left coordinate space (the scroll viewport), which the caller
/// offsets by the grid's frame to get window/root coordinates.
@MainActor
public final class GridProxy {
    public init() {}

    /// Frame of a photo's cell in the WINDOW's content coordinate space (top-left origin), or nil if
    /// the cell isn't currently visible. Computed via AppKit `convert`, so it already accounts for
    /// scroll position, the sidebar, and the toolbar — the SwiftUI zoom overlay (which fills the same
    /// window content) can use it directly without any offset math.
    public var windowFrameForItem: ((PhotoItem) -> CGRect?)?

    /// Scrolls the grid so the photo is vertically centred (used before a fly-back-to-cell close).
    public var scrollToItem: ((PhotoItem) -> Void)?

    /// Scrolls to the newest timeline position. The grid is ordered oldest at top, newest at bottom.
    public var scrollToLatest: (() -> Void)?

    /// The `+` toolbar button: one discrete zoom-IN step (bigger thumbnails). Wired to the SAME
    /// `zoomInStep` the trackpad pinch-in calls, so the button and pinch are identical by construction.
    public var zoomIn: (() -> Void)?

    /// The `−` toolbar button: one discrete zoom-OUT step (smaller thumbnails). Wired to the SAME
    /// `zoomOutStep` the trackpad pinch-out calls.
    public var zoomOut: (() -> Void)?
}
