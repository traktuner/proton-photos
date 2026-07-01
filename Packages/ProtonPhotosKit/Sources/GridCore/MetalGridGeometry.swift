import CoreGraphics

/// Pure content↔viewport coordinate conversion for the Metal grid (unit-tested by
/// `MetalGridCoordinateTransformTests`). Item rects live in content coordinates (origin at the top of
/// the whole library, y increasing downward — matching the flipped scroll document). The MTKView draws
/// in viewport coordinates (origin at the top-left of the visible clip area), so each item is offset by
/// the scroll origin.
package enum MetalGridGeometry {
    /// Convert a content-space rect to viewport space given the current scroll origin (clip bounds origin).
    package static func viewportRect(contentRect: CGRect, visibleOrigin: CGPoint) -> CGRect {
        CGRect(
            x: contentRect.minX - visibleOrigin.x,
            y: contentRect.minY - visibleOrigin.y,
            width: contentRect.width,
            height: contentRect.height
        )
    }
}
