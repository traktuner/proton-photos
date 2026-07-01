#if canImport(UIKit)
import CoreGraphics
import Foundation
import PhotoViewerCore
import UIKit

public enum UIKitViewerImageAdapter {
    public static func image(from cgImage: CGImage, scale: CGFloat = 1) -> UIImage {
        UIImage(cgImage: cgImage, scale: max(scale, 1), orientation: .up)
    }

    public static func image(from data: Data, scale: CGFloat = 1) -> UIImage? {
        ViewerFullImageDecoder.decodeCGImage(data).map { image(from: $0, scale: scale) }
    }
}
#endif
