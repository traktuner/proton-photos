import SwiftUI
import AppKit

/// AppKit-backed zoomable image. `NSScrollView.allowsMagnification` gives us exactly the native
/// behaviour: pinch-to-zoom centred on the cursor and two-finger pan — smooth, no SwiftUI hacks.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ZoomScrollView()
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

/// Keeps the document view filling the viewport while at 1× (so the image fits, centred), and
/// lets `NSScrollView` grow/scroll it when magnified.
private final class ZoomScrollView: NSScrollView {
    override func layout() {
        super.layout()
        if abs(magnification - 1) < 0.001 {
            documentView?.frame = bounds
        }
    }
}
