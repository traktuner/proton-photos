import CoreGraphics

/// Pure content↔viewport coordinate conversion for the Metal grid (unit-tested by
/// `MetalGridCoordinateTransformTests`). Item rects live in content coordinates (origin at the top of
/// the whole library, y increasing downward — matching the flipped scroll document). The MTKView draws
/// in viewport coordinates (origin at the top-left of the visible clip area), so each item is offset by
/// the scroll origin.
enum MetalGridGeometry {
    /// Convert a content-space rect to viewport space given the current scroll origin (clip bounds origin).
    static func viewportRect(contentRect: CGRect, visibleOrigin: CGPoint) -> CGRect {
        CGRect(
            x: contentRect.minX - visibleOrigin.x,
            y: contentRect.minY - visibleOrigin.y,
            width: contentRect.width,
            height: contentRect.height
        )
    }

    /// Convert a viewport-space point (e.g. a mouse location in the MTKView) back to content space.
    static func contentPoint(viewportPoint: CGPoint, visibleOrigin: CGPoint) -> CGPoint {
        CGPoint(x: viewportPoint.x + visibleOrigin.x, y: viewportPoint.y + visibleOrigin.y)
    }

    /// The visible rect expanded vertically by `overscan` points above and below (clamped to content).
    static func overscanRect(visibleRect: CGRect, overscan: CGFloat, contentHeight: CGFloat) -> CGRect {
        let minY = max(0, visibleRect.minY - overscan)
        let maxY = min(max(contentHeight, visibleRect.maxY), visibleRect.maxY + overscan)
        return CGRect(x: visibleRect.minX, y: minY, width: visibleRect.width, height: max(0, maxY - minY))
    }
}
