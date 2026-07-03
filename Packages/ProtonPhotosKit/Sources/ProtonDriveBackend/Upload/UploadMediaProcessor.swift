import Foundation
import ImageIO
import AVFoundation
import CoreGraphics
import UniformTypeIdentifiers
import ProtonDriveSDK

/// Generates the encrypted-thumbnail inputs the SDK upload requires. All work is CPU/IO bound and is
/// only ever called off the main thread (from the upload backend). Best-effort: if a thumbnail can't
/// be produced (corrupt file, unusual codec) it's omitted rather than failing the whole upload.
enum UploadMediaProcessor {
    /// Proton's thumbnail box sizes (longest edge): a small grid thumbnail + a larger preview.
    private static let thumbnailMaxPixel = 512
    private static let previewMaxPixel = 1920

    static func thumbnails(for url: URL, isVideo: Bool) async -> [ThumbnailData] {
        guard let source = await baseImage(for: url, isVideo: isVideo) else { return [] }
        var result: [ThumbnailData] = []
        if let thumb = jpeg(downscaling: source, maxPixel: thumbnailMaxPixel) {
            result.append(ThumbnailData(type: .thumbnail, data: thumb))
        }
        if let preview = jpeg(downscaling: source, maxPixel: previewMaxPixel) {
            result.append(ThumbnailData(type: .preview, data: preview))
        }
        return result
    }

    // MARK: - Base image

    private static func baseImage(for url: URL, isVideo: Bool) async -> CGImage? {
        if isVideo {
            return await videoFrame(url)
        }
        return imageSourceFrame(url)
    }

    /// Full-ish image (downscaled to the preview box) used as the source for both outputs.
    private static func imageSourceFrame(_ url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: previewMaxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
    }

    private static func videoFrame(_ url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: previewMaxPixel, height: previewMaxPixel)
        let time = CMTime(seconds: 0, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    // MARK: - Encoding

    private static func jpeg(downscaling image: CGImage, maxPixel: Int) -> Data? {
        let scaled = downscale(image, maxPixel: maxPixel) ?? image
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func downscale(_ image: CGImage, maxPixel: Int) -> CGImage? {
        let w = image.width, h = image.height
        let longest = max(w, h)
        guard longest > maxPixel else { return image }
        let scale = Double(maxPixel) / Double(longest)
        let nw = Int((Double(w) * scale).rounded()), nh = Int((Double(h) * scale).rounded())
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: nw, height: nh))
        return ctx.makeImage()
    }
}
