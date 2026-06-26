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

    // V3.9 CONTINUOUS MULTI-LEVEL LIVE-PINCH SCRUB DRIVER (single-presentation-lattice). When the first
    // resolved direction is an eligible in-band step, the pinch scrubs the V3.7 plan CONTINUOUSLY across
    // detents via this pure driver (rebuilding the segment plan as the finger crosses each detent —
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
            if pinchActive || pinchSettling || coordinator.isZoomingLive || coordinator.isCommitBridging { return true }
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
            finishInFlightPinchSettle()   // a quick re-pinch must not strand the previous settle's (frozen) plan on screen
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
            metalView.needsDisplay = true
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
    /// crossing — seam-continuous), then scrub it to `segmentQ`.
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
            metalView.needsDisplay = true
        case .reflow:
            if coordinator.liveZoomLevel < 0 {
                // Rubber-band over-zoom past level 0 → spring the visual level back to 0 over a short ramp,
                // then commit at level 0 (seamless: at 0 the live frame equals the settled frame). No snap.
                pinchReflowSettleFrom = coordinator.liveZoomLevel
                pinchReflowSettleStart = CACurrentMediaTime()
                pinchSettling = true
                lastMagnifyEventTime = CACurrentMediaTime()
                metalView.needsDisplay = true
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
            metalView.needsDisplay = true
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
            metalView.needsDisplay = true
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
            metalView.needsDisplay = true
            return true
        }

        return false
    }

    /// If a previous lattice pinch is still running its post-release settle (the settle spans multiple display
    /// ticks — q=0.5→0 at the floor is ~280 ms), a new pinch's `.began` would otherwise leave that plan
    /// `isActive` with a frozen q: `draw(in:)` would keep rendering the stale crossfade frame. So force the
    /// in-flight settle to its terminal and commit it NOW — on whichever detent it had decided — before the
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

    /// Advance the post-release settle on the display tick; push the new segmentQ into the plan; commit the
    /// chain's final detent on a terminal state.
    private func advanceLivePinch() {
        let now = CACurrentMediaTime()
        let dt = pinchAdvancePrevTime == 0 ? 1.0 / 60.0 : max(0, now - pinchAdvancePrevTime)
        pinchAdvancePrevTime = now
        pinchDriver.advance(dt: dt)
        coordinator.setPinchProgress(pinchDriver.segmentQ)
        metalView.needsDisplay = true
        if pinchDriver.isCommitted { commitLivePinch() }
    }

    /// The settle reached a terminal state. Commit the chain to its final detent: apply that detent's anchored
    /// scroll (a no-op when it's the gesture-start detent). The settled frame matches the plan's final-detent
    /// endpoint exactly — no hard snap, no flash.
    private func commitLivePinch() {
        pinchSettling = false
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
        onZoomCommit?(coordinator.level)                      // sync the SwiftUI level binding
        metalView.needsDisplay = true
    }

    /// Advance the reflow over-zoom spring-back: ramp the live VISUAL level from the released over-zoom value
    /// back to 0 (smoothstep), then commit at level 0. The grid elastically returns to the largest detent with
    /// no hard snap; the commit at 0 is seamless because there the live frame equals the settled frame.
    private func advanceReflowOverZoomSettle() {
        let elapsed = CACurrentMediaTime() - pinchReflowSettleStart
        let f = pinchReflowSettleDuration > 0 ? min(1, elapsed / pinchReflowSettleDuration) : 1
        let eased = f * f * (3 - 2 * f)                                   // smoothstep
        coordinator.setLiveVisualLevel(pinchReflowSettleFrom * CGFloat(1 - eased))   // → 0
        metalView.needsDisplay = true
        if f >= 1 {
            pinchSettling = false
            finishLiveZoom(target: 0)                                    // commit at the largest detent
            pinchMode = .undecided
        }
    }

    // MARK: - Live overview layer dissolve (offscreen two-layer cross-dissolve)

    /// Map the pinch magnitude straight to dissolve progress (q=0 at the source level, q=1 at the adjacent
    /// overview level). One boundary step — no detent hysteresis / chaining.
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
        metalView.needsDisplay = true
        if f >= 1 { commitOverviewDissolve() }
    }

    /// Commit the dissolve to its settled endpoint (source if it settled toward 0, else target). The coordinator
    /// adopts the target level/phase + anchored scroll; the settled frame matches the dissolve endpoint exactly.
    private func commitOverviewDissolve() {
        pinchSettling = false
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
        onZoomCommit?(coordinator.level)                      // sync the SwiftUI level binding
        metalView.needsDisplay = true
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

    /// True while scroll must be frozen: the live pinch (scrub or settle), the commit bridge, or a short
    /// grace after the magnify.
    private func isScrollBlocking() -> Bool {
        pinchActive || pinchSettling || coordinator.isZoomingLive || coordinator.isCommitBridging
            || coordinator.isScrollRebasing
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
        // Live-pinch post-release settle. Gated on lattice mode so the driver never drives the reflow fallback;
        // reset the tick dt whenever it isn't running.
        if pinchMode == .lattice, pinchDriver.isSelfAdvancing { advanceLivePinch() } else { pinchAdvancePrevTime = 0 }
        if pinchMode == .overviewDissolve, pinchSettling { advanceOverviewDissolveSettle() }   // release settle
        if pinchMode == .reflow, pinchSettling { advanceReflowOverZoomSettle() }               // over-zoom spring-back
        if coordinator.isScrollRebasing { metalView.needsDisplay = true }                       // edge/corner rebase slide
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
        let origin = scrollView.contentView.bounds.origin
        // +/- anchors at the GRID VIEWPORT CENTRE (never the toolbar-button mouse point, a stale hover, or the
        // top). The pinch path supplies an explicit cursor point instead.
        let anchorPoint = anchorContentPoint ?? CGPoint(x: bounds.width / 2, y: origin.y + vh / 2)
        let viewportPoint = CGPoint(x: anchorPoint.x, y: anchorPoint.y - origin.y)
        let trigger: GridZoomTrigger = newLevel < coordinator.level ? .toolbarPlus : .toolbarMinus   // plus = zoom in
        // Try the single-lattice transition FIRST — including when the grid is freshly bottom-pinned
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
            metalView.needsDisplay = true
            return
        }
        if stickToBottom {
            coordinator.level = newLevel
            applyContentSize(coordinator.contentSize())   // pins to bottom (newest)
            metalView.needsDisplay = true
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
