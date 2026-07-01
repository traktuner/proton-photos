import CoreGraphics

public enum ViewerChromeLayout {
    public static let toolbarHeight: CGFloat = 56
    public static let inspectorWidth: CGFloat = 340

    public static func toolbarFrame(in container: CGRect, height: CGFloat = toolbarHeight) -> CGRect {
        CGRect(x: container.minX, y: container.minY, width: container.width, height: height)
    }

    public static func contentFrame(in container: CGRect, toolbarHeight: CGFloat = toolbarHeight) -> CGRect {
        CGRect(
            x: container.minX,
            y: container.minY + toolbarHeight,
            width: container.width,
            height: max(0, container.height - toolbarHeight)
        )
    }

    public static func inspectorFrame(
        in container: CGRect,
        toolbarHeight: CGFloat = toolbarHeight,
        width: CGFloat = inspectorWidth
    ) -> CGRect {
        let content = contentFrame(in: container, toolbarHeight: toolbarHeight)
        let clampedWidth = min(max(width, 320), min(380, content.width))
        return CGRect(
            x: content.maxX - clampedWidth,
            y: content.minY,
            width: clampedWidth,
            height: content.height
        )
    }

    /// Stable inspector width for a given content area (the region already below the opaque top bar).
    /// Clamped to 320…380 pt and never wider than the content, so it animates in/out without resizing.
    public static func clampedInspectorWidth(in content: CGRect, width: CGFloat = inspectorWidth) -> CGFloat {
        min(max(width, 320), min(380, content.width))
    }

    public static func inspectorOverlapsToolbar(
        container: CGRect,
        toolbarHeight: CGFloat = toolbarHeight,
        width: CGFloat = inspectorWidth
    ) -> Bool {
        inspectorFrame(in: container, toolbarHeight: toolbarHeight, width: width)
            .intersects(toolbarFrame(in: container, height: toolbarHeight))
    }
}
