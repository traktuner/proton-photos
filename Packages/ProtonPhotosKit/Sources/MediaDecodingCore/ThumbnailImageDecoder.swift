import CoreGraphics
import Foundation
import ImageIO

/// Cross-platform ImageIO thumbnail decoder.
///
/// Keep this module free of platform UI frameworks. Platform targets may adapt the returned `CGImage` to their
/// native presentation image type, or directly to Metal textures.
public enum ThumbnailImageDecoder {
    public static func downsample(_ data: Data, maxPixelSize: CGFloat) -> DecodedThumbnail? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let pixelLimit = max(1, Int(maxPixelSize.rounded(.up)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: pixelLimit,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return DecodedThumbnail(image: image)
    }
}
