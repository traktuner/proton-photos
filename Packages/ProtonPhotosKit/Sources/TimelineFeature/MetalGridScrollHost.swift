import AppKit
import MetalKit
import PhotosCore
import GridCore
import MetalGridTextureAppKitAdapter
import TimelineCore

/// The one-shot viewport policy a data-source / route switch hands the host, consumed by the host's
/// layout/content-size path only after layout geometry is valid - never as an immediate scroll from SwiftUI.
///   - `.preserve`: keep the current scroll position (the default for incremental data updates).
///   - `.newest`: place the viewport at the newest (bottom) end exactly once (a route's first visit / launch).
///   - `.restore(anchor)`: re-pin a remembered photo anchor (returning to a previously-visited route so it
///     reopens exactly where the user left it).
/// In every case, after the one-shot placement the user scrolls freely (no sticky pinning, no pullback).
enum GridInitialViewport: Equatable {
    case preserve
    case newest
    case restore(GridScrollAnchor<PhotoUID>)
}

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
    /// Production click routing (content point, click count, modifiers).
    var onCellClick: ((CGPoint, Int, GridClickModifiers) -> Void)?
    /// Marquee (drag-rectangle) selection routing. `onMarqueeChanged` carries the rect in LAYOUT (engine) space
    /// - the host already removes the leading-obstruction inset, exactly like `onCellClick`.
    var onMarqueeBegan: ((GridClickModifiers) -> Void)?
    var onMarqueeChanged: ((CGRect) -> Void)?
    var onMarqueeEnded: (() -> Void)?
    /// The translucent selection rectangle drawn over the grid during a marquee drag (a passive overlay on the
    /// scroll document, so it scrolls with the content it's selecting).
    private let marqueeView = MetalGridMarqueeView()
    /// Fired on any viewport change (scroll / resize / level) so overlays (month labels, a11y) reposition.
    var onViewportChanged: (() -> Void)?
    /// The level the live pinch settled on - so the SwiftUI `level` binding stays in sync after a commit.
    var onZoomCommit: ((Int) -> Void)?

    /// The pre-commit level whose lingering SwiftUI `@Binding level` echo must be ignored after a host-led
    /// commit. A pinch advances `coordinator.level` to the settled level and pushes it to the binding; until
    /// SwiftUI propagates that write, an `updateNSView` pass driven by some OTHER coincident parent-state change
    /// can deliver the stale pre-commit value and (via the legacy reconciliation) re-issue a viewport-centre
    /// zoom - jumping a different photo under the cursor. Armed at the commit sites only when the level actually
    /// changed; consumed/cleared by `reconcileLevelBinding`. nil = no host-led commit awaiting binding sync.
    /// See `LevelBindingReconciler`.
    private var pendingLevelEcho: Int?
    private var gridProfileResolver: TimelineGridProfileResolver?
    private var pendingResolvedGridProfile: GridLevelProfile?

    /// The leading obstruction inset (points) for the native floating sidebar. ONE value drives three things:
    /// (1) event hit-testing is declined for `x < eventLeadingInset` (those events reach the sidebar); (2) input
    /// content/viewport points are converted render→layout by subtracting it before any engine/coordinator API;
    /// (3) it is mirrored to `coordinator.leadingObstructionInset`, which insets the engine LAYOUT width and
    /// translates every rendered rect `+inset` back into render space. The detail MTKView still renders FULL
    /// width (photos draw under the sidebar and animate behind it during pinch); only the SETTLED layout is
    /// inset. 0 when the sidebar is hidden ⇒ plain full-width grid (identity).
    var eventLeadingInset: CGFloat = 0 {
        didSet { applyLeadingInsetChange(from: oldValue) }
    }

    /// The window's translucent toolbar height, plumbed from `MainView`. Mirrored to the coordinator/engine so the
    /// first row rests below the toolbar (the engine's `contentHeight` grows by it). Re-lays content unless a
    /// resize/sidebar/zoom presentation is mid-flight (those re-apply content size on their own settle). Set once
    /// at open and effectively constant thereafter, so a plain relayout is enough - no anchor gymnastics.
    var topBarInset: CGFloat = 0 {
        didSet {
            guard abs(topBarInset - oldValue) > 0.5 else { return }
            coordinator.topBarInset = topBarInset
            guard !coordinator.presentationResizeActive, !coordinator.isSidebarResizing,
                  !coordinator.isZoomingLive, !coordinator.isCommitBridging, !coordinator.isResizeSettling else { return }
            applyContentSize(coordinator.contentSize())
        }
    }
    /// Extra leading breathing room between the sidebar and the grid for the NORMAL levels (L0–L3) only; the
    /// dense square overviews (L4–L5) go edge-to-edge. The coordinator applies it only when a sidebar is present.
    static let normalLevelLeadingGap: CGFloat = 16

    private var streamingTick: CADisplayLink?
    private var displayLinkWakeUntil: CFTimeInterval = 0
    private let displayLinkIdleGrace: CFTimeInterval = 0.25
    /// The grid is laid out oldest→top-left, newest→bottom-right, so it opens pinned to the BOTTOM
    /// (newest) and re-pins on resize/level until the user scrolls away.
    private var stickToBottom = true

    /// One-shot initial-viewport policy installed by a route / data-source switch. While `.newest`, the next
    /// `applyContentSize` that runs with VALID layout geometry (in a window, content width + height + clip
    /// height all valid) places the viewport at the newest end exactly once, then clears the policy back to
    /// `.preserve` and leaves `stickToBottom == false` so the user scrolls freely. If geometry isn't valid yet
    /// (e.g. the host was just recreated and not laid out), the policy STAYS pending - it is never consumed
    /// early, and host recreation can't swallow it. NOT an immediate scroll from SwiftUI.
    private var pendingInitialViewport: GridInitialViewport = .preserve

    /// The viewport size at the previous `layout()` - used to detect a window/sidebar resize and rebase the
    /// scroll so the SAME logical region stays visible (instead of reusing the raw scrollY after slotSide
    /// changes). `.zero` until the first layout.
    /// The grid viewport's frame in SCREEN coords (y-up) at the previous `layout()` - lets the engine detect
    /// WHICH edge moved (window resize or sidebar) so the stationary edge holds the anchor and the moving edge
    /// clips/reveals. `.zero` until the first layout with a window.
    private var lastViewportScreenFrame: NSRect = .zero

    /// The viewport screen frame captured at the START of the current live WINDOW resize - used for the single
    /// settle rebase on `didEndLiveResize`. `.zero` outside a live resize.
    private var liveResizeStartFrame: NSRect = .zero
    /// Release-settle (detent-crossing reflow) clock: the tiles fly from the scaled frame to the settled layout.
    private var resizeSettleStart: CFTimeInterval = 0
    private let resizeSettleDuration: CFTimeInterval = 0.22
    /// Sidebar open/close scale clock: the grid scales (right-anchored) over the sidebar slide, then settles.
    private var sidebarResizeStart: CFTimeInterval = 0
    private let sidebarResizeDuration: CFTimeInterval = 0.3

    // Live focus-row pinch gesture state (engine-owned GridZoomTransaction).
    private var pinchActive = false
    private var pinchBaseLevel = 0
    private var pinchCumulativeMagnification: CGFloat = 0

    // V3.9 CONTINUOUS MULTI-LEVEL LIVE-PINCH SCRUB DRIVER (single-presentation-lattice). When the first
    // resolved direction is an eligible in-band step, the pinch scrubs the V3.7 plan CONTINUOUSLY across
    // detents via this pure driver (rebuilding the segment plan as the finger crosses each detent -
    // seam-continuous); otherwise it falls back to the legacy `GridZoomTransaction` reflow.
    private var pinchDriver = PinchLiveZoomDriver()
    /// Per-gesture routing: undecided until the first direction resolves, then lattice (in-band chain) or reflow.
    // `.overviewDissolve` (overview boundary L3↔L4 / L4↔L5): a two-layer offscreen cross-dissolve. NOT chained
    // and NOT driven by the V3.9 `pinchDriver`; q maps straight from the pinch magnitude, release runs a short
    // linear settle to the nearer endpoint. The accepted `.lattice` (normal L0–L3) path is untouched.
    private enum PinchMode { case undecided, lattice, reflow, overviewDissolve }
    private var pinchMode: PinchMode = .undecided
    private var pinchSettling = false                  // fingers up, the velocity-aware settle ramp is running
    private var pinchBuiltSegment: (Int, Int)?         // the adjacent segment currently built into the plan
    private var pinchChainBand: (lo: Int, hi: Int) = (0, 0)  // eligible chaining band, captured at gesture start
    private var pinchPrevMagnifyTime: CFTimeInterval = 0  // wall-clock of the previous magnify sample (driver dt)
    private var pinchAdvancePrevTime: CFTimeInterval = 0  // wall-clock of the previous settle tick (driver dt)
    // Overview-dissolve gesture state (mode == .overviewDissolve).
    private var pinchOverviewSource = 0
    private var pinchOverviewTarget = 0
    private var pinchOverviewQ: Double = 0
    private var pinchOverviewSettleFrom: Double = 0
    private var pinchOverviewSettleTo: Double = 0
    private var pinchOverviewSettleStart: CFTimeInterval = 0
    private let pinchOverviewSettleDuration: CFTimeInterval = 0.16
    // Reflow over-zoom spring-back (mode == .reflow, released from a rubber-band over-zoom past level 0): a
    // short ramp of the visual level back to 0 so it springs back elastically instead of hard-snapping.
    private var pinchReflowSettleFrom: CGFloat = 0
    private var pinchReflowSettleStart: CFTimeInterval = 0
    private let pinchReflowSettleDuration: CFTimeInterval = 0.18
    /// Time of the last trackpad magnify event - arms a brief scroll-suppression grace window so the residual
    /// finger drift after a pinch (esp. pushing past the largest stage) can't leak into a wild scroll.
    private var lastMagnifyEventTime: CFTimeInterval = 0
    /// SCROLL LOCK: the scroll origin to hold while a pinch (or its grace) is active. Even if a scrollWheel
    /// leaks past both interception points (macOS responsive-scrolling / gesture disambiguation at the
    /// extreme levels), `scrolled()` snaps the position straight back to this - so the grid CANNOT drift
    /// during a zoom. nil = not locked.
    private var scrollLockOrigin: CGPoint?
    /// Post-release commit-bridge timing (the geometry-only transaction→settled settle). Driven by the tick.
    private var bridgeStart: CFTimeInterval = 0
    private let bridgeDuration: CFTimeInterval = GridZoomCommitBridge.duration

    init?(device: MTLDevice, dataSource: MetalGridDataSource, budget: MetalGridBudget = .default,
          gridProfile: GridLevelProfile,
          gridProfileResolver: TimelineGridProfileResolver? = nil) {
        guard let coordinator = MetalGridCoordinator(device: device, dataSource: dataSource, budget: budget,
                                                     gridProfile: gridProfile,
                                                     memoryGovernor: .shared) else { return nil }
        self.coordinator = coordinator
        self.metalView = MetalGridView(frame: .zero, device: device)
        self.gridProfileResolver = gridProfileResolver
        super.init(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        wantsLayer = true
        layer?.backgroundColor = MetalGridPalette.background.cgColor   // uniform Apple-like dark surface
        installImageAvailabilityCallback(on: dataSource)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Decline events under the translucent sidebar so they reach it (the grid renders full-width but must not
    /// steal the sidebar's clicks/scroll). Hit-test only - coordinates for events to the RIGHT of the inset are
    /// unchanged, so click→photo routing and the pinch anchor stay correct.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if eventLeadingInset > 0 {
            if point.x < eventLeadingInset { return nil }
        }
        return super.hitTest(point)
    }

    private func setUp() {
        // Metal view (back): ON-DEMAND rendering. It redraws only when `needsDisplay` is set - on scroll
        // (the clip-bounds observer below) and while thumbnails are still streaming (the display-link
        // tick) - and is fully idle otherwise, so it never burns the main thread competing with the app.
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
        // Do NOT let the scroll view inset its content to the window safe area. Under the native NavigationSplitView
        // the leading safe-area inset is the floating sidebar width (e.g. 282); auto-adjustment pushed the clip to
        // `origin.x = -inset`, which then double-applied with the coordinator's render translation (a huge leading
        // gap on open that "fixed itself" after the first scroll/zoom recomputed the inset). The grid is a plain
        // full-area scroll: it owns its leading-obstruction inset (render translate) and top frost (overlay), so
        // the clip must stay at origin 0. Vertical/horizontal both - the grid never scrolls horizontally.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        spacer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height)
        scrollView.documentView = spacer
        addSubview(scrollView, positioned: .above, relativeTo: metalView)
        marqueeView.isHidden = true
        spacer.addSubview(marqueeView)   // drawn over the photos (the spacer is the front, transparent document)

        coordinator.clipView = scrollView.contentView
        coordinator.metalView = metalView
        coordinator.normalLevelLeadingGap = Self.normalLevelLeadingGap
        coordinator.onContentSizeChange = { [weak self] size in
            guard let self, !self.coordinator.presentationResizeActive, !self.coordinator.isSidebarResizing else { return }   // frozen during the H-resize / sidebar scale
            self.applyContentSize(size)
        }

        spacer.onClick = { [weak self] point, clickCount, modifiers in
            guard let self else { return }
            self.onCellClick?(CGPoint(x: point.x - self.coordinator.leadingObstructionInset, y: point.y), clickCount, modifiers)   // render → layout
        }
        spacer.onMarqueeBegan = { [weak self] mods in
            guard let self else { return }
            self.marqueeView.isHidden = false
            self.onMarqueeBegan?(mods)
        }
        spacer.onMarqueeChanged = { [weak self] rawRect in
            guard let self else { return }
            self.marqueeView.frame = rawRect                 // RAW spacer coords - where the user dragged on screen
            self.marqueeView.needsDisplay = true
            let inset = self.coordinator.leadingObstructionInset
            self.onMarqueeChanged?(rawRect.offsetBy(dx: -inset, dy: 0))   // render → layout (same shift as onCellClick)
        }
        spacer.onMarqueeEnded = { [weak self] in
            guard let self else { return }
            self.marqueeView.isHidden = true
            self.onMarqueeEnded?()
        }
        spacer.onMagnify = { [weak self] event in self?.handleMagnify(event) }
        // Swallow scroll whenever a pinch could leak into one. Wired on BOTH the document spacer and the
        // scroll view itself (two interception points) so trackpad scroll/inertia that bypasses the spacer
        // is still caught. Blocks: the live pinch (`pinchActive` / the engine's live-zoom transaction), a
        // grace window after the last magnify OR the commit, and post-pinch MOMENTUM (the inertia that
        // keeps scrolling the committed grid wildly when you push past the largest/densest stage).
        let block: (NSEvent) -> Bool = { [weak self] event in
            guard let self else { return false }
            if pinchActive || pinchSettling || coordinator.isZoomingLive || coordinator.isCommitBridging || coordinator.isResizeSettling || coordinator.isSidebarResizing { return true }
            let sinceMagnify = CACurrentMediaTime() - lastMagnifyEventTime
            if sinceMagnify < 0.6 { return true }                               // grace after a pinch/commit
            return event.momentumPhase != [] && sinceMagnify < 1.5             // post-pinch inertia
        }
        spacer.shouldBlockScroll = block
        scrollView.shouldBlockScroll = block

        // Redraw on EVERY scroll (incl. momentum / rubber-band) - the scroll itself paces the renderer.
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

    /// A manual WINDOW resize detaches the bottom-pin - EXACTLY like a scroll. Without this, resizing a
    /// freshly-opened grid (still `stickToBottom`) only ever bottom-pins and never runs the viewport-anchor
    /// camera rebase (the user's bug: fresh-open resize was wrong; one tiny scroll "fixed" it because that
    /// cleared `stickToBottom`). Fires only for USER-initiated live resizes (not the initial-open layout), so
    /// "open at newest" is preserved. Observer is (re)wired in `viewDidMoveToWindow`.
    @objc private func windowWillLiveResize() {
        stickToBottom = false
        // Live resize presentation: snapshot the stable grid surface ONCE so the per-tick `layout()` presents it
        // uniformly scaled/slid (no rubber-band, no per-frame engine resolve). The axis is resolved per tick in
        // `layout()` - a horizontal drag scales the snapshot, a vertical drag slides it (counter-scroll), a corner
        // composes both. If the presentation can't run (zoom/transition in flight, no window) the path falls back
        // to `rebaseForResize`.
        liveResizeStartFrame = viewportScreenFrame()
        guard coordinator.canPresentResize else { return }
        coordinator.beginPresentationResize()
        // NOTE: presentsWithTransaction is NOT used - it locks each present to the window transaction but its
        // `waitUntilScheduled` blocks ~80ms/present, throttling the whole resize to ~10fps. The per-tick synchronous
        // `metalView.draw()` in layout() keeps content updating every tick; the async present's ~1-frame offset is
        // imperceptible and FAR better than a 10fps chunky resize.
    }

    /// End of a live WINDOW resize: drop the presentation and SETTLE EXACTLY ONCE - resolve the real layout at the
    /// final size, rebase the scroll once (item-identity, so the same region stays put), redraw normally. If the
    /// gesture had already fallen back (vertical/corner), the presentation is inactive and the normal `layout()`
    /// path already settled it, so this is a no-op beyond clearing the sync-present flag.
    @objc private func windowDidEndLiveResize() {
        guard coordinator.presentationResizeActive else { applyResolvedGridProfileAfterLiveResizeFallback(); return }
        // SETTLE = NO snap. The settle scroll depends on the axis: a WIDTH/corner change scales the tiles (fixed
        // columns, no reflow), so the grid settles to the resize anchor - at the newest end the LAST row stays at the
        // viewport bottom, otherwise the centre item is re-centred (resolved ONCE here, not drifting per frame). A
        // pure VERTICAL change does NOT reflow, so it settles to the COUNTER-SCROLLED scroll the live frame slid to
        // (start scroll − the vertical slide) with no animation. No rebaseForResize (it re-anchored to the TOP).
        let widthChanged = abs(viewportScreenFrame().width - liveResizeStartFrame.width) > 0.5
        let finalScrollY = widthChanged
            ? coordinator.windowResizeReleaseScrollY()
            : coordinator.presentationStartScrollY - coordinator.presentationVerticalShift
        stickToBottom = false
        applyContentSize(coordinator.contentSize())
        let maxScrollY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        let settledY = min(max(0, finalScrollY), maxScrollY)
        // The detent fly-into-place only applies to a width reflow; a pure vertical resize settles instantly.
        let animating = widthChanged && coordinator.beginResizeSettle(targetScrollY: settledY)   // reads the snapshot (still active)
        coordinator.endPresentationResize()
        if abs(settledY - scrollView.contentView.bounds.origin.y) > 0.5 {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: settledY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if animating { resizeSettleStart = CACurrentMediaTime() }
        let finalFrame = viewportScreenFrame()
        let profileOldFrame = liveResizeStartFrame == .zero ? lastViewportScreenFrame : liveResizeStartFrame
        lastViewportScreenFrame = finalFrame
        liveResizeStartFrame = .zero
        _ = applyResolvedGridProfileIfNeeded(oldFrame: profileOldFrame, newFrame: finalFrame)
        requestFrame()
    }

    private func applyResolvedGridProfileAfterLiveResizeFallback() {
        let oldFrame = liveResizeStartFrame == .zero ? lastViewportScreenFrame : liveResizeStartFrame
        let newFrame = viewportScreenFrame()
        liveResizeStartFrame = .zero
        _ = applyResolvedGridProfileIfNeeded(oldFrame: oldFrame, newFrame: newFrame)
    }

    // MARK: - Live focus-row pinch zoom (engine-owned GridZoomTransaction)

    /// Magnification → continuous level position. Pinch OPEN (positive magnification) = zoom IN = lower level
    /// index. Smaller = more sensitive.
    private let magnificationPerLevel: CGFloat = 0.42

    /// A trackpad pinch drives an engine-owned `GridZoomTransaction`: the item under the cursor is the anchor,
    /// the focus row keeps its photos as the level position glides, and on release we snap to the nearest
    /// level (cursor re-anchored). NOT a per-frame stateless re-resolve - no focus-row rewrap.
    ///
    /// The transaction is SINGLE-SECTION only (see `GridZoomTransaction`). Production uses one physical layout
    /// section by design (the flattened photo wall), so the pinch drives the transaction normally. If a grid
    /// ever had multiple physical sections, `beginLiveZoom` would start no transaction and the pinch would stay
    /// inert here (zoom via the +/- controls instead) - a safety fallback, not a production path.
    private func handleMagnify(_ event: NSEvent) {
        switch event.phase {
        case .began:
            finishInFlightPinchSettle()   // a quick re-pinch must not strand the previous settle's (frozen) plan on screen
            finishInFlightGridPresentationForGestureStart()
            let cursorContent = cursorContentPoint(for: event)
            let viewportPoint = CGPoint(x: cursorContent.x, y: cursorContent.y - scrollView.contentView.bounds.origin.y)
            coordinator.beginLiveZoom(cursorContentPoint: cursorContent, viewportPoint: viewportPoint)   // keep the GridZoomTransaction anchor model
            guard coordinator.isZoomingLive else { return }   // no transaction (non-single-section) → inert pinch
            stickToBottom = false
            pinchActive = true
            pinchSettling = false
            pinchBaseLevel = coordinator.level
            pinchCumulativeMagnification = 0
            // V3.9 scrub driver: routing is decided on the first resolved direction (the eligible band is
            // captured now); the driver is begun then. Tuning mirrors the central surface.
            pinchMode = .undecided
            pinchBuiltSegment = nil
            pinchChainBand = coordinator.eligiblePinchChainBand()
            pinchDriver = PinchLiveZoomDriver(tuning: .init(from: coordinator.gridTransition.tuning))
            pinchPrevMagnifyTime = CACurrentMediaTime()
            scrollLockOrigin = scrollView.contentView.bounds.origin   // freeze scroll for the gesture
            lastMagnifyEventTime = CACurrentMediaTime()               // arm the post-pinch scroll grace
        case .changed, .mayBegin:
            guard pinchActive else { return }
            lastMagnifyEventTime = CACurrentMediaTime()
            pinchCumulativeMagnification += event.magnification
            let pos = CGFloat(pinchBaseLevel) - pinchCumulativeMagnification / magnificationPerLevel
            driveLivePinch(continuousLevel: pos)
            requestFrame()
        case .ended:
            guard pinchActive else { return }
            if event.magnification != 0 { pinchCumulativeMagnification += event.magnification }
            endLivePinch(cancelled: false)
        case .cancelled:
            guard pinchActive else { return }
            endLivePinch(cancelled: true)
        default:
            break
        }
    }

    /// Route a live pinch sample. On the FIRST resolved direction, decide the mode: an in-band adjacent step
    /// ⇒ LATTICE (continuous multi-level scrub of the V3.7 plan); otherwise ⇒ the legacy
    /// `GridZoomTransaction` reflow. Once decided, the mode holds for the gesture.
    private func driveLivePinch(continuousLevel pos: CGFloat) {
        let now = CACurrentMediaTime()
        let dt = pinchPrevMagnifyTime == 0 ? 1.0 / 60.0 : max(0, now - pinchPrevMagnifyTime)
        pinchPrevMagnifyTime = now
        switch pinchMode {
        case .reflow:
            coordinator.updateLiveZoom(continuousLevel: pos)
        case .overviewDissolve:
            driveOverviewDissolve(continuousLevel: pos)
        case .lattice:
                _ = applyLatticeSegment(pinchDriver.update(continuousLevel: Double(pos), dt: dt))
                if pinchMode == .reflow { coordinator.updateLiveZoom(continuousLevel: pos) }   // downgraded this frame ⇒ drive the reflow now
        case .undecided:
            let start = pinchBaseLevel
            guard abs(Double(pos) - Double(start)) >= pinchDriver.tuning.directionResolveQ else { return }  // pre-move: keep showing the start detent
            let dir = pos < CGFloat(start) ? -1 : 1
            let next = start + dir
            if next >= pinchChainBand.lo, next <= pinchChainBand.hi {
                pinchMode = .lattice                          // first eligible step is in-band ⇒ continuous chain
                pinchDriver.begin(startLevel: start, chainLo: pinchChainBand.lo, chainHi: pinchChainBand.hi)
                _ = applyLatticeSegment(pinchDriver.update(continuousLevel: Double(pos), dt: dt))
            } else if next >= 0, next < coordinator.levelCount, coordinator.engine.isOverviewBoundary(start, next),
                      coordinator.beginOverviewDissolve(sourceLevel: start, targetLevel: next, viewportSize: metalView.bounds.size) {
                pinchMode = .overviewDissolve                 // overview boundary ⇒ two-layer offscreen dissolve
                pinchOverviewSource = start
                pinchOverviewTarget = next
                driveOverviewDissolve(continuousLevel: pos)
            } else {
                pinchMode = .reflow                           // genuinely out-of-band ⇒ legacy reflow
                coordinator.updateLiveZoom(continuousLevel: pos)
            }
        }
    }

    /// Apply one lattice sample: (re)build the segment plan when the active interval changes (each detent
    /// crossing - seam-continuous), then scrub it to `segmentQ`.
    @discardableResult
    private func applyLatticeSegment(_ out: PinchLiveZoomDriver.Update) -> Bool {
        guard out.hasSegment else { return false }                  // pre-move rest dead-band ⇒ keep the start detent
        let seg = (out.segmentSource, out.segmentTarget)
        if pinchBuiltSegment == nil || pinchBuiltSegment! != seg {
            if coordinator.tryBuildPinchSegment(source: out.segmentSource, target: out.segmentTarget, viewportSize: metalView.bounds.size) {
                pinchBuiltSegment = seg
            } else {
                coordinator.abortPinchPlan()                  // tear down any active plan (no stranded frozen frame)
                pinchMode = .reflow; pinchBuiltSegment = nil  // ineligible (only outside the band) ⇒ reflow
                return false
            }
        }
        coordinator.setPinchProgress(out.segmentQ)
        return true
    }

    /// Fingers up. Lattice ⇒ hand to the velocity-aware settle (display-tick driven), which commits the active
    /// segment to its nearest detent on completion. Reflow ⇒ the existing snap-on-release commit.
    private func endLivePinch(cancelled: Bool) {
        pinchActive = false
        switch pinchMode {
        case .lattice:
            pinchDriver.release(cancelled: cancelled)
            pinchSettling = true
            pinchAdvancePrevTime = 0                          // fresh dt for the first settle tick
            lastMagnifyEventTime = CACurrentMediaTime()
            requestFrame()
        case .reflow:
            if coordinator.liveZoomLevel < 0 {
                // Rubber-band over-zoom past level 0 → spring the visual level back to 0 over a short ramp,
                // then commit at level 0 (seamless: at 0 the live frame equals the settled frame). No snap.
                pinchReflowSettleFrom = coordinator.liveZoomLevel
                pinchReflowSettleStart = CACurrentMediaTime()
                pinchSettling = true
                lastMagnifyEventTime = CACurrentMediaTime()
                requestFrame()
            } else {
                finishLiveZoom(target: cancelled ? pinchBaseLevel : Int(coordinator.liveZoomLevel.rounded()))
            }
        case .overviewDissolve:
            // Settle the dissolve to the nearer endpoint (q<0.5 → source, else target) over a short linear ramp.
            pinchOverviewSettleFrom = pinchOverviewQ
            pinchOverviewSettleTo = (!cancelled && pinchOverviewQ >= 0.5) ? 1.0 : 0.0
            pinchOverviewSettleStart = CACurrentMediaTime()
            pinchSettling = true
            lastMagnifyEventTime = CACurrentMediaTime()
            requestFrame()
        case .undecided:
            if !beginShortPinchStep(cancelled: cancelled) {
                finishLiveZoom(target: pinchBaseLevel)        // no directional input ⇒ commit at start (no change)
            }
        }
    }

    /// A very short directional pinch may never clear the live-scrub dead-band, but Apple Photos still treats it
    /// like a normal adjacent zoom command. Use the gesture direction to seed one segment and let it complete at
    /// the accepted click speed; no hard snap, and no need to lift/re-pinch.
    private func beginShortPinchStep(cancelled: Bool) -> Bool {
        guard !cancelled, abs(pinchCumulativeMagnification) > 1e-6 else { return false }
        let direction = pinchCumulativeMagnification > 0 ? -1 : 1   // positive magnification = pinch-in = lower level
        let next = pinchBaseLevel + direction
        guard next >= 0, next < coordinator.levelCount else { return false }

        if next >= pinchChainBand.lo, next <= pinchChainBand.hi {
            pinchMode = .lattice
            pinchDriver.begin(startLevel: pinchBaseLevel, chainLo: pinchChainBand.lo, chainHi: pinchChainBand.hi)
            let out = pinchDriver.releaseTowardAdjacent(direction: direction)
            guard applyLatticeSegment(out) else { return false }
            pinchSettling = true
            pinchAdvancePrevTime = 0
            lastMagnifyEventTime = CACurrentMediaTime()
            requestFrame()
            return true
        }

        if coordinator.engine.isOverviewBoundary(pinchBaseLevel, next),
           coordinator.beginOverviewDissolve(sourceLevel: pinchBaseLevel, targetLevel: next, viewportSize: metalView.bounds.size) {
            pinchMode = .overviewDissolve
            pinchOverviewSource = pinchBaseLevel
            pinchOverviewTarget = next
            pinchOverviewQ = 0
            coordinator.setOverviewDissolveProgress(0)
            pinchOverviewSettleFrom = 0
            pinchOverviewSettleTo = 1
            pinchOverviewSettleStart = CACurrentMediaTime()
            pinchSettling = true
            lastMagnifyEventTime = CACurrentMediaTime()
            requestFrame()
            return true
        }

        return false
    }

    /// If a previous lattice pinch is still running its post-release settle (the settle spans multiple display
    /// ticks - q=0.5→0 at the floor is ~280 ms), a new pinch's `.began` would otherwise leave that plan
    /// `isActive` with a frozen q: `draw(in:)` would keep rendering the stale crossfade frame. So force the
    /// in-flight settle to its terminal and commit it NOW - on whichever detent it had decided - before the
    /// new gesture starts clean.
    private func finishInFlightPinchSettle() {
        guard pinchSettling else { return }
        if pinchMode == .overviewDissolve { commitOverviewDissolve(); return }   // commit now, don't strand it
        if pinchMode == .reflow {                                                // over-zoom spring-back in flight
            pinchSettling = false; finishLiveZoom(target: 0); pinchMode = .undecided; return
        }
        pinchDriver.advance(dt: 10)                 // jump the velocity-aware ramp straight to its settle detent
        if pinchDriver.isCommitted { commitLivePinch() }
    }

    /// A new pinch must capture cursor/anchor/layout from one committed geometry state. Sidebar and bridge
    /// presentations are visual-only in-flight states; finish them before the next `GridZoomTransaction` begins.
    private func finishInFlightGridPresentationForGestureStart() {
        var didFinishPresentation = false
        if coordinator.isSidebarResizing {
            let (settleScroll, _) = coordinator.endSidebarResize()
            stickToBottom = false
            applyContentSize(coordinator.contentSize())
            let maxScrollY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
            let settledY = min(max(0, settleScroll), maxScrollY)
            if abs(settledY - scrollView.contentView.bounds.origin.y) > 0.5 {
                scrollView.contentView.scroll(to: CGPoint(x: 0, y: settledY))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
            didFinishPresentation = true
        }
        if coordinator.isResizeSettling {
            coordinator.endResizeSettle()
            didFinishPresentation = true
        }
        if coordinator.isCommitBridging {
            coordinator.endCommitBridge()
            didFinishPresentation = true
        }
        guard didFinishPresentation else { return }
        lastViewportScreenFrame = viewportScreenFrame()
        requestFrame()
    }

    /// Advance the post-release settle on the display tick; push the new segmentQ into the plan; commit the
    /// chain's final detent on a terminal state.
    private func advanceLivePinch() {
        let now = CACurrentMediaTime()
        let dt = pinchAdvancePrevTime == 0 ? 1.0 / 60.0 : max(0, now - pinchAdvancePrevTime)
        pinchAdvancePrevTime = now
        pinchDriver.advance(dt: dt)
        coordinator.setPinchProgress(pinchDriver.segmentQ)
        requestFrame()
        if pinchDriver.isCommitted { commitLivePinch() }
    }

    /// The settle reached a terminal state. Commit the chain to its final detent: apply that detent's anchored
    /// scroll (a no-op when it's the gesture-start detent). The settled frame matches the plan's final-detent
    /// endpoint exactly - no hard snap, no flash.
    private func commitLivePinch() {
        pinchSettling = false
        let previousLevel = coordinator.level
        let anchoredY = coordinator.commitPinchChain(toLevel: pinchDriver.finalLevel, viewportSize: metalView.bounds.size)
        let clipH = scrollView.contentView.bounds.height
        let content = coordinator.contentSize()
        let committedY = min(max(0, anchoredY), max(0, content.height - clipH))
        lastMagnifyEventTime = CACurrentMediaTime()           // arm the post-commit scroll grace
        scrollLockOrigin = CGPoint(x: 0, y: committedY)
        applyContentSize(content)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: committedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // Edge/corner clamp: if the anchored scroll was out of bounds, slide there instead of snapping.
        coordinator.beginScrollRebase(fromY: anchoredY, toY: committedY)
        coordinator.logPostCommitAnchor()
        pinchMode = .undecided
        pinchBuiltSegment = nil
        pinchAdvancePrevTime = 0
        pinchDriver.reset()
        commitLevelToBinding(previousLevel: previousLevel)    // sync the SwiftUI level binding (+ arm echo guard)
        requestFrame()
    }

    /// Advance the reflow over-zoom spring-back: ramp the live VISUAL level from the released over-zoom value
    /// back to 0 (smoothstep), then commit at level 0. The grid elastically returns to the largest detent with
    /// no hard snap; the commit at 0 is seamless because there the live frame equals the settled frame.
    private func advanceReflowOverZoomSettle() {
        let elapsed = CACurrentMediaTime() - pinchReflowSettleStart
        let f = pinchReflowSettleDuration > 0 ? min(1, elapsed / pinchReflowSettleDuration) : 1
        let eased = f * f * (3 - 2 * f)                                   // smoothstep
        coordinator.setLiveVisualLevel(pinchReflowSettleFrom * CGFloat(1 - eased))   // → 0
        requestFrame()
        if f >= 1 {
            pinchSettling = false
            finishLiveZoom(target: 0)                                    // commit at the largest detent
            pinchMode = .undecided
        }
    }

    // MARK: - Live overview layer dissolve (offscreen two-layer cross-dissolve)

    /// Map the pinch magnitude straight to dissolve progress (q=0 at the source level, q=1 at the adjacent
    /// overview level). One boundary step - no detent hysteresis / chaining.
    private func driveOverviewDissolve(continuousLevel pos: CGFloat) {
        let s = CGFloat(pinchOverviewSource), t = CGFloat(pinchOverviewTarget)
        let raw = t > s ? (pos - s) : (s - pos)
        pinchOverviewQ = Double(min(1, max(0, raw)))
        coordinator.setOverviewDissolveProgress(pinchOverviewQ)
    }

    /// Advance the post-release linear settle; commit on completion.
    private func advanceOverviewDissolveSettle() {
        let elapsed = CACurrentMediaTime() - pinchOverviewSettleStart
        let f = pinchOverviewSettleDuration > 0 ? min(1, elapsed / pinchOverviewSettleDuration) : 1
        pinchOverviewQ = pinchOverviewSettleFrom + (pinchOverviewSettleTo - pinchOverviewSettleFrom) * f
        coordinator.setOverviewDissolveProgress(pinchOverviewQ)
        requestFrame()
        if f >= 1 { commitOverviewDissolve() }
    }

    /// Commit the dissolve to its settled endpoint (source if it settled toward 0, else target). The coordinator
    /// adopts the target level/phase + anchored scroll; the settled frame matches the dissolve endpoint exactly.
    private func commitOverviewDissolve() {
        pinchSettling = false
        let previousLevel = coordinator.level
        let toTarget = pinchOverviewSettleTo >= 0.5
        let anchoredY = coordinator.commitOverviewDissolve(toTarget: toTarget, viewportSize: metalView.bounds.size)
        let clipH = scrollView.contentView.bounds.height
        let content = coordinator.contentSize()
        let committedY = min(max(0, anchoredY), max(0, content.height - clipH))
        lastMagnifyEventTime = CACurrentMediaTime()           // arm the post-commit scroll grace
        scrollLockOrigin = CGPoint(x: 0, y: committedY)
        applyContentSize(content)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: committedY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        // Edge/corner clamp: if the anchored scroll was out of bounds, slide there instead of snapping.
        coordinator.beginScrollRebase(fromY: anchoredY, toY: committedY)
        coordinator.logPostCommitAnchor()
        pinchMode = .undecided
        pinchOverviewQ = 0
        commitLevelToBinding(previousLevel: previousLevel)    // sync the SwiftUI level binding (+ arm echo guard)
        requestFrame()
    }

    /// Commit the live zoom: rebase scroll from the anchor, then run a short geometry-only BRIDGE that slides
    /// the transaction-final frame to the settled frame (so the column-phase reflow is smooth, not a snap).
    private func finishLiveZoom(target: Int) {
        let previousLevel = coordinator.level
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
        requestFrame()
        commitLevelToBinding(previousLevel: previousLevel)         // sync the SwiftUI level binding (+ arm echo guard)
    }

    /// The cursor's CURRENT content-space point from a gesture event (fresh - never the stale last
    /// mouse-moved position), clamped into the current viewport so a centroid just outside still anchors
    /// sensibly (falls back to the viewport centre).
    private func cursorContentPoint(for event: NSEvent) -> CGPoint {
        let raw = spacer.convert(event.locationInWindow, from: nil)
        let inset = coordinator.leadingObstructionInset                    // sidebar + (normal-level) gap
        let p = CGPoint(x: raw.x - inset, y: raw.y)                         // render → layout space (X)
        let origin = scrollView.contentView.bounds.origin
        let vh = scrollView.contentView.bounds.height
        let layoutW = max(1, bounds.width - inset)                         // the unobscured layout width
        if p.y >= origin.y, p.y <= origin.y + vh, p.x >= 0, p.x <= layoutW { return p }
        return CGPoint(x: layoutW / 2, y: origin.y + vh / 2)               // layout-space viewport centre
    }

    /// A button-driven level change. The discrete +/- path re-anchors scroll at the viewport centre (the
    /// live trackpad pinch is the continuous path, handled in `handleMagnify`).
    func animateToLevel(_ target: Int) {
        setLevel(target)
    }

    /// Reconcile a SwiftUI `level`-binding value delivered to `updateNSView` against the host's authoritative
    /// `coordinator.level`. Drives `animateToLevel` for a genuine external (+/- / keyboard / programmatic)
    /// change; IGNORES a stale echo of a host-led pinch commit (which would otherwise re-issue a viewport-centre
    /// zoom and jump a different photo under the cursor). Pure decision in `LevelBindingReconciler`.
    func reconcileLevelBinding(_ bindingLevel: Int) {
        let action = LevelBindingReconciler.decide(binding: bindingLevel, hostLevel: coordinator.level, staleEcho: pendingLevelEcho)
        switch action {
        case .ignore:
            if pendingLevelEcho != nil, bindingLevel != coordinator.level {        // a suppressed post-commit echo
                GridLevelSyncLog.decision(binding: bindingLevel, hostLevel: coordinator.level, staleEcho: pendingLevelEcho, action: "suppressStaleEcho")
            }
        case .clearLatch:
            pendingLevelEcho = nil
        case .reDrive(let target):
            pendingLevelEcho = nil
            GridLevelSyncLog.decision(binding: bindingLevel, hostLevel: coordinator.level, staleEcho: nil, action: "reDrive")
            animateToLevel(target)
        }
    }

    /// Push the settled level to the SwiftUI `level` binding AND arm the stale-echo guard, so a not-yet-
    /// propagated pre-commit binding value can't re-issue a viewport-centre zoom. The guard is armed ONLY when
    /// the commit actually changed the level - a no-op commit can produce no echo, and arming it would wrongly
    /// swallow the next genuine external change. Call at every host-led commit, in place of `onZoomCommit`.
    private func commitLevelToBinding(previousLevel: Int) {
        if coordinator.level != previousLevel { pendingLevelEcho = previousLevel }
        onZoomCommit?(coordinator.level)
    }

    private func pinToBottom() {
        let maxY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: maxY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// True while scroll must be frozen: the live pinch (scrub or settle), the commit bridge, or a short
    /// grace after the magnify.
    private func isScrollBlocking() -> Bool {
        pinchActive || pinchSettling || coordinator.isZoomingLive || coordinator.isCommitBridging
            || coordinator.isScrollRebasing || coordinator.isResizeSettling || coordinator.isSidebarResizing
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
        requestFrame()
        onViewportChanged?()
    }

    private func installImageAvailabilityCallback(on source: MetalGridDataSource) {
        source.onImagesAvailable = { [weak self] in
            self?.requestFrame()
        }
    }

    private func ensureDisplayLink() {
        guard window != nil, streamingTick == nil else { return }
        let dl = displayLink(target: self, selector: #selector(step))
        dl.add(to: .main, forMode: .common)
        streamingTick = dl
    }

    private func requestFrame(keepDisplayLinkAlive: Bool = true) {
        metalView.needsDisplay = true
        if keepDisplayLinkAlive { wakeDisplayLink() }
    }

    private func wakeDisplayLink(duration: CFTimeInterval? = nil) {
        guard window != nil else { return }
        let grace = duration ?? displayLinkIdleGrace
        displayLinkWakeUntil = max(displayLinkWakeUntil, CACurrentMediaTime() + grace)
        ensureDisplayLink()
        streamingTick?.isPaused = false
    }

    private func displayLinkHasActiveWork(now: CFTimeInterval) -> Bool {
        coordinator.isCommitBridging
            || coordinator.isSidebarResizing
            || coordinator.isResizeSettling
            || coordinator.isScrollRebasing
            || coordinator.gridTransition.activeKind == .click
            || coordinator.isOverviewClickDissolving
            || coordinator.hasPendingVisibleThumbnails
            || pendingResolvedGridProfile != nil
            || (pinchMode == .lattice && pinchDriver.isSelfAdvancing)
            || (pinchMode == .overviewDissolve && pinchSettling)
            || (pinchMode == .reflow && pinchSettling)
            || now < displayLinkWakeUntil
    }

    private func updateDisplayLinkIdleState(now: CFTimeInterval = CACurrentMediaTime()) {
        streamingTick?.isPaused = !displayLinkHasActiveWork(now: now)
    }

    func updateGridProfileResolver(_ resolver: TimelineGridProfileResolver?) {
        gridProfileResolver = resolver
        if resolver == nil { pendingResolvedGridProfile = nil }
        _ = applyResolvedGridProfileIfNeeded(oldFrame: lastViewportScreenFrame, newFrame: viewportScreenFrame())
    }

    private var canApplyResolvedGridProfile: Bool {
        window != nil
            && !inLiveResize
            && !pinchActive
            && !pinchSettling
            && !coordinator.presentationResizeActive
            && !coordinator.isSidebarResizing
            && !coordinator.isResizeSettling
            && !coordinator.isZoomingLive
            && !coordinator.isCommitBridging
            && !coordinator.isScrollRebasing
            && !coordinator.gridTransition.isActive
            && coordinator.overviewDissolve == nil
    }

    @discardableResult
    private func applyResolvedGridProfileIfNeeded(oldFrame: NSRect, newFrame: NSRect) -> Bool {
        guard let resolver = gridProfileResolver else {
            pendingResolvedGridProfile = nil
            return false
        }
        let frame = newFrame.width > 1 ? newFrame : viewportScreenFrame()
        guard frame.width > 1 else { return false }

        let layoutWidth = coordinator.layoutWidth > 1 ? coordinator.layoutWidth : frame.width
        let viewport = TimelineGridViewport(layoutWidth: layoutWidth, layoutHeight: frame.height)
        let resolved = resolver.profile(for: viewport)
        guard resolved.id != coordinator.gridProfileID else {
            pendingResolvedGridProfile = nil
            return false
        }

        guard canApplyResolvedGridProfile else {
            pendingResolvedGridProfile = resolved
            wakeDisplayLink()
            return false
        }

        let previousLevel = coordinator.level
        let oldScrollY = scrollView.contentView.bounds.origin.y
        let oldMaxScroll = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        let atOrBelowBottom = stickToBottom || oldScrollY >= oldMaxScroll - 2
        let sourceFrame = oldFrame == .zero ? frame : oldFrame
        guard let result = coordinator.applyGridProfile(
            resolved,
            oldFrame: sourceFrame,
            newFrame: frame,
            oldScrollY: oldScrollY,
            wasBottomPinned: atOrBelowBottom
        ) else {
            pendingResolvedGridProfile = nil
            return false
        }

        pendingResolvedGridProfile = nil
        applyContentSize(coordinator.contentSize())
        if !stickToBottom {
            let maxY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
            let y = min(max(0, result.newScrollY), maxY)
            scrollLockOrigin = nil
            if abs(y - oldScrollY) > 0.5 {
                let rebasedPoint = CGPoint(x: 0, y: y)
                scrollView.contentView.scroll(to: rebasedPoint)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
        commitLevelToBinding(previousLevel: previousLevel)
        requestFrame()
        onViewportChanged?()
        return true
    }

    // The display link only TRIGGERS redraws while thumbnails are streaming in; when the visible set is
    // fully loaded and not scrolling, no draws happen at all. It's invalidated when the view leaves its
    // window (CADisplayLink retains its target, so this also breaks that retain before dealloc).
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // A manual window resize detaches the bottom-pin (so the camera rebase runs even on a fresh-open grid).
        NotificationCenter.default.removeObserver(self, name: NSWindow.willStartLiveResizeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didEndLiveResizeNotification, object: nil)
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowWillLiveResize),
                                                   name: NSWindow.willStartLiveResizeNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidEndLiveResize),
                                                   name: NSWindow.didEndLiveResizeNotification, object: window)
        }
        if window != nil {
            ensureDisplayLink()
            requestFrame()
            _ = applyResolvedGridProfileIfNeeded(oldFrame: lastViewportScreenFrame, newFrame: viewportScreenFrame())
        } else {
            streamingTick?.invalidate()
            streamingTick = nil
            displayLinkWakeUntil = 0
        }
    }

    @objc private func step() {
        if coordinator.isCommitBridging { advanceCommitBridge() }
        if coordinator.isSidebarResizing { advanceSidebarResize() }    // sidebar open/close scales the grid
        if coordinator.isResizeSettling { advanceResizeSettle() }      // drives the release-time column-reflow morph (window resize or sidebar settle); armed only when the column count actually changes (rare under fixed columns)
        if coordinator.gridTransition.activeKind == .click { requestFrame() }   // toolbar/keyboard +/- click plans need display-link-paced frames
        if coordinator.isOverviewClickDissolving { requestFrame() }     // overview +/- clicks use the same whole-grid dissolve as pinch
        // Live-pinch post-release settle. Gated on lattice mode so the driver never drives the reflow fallback;
        // reset the tick dt whenever it isn't running.
        if pinchMode == .lattice, pinchDriver.isSelfAdvancing { advanceLivePinch() } else { pinchAdvancePrevTime = 0 }
        if pinchMode == .overviewDissolve, pinchSettling { advanceOverviewDissolveSettle() }   // release settle
        if pinchMode == .reflow, pinchSettling { advanceReflowOverZoomSettle() }               // over-zoom spring-back
        if coordinator.isScrollRebasing { requestFrame() }                       // edge/corner rebase slide
        if coordinator.hasPendingVisibleThumbnails { requestFrame() }
        _ = applyResolvedGridProfileIfNeeded(oldFrame: lastViewportScreenFrame, newFrame: viewportScreenFrame())
        updateDisplayLinkIdleState()
    }

    /// Advance the post-release commit bridge (geometry settle). When it completes, end it → normal settled
    /// rendering. Scroll stays locked throughout (the bridge is shorter than the post-magnify grace window).
    private func advanceCommitBridge() {
        let t = bridgeDuration > 0 ? min(1, (CACurrentMediaTime() - bridgeStart) / bridgeDuration) : 1
        coordinator.commitBridgeProgress = CGFloat(t)
        requestFrame()
        if t >= 1 { coordinator.endCommitBridge(); requestFrame() }
    }

    /// Advance the sidebar open/close scale (right-anchored, the grid scaling like a left-edge drag). When the scale
    /// completes, commit the engine inset and settle - instantly, or via the detent fly-into-place if the new width
    /// reflowed (until sticky columns make a width change reflow-free).
    private func advanceSidebarResize() {
        let t = sidebarResizeDuration > 0 ? min(1, (CACurrentMediaTime() - sidebarResizeStart) / sidebarResizeDuration) : 1
        coordinator.presentationSidebarProgress = CGFloat(t)
        requestFrame()
        guard t >= 1 else { return }
        let (settleScroll, animating) = coordinator.endSidebarResize()   // commits the inset + bottom-anchored scroll
        stickToBottom = false
        applyContentSize(coordinator.contentSize())
        let maxScrollY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        let settledY = min(max(0, settleScroll), maxScrollY)
        if abs(settledY - scrollView.contentView.bounds.origin.y) > 0.5 {
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: settledY))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        if animating { resizeSettleStart = CACurrentMediaTime() }
        let oldFrame = lastViewportScreenFrame
        let newFrame = viewportScreenFrame()
        lastViewportScreenFrame = newFrame
        _ = applyResolvedGridProfileIfNeeded(oldFrame: oldFrame, newFrame: newFrame)
        requestFrame()
    }

    /// Advance the release-time resize settle: morph the scaled frame into the settled layout. The scroll is
    /// already at its settled value, so when this completes the canonical render matches exactly (no jump).
    private func advanceResizeSettle() {
        let t = resizeSettleDuration > 0 ? min(1, (CACurrentMediaTime() - resizeSettleStart) / resizeSettleDuration) : 1
        coordinator.resizeSettleProgress = CGFloat(t)
        requestFrame()
        if t >= 1 {
            coordinator.endResizeSettle()
            _ = applyResolvedGridProfileIfNeeded(oldFrame: lastViewportScreenFrame, newFrame: viewportScreenFrame())
            requestFrame()
        }
    }

    override func layout() {
        super.layout()
        metalView.frame = bounds
        let newFrame = viewportScreenFrame()
        let old = lastViewportScreenFrame
        // Live resize presentation: present the cached stable surface SCALED/slid to the new geometry about the
        // stationary edge. NO engine resolve, NO content-size pass, NO scroll rebase this tick - the
        // `onContentSizeChange` callback is gated off too (see init). The single settle happens on
        // `didEndLiveResize`.
        if inLiveResize, coordinator.presentationResizeActive, liveResizeStartFrame != .zero {
            // The presentation handles BOTH axes as ONE stable surface: HORIZONTAL scales the snapshot to the new
            // width (in draw()); VERTICAL slides it - the dragging edge clips while the opposite edge gives up a
            // fraction (Apple's shared-loss counter-scroll). Present SYNCHRONOUSLY this tick: `needsDisplay` only
            // schedules an ASYNC draw the live-resize (event-tracking) runloop COALESCES - that was the vertical
            // flicker (and the ~28%-of-ticks horizontal lag). `draw()` forces an immediate render+present locked to
            // the window border. The single settle happens on `didEndLiveResize`.
            // The vertical counter-scroll (shared-loss slide) applies ONLY to a PURE-height drag, where the tiles
            // keep their size. A corner drag also changes WIDTH ⇒ the tiles SCALE and the resize anchor (centre /
            // bottom) already handles the vertical position; adding the slide on top double-counts and snaps back on
            // release (the corner jump). So gate it off whenever the width is changing.
            let widthChanging = abs(newFrame.width - liveResizeStartFrame.width) > 0.5
            coordinator.presentationVerticalShift = widthChanging ? 0 : verticalCounterScroll(start: liveResizeStartFrame, current: newFrame)
            metalView.draw()
            lastViewportScreenFrame = newFrame
            return
        }
        if applyResolvedGridProfileIfNeeded(oldFrame: old, newFrame: newFrame) {
            lastViewportScreenFrame = newFrame
            return
        }
        if old != .zero, viewportGeometryChanged(old, newFrame) {
            rebaseForResize(oldFrame: old, newFrame: newFrame)  // window resize / sidebar toggle - NOT zoom
        } else {
            applyContentSize(coordinator.contentSize())         // first layout / move-only (no size change)
        }
        lastViewportScreenFrame = newFrame
    }

    /// The VERTICAL counter-scroll (viewport pixels, y-down) for a window vertical resize: the dragging edge clips
    /// the grid, and the OPPOSITE edge gives up a fraction `f` of the height change - Apple's shared-loss slide
    /// (the grid drifts toward the dragging edge instead of the dragging edge guillotining it). 0 when the height
    /// did not change (pure-horizontal). `f` ≈ ⅓ (the opposite edge's share; tunable).
    private func verticalCounterScroll(start: NSRect, current: NSRect) -> CGFloat {
        let dH = start.height - current.height          // shrink positive (screen y-up height == viewport height)
        guard abs(dH) > 0.5 else { return 0 }
        // Which edge moved? Screen coords are y-up: maxY = top, minY = bottom. A bottom-edge drag holds the TOP
        // (maxY) fixed; a top-edge drag holds the BOTTOM (minY) fixed.
        let topEdgeDrag = abs(current.maxY - start.maxY) > abs(current.minY - start.minY)
        let rawShift = MetalGridCoordinator.verticalCounterScrollShift(dH: dH, topEdgeDrag: topEdgeDrag, fraction: 1.0 / 3.0)
        // Clamp to the content bounds: at the very top/bottom of the library the dragging edge CANNOT pull empty
        // space into view, so the reveal redirects to the opposite edge - the effective scroll clamps to
        // [0, maxScroll] at the NEW height. (At the bottom, growing pins the last row and reveals older rows at the
        // top instead of opening a void below; symmetric at the top.)
        let startScrollY = coordinator.presentationStartScrollY
        let maxScroll = max(0, spacer.frame.height - current.height)
        let clampedScroll = min(max(0, startScrollY - rawShift), maxScroll)
        return startScrollY - clampedScroll
    }

    /// The grid LAYOUT viewport's frame in SCREEN coords (y-up): `maxY` = top edge, `minY` = bottom edge. The
    /// MTKView renders full-width under the sidebar, but the engine's settled layout is only the unobscured
    /// width to the right of `coordinator.leadingObstructionInset`. Resize rebase must therefore use this
    /// layout-space frame, never the full render frame, or the sidebar animation changes slotSide without a
    /// coherent scroll rebase. Falls back to local bounds before the view has a window.
    private func viewportScreenFrame() -> NSRect {
        let full: NSRect
        if let window {
            full = window.convertToScreen(convert(bounds, to: nil))
        } else {
            full = bounds
        }
        let inset = coordinator.leadingObstructionInset
        return NSRect(x: full.minX + inset, y: full.minY, width: max(1, full.width - inset), height: full.height)
    }

    private func viewportGeometryChanged(_ old: NSRect, _ new: NSRect) -> Bool {
        abs(old.width - new.width) > 0.5 || abs(old.height - new.height) > 0.5
    }

    /// SwiftUI safe-area changes from the floating sidebar do not always arrive as an AppKit `layout()` pass.
    /// Treat the inset change itself as a layout-width resize so the scroll camera rebases during the sidebar
    /// animation instead of letting content-size changes accumulate and snap on the next scroll/resize tick.
    private func applyLeadingInsetChange(from oldValue: CGFloat) {
        guard abs(eventLeadingInset - oldValue) > 0.5 else { return }
        let oldFrame = lastViewportScreenFrame
        // Sidebar open/close = a LEFT-edge resize of the grid: snapshot at the OLD inset (the engine inset is still
        // `oldValue` here - do NOT commit it first) and SCALE the grid right-anchored to the new inset over the
        // slide duration (a timed virtual drag), then settle. Instant fallback when the presentation can't run
        // (mid window live-resize, no window, zoom in flight, first layout).
        if window != nil, !inLiveResize, oldFrame != .zero, coordinator.beginSidebarResize(fromInset: oldValue, toInset: eventLeadingInset) {
            sidebarResizeStart = CACurrentMediaTime()
            requestFrame()
            return
        }
        coordinator.sidebarObstructionInset = eventLeadingInset
        guard oldFrame != .zero else { return }
        let newFrame = viewportScreenFrame()
        if viewportGeometryChanged(oldFrame, newFrame) {
            rebaseForResize(oldFrame: oldFrame, newFrame: newFrame)
        } else {
            applyContentSize(coordinator.contentSize())
        }
        lastViewportScreenFrame = newFrame
        _ = applyResolvedGridProfileIfNeeded(oldFrame: oldFrame, newFrame: newFrame)
    }

    /// Viewport resized (window or sidebar). Recompute content size from the new width and rebase the scroll
    /// via the engine so the SAME logical region stays visible - the stationary edge holds the anchor, the
    /// moving edge clips/reveals. Never reuse the raw scrollY after slotSide changed, never start a zoom, never
    /// restore an old origin. Bottom-pinned stays pinned.
    private func rebaseForResize(oldFrame: NSRect, newFrame: NSRect) {
        let placingInitial = pendingInitialViewport != .preserve
        let oldScrollY = scrollView.contentView.bounds.origin.y
        // At/below the newest end - scrolled to (or, after a pinch, past a partial last row at) the content bottom -
        // bottom-pin to the NEW content bottom. `stickToBottom` is false after a pinch, so without this a viewport
        // anchor resolved from a point at/in the trailing void lands on a stale item and jumps the grid far into the
        // past (and can leave the clip in the void → black). Bottom-pin keeps the newest at the bottom: no jump, no black.
        let oldMaxScroll = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        let atOrBelowBottom = stickToBottom || oldScrollY >= oldMaxScroll - 2
        let result = coordinator.rebaseForViewportChange(oldFrame: oldFrame, newFrame: newFrame,
                                                         oldScrollY: oldScrollY, wasBottomPinned: atOrBelowBottom)
        applyContentSize(coordinator.contentSize())            // new content height (new width); consumes a pending policy
        if placingInitial, pendingInitialViewport == .preserve { return }  // initial viewport just placed → don't rebase over it
        guard !stickToBottom, let r = result else { return }   // sticky → already bottom-pinned by applyContentSize
        let maxY = max(0, spacer.frame.height - scrollView.contentView.bounds.height)
        let y = min(max(0, r.newScrollY), maxY)
        scrollLockOrigin = nil                                 // a resize must NOT restore a pre-resize origin
        if abs(y - oldScrollY) > 0.5 {                         // skip a no-op scroll (e.g. top-anchored width change)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        requestFrame()                          // first frame after resize uses the rebased scrollY
    }

    /// Set the document spacer to the current content height (width tracks the clip, no h-scroll). This is also
    /// the SINGLE consume point for a pending `.newest` initial-viewport policy: the placement happens here,
    /// only after the spacer/document frame has been installed and the layout geometry is valid - so a route
    /// switch never scrolls before content height + clip height are real.
    private func applyContentSize(_ size: CGSize) {
        let width = scrollView.contentView.bounds.width
        // Geometry not valid yet (no clip width, or no content height) → install nothing and, crucially, leave
        // any pending `.newest` policy PENDING. A later `applyContentSize` (from `layout()` / the content-size
        // callback) consumes it once the geometry is real.
        guard width > 1, size.height > 0 else { return }
        let newFrame = NSRect(x: 0, y: 0, width: width, height: size.height)
        if spacer.frame != newFrame { spacer.frame = newFrame }   // spacer/document frame installed first
        let clipH = scrollView.contentView.bounds.height
        if pendingInitialViewport != .preserve, window != nil, clipH > 0 {
            // Consume the one-shot placement against the now-valid geometry (real window, real content + clip
            // height). After this the policy is cleared and bottom-pinning stays OFF.
            placeForInitialViewport(pendingInitialViewport, clipHeight: clipH)
            pendingInitialViewport = .preserve
        } else if stickToBottom {
            pinToBottom()                    // launch / sticky open: stay at newest (bottom) until the user scrolls
        }
        requestFrame()
        onViewportChanged?()
    }

    /// Consume a pending initial-viewport policy: place the viewport ONCE at the newest (bottom) end (`.newest`)
    /// or re-pin a remembered photo anchor (`.restore`). Unlike `scrollToBottom` / sticky pinning, this does NOT
    /// re-arm bottom-pinning - it leaves `stickToBottom == false` so the user's first manual scroll is honoured
    /// and never pulled back. `.restore` re-resolves the anchored photo's position in the CURRENT layout (so it
    /// is exact across any zoom/width/phase change while away); if that photo is gone (e.g. trashed meanwhile) it
    /// falls back to the newest end.
    private func placeForInitialViewport(_ policy: GridInitialViewport, clipHeight: CGFloat) {
        let maxY = max(0, spacer.frame.height - clipHeight)
        let targetY: CGFloat
        switch policy {
        case .newest:
            targetY = maxY
        case .restore(let anchor):
            if let rect = coordinator.cellContentRect(forUID: anchor.itemID) {
                targetY = min(max(0, rect.minY - anchor.topOffset), maxY)
            } else {
                targetY = maxY                 // the remembered photo no longer exists in this route → newest
            }
        case .preserve:
            return
        }
        stickToBottom = false
        scrollLockOrigin = nil                 // no stale zoom lock may override the placement
        lastMagnifyEventTime = 0               // clear any post-magnify scroll-suppression grace
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Arm a one-shot initial-viewport policy: reset to the canonical bottom-right phase (so the content height
    /// matches what a remembered offset was captured against) and mark the policy pending. The actual placement
    /// is deferred to `applyContentSize` (called below and on every subsequent layout) once the geometry is
    /// valid - never an immediate scroll. Used for sidebar route switches and for a freshly (re)created host.
    func requestInitialViewport(_ policy: GridInitialViewport) {
        guard policy != .preserve else { return }
        pendingInitialViewport = policy
        coordinator.resetCommittedPhase()
        applyContentSize(coordinator.contentSize())   // consume now if geometry is valid; else it stays pending
    }

    /// A layout-invariant snapshot of the current scroll position - the photo at the viewport top plus its
    /// sub-offset - or nil if the grid isn't laid out yet. The shell reads this when leaving a route so it can
    /// reopen the route EXACTLY here later (`.restore`), robust to any zoom/width/phase change while away.
    /// Derived from the existing visible-cell query (NOT the zoom anchor): this is route-scroll memory, not a
    /// zoom anchor - the live pinch / +- path still anchors on the cursor item.
    func currentScrollAnchor() -> GridScrollAnchor<PhotoUID>? {
        let originY = scrollView.contentView.bounds.origin.y
        guard let top = coordinator.visibleCells().min(by: { $0.rect.minY < $1.rect.minY }),
              let uid = coordinator.uid(atFlatIndex: top.flatIndex) else { return nil }
        return GridScrollAnchor(itemID: uid, topOffset: top.rect.minY - originY)
    }

    // MARK: - Public controls

    /// Change zoom level, holding an EXPLICIT anchor point under the same viewport position (zoom directed
    /// toward that point - the Apple rule). `anchorContentPoint` is the cursor's content point for a trackpad
    /// pinch; for +/- it's nil → the viewport centre is used. NEVER the top-visible item. Pinned-to-bottom
    /// (newest) stays pinned.
    func setLevel(_ newLevel: Int, anchorContentPoint: CGPoint? = nil) {
        guard newLevel != coordinator.level else { return }
        let vh = scrollView.contentView.bounds.height
        let origin = scrollView.contentView.bounds.origin
        // +/- anchors at the GRID VIEWPORT CENTRE (never the toolbar-button mouse point, a stale hover, or the
        // top). The pinch path supplies an explicit cursor point instead.
        // Layout-space viewport centre (the engine works in layout space; never add the inset back here - the
        // render translation happens once at the coordinator's draw chokepoint).
        let anchorPoint = anchorContentPoint ?? CGPoint(x: max(1, bounds.width - coordinator.leadingObstructionInset) / 2, y: origin.y + vh / 2)
        let viewportPoint = CGPoint(x: anchorPoint.x, y: anchorPoint.y - origin.y)
        let trigger: GridZoomTrigger = newLevel < coordinator.level ? .toolbarPlus : .toolbarMinus   // plus = zoom in
        // Try the single-lattice transition FIRST - including when the grid is freshly bottom-pinned
        // (`stickToBottom`). Otherwise the early-return below would bypass it. It commits the settled target
        // + an anchored scroll itself; apply its scroll-Y and skip the snap. nil ⇒ unchanged snaps below.
        if let tY = coordinator.tryBeginClickTransition(toLevel: newLevel, anchorContentPoint: anchorPoint,
                                                        viewportPoint: viewportPoint, viewportSize: metalView.bounds.size) {
            stickToBottom = false                          // an anchored zoom ends bottom-pinning (like a scroll)
            applyContentSize(coordinator.contentSize())
            let maxY = max(0, spacer.frame.height - vh)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, tY), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            coordinator.logPostCommitAnchor()
            requestFrame()
            return
        }
        if let tY = coordinator.tryBeginClickOverviewDissolve(toLevel: newLevel, anchorContentPoint: anchorPoint,
                                                              viewportPoint: viewportPoint, viewportSize: metalView.bounds.size) {
            stickToBottom = false
            applyContentSize(coordinator.contentSize())
            let maxY = max(0, spacer.frame.height - vh)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, tY), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            coordinator.logPostCommitAnchor()
            requestFrame()
            return
        }
        if stickToBottom {
            coordinator.level = newLevel
            applyContentSize(coordinator.contentSize())   // pins to bottom (newest)
            requestFrame()
            return
        }
        // Latches the committed column phase so the settled grid keeps the anchor's column (no fly).
        let newY = coordinator.settleScrollOffsetY(toLevel: newLevel, anchorContentPoint: anchorPoint, viewportPoint: viewportPoint, trigger: trigger)
        applyContentSize(coordinator.contentSize())
        if let newY {
            let maxY = max(0, spacer.frame.height - vh)
            scrollView.contentView.scroll(to: CGPoint(x: 0, y: min(max(0, newY), maxY)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        coordinator.logPostCommitAnchor()
        requestFrame()
    }

    /// A photo's cell frame in WINDOW content coordinates (top-left origin), or nil if it isn't visible -
    /// used by the shared-element zoom transition (window-coordinate frame of a visible cell).
    func windowFrame(forUID uid: PhotoUID) -> CGRect? {
        guard let win = window, let contentRect = coordinator.cellContentRect(forUID: uid) else { return nil }
        let origin = scrollView.contentView.bounds.origin
        // cellContentRect is LAYOUT-space (X from 0); translate +inset into render space for the on-screen frame.
        let vp = CGRect(x: contentRect.minX - origin.x + coordinator.leadingObstructionInset, y: contentRect.minY - origin.y, width: contentRect.width, height: contentRect.height)
        guard CGRect(origin: .zero, size: metalView.bounds.size).intersects(vp) else { return nil }
        // The metal view is not flipped (y-up); our viewport rect is top-left origin (y-down).
        let localYUp = CGRect(x: vp.minX, y: metalView.bounds.height - vp.maxY, width: vp.width, height: vp.height)
        let inWindow = metalView.convert(localYUp, to: nil)            // window coords, bottom-left origin
        let contentH = win.contentView?.bounds.height ?? win.frame.height
        return CGRect(x: inWindow.minX, y: contentH - inWindow.maxY, width: inWindow.width, height: inWindow.height)
    }

    /// Install a new data source. For an incremental data update pass `.preserve` (the default - the current
    /// scroll position is kept). For a sidebar route switch pass `.newest`: the host arms the one-shot newest
    /// placement (canonical bottom-right phase) and consumes it via `applyContentSize` once geometry is valid -
    /// it does NOT scroll immediately, and it never arms sticky bottom-pinning.
    func setDataSource(_ source: MetalGridDataSource, initialViewport: GridInitialViewport = .preserve) {
        installImageAvailabilityCallback(on: source)
        if initialViewport != .preserve {
            pendingInitialViewport = initialViewport
            coordinator.resetCommittedPhase()             // canonical bottom-right phase, BEFORE the size callback
        }
        coordinator.setDataSource(source)                 // rebuild + onContentSizeChange → applyContentSize
        applyContentSize(coordinator.contentSize())       // pins to bottom when sticky / consumes a pending policy
    }

    /// Scroll to the newest (bottom) and re-arm the bottom pin. Resets the camera to the canonical bottom-right
    /// phase so the newest view always has the newest item in the corner (no trailing black at the bottom-right).
    func scrollToBottom() {
        stickToBottom = true
        coordinator.resetCommittedPhase()
        applyContentSize(coordinator.contentSize())   // resize for the canonical phase, then pin to bottom
    }

    /// Scroll a specific photo to vertical center (detaches the bottom pin - the user navigated to it).
    func scrollToItem(_ uid: PhotoUID) {
        stickToBottom = false
        guard let rect = coordinator.cellContentRect(forUID: uid) else { return }
        let clipH = scrollView.contentView.bounds.height
        let maxY = max(0, spacer.frame.height - clipH)
        let targetY = min(max(0, rect.midY - clipH / 2), maxY)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        requestFrame()
    }

    /// Scroll a flattened timeline index near the top of the viewport. This is the date-jump primitive for the
    /// overview scrubber: no SwiftUI geometry, no synthetic sections, no custom scroll physics.
    func scrollToFlatIndex(_ index: Int) {
        stickToBottom = false
        guard let rect = coordinator.cellContentRect(forFlatIndex: index) else { return }
        let clipH = scrollView.contentView.bounds.height
        let maxY = max(0, spacer.frame.height - clipH)
        let targetY = min(max(0, rect.minY - 24), maxY)
        scrollView.contentView.scroll(to: CGPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        requestFrame()
        onViewportChanged?()
    }
}
