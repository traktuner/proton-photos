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
    /// The level the live pinch settled on — so the SwiftUI `level` binding stays in sync after a commit.
    var onZoomCommit: ((Int) -> Void)?

    private var streamingTick: CADisplayLink?
    /// The grid is laid out oldest→top-left, newest→bottom-right, so it opens pinned to the BOTTOM
    /// (newest) and re-pins on resize/level until the user scrolls away.
    private var stickToBottom = true

    /// The viewport size at the previous `layout()` — used to detect a window/sidebar resize and rebase the
    /// scroll so the SAME logical region stays visible (instead of reusing the raw scrollY after slotSide
    /// changes). `.zero` until the first layout.
    /// The grid viewport's frame in SCREEN coords (y-up) at the previous `layout()` — lets the engine detect
    /// WHICH edge moved (window resize or sidebar) so the stationary edge holds the anchor and the moving edge
    /// clips/reveals. `.zero` until the first layout with a window.
    private var lastViewportScreenFrame: NSRect = .zero

    // Live focus-row pinch gesture state (engine-owned GridZoomTransaction).
    private var pinchActive = false
    private var pinchBaseLevel = 0
    private var pinchCumulativeMagnification: CGFloat = 0
    /// Time of the last trackpad magnify event — arms a brief scroll-suppression grace window so the residual
    /// finger drift after a pinch (esp. pushing past the largest stage) can't leak into a wild scroll.
    private var lastMagnifyEventTime: CFTimeInterval = 0
    /// SCROLL LOCK: the scroll origin to hold while a pinch (or its grace) is active. Even if a scrollWheel
    /// leaks past both interception points (macOS responsive-scrolling / gesture disambiguation at the
    /// extreme levels), `scrolled()` snaps the position straight back to this — so the grid CANNOT drift
    /// during a zoom. nil = not locked.
    private var scrollLockOrigin: CGPoint?
    /// Post-release commit-bridge timing (the geometry-only transaction→settled settle). Driven by the tick.
    private var bridgeStart: CFTimeInterval = 0
    private let bridgeDuration: CFTimeInterval = GridZoomCommitBridge.duration

    init?(device: MTLDevice, dataSource: MetalGridDataSource, budget: MetalGridBudget = .default) {
        guard let coordinator = MetalGridCoordinator(device: device, dataSource: dataSource, budget: budget) else { return nil }
        self.coordinator = coordinator
        self.metalView = MetalGridView(frame: .zero, device: device)
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.backgroundColor = MetalGridPalette.background.cgColor   // uniform Apple-like dark surface
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
        // Uncovered pixels clear to the grid background (the inter-cell gap + letterbox colour), so a transient
        // coverage gap during a zoom transition is never a black flash.
        metalView.clearColor = MetalGridPalette.clearColor
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
            self.onHitTest?(self.coordinator.hitTest(contentPoint: point), point)
        }
        spacer.onMouseExited = { [weak self] in self?.onHitTest?(nil, .zero) }
        spacer.onClick = { [weak self] point, clickCount, modifiers in
            self?.onCellClick?(point, clickCount, modifiers)
        }
        spacer.onMagnify = { [weak self] event in self?.handleMagnify(event) }
        // Swallow scroll whenever a pinch could leak into one. Wired on BOTH the document spacer and the
        // scroll view itself (two interception points) so trackpad scroll/inertia that bypasses the spacer
        // is still caught. Blocks: the live pinch (`pinchActive` / the engine's live-zoom transaction), a
        // grace window after the last magnify OR the commit, and post-pinch MOMENTUM (the inertia that
        // keeps scrolling the committed grid wildly when you push past the largest/densest stage).
        let block: (NSEvent) -> Bool = { [weak self] event in
            guard let self else { return false }
            if pinchActive || coordinator.isZoomingLive || coordinator.isCommitBridging { return true }
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

    /// A manual WINDOW resize detaches the bottom-pin — EXACTLY like a scroll. Without this, resizing a
    /// freshly-opened grid (still `stickToBottom`) only ever bottom-pins and never runs the viewport-anchor
    /// camera rebase (the user's bug: fresh-open resize was wrong; one tiny scroll "fixed" it because that
    /// cleared `stickToBottom`). Fires only for USER-initiated live resizes (not the initial-open layout), so
    /// "open at newest" is preserved. Observer is (re)wired in `viewDidMoveToWindow`.
    @objc private func windowWillLiveResize() { stickToBottom = false }

    // MARK: - Live focus-row pinch zoom (engine-owned GridZoomTransaction)

    /// Magnification → continuous level position. Pinch OPEN (positive magnification) = zoom IN = lower level
    /// index. Smaller = more sensitive.
    private let magnificationPerLevel: CGFloat = 0.42

    /// A trackpad pinch drives an engine-owned `GridZoomTransaction`: the item under the cursor is the anchor,
    /// the focus row keeps its photos as the level position glides, and on release we snap to the nearest
    /// level (cursor re-anchored). NOT a per-frame stateless re-resolve — no focus-row rewrap.
    ///
    /// The transaction is SINGLE-SECTION only (see `GridZoomTransaction`). Production uses one physical layout
    /// section by design (the flattened photo wall), so the pinch drives the transaction normally. If a grid
    /// ever had multiple physical sections, `beginLiveZoom` would start no transaction and the pinch would stay
    /// inert here (zoom via the +/- controls instead) — a safety fallback, not a production path.
    private func handleMagnify(_ event: NSEvent) {
        switch event.phase {
        case .began:
            let cursorContent = cursorContentPoint(for: event)
            let viewportPoint = CGPoint(x: cursorContent.x, y: cursorContent.y - scrollView.contentView.bounds.origin.y)
            coordinator.beginLiveZoom(cursorContentPoint: cursorContent, viewportPoint: viewportPoint)
            guard coordinator.isZoomingLive else { return }   // no transaction (non-single-section) → inert pinch
            stickToBottom = false
            pinchActive = true
            pinchBaseLevel = coordinator.level
            pinchCumulativeMagnification = 0
            scrollLockOrigin = scrollView.contentView.bounds.origin   // freeze scroll for the gesture
            lastMagnifyEventTime = CACurrentMediaTime()               // arm the post-pinch scroll grace
        case .changed, .mayBegin:
            guard pinchActive else { return }
            lastMagnifyEventTime = CACurrentMediaTime()
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

    /// Commit the live zoom: rebase scroll from the anchor, then run a short geometry-only BRIDGE that slides
    /// the transaction-final frame to the settled frame (so the column-phase reflow is smooth, not a snap).
    private func finishLiveZoom(target: Int) {
        let clamped = max(0, min(target, coordinator.levelCount - 1))
        let newY = coordinator.beginCommitBridge(finalLevel: clamped)   // rebase + capture tx + set level + start bridge
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
        coordinator.setCommitBridgeScrollY(targetY)                 // the bridge settles toward the real scroll pos
        bridgeStart = CACurrentMediaTime()
        applyContentSize(content)
        if !stickToBottom, newY != nil {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if !coordinator.isCommitBridging { coordinator.logPostCommitAnchor() }   // instant commit: probe now (bridge logs at end)
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

    /// A button-driven level change. The discrete +/- path re-anchors scroll at the viewport centre (the
    /// live trackpad pinch is the continuous path, handled in `handleMagnify`).
    func animateToLevel(_ target: Int) {
        setLevel(target)
    }

    private func pinToBottom() {
        let maxY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// True while scroll must be frozen: the live pinch, the commit bridge, or a short grace after the magnify.
    private func isScrollBlocking() -> Bool {
        pinchActive || coordinator.isZoomingLive || coordinator.isCommitBridging
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
        // A manual window resize detaches the bottom-pin (so the camera rebase runs even on a fresh-open grid).
        NotificationCenter.default.removeObserver(self, name: NSWindow.willStartLiveResizeNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillLiveResize),
                                                   name: NSWindow.willStartLiveResizeNotification, object: window)
        }
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
        if coordinator.isCommitBridging { advanceCommitBridge() }
        if coordinator.hasPendingVisibleThumbnails { metalView.needsDisplay = true }
    }

    /// Advance the post-release commit bridge (geometry settle). When it completes, end it → normal settled
    /// rendering. Scroll stays locked throughout (the bridge is shorter than the post-magnify grace window).
    private func advanceCommitBridge() {
        let t = bridgeDuration > 0 ? min(1, (CACurrentMediaTime() - bridgeStart) / bridgeDuration) : 1
        coordinator.commitBridgeProgress = CGFloat(t)
        metalView.needsDisplay = true
        if t >= 1 { coordinator.endCommitBridge(); metalView.needsDisplay = true }
    }

    override func layout() {
        super.layout()
        metalView.frame = bounds
        let newFrame = viewportScreenFrame()
        let old = lastViewportScreenFrame
        if old != .zero, abs(old.width - newFrame.width) > 0.5 || abs(old.height - newFrame.height) > 0.5 {
            rebaseForResize(oldFrame: old, newFrame: newFrame)  // window resize / sidebar toggle — NOT zoom
        } else {
            applyContentSize(coordinator.contentSize())         // first layout / move-only (no size change)
        }
        lastViewportScreenFrame = newFrame
    }

    /// The grid viewport's frame in SCREEN coords (y-up): `maxY` = top edge, `minY` = bottom edge. The engine
    /// compares old↔new to tell which edge moved. Falls back to local bounds before the view has a window.
    private func viewportScreenFrame() -> NSRect {
        guard let window else { return bounds }
        return window.convertToScreen(convert(bounds, to: nil))
    }

    /// Viewport resized (window or sidebar). Recompute content size from the new width and rebase the scroll
    /// via the engine so the SAME logical region stays visible — the stationary edge holds the anchor, the
    /// moving edge clips/reveals. Never reuse the raw scrollY after slotSide changed, never start a zoom, never
    /// restore an old origin. Bottom-pinned stays pinned.
    private func rebaseForResize(oldFrame: NSRect, newFrame: NSRect) {
        let oldScrollY = scrollView.contentView.bounds.origin.y
        let result = coordinator.rebaseForViewportChange(oldFrame: oldFrame, newFrame: newFrame,
                                                         oldScrollY: oldScrollY, wasBottomPinned: stickToBottom)
        applyContentSize(coordinator.contentSize())            // new content height (new width); pins bottom if sticky
        guard !stickToBottom, let r = result else { return }   // sticky → already bottom-pinned by applyContentSize
        let maxY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        let y = min(max(0, r.newScrollY), maxY)
        scrollLockOrigin = nil                                 // a resize must NOT restore a pre-resize origin
        if abs(y - oldScrollY) > 0.5 {                         // skip a no-op scroll (e.g. top-anchored width change)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        metalView.needsDisplay = true                          // first frame after resize uses the rebased scrollY
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
        // +/- anchors at the GRID VIEWPORT CENTRE (never the toolbar-button mouse point, a stale hover, or the
        // top). The pinch path supplies an explicit cursor point instead.
        let anchorPoint = anchorContentPoint ?? CGPoint(x: bounds.width / 2, y: origin.y + vh / 2)
        let viewportPoint = CGPoint(x: anchorPoint.x, y: anchorPoint.y - origin.y)
        let trigger: GridZoomTrigger = newLevel < coordinator.level ? .toolbarPlus : .toolbarMinus   // plus = zoom in
        // Latches the committed column phase so the settled grid keeps the anchor's column (no fly).
        let newY = coordinator.settleScrollOffsetY(toLevel: newLevel, anchorContentPoint: anchorPoint, viewportPoint: viewportPoint, trigger: trigger)
        applyContentSize(coordinator.contentSize())
        if let newY {
            let maxY = max(0, spacer.frame.height - vh)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, newY), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        coordinator.logPostCommitAnchor()
        metalView.needsDisplay = true
    }

    /// A photo's cell frame in WINDOW content coordinates (top-left origin), or nil if it isn't visible —
    /// used by the shared-element zoom transition (window-coordinate frame of a visible cell).
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

    /// Scroll to the newest (bottom) and re-arm the bottom pin. Resets the camera to the canonical bottom-right
    /// phase so the newest view always has the newest item in the corner (no trailing black at the bottom-right).
    func scrollToBottom() {
        stickToBottom = true
        coordinator.resetCommittedPhase()
        applyContentSize(coordinator.contentSize())   // resize for the canonical phase, then pin to bottom
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
