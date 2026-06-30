import CoreGraphics

/// Platform-neutral decoded thumbnail payload.
///
/// `CGImage` and ImageIO are available across Apple platforms, so this type can be used by macOS, iOS, and
/// iPadOS without introducing platform UI image wrappers into the shared decode path.
public struct DecodedThumbnail: @unchecked Sendable {
    public let image: CGImage
    public let pixelWidth: Int
    public let pixelHeight: Int

    public init(image: CGImage) {
        self.image = image
        self.pixelWidth = image.width
        self.pixelHeight = image.height
    }

    public var aspectRatio: CGFloat {
        CGFloat(pixelWidth) / max(CGFloat(pixelHeight), 1)
    }

    public var decodedCostBytes: Int {
        max(1, pixelWidth * pixelHeight * 4)
    }
}
