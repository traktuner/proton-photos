import SwiftUI
import AppKit

/// AppKit-backed zoomable image. `NSScrollView.allowsMagnification` gives us exactly the native
/// behaviour: pinch-to-zoom centred on the cursor and two-finger pan - smooth, no SwiftUI hacks.
/// A pinch-OUT while already at fit-scale flies the photo closed (live shrink + fade feedback).
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    /// Stable identity of the photo being shown. Image changes for the same identity are quality upgrades
    /// (thumbnail/preview → original); identity changes are navigation and must not crossfade old/new photos.
    var itemIdentity: String? = nil
    /// True once the full original is displayed. A false→true transition for the same `itemIdentity` gets the
    /// shared viewer media reveal, instead of the old hard swap.
    var isSharp: Bool = false
    var transitionStyle: ViewerMediaTransitionStyle = .standard
    /// True while the host's zoom overlay is rendering the live dismiss: hide this image so it doesn't double the
    /// overlay's photo, but keep the scroll view itself hit-testable (alpha 1) so the pinch keeps delivering here.
    var isDismissing: Bool = false
    // Interactive pinch-out-to-dismiss: the gesture only reports progress (1 = fullscreen, 0 = collapsed into the
    // grid cell). The actual shrink-into-the-cell + grid fade is rendered by the shared zoom overlay in the host, so
    // the photo flies into its exact cell (not a local layer shrink toward a corner).
    var onPinchDismissBegan: () -> Void = {}
    var onPinchDismissChanged: (CGFloat) -> Void = { _ in }
    var onPinchDismissEnded: (Bool) -> Void = { _ in }
    /// Force-click (trackpad deep press) over the photo - starts a Live Photo's motion clip.
    var onForceClick: () -> Void = {}
    /// The force-click was released (finger lifted) - stops the motion clip, crossfading back to the still.
    var onForceClickEnded: () -> Void = {}
    /// Reports the DISPLAYED photo rect (aspect-fit area, magnification/pan-transformed) in the view's
    /// top-left-origin coordinate space whenever layout/zoom/pan changes it. Lets the host glue overlays
    /// (Live Photo motion layer) to the PHOTO instead of the viewer.
    var onPhotoFrameChanged: ((CGRect) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ZoomScrollView()
        scrollView.onPinchDismissBegan = onPinchDismissBegan
        scrollView.onPinchDismissChanged = onPinchDismissChanged
        scrollView.onPinchDismissEnded = onPinchDismissEnded
        scrollView.onForceClick = onForceClick
        scrollView.onForceClickEnded = onForceClickEnded
        scrollView.onPhotoFrameChanged = onPhotoFrameChanged
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
        context.coordinator.itemIdentity = itemIdentity
        context.coordinator.isSharp = isSharp
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        if let z = scrollView as? ZoomScrollView {
            z.onPinchDismissBegan = onPinchDismissBegan
            z.onPinchDismissChanged = onPinchDismissChanged
            z.onPinchDismissEnded = onPinchDismissEnded
            z.onForceClick = onForceClick
            z.onForceClickEnded = onForceClickEnded
            z.onPhotoFrameChanged = onPhotoFrameChanged
            // Initial/refresh report, async: we're inside a SwiftUI view update and the callback writes @State.
            DispatchQueue.main.async { [weak z] in z?.reportPhotoFrame() }
        }
        guard let imageView = context.coordinator.imageView else { return }
        imageView.alphaValue = isDismissing ? 0 : 1   // hide only the IMAGE; the scroll view stays hit-testable
        if imageView.image !== image {
            let sameItem = context.coordinator.itemIdentity == itemIdentity
            let revealsOriginal = sameItem && !context.coordinator.isSharp && isSharp && !isDismissing
            if revealsOriginal {
                imageView.crossfadeToImage(image, style: transitionStyle)
            } else {
                imageView.image = image
            }
            // Reset zoom ONLY on photo NAVIGATION. A same-item image swap is a QUALITY UPGRADE
            // (thumbnail → preview → original) — resetting here yanked the user's zoom/pan back to fit
            // the moment the sharp original arrived. Same aspect ratio, same geometry: keeping
            // magnification untouched makes the upgrade invisible except for the added sharpness.
            if !sameItem {
                scrollView.magnification = 1
                imageView.frame = scrollView.bounds
            }
        }
        context.coordinator.itemIdentity = itemIdentity
        context.coordinator.isSharp = isSharp
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        weak var imageView: NSImageView?
        var itemIdentity: String?
        var isSharp = false
    }
}

private extension NSImageView {
    static let revealOverlayIdentifier = NSUserInterfaceItemIdentifier("PhotoViewerHighResolutionRevealOverlay")

    /// Crossfades a same-photo quality upgrade without rebuilding the scroll view, preserving the viewer's
    /// native pinch/pan surface and keeping the transition tuning shared with the Live Photo motion blend.
    func crossfadeToImage(_ newImage: NSImage, style: ViewerMediaTransitionStyle) {
        guard let oldImage = image else {
            image = newImage
            return
        }

        subviews
            .filter { $0.identifier == Self.revealOverlayIdentifier }
            .forEach { $0.removeFromSuperview() }

        let outgoing = NSImageView(frame: bounds)
        outgoing.identifier = Self.revealOverlayIdentifier
        outgoing.imageScaling = imageScaling
        outgoing.imageAlignment = imageAlignment
        outgoing.image = oldImage
        outgoing.alphaValue = 1
        outgoing.autoresizingMask = [.width, .height]

        image = newImage
        addSubview(outgoing)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = style.opacityDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            outgoing.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in outgoing.removeFromSuperview() }
        }
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
    var onForceClickEnded: () -> Void = {}
    var onPhotoFrameChanged: ((CGRect) -> Void)?
    /// Last reported photo rect — reports are de-duplicated so a steady frame never spams SwiftUI state.
    private var lastReportedPhotoFrame: CGRect = .null

    private var dismissing = false
    private var dismissProgress: CGFloat = 0    // 0 = full size, grows as the user pinches out
    private var forceClickFired = false         // true between deep-press and release (drives hold-to-play)

    /// The displayed photo rect: the aspect-FIT area of the image inside the (magnified) document view,
    /// converted to this view's space and normalised to a TOP-LEFT origin (the SwiftUI overlay space).
    func reportPhotoFrame() {
        guard let onPhotoFrameChanged,
              let dv = documentView as? NSImageView, let img = dv.image,
              img.size.width > 0, img.size.height > 0, bounds.height > 0 else { return }
        let ib = dv.bounds
        let scale = min(ib.width / img.size.width, ib.height / img.size.height)
        let w = img.size.width * scale
        let h = img.size.height * scale
        let fitted = CGRect(x: ib.midX - w / 2, y: ib.midY - h / 2, width: w, height: h)
        var rect = dv.convert(fitted, to: self)
        if !isFlipped { rect.origin.y = bounds.height - rect.maxY }
        if abs(rect.minX - lastReportedPhotoFrame.minX) < 0.5,
           abs(rect.minY - lastReportedPhotoFrame.minY) < 0.5,
           abs(rect.width - lastReportedPhotoFrame.width) < 0.5,
           abs(rect.height - lastReportedPhotoFrame.height) < 0.5 { return }
        lastReportedPhotoFrame = rect
        onPhotoFrameChanged(rect)
    }

    /// Called by AppKit on every scroll AND magnification change of the clip view — the one central hook
    /// that sees all pan/zoom updates.
    override func reflectScrolledClipView(_ cView: NSClipView) {
        super.reflectScrolledClipView(cView)
        reportPhotoFrame()
    }

    /// Trackpad deep press = hold-to-play: stage ≥ 2 starts the motion; releasing the finger (pressure relaxes
    /// below stage 2) stops it. The trackpad streams decreasing-stage events as the finger lifts, so this is the
    /// reliable release signal - no `mouseUp` override needed.
    override func pressureChange(with event: NSEvent) {
        super.pressureChange(with: event)
        if event.stage >= 2 {
            if !forceClickFired {
                forceClickFired = true
                onForceClick()                  // deep press → play
            }
        } else if forceClickFired {
            forceClickFired = false
            onForceClickEnded()                 // released → stop
        }
    }

    override func layout() {
        super.layout()
        if abs(magnification - 1) < 0.001, !dismissing {
            documentView?.frame = bounds
        }
        reportPhotoFrame()
    }

    override func magnify(with event: NSEvent) {
        let atBase = magnification <= minMagnification + 0.001
        // Intercept only a pinch-OUT that starts at fit-scale - otherwise let the scroll view zoom.
        guard atBase, dismissing || event.magnification < 0 else {
            super.magnify(with: event)
            return
        }
        // This view does not animate itself; it only reports progress. The host renders the live shrink into the
        // exact grid cell plus the grid fade behind, via the shared zoom overlay (the gesture keeps being delivered
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
