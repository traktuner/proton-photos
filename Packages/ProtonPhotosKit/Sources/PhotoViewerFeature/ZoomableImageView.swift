import SwiftUI
import AppKit

/// AppKit-backed zoomable image. `NSScrollView.allowsMagnification` gives us exactly the native
/// behaviour: pinch-to-zoom centred on the cursor and two-finger pan — smooth, no SwiftUI hacks.
/// A pinch-OUT while already at fit-scale flies the photo closed (live shrink + fade feedback).
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    var onPinchClose: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ZoomScrollView()
        scrollView.onPinchClose = onPinchClose
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 1
        scrollView.maxMagnification = 10
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.contentView.drawsBackground = false

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.image = image
        scrollView.documentView = imageView

        context.coordinator.imageView = imageView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        (scrollView as? ZoomScrollView)?.onPinchClose = onPinchClose
        guard let imageView = context.coordinator.imageView else { return }
        if imageView.image !== image {
            imageView.image = image
            scrollView.magnification = 1     // reset zoom when the photo changes
            imageView.frame = scrollView.bounds
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var imageView: NSImageView?
    }
}

/// Keeps the document view filling the viewport while at 1× (so the image fits, centred), lets
/// `NSScrollView` grow/scroll it when magnified, and turns a pinch-out at fit-scale into a
/// "fly closed" dismiss.
private final class ZoomScrollView: NSScrollView {
    var onPinchClose: () -> Void = {}

    private var dismissing = false
    private var dismissProgress: CGFloat = 0    // 0 = full size, grows as the user pinches out

    override func layout() {
        super.layout()
        if abs(magnification - 1) < 0.001, !dismissing {
            documentView?.frame = bounds
        }
    }

    override func magnify(with event: NSEvent) {
        let atBase = magnification <= minMagnification + 0.001
        // Intercept only a pinch-OUT that starts at fit-scale — otherwise let the scroll view zoom.
        guard atBase, dismissing || event.magnification < 0 else {
            super.magnify(with: event)
            return
        }
        switch event.phase {
        case .began:
            dismissing = true
            dismissProgress = 0
            wantsLayer = true
        case .changed:
            dismissProgress = max(0, dismissProgress - event.magnification)   // outward pinch = negative
            let scale = max(0.4, 1 - dismissProgress)
            layer?.transform = CATransform3DMakeScale(scale, scale, 1)
            alphaValue = max(0.25, scale)
        case .ended, .cancelled:
            let shouldClose = dismissProgress > 0.18
            dismissing = false
            if shouldClose {
                onPinchClose()
            } else {
                // Snap back smoothly if the pinch wasn't decisive.
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.22
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    ctx.allowsImplicitAnimation = true
                    layer?.transform = CATransform3DIdentity
                    animator().alphaValue = 1
                }
            }
        default:
            break
        }
    }
}
