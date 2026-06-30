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
/// inside the clip, is where pointer events land — so it forwards clicks + magnify while letting
/// `scrollWheel` bubble to the enclosing scroll view for native scrolling.
final class MetalGridDocumentSpacer: NSView {
    /// Reports a click in CONTENT coordinates with its click count + modifier keys.
    var onClick: ((CGPoint, Int, GridClickModifiers) -> Void)?
    /// Raw trackpad magnify events (for the continuous live-pinch lattice scrub; see `handleMagnify`).
    var onMagnify: ((NSEvent) -> Void)?
    /// While this returns true (a pinch / its settle / post-pinch grace is in flight) scrollWheel events are
    /// SWALLOWED instead of bubbling to the enclosing scroll view — so a pinch whose fingers also drift can't
    /// fire a wild concurrent scroll. Takes the event so momentum/inertia after a pinch can be caught too.
    var shouldBlockScroll: ((NSEvent) -> Bool)?

    /// Marquee (drag-rectangle) selection. A press that DRAGS past the threshold draws a selection rectangle
    /// (CONTENT-space rect reported live); a press that never drags falls through to `onClick` on mouse-UP, so
    /// single / double / ⇧-click selection is preserved unchanged. `onMarqueeBegan` carries the mouse-down
    /// modifiers (⇧ = add to the existing selection).
    var onMarqueeBegan: ((GridClickModifiers) -> Void)?
    var onMarqueeChanged: ((CGRect) -> Void)?
    var onMarqueeEnded: (() -> Void)?

    private var mouseDownPoint: CGPoint?
    private var mouseDownClickCount = 0
    private var mouseDownModifiers: GridClickModifiers = []
    private var isMarqueeing = false
    private static let marqueeThreshold: CGFloat = 4   // px of drag before a press becomes a marquee (jitter-tolerant)

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) { /* transparent — the Metal view behind shows through */ }

    override func mouseDown(with event: NSEvent) {
        // Defer the click DECISION to mouse-up: a press that turns into a drag becomes a marquee, not a click.
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        mouseDownClickCount = event.clickCount
        mouseDownModifiers = MetalGridInteractionController.modifiers(from: event)
        isMarqueeing = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !isMarqueeing {
            guard hypot(p.x - start.x, p.y - start.y) >= Self.marqueeThreshold else { return }
            isMarqueeing = true
            onMarqueeBegan?(mouseDownModifiers)
        }
        onMarqueeChanged?(CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                                 width: abs(p.x - start.x), height: abs(p.y - start.y)))
    }
    override func mouseUp(with event: NSEvent) {
        if isMarqueeing {
            onMarqueeEnded?()
        } else if let start = mouseDownPoint {
            onClick?(start, mouseDownClickCount, mouseDownModifiers)   // never dragged → it was a click after all
        }
        mouseDownPoint = nil
        isMarqueeing = false
    }
    override func magnify(with event: NSEvent) {
        onMagnify?(event)
        // Owned by the discrete zoom; do NOT forward to super (no NSScrollView live magnification).
    }
    override func scrollWheel(with event: NSEvent) {
        if shouldBlockScroll?(event) == true { return }   // pinch in flight → swallow the concurrent pan
        super.scrollWheel(with: event)                    // otherwise bubble to the enclosing scroll view
    }
}

/// The translucent drag-rectangle drawn over the grid during a marquee selection. A passive overlay: it never
/// hit-tests (events pass straight through to the spacer that drives the drag) and is hidden when idle.
final class MetalGridMarqueeView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 0.5, dy: 0.5)
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        r.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: r); path.lineWidth = 1; path.stroke()
    }
}

/// The enclosing `NSScrollView`, subclassed so it ALSO swallows `scrollWheel` during a pinch / its grace —
/// a second interception point behind the document spacer. Trackpad scroll/inertia that bypasses the spacer
/// (or arrives as post-gesture momentum) is the actual thing that scrolls the grid, so blocking it here is
/// the reliable backstop against the "wild scroll while pinching at the extreme detents" bug.
final class MetalGridBlockingScrollView: NSScrollView {
    var shouldBlockScroll: ((NSEvent) -> Bool)?
    override func scrollWheel(with event: NSEvent) {
        if shouldBlockScroll?(event) == true { return }
        super.scrollWheel(with: event)
    }
}
