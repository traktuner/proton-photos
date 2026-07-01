import PhotoViewerCore
import SwiftUI

extension ViewerMediaTransitionStyle {
    var opacityAnimation: Animation { .easeInOut(duration: opacityDuration) }
    var scaleAnimation: Animation { .easeInOut(duration: scaleDuration) }
}
