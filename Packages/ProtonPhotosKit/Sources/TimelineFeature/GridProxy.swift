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

    /// Force ONE repaint after a full-screen overlay (the photo viewer) that fully covered the grid is dismissed.
    /// The on-demand MTKView's layer surface is purged by the window server under full occlusion, and on reveal
    /// nothing sets `needsDisplay` (every visible tile is still GPU-resident, so the streaming tick is idle) — so the
    /// revealed grid shows its empty clear surface until a stray relayout finally redraws it (the clear flash + the
    /// top-to-bottom rebuild). One redraw repaints the whole viewport from resident textures in a single frame.
    public var redrawOnReveal: (() -> Void)?

    /// Scrolls the grid to a flattened timeline index. Used by date navigation overlays; the Metal host resolves
    /// the index through the same production geometry as visible cells, so no SwiftUI layout math is duplicated.
    public var scrollToFlatIndex: ((Int) -> Void)?

    /// Scrolls to the newest timeline position. The grid is ordered oldest at top, newest at bottom.
    public var scrollToLatest: (() -> Void)?

    /// A layout-invariant snapshot of the grid's current scroll position (the top photo + its sub-offset), or
    /// nil before the grid is wired. The shell reads this when leaving a route to remember where the user was,
    /// so it can reopen that route EXACTLY there later (robust to zoom/resize). Read-only — never scrolls.
    public var currentScrollAnchor: (() -> GridScrollAnchor?)?

    /// The `+` toolbar button: one discrete zoom-IN step (bigger thumbnails). Wired to the SAME
    /// `zoomInStep` the trackpad pinch-in calls, so the button and pinch are identical by construction.
    public var zoomIn: (() -> Void)?

    /// The `−` toolbar button: one discrete zoom-OUT step (smaller thumbnails). Wired to the SAME
    /// `zoomOutStep` the trackpad pinch-out calls.
    public var zoomOut: (() -> Void)?

    /// The aspect/square toolbar toggle: flip the NORMAL-level (L0–L3) thumbnail content fit between
    /// aspectFitInsideSquare and squareFillCrop. Pure content-fit change — never mutates level/zoom/scroll/
    /// phase/geometry. Ignored on the overview levels (L4–L5, square-only).
    public var toggleContentMode: (() -> Void)?

    /// Set the NORMAL-level content-mode preference explicitly (used by the toolbar's two-state control).
    public var setContentMode: ((TileContentDisplayMode) -> Void)?

    /// Query the live content-mode state for rendering the toolbar control (current mode + whether the
    /// toggle is available at the current level). Returns nil before the grid is wired.
    public var contentModeState: (() -> (mode: TileContentDisplayMode, toggleAvailable: Bool))?
}
