#if canImport(UIKit)
import CoreGraphics
import PhotoViewerCore

public struct UIKitViewerTransitionTiming: Equatable, Sendable {
    public let opacityDuration: Double
    public let scaleDuration: Double
    public let liveMotionScale: CGFloat

    public init(style: ViewerMediaTransitionStyle = .standard) {
        self.opacityDuration = style.opacityDuration
        self.scaleDuration = style.scaleDuration
        self.liveMotionScale = style.liveMotionScale
    }

    public var liveMotionTransform: CGAffineTransform {
        CGAffineTransform(scaleX: liveMotionScale, y: liveMotionScale)
    }
}
#endif
