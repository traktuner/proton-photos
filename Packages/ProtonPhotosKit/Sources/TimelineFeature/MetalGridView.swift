import AppKit
import MetalKit

/// The viewport-sized `MTKView` that draws the visible grid. It sits BEHIND a fully transparent
/// `NSScrollView` (see `MetalGridScrollHost`), so the scroll view owns all physics while this view just
/// renders. It never participates in hit testing (events flow to the scroll view in front of it).
final class MetalGridView: MTKView {
    override var isOpaque: Bool { true }   // draws its own opaque clear-color background
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var acceptsFirstResponder: Bool { false }
}

/// The scroll view's `documentView`: a transparent, flipped spacer sized to the full content height. It
/// provides the scrollable area (drives scrollbars / inertia / rubber-band) and, being the top-most view
/// inside the clip, is where pointer events land — so it forwards mouse moves/clicks for the debug
/// crosshair + hit-test logging while letting `scrollWheel` bubble to the enclosing scroll view for
/// native scrolling.
final class MetalGridDocumentSpacer: NSView {
    /// Reports the pointer location in CONTENT coordinates (this view's own coordinate space).
    var onMouseMoved: ((CGPoint) -> Void)?
    var onMouseExited: (() -> Void)?
    /// Reports a click in CONTENT coordinates with its click count + modifier keys.
    var onClick: ((CGPoint, Int, GridClickModifiers) -> Void)?
    /// Raw trackpad magnify events (for discrete pinch-to-zoom that mirrors the +/- buttons).
    var onMagnify: ((NSEvent) -> Void)?
    /// While this returns true (a pinch / its settle is in flight) scrollWheel events are SWALLOWED instead
    /// of bubbling to the enclosing scroll view — so a pinch whose fingers also drift doesn't fire a wild
    /// concurrent scroll. (A still-fingered pinch never produced the pan; this makes the moving one behave.)
    var shouldBlockScroll: (() -> Bool)?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) { /* transparent — the Metal view behind shows through */ }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) {
        onMouseMoved?(convert(event.locationInWindow, from: nil))
    }
    override func mouseExited(with event: NSEvent) { onMouseExited?() }
    override func mouseDown(with event: NSEvent) {
        onClick?(convert(event.locationInWindow, from: nil), event.clickCount, MetalGridInteractionController.modifiers(from: event))
        // Do not call super for selection; let scrollWheel/drag still bubble normally for other events.
    }
    override func magnify(with event: NSEvent) {
        onMagnify?(event)
        // Owned by the discrete zoom; do NOT forward to super (no NSScrollView live magnification).
    }
    override func scrollWheel(with event: NSEvent) {
        if shouldBlockScroll?() == true { return }   // pinch in flight → swallow the concurrent pan
        super.scrollWheel(with: event)               // otherwise bubble to the enclosing scroll view
    }
}
