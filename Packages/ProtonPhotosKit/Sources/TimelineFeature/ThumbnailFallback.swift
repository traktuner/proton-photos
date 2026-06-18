import AppKit
import CoreGraphics

enum GridThumbnailFallback {
    static let placeholderImage: CGImage = {
        let side = 16
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let gray: UInt8 = 46
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            pixels[offset] = gray
            pixels[offset + 1] = gray
            pixels[offset + 2] = gray
            pixels[offset + 3] = 255
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: side,
            height: side,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )!
    }()

    static var placeholderSize: CGSize {
        CGSize(width: placeholderImage.width, height: placeholderImage.height)
    }

    static func placeholderNSImage() -> NSImage {
        NSImage(cgImage: placeholderImage, size: NSSize(width: placeholderImage.width, height: placeholderImage.height))
    }
}
