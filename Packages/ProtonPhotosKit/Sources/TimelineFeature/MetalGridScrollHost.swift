import AppKit
import MetalKit
import PhotosCore

/// Option-A scroll architecture: a native `NSScrollView` owns scroll physics (scrollbars, trackpad
/// inertia, rubber-band, keyboard paging) over a transparent, content-sized document spacer; a
/// viewport-sized `MetalGridView` sits BEHIND the transparent scroll view and draws only the visible
/// items each frame from the scroll origin. No custom scroll physics, no fake scrolling.
///
///   ┌ MetalGridScrollHost (this view) ────────────────┐
///   │  MetalGridView (MTKView)   ← back, viewport-sized│   draws visible viewport
///   │  NSScrollView (transparent)← front               │   owns physics
///   │    └ NSClipView (transparent)                     │
///   │        └ MetalGridDocumentSpacer (contentSize)    │   scrollable area + pointer events
///   └──────────────────────────────────────────────────┘
final class MetalGridScrollHost: NSView {
    let coordinator: MetalGridCoordinator
    private let metalView: MetalGridView
    private let scrollView = MetalGridBlockingScrollView()
    private let spacer = MetalGridDocumentSpacer()

    var onHUD: ((MetalGridHUD) -> Void)? {
        didSet { coordinator.onHUD = onHUD }
    }
    /// Reports the UID (or nil) under the pointer + the content point — for the debug crosshair/log.
    var onHitTest: ((PhotoUID?, CGPoint) -> Void)?
    /// Production click routing (content point, click count, modifiers). Lab leaves it nil.
    var onCellClick: ((CGPoint, Int, GridClickModifiers) -> Void)?
    /// Fired on any viewport change (scroll / resize / level) so overlays (month labels, a11y) reposition.
    var onViewportChanged: (() -> Void)?
    /// One discrete zoom step from a trackpad pinch (mirrors the +/- buttons). LEGACY path only.
    var onZoomStep: ((GridZoomDirection) -> Void)?
    /// The detent the continuous pinch / button transition settled on — so the SwiftUI `level` binding
    /// stays in sync. (Detent-zoom path only.)
    var onZoomCommit: ((Int) -> Void)?

    private var streamingTick: CADisplayLink?
    /// The grid is laid out oldest→top-left, newest→bottom-right, so it opens pinned to the BOTTOM
    /// (newest) and re-pins on resize/level until the user scrolls away.
    private var stickToBottom = true
    private var pinchDetector = PinchStepDetector()
    private var lastPinchStepTime: CFTimeInterval = 0

    // Continuous detent-zoom gesture state (used only when coordinator.usesDetentZoom).
    private var lastMouseContentPoint: CGPoint?
    private var pinchActive = false
    private var pinchBaseLevel = 0
    private var pinchCumulativeMagnification: CGFloat = 0
    private var pinchLastPosition: CGFloat = 0
    private var pinchLastTime: CFTimeInterval = 0
    private var pinchVelocity: CGFloat = 0   // levels/sec
    /// Time of the last trackpad magnify event — arms a brief scroll-suppression grace window so the residual
    /// finger drift after a pinch (esp. pushing past the largest stage) can't leak into a wild scroll.
    private var lastMagnifyEventTime: CFTimeInterval = 0
    /// SCROLL LOCK: the scroll origin to hold while a pinch (or its grace) is active. Even if a scrollWheel
    /// leaks past both interception points (macOS responsive-scrolling / gesture disambiguation at the
    /// extreme detents), `scrolled()` snaps the position straight back to this — so the grid CANNOT drift
    /// during a zoom. nil = not locked.
    private var scrollLockOrigin: CGPoint?
    // Post-release (or button) settle animation.
    private var settleActive = false
    private var settleFrom: CGFloat = 0
    private var settleTo: CGFloat = 0
    private var settleTarget: Int?
    private var settleStart: CFTimeInterval = 0
    private var settleCrossfadeStart: Float = 0   // the zoom-out fade value the settle continues from
    private var settleDuration: CFTimeInterval = 0.22

    init?(device: MTLDevice, dataSource: MetalGridDataSource, budget: MetalGridBudget = .default) {
        guard let coordinator = MetalGridCoordinator(device: device, dataSource: dataSource, budget: budget) else { return nil }
        self.coordinator = coordinator
        self.metalView = MetalGridView(frame: .zero, device: device)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.backgroundColor = NSColor(red: 0.043, green: 0.039, blue: 0.035, alpha: 1).cgColor
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        // Metal view (back): ON-DEMAND rendering. It redraws only when `needsDisplay` is set — on scroll
        // (the clip-bounds observer below) and while thumbnails are still streaming (the display-link
        // tick) — and is fully idle otherwise, so it never burns the main thread competing with the app.
        metalView.frame = bounds
        metalView.autoresizingMask = [.width, .height]
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        // Uncovered pixels clear to the grid background (matches the inter-cell gap colour), so a transient
        // coverage gap during a zoom transition is never a black flash.
        metalView.clearColor = MTLClearColor(red: 0.043, green: 0.039, blue: 0.035, alpha: 1)
        metalView.delegate = coordinator
        addSubview(metalView)

        // Scroll view (front): fully transparent so the Metal view shows through.
        scrollView.frame = bounds
        scrollView.autoresizingMask = [.width, .height]
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        spacer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        scrollView.documentView = spacer
        addSubview(scrollView, positioned: .above, relativeTo: metalView)

        coordinator.clipView = scrollView.contentView
        coordinator.metalView = metalView
        coordinator.onContentSizeChange = { [weak self] size in self?.applyContentSize(size) }

        spacer.onMouseMoved = { [weak self] point in
            guard let self else { return }
            self.lastMouseContentPoint = point
            self.onHitTest?(self.coordinator.hitTest(contentPoint: point), point)
        }
        spacer.onMouseExited = { [weak self] in self?.onHitTest?(nil, .zero) }
        spacer.onClick = { [weak self] point, clickCount, modifiers in
            self?.onCellClick?(point, clickCount, modifiers)
        }
        spacer.onMagnify = { [weak self] event in self?.handleMagnify(event) }
        // Swallow scroll whenever a pinch could leak into one. Wired on BOTH the document spacer and the
        // scroll view itself (two interception points) so trackpad scroll/inertia that bypasses the spacer
        // is still caught. Blocks: the live pinch + its settle (`pinchActive`/`settleActive`/`zoomSession`),
        // a grace window after the last magnify OR the commit, and post-pinch MOMENTUM (the inertia that
        // keeps scrolling the committed grid wildly when you push past the largest/densest stage).
        let block: (NSEvent) -> Bool = { [weak self] event in
            guard let self else { return false }
            if pinchActive || settleActive || coordinator.isZoomingLive { return true }
            let sinceMagnify = CACurrentMediaTime() - lastMagnifyEventTime
            if sinceMagnify < 0.6 { return true }                               // grace after a pinch/commit
            return event.momentumPhase != [] && sinceMagnify < 1.5             // post-pinch inertia
        }
        spacer.shouldBlockScroll = block
        scrollView.shouldBlockScroll = block

        // Redraw on EVERY scroll (incl. momentum / rubber-band) — the scroll itself paces the renderer.
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        // A user-initiated live scroll detaches the "stick to bottom" pin.
        NotificationCenter.default.addObserver(
            self, selector: #selector(userWillScroll),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView
        )
    }

    @objc private func userWillScroll() { stickToBottom = false }

    // MARK: - Live focus-row pinch zoom (engine-owned GridZoomTransaction)

    /// Magnification → continuous level position. Pinch OPEN (positive magnification) = zoom IN = lower level
    /// index. Smaller = more sensitive.
    private let magnificationPerLevel: CGFloat = 0.42

    /// A trackpad pinch drives an engine-owned `GridZoomTransaction`: the item under the cursor is the anchor,
    /// the focus row keeps its photos as the level position glides, and on release we snap to the nearest
    /// detent (cursor re-anchored). NOT a per-frame stateless re-resolve — no focus-row rewrap.
    private func handleMagnify(_ event: NSEvent) {
        lastMagnifyEventTime = CACurrentMediaTime()   // arms the post-pinch scroll grace window
        switch event.phase {
        case .began:
            cancelSettle()
            stickToBottom = false
            pinchActive = true
            pinchBaseLevel = coordinator.level
            pinchCumulativeMagnification = 0
            scrollLockOrigin = scrollView.contentView.bounds.origin   // freeze scroll for the gesture
            let cursorContent = cursorContentPoint(for: event)
            let viewportPoint = CGPoint(x: cursorContent.x, y: cursorContent.y - scrollView.contentView.bounds.origin.y)
            coordinator.beginLiveZoom(cursorContentPoint: cursorContent, viewportPoint: viewportPoint)
        case .changed, .mayBegin:
            guard pinchActive else { return }
            pinchCumulativeMagnification += event.magnification
            let pos = CGFloat(pinchBaseLevel) - pinchCumulativeMagnification / magnificationPerLevel
            coordinator.updateLiveZoom(continuousLevel: pos)
            metalView.needsDisplay = true
        case .ended:
            guard pinchActive else { return }
            pinchActive = false
            finishLiveZoom(target: Int(coordinator.liveZoomLevel.rounded()))
        case .cancelled:
            guard pinchActive else { return }
            pinchActive = false
            finishLiveZoom(target: pinchBaseLevel)
        default:
            break
        }
    }

    /// Commit the live zoom to a settled detent and re-anchor scroll so the cursor item stays put.
    private func finishLiveZoom(target: Int) {
        let clamped = max(0, min(target, coordinator.levelCount - 1))
        let newY = coordinator.liveZoomCommitScrollOffsetY(finalLevel: clamped)   // reads tx, latches view anchor
        coordinator.commitLiveZoom(finalLevel: clamped)                           // clears tx, sets level
        let clipH = scrollView.contentView.bounds.height
        let content = coordinator.contentSize()
        let targetY = (!stickToBottom && newY != nil)
            ? min(max(0, newY!), max(0, content.height - clipH))
            : scrollView.contentView.bounds.origin.y
        // CRITICAL: set the scroll lock to the COMMITTED position BEFORE any scroll/resize. The post-magnify
        // grace window keeps `scrolled()` snapping the clip back to `scrollLockOrigin`; if that still held the
        // PRE-zoom origin, it would instantly undo the commit scroll → the grid jumps to a different position.
        lastMagnifyEventTime = CACurrentMediaTime()
        scrollLockOrigin = CGPoint(x: 0, y: targetY)
        applyContentSize(content)
        if !stickToBottom, newY != nil {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        metalView.needsDisplay = true
        onZoomCommit?(coordinator.level)                            // sync the SwiftUI level binding
    }

    /// The cursor's CURRENT content-space point from a gesture event (fresh — never the stale last
    /// mouse-moved position), clamped into the current viewport so a centroid just outside still anchors
    /// sensibly (falls back to the viewport centre).
    private func cursorContentPoint(for event: NSEvent) -> CGPoint {
        let p = spacer.convert(event.locationInWindow, from: nil)
        let origin = scrollView.contentView.bounds.origin
        let vh = scrollView.contentView.bounds.height
        if p.y >= origin.y, p.y <= origin.y + vh, p.x >= 0, p.x <= bounds.width { return p }
        return CGPoint(x: bounds.width / 2, y: origin.y + vh / 2)
    }

    // MARK: - Continuous detent pinch (Apple-matched)

    /// A trackpad pinch glides the continuous level position between detents; release snaps to the nearest
    /// (velocity-biased) and settles. The grid renders the two-surface transition the whole time.
    private func handleContinuousMagnify(_ event: NSEvent) {
        switch event.phase {
        case .began:
            cancelSettle()
            coordinator.isZoomSettling = false   // live drag → clean opaque scale, no ghost
            stickToBottom = false
            pinchActive = true
            pinchBaseLevel = coordinator.level
            pinchCumulativeMagnification = 0
            pinchLastPosition = CGFloat(coordinator.level)
            pinchLastTime = CACurrentMediaTime()
            pinchVelocity = 0
            scrollLockOrigin = scrollView.contentView.bounds.origin   // freeze scroll for the whole gesture
            coordinator.beginZoomTransition(anchorContentPoint: anchorContentForGestureStart())
        case .changed, .mayBegin:
            guard pinchActive else { return }
            pinchCumulativeMagnification += event.magnification
            let raw = coordinator.detentModel.rawLevelPosition(source: pinchBaseLevel, cumulativeMagnification: pinchCumulativeMagnification)
            let pos = coordinator.detentModel.rubberBanded(raw)   // soft over-travel past the ends
            let now = CACurrentMediaTime()
            let dt = now - pinchLastTime
            if dt > 0.001 {
                let v = (pos - pinchLastPosition) / CGFloat(dt)
                pinchVelocity = pinchVelocity * 0.6 + v * 0.4   // smoothed levels/sec
                pinchLastTime = now
                pinchLastPosition = pos
            }
            coordinator.updateZoomTransition(levelPosition: pos)
            metalView.needsDisplay = true
        case .ended:
            guard pinchActive else { return }
            pinchActive = false
            let finalLevel = coordinator.snapLevel(velocity: pinchVelocity)
            beginSettle(toLevel: finalLevel)
        case .cancelled:
            guard pinchActive else { return }
            pinchActive = false
            beginSettle(toLevel: pinchBaseLevel)
        default:
            break
        }
    }

    /// Content point under the cursor at gesture start, or the viewport centre if the pointer is unknown or
    /// STALE. `lastMouseContentPoint` is only refreshed on mouse-moved, so after a scroll it can hold an
    /// off-screen content point from the previous scroll position — anchoring to that makes the zoom jump to
    /// an unrelated part of the timeline. Trust it only when it lies inside the CURRENT viewport.
    private func anchorContentForGestureStart() -> CGPoint {
        let origin = scrollView.contentView.bounds.origin
        let vh = scrollView.contentView.bounds.height
        let center = CGPoint(x: bounds.width / 2, y: origin.y + vh / 2)
        guard let p = lastMouseContentPoint,
              p.y >= origin.y, p.y <= origin.y + vh, p.x >= 0, p.x <= bounds.width else { return center }
        return p
    }

    /// Animate the continuous level position onto an integer detent, then commit + re-anchor scroll.
    private func beginSettle(toLevel target: Int) {
        let from = coordinator.activeLevelPosition ?? CGFloat(coordinator.level)
        if abs(from - CGFloat(target)) < 0.001 {
            finishSettle(target: target)
            return
        }
        settleActive = true
        coordinator.isZoomSettling = true        // release → cross-dissolve the reflow, briefly
        coordinator.settleTargetLevel = target
        // CONTINUE the overlay fade from where the drag left it (no reset/flicker), then ramp it to 1 so the
        // denser grid finishes fading in. A plain zoom-in re-align has lastZoomFade == 0 → starts at 0.
        settleCrossfadeStart = coordinator.lastZoomFadeValue
        coordinator.settleCrossfade = CGFloat(settleCrossfadeStart)
        settleFrom = from
        settleTo = CGFloat(target)
        settleTarget = target
        settleStart = CACurrentMediaTime()
        streamingTick?.isPaused = false
        metalView.needsDisplay = true
    }

    private func advanceSettle(now: CFTimeInterval) {
        guard settleActive, let target = settleTarget else { return }
        let t = settleDuration > 0 ? min(1, (now - settleStart) / settleDuration) : 1
        let e = 1 - pow(1 - t, 3)   // easeOutCubic
        let pos = settleFrom + (settleTo - settleFrom) * CGFloat(e)
        let start = CGFloat(settleCrossfadeStart)
        coordinator.settleCrossfade = start + (1 - start) * CGFloat(e)  // continue the fade → 1
        coordinator.updateZoomTransition(levelPosition: pos)
        metalView.needsDisplay = true
        if t >= 1 { finishSettle(target: target) }
    }

    private func finishSettle(target: Int) {
        settleActive = false
        coordinator.isZoomSettling = false
        settleTarget = nil
        lastMagnifyEventTime = CACurrentMediaTime()   // re-arm the scroll grace from the commit moment
        let originY = coordinator.scrollOriginAfterCommit(finalLevel: target)
        coordinator.commitZoomTransition(finalLevel: target)
        applyContentSize(coordinator.contentSize())
        if !stickToBottom, let originY {
            let maxY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
            let y = min(max(0, originY), maxY)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        scrollLockOrigin = scrollView.contentView.bounds.origin   // re-lock to the committed origin for the grace
        metalView.needsDisplay = true
        onZoomCommit?(target)
    }

    private func cancelSettle() {
        settleActive = false
        settleTarget = nil
    }

    /// Animate a button-driven level change as a transition (anchored at the viewport centre).
    func animateToLevel(_ target: Int) {
        guard coordinator.usesDetentZoom else { setLevel(target); return }
        let clamped = min(max(target, 0), coordinator.detentModel.count - 1)
        if coordinator.zoomSession == nil && coordinator.level == clamped { return }
        if pinchActive { return }                       // a live pinch owns the gesture
        if settleActive && settleTarget == clamped { return }
        cancelSettle()
        if coordinator.zoomSession == nil {
            let origin = scrollView.contentView.bounds.origin
            coordinator.beginZoomTransition(anchorContentPoint: CGPoint(x: bounds.width / 2, y: origin.y + bounds.height / 2))
        }
        beginSettle(toLevel: clamped)
    }

    private func pinToBottom() {
        let maxY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// True while scroll must be frozen: the live pinch, its settle, or a short grace after the last magnify.
    private func isScrollBlocking() -> Bool {
        pinchActive || settleActive || coordinator.isZoomingLive
            || CACurrentMediaTime() - lastMagnifyEventTime < 0.6
    }

    @objc private func scrolled() {
        // SCROLL LOCK backstop: if anything scrolled the grid during a zoom (a leaked scrollWheel / inertia),
        // snap it straight back to the frozen origin so the grid can't drift. Once the zoom is fully done,
        // release the lock and scroll normally.
        if isScrollBlocking(), let locked = scrollLockOrigin {
            let cur = scrollView.contentView.bounds.origin
            if abs(cur.x - locked.x) > 0.5 || abs(cur.y - locked.y) > 0.5 {
                scrollView.contentView.scroll(to: locked)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        } else {
            scrollLockOrigin = nil
        }
        metalView.needsDisplay = true
        onViewportChanged?()
    }

    // The display link only TRIGGERS redraws while thumbnails are streaming in; when the visible set is
    // fully loaded and not scrolling, no draws happen at all. It's invalidated when the view leaves its
    // window (CADisplayLink retains its target, so this also breaks that retain before dealloc).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            if streamingTick == nil {
                let dl = displayLink(target: self, selector: #selector(step))
                dl.add(to: .main, forMode: .common)
                streamingTick = dl
            }
            streamingTick?.isPaused = false
            metalView.needsDisplay = true
        } else {
            streamingTick?.invalidate()
            streamingTick = nil
        }
    }

    @objc private func step() {
        if settleActive { advanceSettle(now: CACurrentMediaTime()) }
        if coordinator.hasPendingVisibleThumbnails { metalView.needsDisplay = true }
    }

    override func layout() {
        super.layout()
        metalView.frame = bounds
        applyContentSize(coordinator.contentSize())
    }

    /// Set the document spacer to the current content height (width tracks the clip, no h-scroll).
    private func applyContentSize(_ size: CGSize) {
        let width = scrollView.contentView.bounds.width
        guard width > 1, size.height > 0 else { return }
        let newFrame = NSRect(x: 0, y: 0, width: width, height: size.height)
        if spacer.frame != newFrame { spacer.frame = newFrame }
        if stickToBottom { pinToBottom() }   // open at / stay at newest (bottom) until the user scrolls
        metalView.needsDisplay = true
        onViewportChanged?()
    }

    // MARK: - Public controls

    /// Change zoom level, holding an EXPLICIT anchor point under the same viewport position (zoom directed
    /// toward that point — the Apple rule). `anchorContentPoint` is the cursor's content point for a trackpad
    /// pinch; for +/- it's nil → the viewport centre is used. NEVER the top-visible item. Pinned-to-bottom
    /// (newest) stays pinned.
    func setLevel(_ newLevel: Int, anchorContentPoint: CGPoint? = nil) {
        guard newLevel != coordinator.level else { return }
        let vh = scrollView.contentView.bounds.height
        if stickToBottom {
            coordinator.level = newLevel
            applyContentSize(coordinator.contentSize())   // pins to bottom (newest)
            metalView.needsDisplay = true
            return
        }
        let origin = scrollView.contentView.bounds.origin
        // Explicit cursor point (pinch) else the viewport centre — an explicit viewport point, not the top.
        let anchorPoint = anchorContentPoint ?? CGPoint(x: bounds.width / 2, y: origin.y + vh / 2)
        let viewportPoint = CGPoint(x: anchorPoint.x, y: anchorPoint.y - origin.y)
        // Latches the view anchor / column phase so the settled grid keeps the focus item's column (seamless).
        let newY = coordinator.settleScrollOffsetY(toLevel: newLevel, anchorContentPoint: anchorPoint, viewportPoint: viewportPoint)
        applyContentSize(coordinator.contentSize())
        if let newY {
            let maxY = max(0, spacer.frame.height - vh)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, newY), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        metalView.needsDisplay = true
    }

    /// A photo's cell frame in WINDOW content coordinates (top-left origin), or nil if it isn't visible —
    /// used by the shared-element zoom transition (matches `PhotoGridView`'s `windowFrame(for:)`).
    func windowFrame(forUID uid: PhotoUID) -> CGRect? {
        guard let win = window, let contentRect = coordinator.cellContentRect(forUID: uid) else { return nil }
        let origin = scrollView.contentView.bounds.origin
        let vp = CGRect(x: contentRect.minX - origin.x, y: contentRect.minY - origin.y, width: contentRect.width, height: contentRect.height)
        guard CGRect(origin: .zero, size: metalView.bounds.size).intersects(vp) else { return nil }
        // The metal view is not flipped (y-up); our viewport rect is top-left origin (y-down).
        let localYUp = CGRect(x: vp.minX, y: metalView.bounds.height - vp.maxY, width: vp.width, height: vp.height)
        let inWindow = metalView.convert(localYUp, to: nil)            // window coords, bottom-left origin
        let contentH = win.contentView?.bounds.height ?? win.frame.height
        return CGRect(x: inWindow.minX, y: contentH - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    func setDataSource(_ source: MetalGridDataSource) {
        coordinator.setDataSource(source)
        applyContentSize(coordinator.contentSize())   // pins to bottom when sticky (newest first)
    }

    func scrollToTop() {
        stickToBottom = false
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Scroll to the newest (bottom) and re-arm the bottom pin.
    func scrollToBottom() {
        stickToBottom = true
        pinToBottom()
    }

    /// Scroll a specific photo to vertical center (detaches the bottom pin — the user navigated to it).
    func scrollToItem(_ uid: PhotoUID) {
        stickToBottom = false
        guard let rect = coordinator.cellContentRect(forUID: uid) else { return }
        let clipH = scrollView.contentView.bounds.height
        let maxY = max(0, spacer.frame.height - clipH)
        let targetY = min(max(0, rect.midY - clipH / 2), maxY)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        metalView.needsDisplay = true
    }
}
