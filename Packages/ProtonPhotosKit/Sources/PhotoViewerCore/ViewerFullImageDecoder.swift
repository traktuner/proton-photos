import CoreGraphics
import Foundation
import ImageIO

public enum ViewerFullImageDecoder {
    /// Fully decodes original image bytes into a ready-to-upload/draw `CGImage`.
    ///
    /// `kCGImageSourceShouldCacheImmediately` forces rasterization during this call, so platform adapters can run
    /// it off the main actor and avoid lazy decode during first draw. The thumbnail path is intentionally sized to
    /// the original pixel dimensions to preserve full resolution while baking EXIF orientation through
    /// `kCGImageSourceCreateThumbnailWithTransform`.
    public static func decodeCGImage(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let maxDim = max(
            props?[kCGImagePropertyPixelWidth] as? Int ?? 0,
            props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        )
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDim > 0 ? maxDim : 100_000,
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
