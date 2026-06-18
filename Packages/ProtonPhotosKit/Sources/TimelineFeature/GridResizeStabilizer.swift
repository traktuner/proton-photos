import CoreGraphics
import Foundation

public extension Notification.Name {
    /// Posted by the app shell to bracket a sidebar drag / sidebar toggle so the grid can keep its
    /// visual region stable while the width animates. `userInfo`: `reason` (raw `GridResizeReason`),
    /// `phase` ("begin" / "change" / "end").
    static let protonPhotosGridResizeHint = Notification.Name("ProtonPhotos.gridResizeHint")
    static let protonPhotosToggleSidebar = Notification.Name("ProtonPhotos.toggleSidebar")
}

/// Why the grid is being resized. Drives logging + which native hooks bracket the session; the
/// behaviour is identical for all three (native relayout, anchor preserved, grid always visible).
public enum GridResizeReason: String, Sendable, Equatable {
    case windowResize
    case sidebarDrag
    case sidebarToggle
}

/// The stabilizer is deliberately a two-state machine. There is **no** overlay / snapshot / commit
/// state — the real grid is never hidden, so there is nothing to fade back in.
public enum GridResizeStabilizerState: Equatable {
    case idle
    case resizing(GridResizeReason)

    public var isResizing: Bool {
        if case .resizing = self { return true }
        return false
    }

    public var reason: GridResizeReason? {
        if case .resizing(let reason) = self { return reason }
        return nil
    }
}

// MARK: - Anchor

public enum ResizeAnchorKind: String, Sendable, Equatable {
    /// The point under the mouse, when the cursor is inside the grid viewport. Highest priority.
    case mouse
    /// A selected (and visible) item's centre.
    case selectedItem
    /// The viewport centre's content point (no item resolved, or the fallback).
    case viewportCenter
    /// A raw content point (cursor in a gap / empty grid) — preserved by vertical fraction.
    case content
}

/// A pure description of the point the resize must keep stable. `uid` + `localPoint` (a unit point
/// inside that item's cell) let the coordinator re-resolve the SAME photo's content point after the
/// width-driven relayout; `viewportPoint` is where that point should stay on screen. Pure + `Codable`
/// so the anchor math is unit-testable without AppKit.
public struct ResizeAnchor: Sendable, Equatable {
    public var kind: ResizeAnchorKind
    public var viewportPoint: CGPoint
    public var contentPoint: CGPoint
    public var uid: String?
    public var localPoint: CGPoint?

    public init(
        kind: ResizeAnchorKind,
        viewportPoint: CGPoint,
        contentPoint: CGPoint,
        uid: String? = nil,
        localPoint: CGPoint? = nil
    ) {
        self.kind = kind
        self.viewportPoint = viewportPoint
        self.contentPoint = contentPoint
        self.uid = uid
        self.localPoint = localPoint
    }
}

public struct ResizeScrollSolution: Sendable, Equatable {
    /// The clip-view bounds origin that keeps the anchor's content point under `anchorViewportPoint`.
    public var scrollOrigin: CGPoint
    /// Residual (clamped origin can't always honour the request near the content edges). `.zero` when
    /// the anchor is reachable. Reported in logs as `anchorError`.
    public var anchorError: CGPoint

    public init(scrollOrigin: CGPoint, anchorError: CGPoint) {
        self.scrollOrigin = scrollOrigin
        self.anchorError = anchorError
    }
}

/// The whole anchor preservation math, isolated and pure. Given where the anchor's content point
/// lands after the relayout (`targetContentPoint`) and where we want it on screen
/// (`anchorViewportPoint`), return the scroll origin — clamped into the valid content range — plus
/// the residual error. No overlay, no snapshot: this is the entire resize "trick".
public func computeScrollOriginPreservingResizeAnchor(
    targetContentPoint: CGPoint,
    anchorViewportPoint: CGPoint,
    contentSize: CGSize,
    viewportSize: CGSize
) -> ResizeScrollSolution {
    let maxX = max(0, contentSize.width - viewportSize.width)
    let maxY = max(0, contentSize.height - viewportSize.height)
    let requested = CGPoint(
        x: targetContentPoint.x - anchorViewportPoint.x,
        y: targetContentPoint.y - anchorViewportPoint.y
    )
    let origin = CGPoint(
        x: min(max(requested.x, 0), maxX),
        y: min(max(requested.y, 0), maxY)
    )
    let actualAnchorContent = CGPoint(
        x: origin.x + anchorViewportPoint.x,
        y: origin.y + anchorViewportPoint.y
    )
    return ResizeScrollSolution(
        scrollOrigin: origin,
        anchorError: CGPoint(
            x: actualAnchorContent.x - targetContentPoint.x,
            y: actualAnchorContent.y - targetContentPoint.y
        )
    )
}

// MARK: - Placeholder rule

/// What a grid cell shows during (and after) a resize. The rule: a cell whose thumbnail has not
/// decoded must still draw the deterministic placeholder at its computed rect — NEVER an empty hole.
/// `PhotoGridItem` enforces this by always assigning `GridThumbnailFallback.placeholderImage` when it
/// has no decoded image; this enum makes the rule explicit + testable.
public enum ResizeCellFill: Sendable, Equatable {
    case image
    case placeholder
}

public func gridCellFillDuringResize(hasDecodedImage: Bool) -> ResizeCellFill {
    hasDecodedImage ? .image : .placeholder
}

// MARK: - Stabilizer

/// Replaces the rejected `GridResizeTransitionCoordinator` snapshot-overlay path. This coordinator
/// owns ONLY the resize *state* and the visibility invariant — the actual relayout is the native
/// `NSCollectionView` width-driven relayout, performed in place with the real grid visible the entire
/// time. Boring and stable on purpose: there is no surface to render, nothing to hide, nothing to
/// fade, so there is no path that can leave a black region.
@MainActor
public final class GridResizeStabilizer {
    /// How long after the last width change a session with no explicit `end` signal (e.g. a sidebar
    /// toggle animation) is considered finished.
    public static let idleTimeout: TimeInterval = 0.16

    public private(set) var state: GridResizeStabilizerState = .idle

    /// Hard invariant, asserted by `NoOverlayResizePathTest`: this path never renders a snapshot.
    public let usesSnapshotOverlay = false

    /// The collection view's hidden/alpha during resize — ALWAYS visible. Production code reads these
    /// so the rule "grid stays visible" lives in exactly one place and is unit-testable.
    public var collectionHidden: Bool { false }
    public var collectionAlpha: CGFloat { 1 }

    /// Count of the explicitly-allowed `reloadData`-during-resize escapes (should stay 0 on the normal
    /// path). Asserted by `NoReloadDuringResizeTest`.
    public private(set) var reloadDuringResizeCount = 0

    public init() {}

    public var isResizing: Bool { state.isResizing }
    public var reason: GridResizeReason? { state.reason }

    public func begin(reason: GridResizeReason) {
        state = .resizing(reason)
    }

    /// Update the reason without leaving the resizing state (e.g. a sidebar drag that becomes a window
    /// resize). Starts a session if idle.
    public func update(reason: GridResizeReason) {
        state = .resizing(reason)
    }

    public func end() {
        state = .idle
    }

    /// While resizing, structural `reloadData` work must be deferred (the normal path) — never run
    /// against the live grid mid-resize.
    public func shouldDeferReload() -> Bool { isResizing }

    /// The one escape hatch: a caller that truly must reload during resize records it here so it is
    /// counted + logged rather than silent. The normal path never calls this.
    public func noteReloadDuringResize() {
        reloadDuringResizeCount += 1
    }
}
