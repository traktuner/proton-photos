import SwiftUI
import AppKit

/// AppKit-backed zoomable image. `NSScrollView.allowsMagnification` gives us exactly the native
/// behaviour: pinch-to-zoom centred on the cursor and two-finger pan — smooth, no SwiftUI hacks.
/// A pinch-OUT while already at fit-scale flies the photo closed (live shrink + fade feedback).
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    /// True while the host's zoom overlay is rendering the live dismiss: hide THIS image so it doesn't double the
    /// overlay's photo, but keep the scroll view itself hit-testable (alpha 1) so the pinch keeps delivering here.
    var isDismissing: Bool = false
    // Interactive pinch-out-to-dismiss: the gesture only REPORTS progress (1 = fullscreen, 0 = collapsed into the
    // grid cell). The actual shrink-into-the-cell + grid fade is rendered by the shared zoom overlay in the host, so
    // the photo flies into its EXACT cell (not a local layer shrink toward a corner).
    var onPinchDismissBegan: () -> Void = {}
    var onPinchDismissChanged: (CGFloat) -> Void = { _ in }
    var onPinchDismissEnded: (Bool) -> Void = { _ in }
    /// Force-click (trackpad deep press) over the photo — used to play a Live Photo's motion clip.
    var onForceClick: () -> Void = {}

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ZoomScrollView()
        scrollView.onPinchDismissBegan = onPinchDismissBegan
        scrollView.onPinchDismissChanged = onPinchDismissChanged
        scrollView.onPinchDismissEnded = onPinchDismissEnded
        scrollView.onForceClick = onForceClick
        scrollView.pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryDeepClick)
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
        if let z = scrollView as? ZoomScrollView {
            z.onPinchDismissBegan = onPinchDismissBegan
            z.onPinchDismissChanged = onPinchDismissChanged
            z.onPinchDismissEnded = onPinchDismissEnded
        }
        guard let imageView = context.coordinator.imageView else { return }
        imageView.alphaValue = isDismissing ? 0 : 1   // hide only the IMAGE; the scroll view stays hit-testable
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
    var onPinchDismissBegan: () -> Void = {}
    var onPinchDismissChanged: (CGFloat) -> Void = { _ in }
    var onPinchDismissEnded: (Bool) -> Void = { _ in }
    var onForceClick: () -> Void = {}

    private var dismissing = false
    private var dismissProgress: CGFloat = 0    // 0 = full size, grows as the user pinches out
    private var forceClickFired = false         // one trigger per deep-press (reset when pressure relaxes)

    /// Trackpad deep press (the firm click after the soft click): stage ≥ 2 = a force click. Fires once per press.
    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        if event.stage >= 2, !forceClickFired {
            forceClickFired = true
            onForceClick()
        } else if event.stage < 2 {
            forceClickFired = false
        }
    }

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
        // This view does NOT animate itself — it just REPORTS progress. The host renders the live shrink into the
        // EXACT grid cell + the grid fade behind, via the shared zoom overlay (the gesture keeps being delivered
        // here while the host renders the viewer invisible).
        switch event.phase {
        case .began:
            dismissing = true
            dismissProgress = 0
            onPinchDismissBegan()
        case .changed:
            dismissProgress = max(0, dismissProgress - event.magnification)   // outward pinch = negative
            onPinchDismissChanged(max(0, min(1, 1 - dismissProgress)))        // 1 = fullscreen, 0 = the grid cell
        case .ended, .cancelled:
            // A small/quick pinch is enough to fly it home (low threshold).
            let shouldClose = event.phase == .ended && dismissProgress > 0.07
            dismissing = false
            onPinchDismissEnded(shouldClose)
        default:
            break
        }
    }
}
