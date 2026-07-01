import MediaDecodingCore
import AppKit

enum MacThumbnailImageDecoder {
    static func image(from decoded: DecodedThumbnail) -> NSImage {
        NSImage(
            cgImage: decoded.image,
            size: NSSize(width: decoded.pixelWidth, height: decoded.pixelHeight)
        )
    }

    static func decodedCost(_ image: NSImage) -> Int {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return max(1, Int(image.size.width * image.size.height * 4))
    }
}
