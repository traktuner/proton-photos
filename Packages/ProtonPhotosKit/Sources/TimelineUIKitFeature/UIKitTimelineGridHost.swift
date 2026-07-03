#if canImport(UIKit)
import CoreGraphics
import GridCore
import MediaCacheUIKitAdapter
import Metal
import MetalGridComposeCore
import MetalGridTextureCore
import MetalGridTextureUIKitAdapter
import MetalRenderingCore
import os
import PhotosCore
import SwiftUI
import TimelineCore
import TimelineUIKitAdapter
import UIKit

/// SwiftUI bridge for the first real iOS/iPadOS timeline grid host.
///
/// This is intentionally thin: UIKit owns the scroll surface and drawable, while GridCore, MediaFeedCore,
/// MetalGridTextureCore, and MetalRenderingCore still own layout, decoded thumbnails, residency, and drawing.
public struct UIKitTimelineGrid: UIViewRepresentable {
    private let items: [PhotoItem]
    private let thumbnailFeed: UIKitThumbnailFeed
    private let level: Int?
    private let displayMode: TileContentDisplayMode
    private let selectionMode: Bool
    private let selectedUIDs: Set<PhotoUID>
    /// Whether this grid's surface is the active one (its tab is selected). When false the host stops its
    /// display link and cancels ahead-warm so a hidden grid never competes with menus/transitions on screen;
    /// defaults to true so a grid that is always visible (e.g. a pushed collection detail) behaves as before.
    private let isActive: Bool
    private let onFirstContentReady: (() -> Void)?
    private let onOpenPhoto: ((PhotoItem) -> Void)?
    private let onToggleSelection: ((PhotoItem) -> Void)?

    public init(
        items: [PhotoItem],
        thumbnailFeed: UIKitThumbnailFeed,
        level: Int? = nil,
        displayMode: TileContentDisplayMode = .squareFillCrop,
        selectionMode: Bool = false,
        selectedUIDs: Set<PhotoUID> = [],
        isActive: Bool = true,
        onFirstContentReady: (() -> Void)? = nil,
        onOpenPhoto: ((PhotoItem) -> Void)? = nil,
        onToggleSelection: ((PhotoItem) -> Void)? = nil
    ) {
        self.items = items
        self.thumbnailFeed = thumbnailFeed
        self.level = level
        self.displayMode = displayMode
        self.selectionMode = selectionMode
        self.selectedUIDs = selectedUIDs
        self.isActive = isActive
        self.onFirstContentReady = onFirstContentReady
        self.onOpenPhoto = onOpenPhoto
        self.onToggleSelection = onToggleSelection
    }

    @MainActor
    public func makeUIView(context: Context) -> UIKitTimelineGridHostView {
        let view = UIKitTimelineGridHostView()
        view.onFirstContentReady = onFirstContentReady
        view.onOpenPhoto = onOpenPhoto
        view.onToggleSelection = onToggleSelection
        view.configure(items: items, thumbnailFeed: thumbnailFeed, level: level, displayMode: displayMode,
                       selectionMode: selectionMode, selectedUIDs: selectedUIDs)
        view.setActive(isActive)
        return view
    }

    @MainActor
    public func updateUIView(_ uiView: UIKitTimelineGridHostView, context: Context) {
        uiView.onFirstContentReady = onFirstContentReady
        uiView.onOpenPhoto = onOpenPhoto
        uiView.onToggleSelection = onToggleSelection
        uiView.configure(items: items, thumbnailFeed: thumbnailFeed, level: level, displayMode: displayMode,
                         selectionMode: selectionMode, selectedUIDs: selectedUIDs)
        uiView.setActive(isActive)
    }
}

@MainActor
public final class UIKitTimelineGridHostView: UIView {
    private let metalView = UIKitTimelineMetalHostView()
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let profileAdapter = UIKitTimelineGridProfileAdapter()
    private let displayLink = UIKitTimelineDisplayLinkDriver()

    private var device: MTLDevice?
    private var renderer: MetalGridRenderer?
    private var textureCache: MetalGridTextureCache<PhotoUID>?
    private var texturePolicy: UIKitMetalGridTexturePolicy?
    private var thumbnailFeed: UIKitThumbnailFeed?
    private var items: [PhotoItem] = []
    /// Flat UID order for the current items, cached so the per-frame composer input never re-maps the library.
    private var itemUIDs: [PhotoUID] = []
    private var itemIndexByUID: [PhotoUID: Int] = [:]
    private var levelOverride: Int?
    /// The user-driven density level set by pinch. Takes precedence over the profile default so pinch survives
    /// item refreshes; cleared when an explicit external `level` arrives. `nil` → profile default (data-driven).
    private var interactiveLevel: Int?
    /// The level captured at pinch-gesture start (the cumulative-scale reference).
    private var pinchStartLevel: Int?
    /// Engine-owned live pinch transaction. This mirrors the macOS grid path at the Core boundary: the item under
    /// the fingers is captured once, then every live frame is resolved by `GridZoomTransaction` instead of discrete
    /// per-change reflow.
    private var zoomTransaction: GridZoomTransaction?
    private var zoomTransactionLevel: CGFloat = 0
    private var pinchLockedOffsetY: CGFloat?
    /// Optional cursor-aligned column phase committed after a live pinch. Settled iOS layout must use it everywhere
    /// the macOS layout does (rendering, hit-testing, content size), or the release seam can jump horizontally.
    private var committedPhase: Int?
    private var commitBridgeTransaction: GridZoomTransaction?
    private var commitBridgeLevel = 0
    private var commitBridgeScrollY: CGFloat = 0
    private var commitBridgePhase: Int?
    private var commitBridgeStart: CFTimeInterval = 0
    private var displayMode: TileContentDisplayMode = .squareFillCrop
    /// Selection state, mirrored from SwiftUI each `configure`. In selection mode a tap toggles a cell instead of
    /// opening it, and the grid draws the shared selection decorations (blue outline + checkmark badge).
    private var selectionMode = false
    private var selectedUIDs: Set<PhotoUID> = []
    /// Cached video-UID set for the video badge decoration, rebuilt only when the item set changes.
    private var videoUIDs: Set<PhotoUID> = []
    private var warmTask: Task<Void, Never>?
    private var lastWarmIDs: [PhotoUID] = []
    /// Scroll-direction-biased prefetch (shared `GridScrollAheadPolicy`): the user's last vertical travel
    /// direction, learned from finger scrolls only (`nil` until the first real scroll — no direction, no
    /// ahead-warm). Reset when the content set changes.
    private var scrollDirectionDown: Bool?
    private var lastScrollY: CGFloat = 0
    /// One ahead-warm at a time, keyed by (range, direction, level) so a settled static viewport never
    /// re-issues the same prefetch. RAM-neutral: it decodes into the existing budgets at
    /// `.nearViewportScrollAhead` priority and never runs while visible warm work is pending.
    private var aheadWarmTask: Task<Void, Never>?
    private var aheadWarmInFlight = false
    private var lastAheadKey = ""
    /// True while a `warmDecoded` pass is running, so passes never stack. Replaces the old exact-set dedup as the
    /// re-warm gate: a still-missing visible set is re-warmed on the next pass whenever the set changed OR
    /// `warmNeedsRepass` was raised (an arrival / demand move), so a tile that lands on disk under a STATIC
    /// viewport is decoded disk→RAM without needing a scroll nudge.
    private var warmInFlight = false
    /// Monotonic id for the in-flight warm pass. A pass's completion only mutates `warmInFlight` when its id is
    /// still current, so a stale pass cancelled by a detach can never clear the flag out from under a newer pass
    /// (which would briefly permit two overlapping warms right after a tab re-attach).
    private var warmGeneration = 0
    /// Raised by the feed's arrival wake (a download landed on disk) or when demand moved mid-pass: the next warm
    /// must re-issue even if the visible set is unchanged, so the just-arrived bytes get decoded to RAM.
    private var warmNeedsRepass = false
    /// The feed the arrival wake is currently wired to (reference identity), so `configure` re-subscribes only
    /// when a new feed instance arrives (a new session/route), never on every SwiftUI update pass.
    private weak var wiredFeed: UIKitThumbnailFeed?
    /// Cached grid profile + engine so a plain finger-scroll frame reuses them instead of reconstructing a
    /// `SquareTileGridEngine` (+ its section arrays) and re-resolving the profile every vsync. The profile is a
    /// pure function of the layout size; the engine of (item count, profile) — both change only on
    /// configure / resize, never mid-scroll — so this removes the per-frame allocation churn.
    private var cachedProfile: GridLevelProfile?
    private var cachedProfileLayoutSize: CGSize = .zero
    private var cachedEngine: SquareTileGridEngine?
    private var cachedEngineItemCount = -1
    private var cachedEngineProfileID: String?
    private var needsInitialNewestViewport = true
    private var userHasScrolledTimeline = false
    private var isApplyingProgrammaticScroll = false
    /// One-shot per content set: fires once the first fully-populated on-screen frame is drawn (every visible
    /// cell resident or unfetchable), mirroring the macOS coordinator. Reset when a new non-empty UID set lands.
    private var firstContentReported = false

    /// Coalesces every invalidation (scroll deltas, new items, layout, arrived thumbnails) into at most ONE
    /// render per display-link tick. Rendering directly from scroll events acquires a drawable per touch delta —
    /// the 3-deep CAMetalLayer pool exhausts within a frame and `nextDrawable()` then blocks the main thread,
    /// which is exactly the scroll stutter this replaces. The pump also retries after a failed present, so a
    /// transiently unavailable drawable (fresh mount, tab re-attach) can never strand a black grid until the
    /// next scroll event.
    private var framePump = GridFramePump()
    private var perf = RenderPerfWindow()

    public private(set) var isMetal3Capable = false

    /// Called on the main actor the first time every visible cell is drawn for the current content — the shell's
    /// signal that the launch/loading UI can lift onto a real grid (never blank cells). One-shot per content set.
    public var onFirstContentReady: (() -> Void)?

    /// Called on the main actor when the user taps a photo cell, with the tapped item. The shell presents the viewer.
    public var onOpenPhoto: ((PhotoItem) -> Void)?

    /// Called on the main actor when the user taps a cell WHILE in selection mode, with the tapped item. The shell
    /// toggles that item's membership in the selection set.
    public var onToggleSelection: ((PhotoItem) -> Void)?

    public override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        configureSubviews()
        configureMetal()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureSubviews()
        configureMetal()
    }

    deinit {
        warmTask?.cancel()
    }

    public func configure(
        items: [PhotoItem],
        thumbnailFeed: UIKitThumbnailFeed,
        level: Int? = nil,
        displayMode: TileContentDisplayMode = .squareFillCrop,
        selectionMode: Bool = false,
        selectedUIDs: Set<PhotoUID> = []
    ) {
        self.selectionMode = selectionMode
        self.selectedUIDs = selectedUIDs
        let newUIDs = items.map(\.uid)
        let uidsChanged = itemUIDs != newUIDs
        let shouldOpenAtNewest = uidsChanged && !newUIDs.isEmpty && !userHasScrolledTimeline
        self.items = items
        self.itemUIDs = newUIDs
        self.thumbnailFeed = thumbnailFeed
        // Subscribe to the feed's arrival wake ONCE per feed instance (a new session/route builds a new feed):
        // a background download landing on disk then re-warms + redraws this host, so a visible tile fills
        // without the user having to scroll a nudge further. Mirrors the macOS `installImageAvailabilityCallback`.
        if wiredFeed !== thumbnailFeed {
            wiredFeed = thumbnailFeed
            thumbnailFeed.setOnImagesAvailable { [weak self] in
                Task { @MainActor in self?.handleImagesAvailable() }
            }
        }
        // An explicit external level is authoritative: it clears any pinch-driven level so the host follows the
        // caller again (a nil level leaves the user's pinch level in place).
        if let level, level != levelOverride {
            interactiveLevel = nil
            committedPhase = nil
            cancelLiveZoomState()
        }
        self.levelOverride = level
        self.displayMode = displayMode
        if uidsChanged {
            committedPhase = nil
            cancelLiveZoomState()
            itemIndexByUID = Dictionary(
                newUIDs.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { _, latest in latest }
            )
            videoUIDs = Set(items.filter(\.isVideo).map(\.uid))
            lastWarmIDs = []
            scrollDirectionDown = nil
            lastAheadKey = ""
            if !newUIDs.isEmpty {
                // A new content set must report its own first drawn frame.
                firstContentReported = false
            }
            if shouldOpenAtNewest {
                needsInitialNewestViewport = true
            } else if newUIDs.isEmpty {
                needsInitialNewestViewport = true
                userHasScrolledTimeline = false
            }
        }
        refreshContentSize()
        requestRender()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        scrollView.frame = bounds
        applyContentInsets()
        metalView.updateDrawableSize()
        refreshTextureCacheIfNeeded()
        refreshContentSize()
        requestRender()
    }

    public override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        setNeedsLayout()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            suspendRenderLoop()
        } else if framePump.isActive {
            // Re-attached while the tab is the active surface → resume. If the tab is inactive, stay
            // suspended; `setActive(true)` resumes later (window is present by then).
            resumeRenderLoop()
        }
    }

    /// Tab/surface activation from the SwiftUI host. An inactive grid must not keep the display link alive
    /// doing render + warm work that competes with the menus/transitions on screen. This is the platform
    /// plumbing for the shared `GridFramePump` active gate — Core decides "should the loop run", UIKit
    /// supplies the lifecycle event. Only acts on a real transition (the pump reports it), so a steady
    /// stream of identical `updateUIView` calls is free.
    public func setActive(_ active: Bool) {
        guard framePump.setActive(active) else { return }
        if active {
            // Resume only makes sense once we are in a window; otherwise `didMoveToWindow` will resume on
            // attach (the pump is now active), so this is safe either way.
            if window != nil { resumeRenderLoop() }
        } else {
            suspendRenderLoop()
        }
        UIHitchLog.gridActivity(
            active: active, hasWindow: window != nil, displayLinkRunning: displayLink.isRunning,
            warmInFlight: warmInFlight, aheadWarmInFlight: aheadWarmInFlight, items: items.count)
    }

    /// Stop the render loop and drop all in-flight warm work — used both when the view leaves its window and
    /// when the tab deactivates. Visible cache/textures stay resident, so returning redraws immediately.
    private func suspendRenderLoop() {
        displayLink.stop()
        perf.noteLoopStopped()
        warmTask?.cancel()
        aheadWarmTask?.cancel()
        aheadWarmInFlight = false
        cancelLiveZoomState()
        warmGeneration &+= 1   // retire the cancelled pass so its late completion can't touch a newer one
        warmInFlight = false   // never leave the warm gate latched shut after a suspend cancels the pass
    }

    /// Re-arm exactly one render on return to the active window, decoding any visible tiles whose bytes
    /// landed while we were suspended (no scroll nudge needed).
    private func resumeRenderLoop() {
        metalView.updateDrawableSize()
        warmNeedsRepass = true
        requestRender()
    }

    private func configureSubviews() {
        backgroundColor = UIColor(
            red: CGFloat(MetalGridRenderPalette.backgroundRGBA.r),
            green: CGFloat(MetalGridRenderPalette.backgroundRGBA.g),
            blue: CGFloat(MetalGridRenderPalette.backgroundRGBA.b),
            alpha: CGFloat(MetalGridRenderPalette.backgroundRGBA.a)
        )

        metalView.translatesAutoresizingMaskIntoConstraints = true
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(metalView)

        scrollView.translatesAutoresizingMaskIntoConstraints = true
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.backgroundColor = .clear
        scrollView.isOpaque = false
        scrollView.delegate = self
        scrollView.alwaysBounceVertical = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        contentView.backgroundColor = .clear
        scrollView.addSubview(contentView)
        addSubview(scrollView)

        // Tap-to-open and pinch-to-change-density ride on the scroll surface so they coexist with the pan/scroll
        // gesture. The tap requires no movement (never fights a scroll); the pinch drives an engine-owned
        // `GridZoomTransaction` through shared GridCore geometry — no bespoke iOS layout math.
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        scrollView.addGestureRecognizer(tap)

        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        pinch.delegate = self
        scrollView.addGestureRecognizer(pinch)
    }

    private func configureMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            isMetal3Capable = false
            return
        }
        isMetal3Capable = UIKitTimelineMetalCapability.supportsTimelineGrid(device: device)
        guard isMetal3Capable else { return }
        self.device = device
        renderer = MetalGridRenderer(device: device)
        metalView.configure(device: device)
        refreshTextureCacheIfNeeded()
    }

    private func refreshTextureCacheIfNeeded() {
        guard let device, bounds.width > 0, bounds.height > 0 else { return }
        let policy = UIKitMetalGridTexturePolicies.policy(forViewportSize: bounds.size)
        if texturePolicy == policy, textureCache != nil { return }
        texturePolicy = policy
        let cache: MetalGridTextureCache<PhotoUID>? = UIKitMetalGridTextureCacheFactory.makeCache(device: device, policy: policy)
        textureCache = cache
        // Register the GPU texture cache with the shared memory governor (identity-keyed: a rebuilt cache
        // replaces the previous registration). On pressure the cache sheds offscreen residency but never
        // the visible pinned set, so what is on screen stays drawable — mirroring the macOS coordinator.
        if let cache {
            UIKitMemoryPressureCoordinator.shared.attach(cache, key: "gridTextureCache") { [weak cache] tier in
                cache?.setResidencyPressureScale(tier.budgetScale)
            }
        }
    }

    /// Keeps the LAST row of content clear of the bottom bar / home indicator: the scroll surface extends
    /// under the (translucent) bar for the full-bleed look, but the content range ends above it, so fully
    /// scrolled to the newest photo every thumbnail of the final row stays visible and tappable. Safe-area
    /// driven — tab bar, home indicator, orientation and iPad sidebar layouts all flow through the same inset.
    private func applyContentInsets() {
        let bottom = safeAreaInsets.bottom
        if scrollView.contentInset.bottom != bottom {
            scrollView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: bottom, right: 0)
        }
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: safeAreaInsets.top, left: 0, bottom: bottom, right: 0)
    }

    /// The largest valid vertical content offset given the current content size and bottom inset.
    private var maxContentOffsetY: CGFloat {
        max(0, scrollView.contentSize.height - bounds.height + scrollView.contentInset.bottom)
    }

    private func refreshContentSize() {
        let size = resolvedContentSize()
        scrollView.contentSize = size
        contentView.frame = CGRect(origin: .zero, size: size)
        applyInitialNewestViewportIfNeeded(contentSize: size)
    }

    private func applyInitialNewestViewportIfNeeded(contentSize: CGSize) {
        guard needsInitialNewestViewport,
              bounds.width > 0,
              bounds.height > 0,
              !itemUIDs.isEmpty
        else { return }

        let bottomY = maxContentOffsetY
        isApplyingProgrammaticScroll = true
        scrollView.setContentOffset(CGPoint(x: 0, y: bottomY), animated: false)
        isApplyingProgrammaticScroll = false
        needsInitialNewestViewport = false
    }

    private func resolvedContentSize() -> CGSize {
        guard bounds.width > 0, !items.isEmpty else { return bounds.size }
        let profile = currentProfile()
        let level = activeLevel(profile: profile)
        let engine = currentEngine(profile: profile)
        let content = engine.contentSize(level: level, width: bounds.width, columnPhase: committedPhase)
        return CGSize(width: max(bounds.width, content.width), height: max(bounds.height + 1, content.height))
    }

    private func activeLevel(profile: GridLevelProfile) -> Int {
        profile.clampLevel(interactiveLevel ?? levelOverride ?? profile.defaultLevel)
    }

    /// True while the user is actively scrolling, decelerating, or pinching. The shared soft→sharp upgrade path
    /// is gated OFF during interaction (so it never churns uploads and drops frames mid-gesture) and back ON once
    /// the grid settles — the mobile-appropriate scheduling of the SAME shared composer upgrade, not a fork.
    private var isInteracting: Bool {
        scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating || pinchStartLevel != nil
            || zoomTransaction != nil || commitBridgeTransaction != nil
    }

    /// The grid profile for the current layout size, rebuilt only when that size changes (never mid-scroll).
    /// The profile is a pure function of the usable layout size, so caching on it keeps a plain scroll frame
    /// from re-resolving the density ladder every vsync.
    private func currentProfile() -> GridLevelProfile {
        let layoutSize = UIKitTimelineGridProfileAdapter.layoutSize(
            forBounds: metalView.bounds, safeAreaInsets: metalView.safeAreaInsets)
        if let cachedProfile, cachedProfileLayoutSize == layoutSize { return cachedProfile }
        if cachedProfile != nil {
            committedPhase = nil
            cancelLiveZoomState()
        }
        let profile = profileAdapter.profile(for: metalView)
        cachedProfile = profile
        cachedProfileLayoutSize = layoutSize
        // A profile change can change the level ladder, so the engine keyed on it must rebuild too.
        cachedEngine = nil
        return profile
    }

    /// The canonical geometry engine for the current item count + profile, rebuilt only when either changes.
    /// A finger-scroll changes neither, so the engine (and its section arrays) is constructed once, not per frame.
    private func currentEngine(profile: GridLevelProfile) -> SquareTileGridEngine {
        if let cachedEngine, cachedEngineItemCount == items.count, cachedEngineProfileID == profile.id {
            return cachedEngine
        }
        let engine = SquareTileGridEngine(sectionCounts: [items.count], profile: profile)
        cachedEngine = engine
        cachedEngineItemCount = items.count
        cachedEngineProfileID = profile.id
        return engine
    }

    /// Arrival wake from the shared feed (a background download landed thumbnails on disk while this viewport is
    /// live). Re-warm the still-missing visible cells (decoding the new bytes disk→RAM) and redraw — this is what
    /// lets the render loop legitimately idle through a network wait instead of spinning, since an arrival always
    /// re-arms it. One-hop to the main actor; the pump coalesces the redraw to at most one frame.
    private func handleImagesAvailable() {
        warmNeedsRepass = true
        requestRender()
    }

    // MARK: - Coalesced render loop

    /// Mark the on-screen state dirty and make sure the display link is ticking. All invalidations funnel
    /// through here; actual drawing happens only in `tick`, at most once per vsync.
    private func requestRender() {
        guard isMetal3Capable else { return }
        framePump.invalidate()
        // Start the loop only when the surface can actually draw: in a window AND active (the pump gates
        // `shouldTick` on active). A hidden/inactive grid stays marked dirty, so returning re-arms it, but
        // never spins the display link while menus/other tabs are on screen.
        guard window != nil, framePump.shouldTick else { return }
        if !displayLink.isRunning {
            displayLink.start { [weak self] _ in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard framePump.shouldTick else {
            displayLink.stop()
            perf.noteLoopStopped()
            return
        }
        let outcome = renderNow()
        let keepTicking: Bool
        switch outcome {
        case .skippedNoSurface:
            // Nothing drawable yet (zero bounds / no cache) — the event that changes that (layout,
            // configure) re-requests a render, so don't spin.
            keepTicking = framePump.completeTick(presented: true, hasPendingWork: false)
        case .noDrawable:
            // Transient drawable starvation — retry next tick so content can never strand off-screen.
            keepTicking = framePump.completeTick(presented: false, hasPendingWork: false)
        case let .drawn(hasPendingWork):
            keepTicking = framePump.completeTick(presented: true, hasPendingWork: hasPendingWork)
        }
        var drawableFailed = false
        if case .noDrawable = outcome { drawableFailed = true }
        perf.noteTick(drawableFailed: drawableFailed)
        if !keepTicking {
            perf.flush(reason: "idle")
            displayLink.stop()
        }
    }

    private enum RenderOutcome {
        case skippedNoSurface
        case noDrawable
        case drawn(hasPendingWork: Bool)
    }

    @discardableResult
    private func renderNow() -> RenderOutcome {
        guard isMetal3Capable,
              bounds.width > 0,
              bounds.height > 0,
              let renderer,
              let textureCache,
              let texturePolicy
        else { return .skippedNoSurface }
        guard let target = MetalGridDrawableTarget(layer: metalView.metalLayer) else { return .noDrawable }

        let viewportSize = bounds.size
        let overscan = texturePolicy.budget.overscanFraction * viewportSize.height
        let profile = currentProfile()
        let level = activeLevel(profile: profile)
        let engine = currentEngine(profile: profile)

        if let tx = commitBridgeTransaction {
            let elapsed = max(0, CACurrentMediaTime() - commitBridgeStart)
            if elapsed < GridZoomCommitBridge.duration {
                let slots = GridZoomCommitBridge.frame(
                    transaction: tx,
                    engine: engine,
                    targetLevel: commitBridgeLevel,
                    viewportSize: viewportSize,
                    scrollY: commitBridgeScrollY,
                    overscan: overscan,
                    progress: CGFloat(elapsed / GridZoomCommitBridge.duration),
                    columnPhase: commitBridgePhase
                )
                let metrics = engine.resolvedMetrics(level: commitBridgeLevel, width: bounds.width)
                return renderSlotFrame(
                    target: target,
                    renderer: renderer,
                    textureCache: textureCache,
                    slots: slots,
                    slotSidePoints: metrics.slotSide,
                    viewportSize: viewportSize,
                    allowUpgrade: false,
                    reportFirstContent: false,
                    forcePendingWork: true
                )
            }
            commitBridgeTransaction = nil
            commitBridgeStart = 0
        }

        if let tx = zoomTransaction {
            let frame = tx.frame(continuousLevel: zoomTransactionLevel, viewportSize: viewportSize, overscan: overscan)
            return renderSlotFrame(
                target: target,
                renderer: renderer,
                textureCache: textureCache,
                slots: frame.visibleSlots,
                slotSidePoints: frame.slotSide,
                viewportSize: viewportSize,
                allowUpgrade: false,
                reportFirstContent: false,
                forcePendingWork: false
            )
        }

        let plan = engine.framePlan(
            level: level,
            viewportSize: viewportSize,
            scrollOffset: scrollView.contentOffset,
            overscan: overscan,
            columnPhase: committedPhase
        )

        let outcome = renderSlotFrame(
            target: target,
            renderer: renderer,
            textureCache: textureCache,
            slots: plan.visibleSlots.map {
                GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
            },
            slotSidePoints: plan.slotSide,
            viewportSize: viewportSize,
            allowUpgrade: !isInteracting,
            reportFirstContent: true,
            forcePendingWork: false
        )
        // Settled frames only: pre-decode the next rows in the user's travel direction (disk→RAM) so
        // resuming the scroll lands on RAM-ready tiles. Never during interaction, never over visible work.
        if !isInteracting {
            scheduleScrollAheadWarmIfIdle(plan: plan)
        }
        return outcome
    }

    private func renderSlotFrame(
        target: MetalGridDrawableTarget,
        renderer: MetalGridRenderer,
        textureCache: MetalGridTextureCache<PhotoUID>,
        slots: [GridRenderSlot],
        slotSidePoints: CGFloat,
        viewportSize: CGSize,
        allowUpgrade: Bool,
        reportFirstContent: Bool,
        forcePendingWork: Bool
    ) -> RenderOutcome {
        let uploadPixels = GridTextureUploadSizing.uploadPixels(
            slotSidePoints: slotSidePoints,
            backingScale: metalView.metalLayer.contentsScale,
            headroom: 1.15,
            floor: 64,
            cap: textureCache.maxTexturePixels
        )

        // Same universal composition sequence the macOS host uses (MetalGridFrameComposer), so a
        // streaming/rendering fix lands on both platforms at once. This host owns only the iOS plumbing:
        // the CAMetalLayer drawable, the level-aware upload size, the CADisplayLink, and the warm pump.
        let ids = MetalGridFrameComposer.classifyVisibility(
            slots: slots, flatUIDs: itemUIDs, viewportSize: viewportSize)
        let feed = thumbnailFeed
        let streamResult = MetalGridFrameComposer.stream(
            cache: textureCache,
            visibleIDs: ids.visible,
            overscanIDs: ids.overscan,
            pinOverscan: true,
            effectiveUploadPixels: uploadPixels,
            allowUpgrade: allowUpgrade,
            hasImage: { feed?.memoryCGImage(for: $0) != nil },
            canRetry: { !(feed?.isKnownUnfetchable($0) ?? false) },
            provideImage: { feed?.memoryCGImage(for: $0) }
        )
        let groups = MetalGridFrameComposer.buildGroups(
            slots: MetalGridFrameComposer.viewportDrawSlots(slots, viewportSize: viewportSize),
            flatUIDs: itemUIDs,
            cache: textureCache,
            displayMode: displayMode,
            cornerRadius: GridVisualConstants.thumbnailCornerRadius,
            decorations: productionDecorations()
        ).groups
        textureCache.evictToBudget()
        renderer.render(to: target, viewportSize: viewportSize, groups: groups)

        let missingVisible = newestFirst(
            ids.visible.filter { uid in
                !textureCache.isResident(uid) && !(feed?.isKnownUnfetchable(uid) ?? false)
            }
        )
        // First fully-populated on-screen frame → tell the shell to lift the loading UI onto a real grid.
        // One-shot per content set; deferred to the next runloop tick so it never mutates observed shell
        // state during a SwiftUI update pass (renderNow can run inside updateUIView → layoutSubviews).
        if reportFirstContent, !firstContentReported, !ids.visible.isEmpty, missingVisible.isEmpty {
            firstContentReported = true
            if let onFirstContentReady {
                DispatchQueue.main.async { onFirstContentReady() }
            }
        }
        // Warm the still-missing visible tiles (reliability) AND the composer's warm list, which — when settled —
        // adds the sources of undersized resident textures whose RAM decode was evicted, so the upgrade can
        // re-decode and sharpen instead of the loop spinning on a pending upgrade it can never satisfy. Mirrors
        // the macOS host, which warms `result.warm`.
        scheduleWarmIfNeeded(warmUnion(missingVisible, streamResult.warm), pixelSize: uploadPixels)
        // Keep ticking ONLY for work the render loop can actually make progress on this vsync: a visible tile
        // already decoded in RAM but held back by the per-frame upload budget (`uploadPending`), a soft→sharp
        // upgrade in flight, or a warm pass running. A visible tile that is still missing with NO RAM image is
        // waiting on the network/disk crawl — the feed's arrival wake (`handleImagesAvailable`) re-arms the loop
        // when its bytes land, so we idle through that wait instead of spinning full frames the whole time.
        // RAM-decoded but not yet GPU-resident (the `ramHitGpuMissing` diagnostic): these tiles can fill on
        // the very next frames within the upload budget — a persistent count means upload-budget starvation.
        let ramReadyMissing = missingVisible.reduce(into: 0) { count, uid in
            if feed?.memoryCGImage(for: uid) != nil { count += 1 }
        }
        let uploadPending = ramReadyMissing > 0
        // Residency saturation means neither a deferred upload nor a deferred upgrade can make progress until the
        // streaming window changes (scroll/zoom, which re-arm on their own), so both are gated on it — matching
        // the macOS coordinator and avoiding a spin on placeholders that cannot fill this frame.
        let canMakeProgress = !textureCache.residencySaturatedThisFrame
        let hasPendingWork = forcePendingWork
            || warmInFlight
            || ((uploadPending || streamResult.pendingVisibleQualityUpgrade) && canMakeProgress)
        perf.noteDraw(visible: ids.visible.count, missing: missingVisible.count,
                      ramHitGpuMiss: ramReadyMissing, saturated: textureCache.residencySaturatedThisFrame,
                      cache: textureCache)
        return .drawn(hasPendingWork: hasPendingWork)
    }

    /// The resolved grid geometry for the current viewport + active level, or nil when there is nothing to lay
    /// out. Built the same way `renderNow` builds it, so hit-testing and rendering never diverge.
    private func currentGridContext() -> (engine: SquareTileGridEngine, level: Int, profile: GridLevelProfile)? {
        guard bounds.width > 0, !items.isEmpty else { return nil }
        let profile = currentProfile()
        let level = activeLevel(profile: profile)
        let engine = currentEngine(profile: profile)
        return (engine, level, profile)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // A tap that merely halts a decelerating scroll must not also open/select a photo.
        guard gesture.state == .ended, !scrollView.isDecelerating, zoomTransaction == nil,
              let ctx = currentGridContext() else { return }
        // contentView spans the full content size at origin .zero, so its coordinate space IS the engine's
        // content space (y down, origin at the library top).
        let contentPoint = gesture.location(in: contentView)
        guard let slot = ctx.engine.hitTest(
            contentPoint: contentPoint,
            level: ctx.level,
            width: bounds.width,
            columnPhase: committedPhase
        ),
              slot.index >= 0, slot.index < items.count
        else { return }
        // In selection mode a tap toggles the cell (and never opens the viewer); otherwise it opens.
        if selectionMode {
            onToggleSelection?(items[slot.index])
        } else {
            onOpenPhoto?(items[slot.index])
        }
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let ctx = currentGridContext() else { return }
        let viewportPoint = gesture.location(in: self)
        switch gesture.state {
        case .began:
            commitBridgeTransaction = nil
            commitBridgeStart = 0
            pinchStartLevel = ctx.level
            pinchLockedOffsetY = scrollView.contentOffset.y
            let contentPoint = CGPoint(x: viewportPoint.x, y: viewportPoint.y + scrollView.contentOffset.y)
            zoomTransaction = ctx.engine.beginZoomTransaction(
                cursorContentPoint: contentPoint,
                viewportPoint: viewportPoint,
                level: ctx.level,
                width: bounds.width,
                columnPhase: committedPhase
            )
            zoomTransactionLevel = CGFloat(ctx.level)
            // Engage the user so the newest-bottom auto-pin never fights the zoom.
            userHasScrolledTimeline = true
            requestRender()
        case .changed:
            guard let startLevel = pinchStartLevel, zoomTransaction != nil else { return }
            let rawLevel = livePinchRawLevel(startLevel: startLevel, scale: gesture.scale)
            zoomTransactionLevel = GridLiveZoomBounds.visualLevel(rawLevel: rawLevel, levelCount: ctx.engine.levelCount)
            requestRender()
        case .ended, .cancelled, .failed:
            guard let startLevel = pinchStartLevel else {
                cancelLiveZoomState()
                requestRender()
                return
            }
            let rawLevel = livePinchRawLevel(startLevel: startLevel, scale: gesture.scale)
            let finalLevel = ctx.profile.clampLevel(Int(rawLevel.rounded()))
            if gesture.state == .ended, finalLevel != startLevel {
                commitLiveZoom(to: finalLevel, engine: ctx.engine)
            } else {
                returnLiveZoomToCurrentLevel()
            }
        default:
            break
        }
    }

    /// UIKit reports a cumulative scale; GridCore owns the shared logarithmic ladder tuning. Scale > 1 means zoom
    /// in, so the raw level moves toward lower ids.
    private func livePinchRawLevel(startLevel: Int, scale: CGFloat) -> CGFloat {
        CGFloat(startLevel) - GridPinchDensityPolicy.continuousLevelDelta(pinchScale: scale)
    }

    private func commitLiveZoom(to targetLevel: Int, engine: SquareTileGridEngine) {
        guard let tx = zoomTransaction else {
            cancelLiveZoomState()
            requestRender()
            return
        }
        let level = engine.clampLevel(targetLevel)
        let desiredColumn = engine.cursorColumn(viewportX: tx.anchorViewportPoint.x, level: level, width: bounds.width)
        let phase = engine.columnPhase(forItem: tx.anchorGlobalIndex, targetColumn: desiredColumn, level: level, width: bounds.width)
        let rawY = engine.anchoredScrollOffset(
            flatIndex: tx.anchorGlobalIndex,
            localFraction: tx.anchorLocalFraction,
            viewportPoint: tx.anchorViewportPoint,
            level: level,
            width: bounds.width,
            columnPhase: phase
        ).y
        let targetContent = engine.contentSize(level: level, width: bounds.width, columnPhase: phase)
        let targetMaxY = max(0, max(bounds.height + 1, targetContent.height) - bounds.height + scrollView.contentInset.bottom)
        let scrollY = min(max(0, rawY), targetMaxY)

        committedPhase = phase
        interactiveLevel = level
        commitBridgeTransaction = tx
        commitBridgeLevel = level
        commitBridgeScrollY = scrollY
        commitBridgePhase = phase
        commitBridgeStart = CACurrentMediaTime()
        zoomTransaction = nil
        pinchStartLevel = nil
        pinchLockedOffsetY = nil

        refreshContentSize()
        isApplyingProgrammaticScroll = true
        scrollView.setContentOffset(CGPoint(x: 0, y: scrollY), animated: false)
        isApplyingProgrammaticScroll = false
        requestRender()
    }

    private func returnLiveZoomToCurrentLevel() {
        guard let tx = zoomTransaction, let startLevel = pinchStartLevel else {
            cancelLiveZoomState()
            requestRender()
            return
        }
        let scrollY = min(max(pinchLockedOffsetY ?? scrollView.contentOffset.y, 0), maxContentOffsetY)
        commitBridgeTransaction = tx
        commitBridgeLevel = startLevel
        commitBridgeScrollY = scrollY
        commitBridgePhase = committedPhase
        commitBridgeStart = CACurrentMediaTime()
        zoomTransaction = nil
        pinchStartLevel = nil
        pinchLockedOffsetY = nil
        requestRender()
    }

    private func cancelLiveZoomState() {
        zoomTransaction = nil
        pinchStartLevel = nil
        pinchLockedOffsetY = nil
        commitBridgeTransaction = nil
        commitBridgeStart = 0
    }

    private func newestFirst(_ uids: [PhotoUID]) -> [PhotoUID] {
        uids.sorted { lhs, rhs in
            (itemIndexByUID[lhs] ?? -1) > (itemIndexByUID[rhs] ?? -1)
        }
    }

    /// The still-missing visible tiles (newest-first, reliability-critical order) followed by any additional warm
    /// UIDs the composer requested (upgrade re-decode sources), de-duplicated. A no-op-ish superset when settled
    /// is off (the composer's warm list is then just the missing tiles).
    private func warmUnion(_ missing: [PhotoUID], _ streamWarm: [PhotoUID]) -> [PhotoUID] {
        guard !streamWarm.isEmpty else { return missing }
        var out = missing
        var seen = Set(missing)
        for uid in streamWarm where seen.insert(uid).inserted { out.append(uid) }
        return out
    }

    /// The shared grid decorations for the current frame — always built, mirroring the macOS coordinator, so a
    /// video badge shows during normal browsing and the checkmark badge shows in selection mode (the composer
    /// makes the two mutually exclusive in the bottom-right corner, and the selection outline is drawn only for
    /// selected cells). The Proton primary (0x6D4AFF) is injected as neutral SIMD/glyph data at this adapter
    /// edge, keeping the composer platform-neutral.
    private func productionDecorations() -> MetalGridDecorations<PhotoUID> {
        let accent = SIMD4<Float>(Float(0x6D) / 255, Float(0x4A) / 255, Float(0xFF) / 255, 1)
        return MetalGridDecorations(
            accent: accent,
            accentGlyphColor: MetalGridGlyphColor(
                red: Double(accent.x), green: Double(accent.y), blue: Double(accent.z), alpha: 1),
            selectionMode: selectionMode,
            // Outlines belong to selection mode only; normal browsing carries an empty set so a bare grid draws
            // just thumbnails + video badges.
            selected: selectionMode ? selectedUIDs : [],
            favorites: [],
            isVideo: { [videoUIDs] uid in videoUIDs.contains(uid) }
        )
    }

    /// Pre-decode the rows just beyond the streamed window in the user's travel direction, disk→RAM, at
    /// `.nearViewportScrollAhead` priority — the shared `GridScrollAheadPolicy` range over this host's flat
    /// UID order. Strictly subordinate to visible work: it runs only on settled frames with NO visible warm
    /// pass in flight, decodes in small chunks, and aborts between chunks the moment a visible pass starts.
    /// RAM-neutral by design — it fills the EXISTING decoded budget ahead of need; no cache grows.
    private func scheduleScrollAheadWarmIfIdle(plan: GridFramePlan) {
        // Never pre-warm ahead for an inactive/hidden grid — that would decode disk→RAM off-screen while the
        // user is in another tab/menu. (renderNow only runs when active, so this is defense-in-depth.)
        guard framePump.isActive else { return }
        guard let thumbnailFeed, let down = scrollDirectionDown, !itemUIDs.isEmpty else { return }
        guard !warmInFlight, !aheadWarmInFlight else { return }
        let indices = plan.visibleSlots.map(\.index)
        guard let minIndex = indices.min(), let maxIndex = indices.max() else { return }
        let range = GridScrollAheadPolicy.aheadRange(
            coveredIndexRange: minIndex ... maxIndex,
            itemCount: itemUIDs.count,
            columns: plan.columns,
            rowsAhead: 3,
            direction: down ? .towardHigherIndices : .towardLowerIndices
        )
        guard !range.isEmpty else { return }
        let key = "\(range.lowerBound)-\(range.upperBound)-\(down)-\(plan.levelID)"
        guard key != lastAheadKey else { return }
        lastAheadKey = key
        let missing = range
            .map { itemUIDs[$0] }
            .filter { thumbnailFeed.memoryCGImage(for: $0) == nil && !thumbnailFeed.isKnownUnfetchable($0) }
        guard !missing.isEmpty else { return }
        let pixelSize = GridTextureUploadSizing.uploadPixels(
            slotSidePoints: plan.slotSide,
            backingScale: metalView.metalLayer.contentsScale,
            headroom: 1.15,
            floor: 64,
            cap: textureCache?.maxTexturePixels ?? 320
        )
        let requests = missing.map { ThumbnailRequest(uid: $0, pixelSize: pixelSize, cropMode: displayMode.rawValue) }
        aheadWarmInFlight = true
        aheadWarmTask = Task { [weak self, thumbnailFeed] in
            // Small chunks so a visible warm pass (which takes strict priority) never waits behind a long
            // ahead batch on the serial feed actor; abort the remainder the moment visible work starts.
            for chunk in stride(from: 0, to: requests.count, by: 12).map({ Array(requests[$0 ..< min($0 + 12, requests.count)]) }) {
                if Task.isCancelled { break }
                let visibleBusy = await MainActor.run { [weak self] in self?.warmInFlight ?? true }
                if visibleBusy { break }
                _ = await thumbnailFeed.warmDecoded(chunk, priority: .nearViewportScrollAhead, limit: chunk.count)
            }
            await MainActor.run { [weak self] in self?.aheadWarmInFlight = false }
        }
    }

    /// Decode the still-missing visible cells disk→RAM (queuing network for the rest), at most one pass at a time.
    ///
    /// The gate is `warmInFlight`, NOT exact-set equality: a pass is re-issued whenever the missing set changed OR
    /// `warmNeedsRepass` was raised (a feed arrival / demand move). That is what fixes "black until the user
    /// scrolls a nudge further" — under a STATIC viewport, a tile whose bytes land on disk (via the crawl worker,
    /// which only stores to disk) is re-warmed on the next pass and decoded into the RAM tier the renderer reads,
    /// instead of being permanently deduped away because the visible set never changed. On completion it redraws;
    /// if cells are still missing the next frame re-invokes this, so the fill continues to convergence.
    private func scheduleWarmIfNeeded(_ uids: [PhotoUID], pixelSize: Int) {
        guard let thumbnailFeed else { return }
        var seen = Set<PhotoUID>()
        let unique = uids.filter { seen.insert($0).inserted }
        guard !unique.isEmpty else { lastWarmIDs = []; warmNeedsRepass = false; return }
        if warmInFlight {
            // A pass is running; if demand moved, remember to re-issue once it finishes.
            if unique != lastWarmIDs { warmNeedsRepass = true }
            return
        }
        guard unique != lastWarmIDs || warmNeedsRepass else { return }
        warmNeedsRepass = false
        lastWarmIDs = unique
        warmInFlight = true
        warmGeneration &+= 1
        let generation = warmGeneration
        let requests = unique.map { ThumbnailRequest(uid: $0, pixelSize: pixelSize, cropMode: displayMode.rawValue) }
        warmTask = Task { [weak self, thumbnailFeed] in
            _ = await thumbnailFeed.warmDecoded(requests, priority: .visibleNow, limit: max(1, requests.count))
            await MainActor.run {
                guard let self, self.warmGeneration == generation else { return }
                self.warmInFlight = false
                // Redraw to upload whatever decoded; renderNow re-invokes this for any cells still missing.
                self.requestRender()
            }
        }
    }
}

extension UIKitTimelineGridHostView: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if let lockedY = pinchLockedOffsetY {
            let clamped = min(max(lockedY, 0), maxContentOffsetY)
            if abs(scrollView.contentOffset.y - clamped) > 0.5 {
                isApplyingProgrammaticScroll = true
                scrollView.setContentOffset(CGPoint(x: 0, y: clamped), animated: false)
                isApplyingProgrammaticScroll = false
            }
            requestRender()
            return
        }
        if !isApplyingProgrammaticScroll,
           scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
            userHasScrolledTimeline = true
            // Learn the travel direction from real finger scrolls only (drives the settled ahead-warm).
            let dy = scrollView.contentOffset.y - lastScrollY
            if abs(dy) > 1 { scrollDirectionDown = dy > 0 }
        }
        lastScrollY = scrollView.contentOffset.y
        // Scroll deltas arrive faster than vsync — mark dirty only; the display link draws exactly once
        // per frame with whatever offset is current by then.
        perf.noteScrollEvent()
        requestRender()
    }

    // Re-arm a render the moment the grid SETTLES (drag ended without deceleration, deceleration finished, or a
    // programmatic scroll animation completed). `renderNow` then runs a frame with `isInteracting == false`, so
    // the shared soft→sharp upgrade path (gated off during the gesture) runs and undersized visible tiles sharpen.
    public func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { requestRender() }
    }

    public func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        requestRender()
    }

    public func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        requestRender()
    }
}

extension UIKitTimelineGridHostView: UIGestureRecognizerDelegate {
    /// Let tap / pinch coexist with the scroll view's own pan (and each other) — a two-finger pinch and a
    /// one-finger scroll never contend, and a tap requires no movement.
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}

// MARK: - Low-noise render diagnostics

/// One-second aggregation window for the render loop, logged at `.notice` so a plain `log stream` capture (no
/// `--level debug`) separates render/upload/upgrade/warm work — one concise line per second WHILE the loop runs,
/// silent when idle. It answers the perf questions directly: how many input events were coalesced into how many
/// draws, whether drawable acquisition ever failed, and what the streaming pipeline did (uploads / deferrals /
/// in-place quality upgrades / residency).
@MainActor
private struct RenderPerfWindow {
    private static let logger = Logger(subsystem: "me.protonphotos.ios", category: "MobileGridPerf")

    private var windowStart: CFTimeInterval = 0
    private var scrollEvents = 0
    private var ticks = 0
    private var draws = 0
    private var drawableFailures = 0
    private var uploads = 0
    private var uploadMs: Double = 0
    private var deferredUploads = 0
    private var upgrades = 0
    private var lastVisible = 0
    private var lastMissing = 0
    private var lastResidentBytes = 0
    private var lastResidentCapBytes = 0
    /// Frames this window in which the resident byte/count budget refused an upload (residency saturation).
    private var saturatedDraws = 0
    /// Last frame's RAM-decoded-but-not-GPU-resident visible count (`ramHitGpuMissing`).
    private var lastRamHitGpuMiss = 0
    /// Timestamp of the previous tick, and how many inter-tick gaps this window exceeded ~2 frames (33 ms) —
    /// a cheap proxy for a visible render-loop hitch. Reset to 0 when the loop stops so a resume after an
    /// idle stretch is never counted as one giant gap.
    private var lastTickAt: CFTimeInterval = 0
    private var hitches = 0
    private var maxGapMs: Double = 0

    mutating func noteScrollEvent() {
        scrollEvents += 1
    }

    /// The loop stopped (idle or suspended) — forget the last tick time so the next run's first gap is not
    /// measured against a stale timestamp.
    mutating func noteLoopStopped() {
        lastTickAt = 0
    }

    mutating func noteDraw<ID>(visible: Int, missing: Int, ramHitGpuMiss: Int, saturated: Bool,
                               cache: MetalGridTextureCache<ID>?) {
        draws += 1
        lastVisible = visible
        lastMissing = missing
        lastRamHitGpuMiss = ramHitGpuMiss
        if saturated { saturatedDraws += 1 }
        if let cache {
            uploads += cache.uploadsThisFrame
            uploadMs += cache.uploadMsThisFrame
            deferredUploads += cache.deferredUploadsThisFrame
            upgrades += cache.upgradesThisFrame
            lastResidentBytes = cache.residentBytes
            lastResidentCapBytes = cache.residentByteBudget
        }
    }

    mutating func noteTick(drawableFailed: Bool) {
        ticks += 1
        if drawableFailed { drawableFailures += 1 }
        let now = CACurrentMediaTime()
        if lastTickAt != 0 {
            let gapMs = (now - lastTickAt) * 1000
            if gapMs > 33 { hitches += 1; maxGapMs = max(maxGapMs, gapMs) }
        }
        lastTickAt = now
        if windowStart == 0 { windowStart = now }
        if now - windowStart >= 1.0 {
            flush(reason: "window")
            windowStart = now
        }
    }

    mutating func flush(reason: String) {
        guard ticks > 0 else { return }
        let (t, d, s, f) = (ticks, draws, scrollEvents, drawableFailures)
        let (u, um, du, up) = (uploads, String(format: "%.2f", uploadMs), deferredUploads, upgrades)
        let (vis, mis, mb) = (lastVisible, lastMissing, lastResidentBytes / 1_048_576)
        let (capMB, sat, ramGpu) = (lastResidentCapBytes / 1_048_576, saturatedDraws, lastRamHitGpuMiss)
        let (hit, gap) = (hitches, String(format: "%.0f", maxGapMs))
        Self.logger.notice("""
        [MobileGridPerf] \(reason, privacy: .public) ticks=\(t) draws=\(d) scrollEvents=\(s) \
        drawableFail=\(f) uploads=\(u) uploadMs=\(um, privacy: .public) deferred=\(du) upgrades=\(up) \
        visible=\(vis) missing=\(mis) ramGpuMiss=\(ramGpu) residentMB=\(mb)/\(capMB) saturated=\(sat) \
        hitches=\(hit) maxGapMs=\(gap, privacy: .public)
        """)
        // A visible hitch during grid activity gets its own low-noise [UIHitch] line (1 s throttled via the
        // window) so a `log stream` filtered to [UIHitch] shows both tab transitions AND grid frame stalls.
        if hitches > 0 {
            UIHitchLog.frameGap(hitches: hitches, maxGapMs: maxGapMs, ticks: ticks, draws: draws)
        }
        scrollEvents = 0
        ticks = 0
        draws = 0
        drawableFailures = 0
        uploads = 0
        uploadMs = 0
        deferredUploads = 0
        upgrades = 0
        saturatedDraws = 0
        hitches = 0
        maxGapMs = 0
    }
}

// MARK: - UI hitch diagnostics

/// Low-noise `[UIHitch]` diagnostics for menu/tab smoothness: emits only on grid ACTIVITY transitions and,
/// at most once per second, when the render loop measured a frame gap over ~2 frames. It never logs per
/// frame. The app shell emits its own `[UIHitch] tab=…` line on tab changes (same category), so a single
/// `log stream --predicate 'category == "UIHitch"'` shows the whole interaction picture.
@MainActor
enum UIHitchLog {
    private static let logger = Logger(subsystem: "me.protonphotos.ios", category: "UIHitch")

    static func gridActivity(active: Bool, hasWindow: Bool, displayLinkRunning: Bool,
                             warmInFlight: Bool, aheadWarmInFlight: Bool, items: Int) {
        logger.notice("""
        [UIHitch] event=gridActivity gridActive=\(active) window=\(hasWindow) \
        displayLink=\(displayLinkRunning) warmInFlight=\(warmInFlight) aheadWarm=\(aheadWarmInFlight) \
        items=\(items)
        """)
    }

    static func frameGap(hitches: Int, maxGapMs: Double, ticks: Int, draws: Int) {
        logger.notice("""
        [UIHitch] event=gridFrameGap hitches=\(hitches) maxGapMs=\(String(format: "%.0f", maxGapMs), privacy: .public) \
        ticks=\(ticks) draws=\(draws)
        """)
    }
}
#endif
