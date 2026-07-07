#if canImport(UIKit)
import CoreGraphics
import Foundation
import PhotoViewerCore
import UIKit

public enum UIKitViewerImageAdapter {
    public static func image(from cgImage: CGImage, scale: CGFloat = 1) -> UIImage {
        UIImage(cgImage: cgImage, scale: max(scale, 1), orientation: .up)
    }

    /// Decode image bytes into a `UIImage`, optionally BOUNDED to `maxPixelSize` (longest side) - the memory-bounded
    /// viewer display decode. `nil` keeps full resolution (zoom/export). The heavy ImageIO decode is forced now
    /// (`kCGImageSourceShouldCacheImmediately`), so callers should invoke this OFF the main actor.
    public static func image(from data: Data, scale: CGFloat = 1, maxPixelSize: Int? = nil) -> UIImage? {
        ViewerFullImageDecoder.decodeCGImage(data, maxPixelSize: maxPixelSize).map { image(from: $0, scale: scale) }
    }
}
#endif
