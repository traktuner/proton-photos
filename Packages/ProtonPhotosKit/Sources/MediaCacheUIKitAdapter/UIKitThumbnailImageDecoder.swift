#if canImport(UIKit)
import MediaDecodingCore
import UIKit

enum UIKitThumbnailImageDecoder {
    static func image(from decoded: DecodedThumbnail) -> UIImage {
        UIImage(cgImage: decoded.image, scale: 1, orientation: .up)
    }

    static func decodedCost(_ image: UIImage) -> Int {
        if let cgImage = image.cgImage, cgImage.width > 0, cgImage.height > 0 {
            return cgImage.width * cgImage.height * 4
        }
        let scale = max(image.scale, 1)
        return max(1, Int(image.size.width * scale * image.size.height * scale * 4))
    }
}
#endif
