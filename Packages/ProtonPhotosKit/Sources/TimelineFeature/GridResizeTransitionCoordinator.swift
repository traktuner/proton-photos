import CoreGraphics
import Foundation

public extension Notification.Name {
    static let protonPhotosGridResizeHint = Notification.Name("ProtonPhotos.gridResizeHint")
    static let protonPhotosToggleSidebar = Notification.Name("ProtonPhotos.toggleSidebar")
}

public enum GridResizeTransitionReason: String, Sendable, Equatable {
    case windowResize
    case sidebarDrag
    case sidebarToggle
}

public enum GridResizeAnchorKind: String, Sendable, Equatable {
    case mouse
    case viewportCenter
    case selectedItem
    case content
}

public struct GridResizeAnchor: Sendable, Equatable {
    public var kind: GridResizeAnchorKind
    public var viewportPoint: CGPoint
    public var contentPoint: CGPoint

    public init(kind: GridResizeAnchorKind, viewportPoint: CGPoint, contentPoint: CGPoint) {
        self.kind = kind
        self.viewportPoint = viewportPoint
        self.contentPoint = contentPoint
    }
}

public struct GridResizeOverlayTransform: Sendable, Equatable {
    public var frame: CGRect
    public var scale: CGFloat
}

public struct GridResizeTransaction: Sendable, Equatable {
    public var id: Int
    public var sourceViewportSize: CGSize
    public var sourceContentOrigin: CGPoint
    public var sourceVisibleRect: CGRect
    public var sourceSnapshotSize: CGSize
    public var sourceSnapshotFrame: CGRect
    public var anchor: GridResizeAnchor
    public var startTime: TimeInterval
    public var lastSizeChangeTime: TimeInterval
    public var reason: GridResizeTransitionReason
    public var pendingTargetViewportSize: CGSize
    public var pendingTargetSidebarWidth: CGFloat?
    public var overlayID: Int?
}

public enum GridResizeTransitionState: Equatable {
    case idle
    case resizing(GridResizeTransaction)
    case committing(GridResizeTransaction)
}

public struct GridResizeCommitResult: Sendable, Equatable {
    public var scrollOrigin: CGPoint
    public var anchorError: CGPoint
}

@MainActor
public final class GridResizeTransitionCoordinator {
    public static let defaultDebounce: TimeInterval = 0.11
    public static let defaultFadeDuration: TimeInterval = 0.14

    public private(set) var state: GridResizeTransitionState = .idle
    private var nextID = 1

    public init() {}

    @discardableResult
    public func begin(
        reason: GridResizeTransitionReason,
        sourceViewportSize: CGSize,
        sourceContentOrigin: CGPoint,
        sourceVisibleRect: CGRect,
        sourceSnapshotSize: CGSize,
        sourceSnapshotFrame: CGRect,
        anchor: GridResizeAnchor,
        sidebarWidth: CGFloat?,
        now: TimeInterval,
        overlayID: Int?
    ) -> GridResizeTransaction {
        if case var .committing(transaction) = state {
            transaction.reason = reason
            transaction.lastSizeChangeTime = now
            transaction.pendingTargetViewportSize = sourceViewportSize
            transaction.pendingTargetSidebarWidth = sidebarWidth
            state = .resizing(transaction)
            return transaction
        }

        if case var .resizing(transaction) = state {
            transaction.reason = reason
            transaction.lastSizeChangeTime = now
            transaction.pendingTargetViewportSize = sourceViewportSize
            transaction.pendingTargetSidebarWidth = sidebarWidth
            state = .resizing(transaction)
            return transaction
        }

        let id = nextID
        nextID += 1
        let transaction = GridResizeTransaction(
            id: id,
            sourceViewportSize: sourceViewportSize,
            sourceContentOrigin: sourceContentOrigin,
            sourceVisibleRect: sourceVisibleRect,
            sourceSnapshotSize: sourceSnapshotSize,
            sourceSnapshotFrame: sourceSnapshotFrame,
            anchor: anchor,
            startTime: now,
            lastSizeChangeTime: now,
            reason: reason,
            pendingTargetViewportSize: sourceViewportSize,
            pendingTargetSidebarWidth: sidebarWidth,
            overlayID: overlayID
        )
        state = .resizing(transaction)
        return transaction
    }

    public func noteSizeChange(targetViewportSize: CGSize, sidebarWidth: CGFloat?, now: TimeInterval) {
        switch state {
        case .idle:
            return
        case var .resizing(transaction):
            transaction.pendingTargetViewportSize = targetViewportSize
            transaction.pendingTargetSidebarWidth = sidebarWidth
            transaction.lastSizeChangeTime = now
            state = .resizing(transaction)
        case var .committing(transaction):
            transaction.pendingTargetViewportSize = targetViewportSize
            transaction.pendingTargetSidebarWidth = sidebarWidth
            transaction.lastSizeChangeTime = now
            state = .resizing(transaction)
        }
    }

    public func readyToCommit(now: TimeInterval, debounce: TimeInterval = defaultDebounce) -> Bool {
        guard case let .resizing(transaction) = state else { return false }
        return now - transaction.lastSizeChangeTime >= debounce
    }

    @discardableResult
    public func beginCommit() -> GridResizeTransaction? {
        guard case let .resizing(transaction) = state else { return nil }
        state = .committing(transaction)
        return transaction
    }

    public func finishCommit() {
        state = .idle
    }

    public func cleanup() {
        state = .idle
    }

    public var activeTransaction: GridResizeTransaction? {
        switch state {
        case .idle:
            return nil
        case .resizing(let transaction), .committing(let transaction):
            return transaction
        }
    }

    public static func overlayTransform(
        sourceViewportSize: CGSize,
        targetViewportSize: CGSize,
        anchor: GridResizeAnchor
    ) -> GridResizeOverlayTransform {
        let sourceWidth = max(sourceViewportSize.width, 1)
        let sourceHeight = max(sourceViewportSize.height, 1)
        let targetWidth = max(targetViewportSize.width, 1)
        let targetHeight = max(targetViewportSize.height, 1)
        let scale = max(1, targetWidth / sourceWidth, targetHeight / sourceHeight)
        let targetAnchor = CGPoint(
            x: min(max(anchor.viewportPoint.x, 0), targetWidth),
            y: min(max(anchor.viewportPoint.y, 0), targetHeight)
        )
        let origin = CGPoint(
            x: targetAnchor.x - anchor.viewportPoint.x * scale,
            y: targetAnchor.y - anchor.viewportPoint.y * scale
        )
        return GridResizeOverlayTransform(
            frame: CGRect(origin: origin, size: CGSize(width: sourceWidth * scale, height: sourceHeight * scale)),
            scale: scale
        )
    }

    public static func preservedScrollOrigin(
        sourceAnchorContentPoint: CGPoint,
        targetAnchorViewportPoint: CGPoint,
        targetContentSize: CGSize,
        targetViewportSize: CGSize
    ) -> GridResizeCommitResult {
        let maxX = max(0, targetContentSize.width - targetViewportSize.width)
        let maxY = max(0, targetContentSize.height - targetViewportSize.height)
        let requested = CGPoint(
            x: sourceAnchorContentPoint.x - targetAnchorViewportPoint.x,
            y: sourceAnchorContentPoint.y - targetAnchorViewportPoint.y
        )
        let origin = CGPoint(
            x: min(max(requested.x, 0), maxX),
            y: min(max(requested.y, 0), maxY)
        )
        let actualAnchor = CGPoint(x: origin.x + targetAnchorViewportPoint.x, y: origin.y + targetAnchorViewportPoint.y)
        return GridResizeCommitResult(
            scrollOrigin: origin,
            anchorError: CGPoint(x: actualAnchor.x - sourceAnchorContentPoint.x, y: actualAnchor.y - sourceAnchorContentPoint.y)
        )
    }
}
