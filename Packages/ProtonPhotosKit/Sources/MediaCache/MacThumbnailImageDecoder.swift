import AppKit
import MediaDecodingCore

struct MacDecodedThumbnail: @unchecked Sendable {
    let image: NSImage
    let pixelWidth: Int
    let pixelHeight: Int
    let costBytes: Int

    var aspectRatio: CGFloat {
        CGFloat(pixelWidth) / max(CGFloat(pixelHeight), 1)
    }
}

enum MacThumbnailImageDecoder {
    static func decode(_ data: Data, maxPixelSize: CGFloat) -> MacDecodedThumbnail? {
        if let decoded = ThumbnailImageDecoder.downsample(data, maxPixelSize: maxPixelSize) {
            let image = NSImage(
                cgImage: decoded.image,
                size: NSSize(width: decoded.pixelWidth, height: decoded.pixelHeight)
            )
            return MacDecodedThumbnail(
                image: image,
                pixelWidth: decoded.pixelWidth,
                pixelHeight: decoded.pixelHeight,
                costBytes: decoded.decodedCostBytes
            )
        }

        guard let image = NSImage(data: data) else { return nil }
        return MacDecodedThumbnail(
            image: image,
            pixelWidth: max(1, Int(image.size.width)),
            pixelHeight: max(1, Int(image.size.height)),
            costBytes: decodedCost(image)
        )
    }

    static func decodedCost(_ image: NSImage) -> Int {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        return max(1, Int(image.size.width * image.size.height * 4))
    }
}
