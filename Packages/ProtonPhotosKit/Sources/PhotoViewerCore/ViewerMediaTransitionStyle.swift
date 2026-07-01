import CoreGraphics
import Foundation

/// One source of truth for viewer media transition timing and scale policy.
///
/// Core owns only portable values. Platform UI adapters turn those values into native animation types.
public struct ViewerMediaTransitionStyle: Equatable, Sendable {
    public var opacityDuration: Double
    public var scaleDuration: Double
    public var liveMotionScale: CGFloat

    public init(opacityDuration: Double, scaleDuration: Double, liveMotionScale: CGFloat) {
        self.opacityDuration = opacityDuration
        self.scaleDuration = scaleDuration
        self.liveMotionScale = liveMotionScale
    }

    public static let standard = ViewerMediaTransitionStyle(
        opacityDuration: 0.18,
        scaleDuration: 0.30,
        liveMotionScale: 1.04
    )
}
