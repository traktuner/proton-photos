import CoreGraphics

/// Platform-neutral command/event seam between an outer shell and a grid host.
///
/// The proxy is intentionally ID-based and generic: Core owns the command surface, while app/feature layers
/// decide what their item identity type is. It contains no renderer, view, cache, image, or platform framework
/// dependency.
@MainActor
public final class GridProxy<ItemID: Hashable & Sendable> {
    public init() {}

    /// Frame of an item's cell in the shell/window content coordinate space, or nil if the cell is not visible.
    public var windowFrameForItem: ((ItemID) -> CGRect?)?

    /// Scrolls the grid so the item is vertically centered.
    public var scrollToItem: ((ItemID) -> Void)?

    /// Scrolls the grid to a flattened timeline index. Used by date navigation overlays; the host resolves the
    /// index through production geometry, so no outer UI duplicates grid layout math.
    public var scrollToFlatIndex: ((Int) -> Void)?

    /// Scrolls to the newest timeline position.
    public var scrollToLatest: (() -> Void)?

    /// Read-only layout-invariant snapshot of the grid's current scroll position. The shell stores it per route.
    public var currentScrollAnchor: (() -> GridScrollAnchor<ItemID>?)?

    /// One discrete zoom-in step. The host wires this to the same path as trackpad pinch-in.
    public var zoomIn: (() -> Void)?

    /// One discrete zoom-out step. The host wires this to the same path as trackpad pinch-out.
    public var zoomOut: (() -> Void)?

    /// Flip normal-level thumbnail content fit. This is a content-fit command only; it must not mutate grid
    /// level, zoom, scroll, phase, or geometry.
    public var toggleContentMode: (() -> Void)?

    /// Set the normal-level content-mode preference explicitly.
    public var setContentMode: ((TileContentDisplayMode) -> Void)?

    /// Query live content-mode state for the shell control.
    public var contentModeState: (() -> (mode: TileContentDisplayMode, toggleAvailable: Bool))?

    /// Grid-to-shell event fired once the first on-screen frame is fully populated.
    public var onFirstContentReady: (() -> Void)?

    /// Live notification of a window-resize / sidebar-scale gesture being in progress.
    /// The shell uses this to suspend costly compositing (e.g. within-window vibrancy blur)
    /// while the Metal surface is being scaled per tick, then re-enables it on false.
    public var liveResizeChanged: ((_ active: Bool) -> Void)?
}
