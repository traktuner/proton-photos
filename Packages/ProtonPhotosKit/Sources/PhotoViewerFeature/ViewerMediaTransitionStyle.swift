import SwiftUI

/// One source of truth for viewer media transitions.
///
/// Used for both Live Photo still↔motion blending and still-image quality upgrades
/// (thumbnail/preview → full original), so future tuning changes happen in one place.
struct ViewerMediaTransitionStyle {
    var opacityDuration: Double
    var scaleDuration: Double
    var liveMotionScale: CGFloat

    static let standard = ViewerMediaTransitionStyle(
        opacityDuration: 0.18,
        scaleDuration: 0.30,
        liveMotionScale: 1.04
    )

    var opacityAnimation: Animation { .easeInOut(duration: opacityDuration) }
    var scaleAnimation: Animation { .easeInOut(duration: scaleDuration) }
}
