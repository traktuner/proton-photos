import CoreGraphics
import Foundation
import ImageIO

public enum ViewerFullImageDecoder {
    /// Decodes image bytes into a ready-to-upload/draw `CGImage`, optionally BOUNDED to a maximum longest-side
    /// pixel size.
    ///
    /// `kCGImageSourceShouldCacheImmediately` forces rasterization during this call, so platform adapters can run
    /// it off the main actor and avoid a lazy decode during first draw. `kCGImageSourceCreateThumbnailWithTransform`
    /// bakes EXIF orientation.
    ///
    /// - Parameter maxPixelSize: when non-nil, the longest side is capped at `min(maxPixelSize, originalLongest)`
    ///   - the memory-bounded viewer DISPLAY decode (screen-sized), so a huge original never decodes into a giant
    ///   image just because a page appeared. When nil (the default), the original pixel dimensions are preserved -
    ///   the full-quality path used for zoom/export.
    public static func decodeCGImage(_ data: Data, maxPixelSize: Int? = nil) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let originalLongest = max(
            props?[kCGImagePropertyPixelWidth] as? Int ?? 0,
            props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        )
        // Never upscale past the source; a nil cap keeps full resolution (fallback 100_000 when dims are unknown).
        let target: Int
        if let maxPixelSize {
            target = originalLongest > 0 ? min(maxPixelSize, originalLongest) : maxPixelSize
        } else {
            target = originalLongest > 0 ? originalLongest : 100_000
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, target),
        ]
        if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) {
            return image
        }
        let fallbackOptions: [CFString: Any] = [
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateImageAtIndex(source, 0, fallbackOptions as CFDictionary)
    }
}
