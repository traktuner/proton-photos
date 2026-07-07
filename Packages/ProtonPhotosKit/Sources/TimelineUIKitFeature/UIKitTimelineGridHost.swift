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
    private let fillOrder: GridFillOrder
    private let initialViewportPlacement: TimelineInitialViewportPlacement
    private let displayMode: TileContentDisplayMode
    private let selectionMode: Bool
    private let selectedUIDs: Set<PhotoUID>
    /// Whether this grid's surface is the active one (its tab is selected). When false the host stops its
    /// display link and cancels ahead-warm so a hidden grid never competes with menus/transitions on screen;
    /// defaults to true so a grid that is always visible (e.g. a pushed collection detail) behaves as before.
    private let isActive: Bool
    /// A monotonically-bumped signal from the shell: whenever it changes, the grid scrolls to the newest
    /// photos. Drives the "retap the active Fotos tab → jump to newest" gesture without any scroll math leaking
    /// out of the host. Compared against a `Coordinator`-remembered last value so a steady stream of identical
    /// update passes is free.
    private let scrollToLatestSignal: Int
    private let onFirstContentReady: (() -> Void)?
    private let onOpenPhoto: ((PhotoItem) -> Void)?
    private let onToggleSelection: ((PhotoItem) -> Void)?
    private let onDragSelectionChanged: ((Set<PhotoUID>) -> Void)?

    public init(
        items: [PhotoItem],
        thumbnailFeed: UIKitThumbnailFeed,
        level: Int? = nil,
        fillOrder: GridFillOrder = .newestBottomTrailing,
        initialViewportPlacement: TimelineInitialViewportPlacement = .automatic,
        displayMode: TileContentDisplayMode = .squareFillCrop,
        selectionMode: Bool = false,
        selectedUIDs: Set<PhotoUID> = [],
        isActive: Bool = true,
        scrollToLatestSignal: Int = 0,
        onFirstContentReady: (() -> Void)? = nil,
        onOpenPhoto: ((PhotoItem) -> Void)? = nil,
        onToggleSelection: ((PhotoItem) -> Void)? = nil,
        onDragSelectionChanged: ((Set<PhotoUID>) -> Void)? = nil
    ) {
        self.items = items
        self.thumbnailFeed = thumbnailFeed
        self.level = level
        self.fillOrder = fillOrder
        self.initialViewportPlacement = initialViewportPlacement
        self.displayMode = displayMode
        self.selectionMode = selectionMode
        self.selectedUIDs = selectedUIDs
        self.isActive = isActive
        self.scrollToLatestSignal = scrollToLatestSignal
        self.onFirstContentReady = onFirstContentReady
        self.onOpenPhoto = onOpenPhoto
        self.onToggleSelection = onToggleSelection
        self.onDragSelectionChanged = onDragSelectionChanged
    }

    /// Remembers the last applied scroll-to-latest signal, so the representable acts only on a real change
    /// (SwiftUI's update-diffing idiom) — never re-scrolling on an unrelated update pass.
    public final class Coordinator {
        var lastScrollToLatestSignal: Int

        init(initialScrollSignal: Int) {
            lastScrollToLatestSignal = initialScrollSignal
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(initialScrollSignal: scrollToLatestSignal)
    }

    @MainActor
    public func makeUIView(context: Context) -> UIKitTimelineGridHostView {
        let view = UIKitTimelineGridHostView()
        view.onFirstContentReady = onFirstContentReady
        view.onOpenPhoto = onOpenPhoto
        view.onToggleSelection = onToggleSelection
        view.onDragSelectionChanged = onDragSelectionChanged
        view.configure(items: items, thumbnailFeed: thumbnailFeed, level: level, fillOrder: fillOrder,
                       initialViewportPlacement: initialViewportPlacement, displayMode: displayMode,
                       selectionMode: selectionMode, selectedUIDs: selectedUIDs)
        view.setActive(isActive)
        return view
    }

    @MainActor
    public func updateUIView(_ uiView: UIKitTimelineGridHostView, context: Context) {
        uiView.onFirstContentReady = onFirstContentReady
        uiView.onOpenPhoto = onOpenPhoto
        uiView.onToggleSelection = onToggleSelection
        uiView.onDragSelectionChanged = onDragSelectionChanged
        uiView.configure(items: items, thumbnailFeed: thumbnailFeed, level: level, fillOrder: fillOrder,
                         initialViewportPlacement: initialViewportPlacement, displayMode: displayMode,
                         selectionMode: selectionMode, selectedUIDs: selectedUIDs)
        uiView.setActive(isActive)
        // Retap of the active Fotos tab bumped the signal → scroll to the newest photos. Diffed against the
        // coordinator's last value so this fires once per retap, never on an unrelated update pass.
        if scrollToLatestSignal != context.coordinator.lastScrollToLatestSignal {
            context.coordinator.lastScrollToLatestSignal = scrollToLatestSignal
            uiView.scrollToLatest()
        }
    }
}

@MainActor
public final class UIKitTimelineGridHostView: UIView {
    private static let gridClearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

    let metalView = UIKitTimelineMetalHostView()
    let scrollView = UIScrollView()
    private let contentView = UIView()
    private let profileAdapter = UIKitTimelineGridProfileAdapter()
    private let displayLink = UIKitTimelineDisplayLinkDriver()

    private var device: MTLDevice?
    var renderer: MetalGridRenderer?
    var textureCache: MetalGridTextureCache<PhotoUID>?
    var texturePolicy: UIKitMetalGridTexturePolicy?
    var thumbnailFeed: UIKitThumbnailFeed?
    private var items: [PhotoItem] = []
    /// Flat UID order for the current items, cached so the per-frame composer input never re-maps the library.
    var itemUIDs: [PhotoUID] = []
    var itemIndexByUID: [PhotoUID: Int] = [:]
    private var levelOverride: Int?
    /// The user-driven density level set by pinch. Takes precedence over the profile default so pinch survives
    /// item refreshes; cleared when an explicit external `level` arrives. `nil` → profile default (data-driven).
    var interactiveLevel: Int?
    /// The level captured at pinch-gesture start (the cumulative-scale reference).
    var pinchStartLevel: Int?
    /// Engine-owned live pinch transaction. This mirrors the macOS grid path at the Core boundary: the item under
    /// the fingers is captured once, then every live frame is resolved by `GridZoomTransaction` instead of discrete
    /// per-change reflow.
    var zoomTransaction: GridZoomTransaction?
    var zoomTransactionLevel: CGFloat = 0
    var pinchLockedOffsetY: CGFloat?
    /// Optional cursor-aligned column phase committed after a live pinch. Settled iOS layout must use it everywhere
    /// the macOS layout does (rendering, hit-testing, content size), or the release seam can jump horizontally.
    var committedPhase: Int?
    var commitBridgeTransaction: GridZoomTransaction?
    var commitBridgeLevel = 0
    var commitBridgeScrollY: CGFloat = 0
    var commitBridgePhase: Int?
    var commitBridgeStart: CFTimeInterval = 0
    /// Same shared presentation lattice macOS uses for focus-row levels. iOS owns only gesture/lifecycle
    /// plumbing; GridCore owns the reversible alpha/geometry plan so photos crossfade instead of popping.
    var gridTransition = GridTransitionController()
    var pinchDriver = PinchLiveZoomDriver()
    enum PinchMode { case undecided, lattice, reflow, overviewDissolve }
    var pinchMode: PinchMode = .undecided
    var pinchSettling = false
    var pinchBuiltSegment: (Int, Int)?
    var pinchChainBand: (lo: Int, hi: Int) = (0, 0)
    var pinchPrevSampleTime: CFTimeInterval = 0
    var pinchAdvancePrevTime: CFTimeInterval = 0
    var pinchOverviewSource = 0
    var pinchOverviewTarget = 0
    var pinchOverviewQ: Double = 0
    var pinchOverviewSettleFrom: Double = 0
    var pinchOverviewSettleTo: Double = 0
    var pinchOverviewSettleStart: CFTimeInterval = 0
    let pinchOverviewSettleDuration: CFTimeInterval = 0.16
    var overviewDissolve: OverviewLayerDissolvePlan?
    var displayMode: TileContentDisplayMode = .squareFillCrop
    private var fillOrder: GridFillOrder = .newestBottomTrailing
    /// Selection state, mirrored from SwiftUI each `configure`. In selection mode a tap toggles a cell instead of
    /// opening it, and the grid draws the shared selection decorations (blue outline + checkmark badge).
    var selectionMode = false
    var selectedUIDs: Set<PhotoUID> = []
    /// Cached video-UID set for the video badge decoration, rebuilt only when the item set changes.
    private var videoUIDs: Set<PhotoUID> = []

    // MARK: - Drag selection (selection-mode finger drag)
    /// True once a long-press-and-drag selection is under way.
    private var dragActive = false
    /// The item index the drag started on (the range's fixed end).
    private var dragAnchorIndex: Int?
    /// Whether the drag ADDS to (true) or REMOVES from (false) the selection — decided from the anchor cell's
    /// membership at drag start, the iOS Photos convention.
    private var dragSelecting = true
    /// The selection the drag started from; every move recomputes the swept range against THIS base, so pulling
    /// the finger back reverts the cells it left.
    private var dragBaseSelection: Set<PhotoUID> = []
    /// The live, in-progress selection. While non-nil it drives the selection decorations INSTEAD of
    /// `selectedUIDs`, so a drag redraws by re-rendering the Metal grid — never by pushing state through SwiftUI
    /// every frame (which would rebuild the hosting screen's body per move).
    private var dragLiveSelection: Set<PhotoUID>?
    /// The last item index resolved under the finger; kept when the finger is momentarily in an inter-row gap so
    /// the swept range never collapses mid-drag.
    private var dragCurrentIndex: Int?
    /// The finger's last position in viewport space, so an auto-scroll tick (finger stationary, content moving)
    /// re-resolves the item under it against the new content offset — no skipped rows.
    private var dragLastViewportPoint: CGPoint = .zero
    /// Dedicated driver for the edge auto-scroll ramp — SEPARATE from the render `displayLink` (whose driver
    /// stops itself on re-start), so auto-scrolling the selection never stops the render loop.
    private let autoScrollLink = UIKitTimelineDisplayLinkDriver()
    private var autoScrollLastTimestamp: CFTimeInterval = 0
    /// The edge band thickness and max ramp speed for drag-select auto-scroll (points, points/second).
    private static let autoScrollEdgeInset: CGFloat = 96
    private static let autoScrollMaxSpeed: CGFloat = 1400
    var warmTask: Task<Void, Never>?
    var lastWarmIDs: [PhotoUID] = []
    /// Scroll-direction-biased prefetch (shared `GridScrollAheadPolicy`): the user's last vertical travel
    /// direction, learned from finger scrolls only (`nil` until the first real scroll — no direction, no
    /// ahead-warm). Reset when the content set changes.
    var scrollDirectionDown: Bool?
    private var lastScrollY: CGFloat = 0
    /// One ahead-warm at a time, keyed by (range, direction, level) so a settled static viewport never
    /// re-issues the same prefetch. RAM-neutral: it decodes into the existing budgets at
    /// `.nearViewportScrollAhead` priority and never runs while visible warm work is pending.
    var aheadWarmTask: Task<Void, Never>?
    var aheadWarmInFlight = false
    var lastAheadKey = ""
    /// True while a `warmDecoded` pass is running, so passes never stack. Replaces the old exact-set dedup as the
    /// re-warm gate: a still-missing visible set is re-warmed on the next pass whenever the set changed OR
    /// `warmNeedsRepass` was raised (an arrival / demand move), so a tile that lands on disk under a STATIC
    /// viewport is decoded disk→RAM without needing a scroll nudge.
    var warmInFlight = false
    /// Monotonic id for the in-flight warm pass. A pass's completion only mutates `warmInFlight` when its id is
    /// still current, so a stale pass cancelled by a detach can never clear the flag out from under a newer pass
    /// (which would briefly permit two overlapping warms right after a tab re-attach).
    var warmGeneration = 0
    /// Raised by the feed's arrival wake (a download landed on disk) or when demand moved mid-pass: the next warm
    /// must re-issue even if the visible set is unchanged, so the just-arrived bytes get decoded to RAM.
    var warmNeedsRepass = false
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
    private var cachedEngineFillOrder: GridFillOrder = .newestBottomTrailing
    private var initialViewportPlacement: TimelineInitialViewportPlacement = .automatic
    private var needsInitialViewportPlacement = true
    var userHasScrolledTimeline = false
    var isApplyingProgrammaticScroll = false
    /// One-shot per content set: fires once the first fully-populated on-screen frame is drawn (every visible
    /// cell resident or unfetchable), mirroring the macOS coordinator. Reset when a new non-empty UID set lands.
    private var firstContentReported = false

    /// Coalesces every invalidation (scroll deltas, new items, layout, arrived thumbnails) into at most ONE
    /// render per display-link tick. Rendering directly from scroll events acquires a drawable per touch delta —
    /// the 3-deep CAMetalLayer pool exhausts within a frame and `nextDrawable()` then blocks the main thread,
    /// which is exactly the scroll stutter this replaces. The pump also retries after a failed present, so a
    /// transiently unavailable drawable (fresh mount, tab re-attach) can never strand a black grid until the
    /// next scroll event.
    var framePump = GridFramePump()
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

    /// Called on the main actor when a finger-drag selection COMMITS (the gesture ends), with the resulting UID
    /// set. The shell writes it to its selection state ONCE per drag — never per frame — so a drag never triggers
    /// a per-frame SwiftUI rebuild.
    public var onDragSelectionChanged: ((Set<PhotoUID>) -> Void)?

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
        fillOrder: GridFillOrder = .newestBottomTrailing,
        initialViewportPlacement: TimelineInitialViewportPlacement = .automatic,
        displayMode: TileContentDisplayMode = .squareFillCrop,
        selectionMode: Bool = false,
        selectedUIDs: Set<PhotoUID> = []
    ) {
        self.selectionMode = selectionMode
        self.selectedUIDs = selectedUIDs
        // SwiftUI re-runs configure on EVERY update pass of the hosting screen (selection taps, sheet/cover
        // presentation, load-state flips), almost always re-passing the same snapshot array — Array's `==`
        // then short-circuits on storage identity, skipping the per-pass UID re-map. Full CONTENT equality
        // (not UID equality) is the skip test on purpose: items can be re-published with stable UIDs but
        // enriched metadata (tags, burst members), and those passes must fall through to refresh `items`.
        let uidsChanged: Bool
        if items == self.items {
            uidsChanged = false
        } else {
            let newUIDs = items.map(\.uid)
            uidsChanged = itemUIDs != newUIDs
            self.items = items
            self.itemUIDs = newUIDs
        }
        let shouldPlaceInitialViewport = uidsChanged && !itemUIDs.isEmpty && !userHasScrolledTimeline
        self.thumbnailFeed = thumbnailFeed
        if fillOrder != self.fillOrder {
            self.fillOrder = fillOrder
            committedPhase = nil
            cachedEngine = nil
            needsInitialViewportPlacement = true
            userHasScrolledTimeline = false
        }
        if initialViewportPlacement != self.initialViewportPlacement {
            self.initialViewportPlacement = initialViewportPlacement
            needsInitialViewportPlacement = true
            userHasScrolledTimeline = false
        }
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
                itemUIDs.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { _, latest in latest }
            )
            videoUIDs = Set(items.filter(\.isVideo).map(\.uid))
            lastWarmIDs = []
            scrollDirectionDown = nil
            lastAheadKey = ""
            if !itemUIDs.isEmpty {
                // A new content set must report its own first drawn frame.
                firstContentReported = false
            }
            if shouldPlaceInitialViewport {
                needsInitialViewportPlacement = true
            } else if itemUIDs.isEmpty {
                needsInitialViewportPlacement = true
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
        cancelDragSelectIfActive()   // never leave an edge auto-scroll driver running off-screen / off-tab
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
        backgroundColor = .black

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

        // Selection-mode finger drag: hold a photo, then drag across cells to select a contiguous range, with
        // edge auto-scroll. It only begins in selection mode (`gestureRecognizerShouldBegin`), so normal scroll,
        // tap-to-open, and pinch are untouched otherwise; once it begins it disables scroll for the drag so the
        // one finger selects instead of scrolling.
        let dragSelect = UILongPressGestureRecognizer(target: self, action: #selector(handleDragSelect(_:)))
        dragSelect.minimumPressDuration = 0.18
        dragSelect.delegate = self
        scrollView.addGestureRecognizer(dragSelect)
    }

    private func configureMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            isMetal3Capable = false
            return
        }
        isMetal3Capable = UIKitTimelineMetalCapability.supportsTimelineGrid(device: device)
        guard isMetal3Capable else { return }
        self.device = device
        renderer = MetalGridRenderer(device: device, clearColor: Self.gridClearColor)
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
    /// ALSO adds a TOP inset equal to safeAreaInsets.top so the first row rests below the navigation bar
    /// instead of being covered by it.
    private func applyContentInsets() {
        let top = safeAreaInsets.top
        let bottom = safeAreaInsets.bottom
        if scrollView.contentInset.top != top || scrollView.contentInset.bottom != bottom {
            scrollView.contentInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        }
        scrollView.verticalScrollIndicatorInsets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
    }

    /// The largest valid vertical content offset given the current content size and bottom inset.
    var maxContentOffsetY: CGFloat {
        max(0, scrollView.contentSize.height - bounds.height + scrollView.contentInset.bottom)
    }

    func refreshContentSize() {
        let size = resolvedContentSize()
        scrollView.contentSize = size
        contentView.frame = CGRect(origin: .zero, size: size)
        applyInitialViewportPlacementIfNeeded(contentSize: size)
    }

    private func applyInitialViewportPlacementIfNeeded(contentSize: CGSize) {
        guard needsInitialViewportPlacement,
              bounds.width > 0,
              bounds.height > 0,
              !itemUIDs.isEmpty
        else { return }

        // When the content fits within one screen (few photos — e.g. a small map cluster), there is no
        // real scroll room: `resolvedContentSize` floors the height to `bounds.height + 1`, so
        // `maxContentOffsetY` is a ~1pt phantom that would scroll the first row UP under the navigation
        // bar. Rest at `-safeAreaInsets.top` instead so the first row sits just below the bar. Only when
        // the content genuinely overflows do we scroll to the newest (bottom) row.
        let fitsOnScreen = contentSize.height <= bounds.height + 1
        let targetY: CGFloat
        if fitsOnScreen {
            targetY = -safeAreaInsets.top
        } else {
            targetY = initialViewportOpensAtNewest ? maxContentOffsetY : -safeAreaInsets.top
        }
        isApplyingProgrammaticScroll = true
        scrollView.setContentOffset(CGPoint(x: 0, y: targetY), animated: false)
        isApplyingProgrammaticScroll = false
        needsInitialViewportPlacement = false
    }

    private var initialViewportOpensAtNewest: Bool {
        switch initialViewportPlacement {
        case .automatic:
            return fillOrder == .newestBottomTrailing
        case .newest:
            return true
        case .oldest:
            return false
        }
    }

    /// Scrolls the timeline to the newest photos — the bottom-anchored final row — for the "retap the active
    /// Fotos tab" gesture. A pure `contentOffset` move that reuses the SAME bottom math as the initial newest
    /// viewport: it touches neither the density level, the selection, nor the item set, so it can never reload
    /// or reset the grid. Bracketed by `isApplyingProgrammaticScroll` (matching every other programmatic
    /// scroll here); an animated scroll is additionally exempt from user-scroll learning because it sets none
    /// of isTracking/isDragging/isDecelerating. A no-op when already at the newest row, so retapping at the
    /// bottom never jitters.
    public func scrollToLatest(animated: Bool = true) {
        guard window != nil, bounds.height > 0, !itemUIDs.isEmpty else { return }
        let target = maxContentOffsetY
        guard abs(scrollView.contentOffset.y - target) > 0.5 else { return }
        isApplyingProgrammaticScroll = true
        scrollView.setContentOffset(CGPoint(x: 0, y: target), animated: animated)
        isApplyingProgrammaticScroll = false
        requestRender()
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
            || gridTransition.isActive || overviewDissolve != nil || pinchSettling
    }

    /// The grid profile for the current layout size, rebuilt only when that size changes (never mid-scroll).
    /// The profile is a pure function of the usable layout size, so caching on it keeps a plain scroll frame
    /// from re-resolving the density ladder every vsync.
    func currentProfile() -> GridLevelProfile {
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
    func currentEngine(profile: GridLevelProfile) -> SquareTileGridEngine {
        if let cachedEngine, cachedEngineItemCount == items.count, cachedEngineProfileID == profile.id,
           cachedEngineFillOrder == fillOrder {
            return cachedEngine
        }
        let engine = SquareTileGridEngine(sectionCounts: [items.count], profile: profile, fillOrder: fillOrder)
        cachedEngine = engine
        cachedEngineItemCount = items.count
        cachedEngineProfileID = profile.id
        cachedEngineFillOrder = fillOrder
        return engine
    }

    // MARK: - Coalesced render loop

    /// Mark the on-screen state dirty and make sure the display link is ticking. All invalidations funnel
    /// through here; actual drawing happens only in `tick`, at most once per vsync.
    func requestRender() {
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
        advancePinchSettleIfNeeded()
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
        guard let target = MetalGridDrawableTarget(layer: metalView.metalLayer, clearColor: Self.gridClearColor) else {
            return .noDrawable
        }

        let viewportSize = bounds.size
        let overscan = texturePolicy.budget.overscanFraction * viewportSize.height
        let profile = currentProfile()
        let level = activeLevel(profile: profile)
        let engine = currentEngine(profile: profile)

        if let dissolve = overviewDissolve {
            return renderOverviewDissolve(
                target: target,
                renderer: renderer,
                textureCache: textureCache,
                plan: dissolve,
                viewportSize: viewportSize
            )
        }

        if gridTransition.isActive {
            return renderTransitionFrame(
                target: target,
                renderer: renderer,
                textureCache: textureCache,
                viewportSize: viewportSize
            )
        }

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
            slots: renderSlots(from: plan.visibleSlots),
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

    private func renderTransitionFrame(
        target: MetalGridDrawableTarget,
        renderer: MetalGridRenderer,
        textureCache: MetalGridTextureCache<PhotoUID>,
        viewportSize: CGSize
    ) -> RenderOutcome {
        let draws = gridTransition.currentDraws()
        guard !draws.isEmpty else { return .drawn(hasPendingWork: false) }
        let slotSide = draws.reduce(CGFloat(64)) { partial, draw in
            max(partial, max(draw.rect.width, draw.rect.height))
        }
        let uids = uniqueUIDs(draws.compactMap { draw -> PhotoUID? in
            draw.index >= 0 && draw.index < itemUIDs.count ? itemUIDs[draw.index] : nil
        })
        streamTransitionTextures(uids: uids, slotSidePoints: slotSide, textureCache: textureCache)
        let groups = transitionGroups(draws: draws, textureCache: textureCache, displayMode: displayMode)
        textureCache.evictToBudget()
        renderer.render(to: target, viewportSize: viewportSize, groups: groups)
        return finishTransitionDraw(uids: uids, slotSidePoints: slotSide, textureCache: textureCache)
    }

    /// Shared tail of every transition/dissolve frame: warm the still-missing tiles at the transition's
    /// upload size, record the draw, and keep ticking only while settle/warm/upload progress is possible.
    private func finishTransitionDraw(
        uids: [PhotoUID],
        slotSidePoints: CGFloat,
        textureCache: MetalGridTextureCache<PhotoUID>
    ) -> RenderOutcome {
        let feed = thumbnailFeed
        let missing = newestFirst(uids.filter { uid in
            !textureCache.isResident(uid) && !(feed?.isKnownUnfetchable(uid) ?? false)
        })
        scheduleWarmIfNeeded(missing, pixelSize: transitionUploadPixels(slotSidePoints: slotSidePoints, textureCache: textureCache))
        let ramReadyMissing = missing.reduce(into: 0) { count, uid in
            if feed?.memoryCGImage(for: uid) != nil { count += 1 }
        }
        perf.noteDraw(visible: uids.count, missing: missing.count,
                      ramHitGpuMiss: ramReadyMissing, saturated: textureCache.residencySaturatedThisFrame,
                      cache: textureCache)
        return .drawn(hasPendingWork: pinchSettling || warmInFlight || ramReadyMissing > 0)
    }

    private func renderOverviewDissolve(
        target: MetalGridDrawableTarget,
        renderer: MetalGridRenderer,
        textureCache: MetalGridTextureCache<PhotoUID>,
        plan: OverviewLayerDissolvePlan,
        viewportSize: CGSize
    ) -> RenderOutcome {
        let sourceSlots = renderSlots(from: plan.source.visibleSlots)
        let targetSlots = renderSlots(from: plan.target.visibleSlots)
        let allSlots = sourceSlots + targetSlots
        let uids = uniqueUIDs(allSlots.compactMap { slot -> PhotoUID? in
            slot.index >= 0 && slot.index < itemUIDs.count ? itemUIDs[slot.index] : nil
        })
        let slotSide = allSlots.reduce(CGFloat(64)) { partial, slot in
            max(partial, max(slot.rect.width, slot.rect.height))
        }
        let sourceResidentBefore = residentSlotCount(sourceSlots, textureCache: textureCache)
        let targetResidentBefore = residentSlotCount(targetSlots, textureCache: textureCache)
        streamTransitionTextures(uids: uids, slotSidePoints: slotSide, textureCache: textureCache)
        let sourceResidentAfter = residentSlotCount(sourceSlots, textureCache: textureCache)
        let targetResidentAfter = residentSlotCount(targetSlots, textureCache: textureCache)
        textureCache.evictToBudget()
        renderer.renderLayerDissolve(
            to: target,
            viewportSize: viewportSize,
            redrawSource: sourceResidentAfter != sourceResidentBefore,
            redrawTarget: targetResidentAfter != targetResidentBefore,
            sourceGroups: {
                MetalGridFrameComposer.buildGroups(
                    slots: MetalGridFrameComposer.viewportDrawSlots(sourceSlots, viewportSize: viewportSize),
                    flatUIDs: itemUIDs,
                    cache: textureCache,
                    displayMode: plan.sourceDisplayMode,
                    cornerRadius: GridVisualConstants.thumbnailCornerRadius,
                    decorations: productionDecorations()
                ).groups
            },
            targetGroups: {
                MetalGridFrameComposer.buildGroups(
                    slots: MetalGridFrameComposer.viewportDrawSlots(targetSlots, viewportSize: viewportSize),
                    flatUIDs: itemUIDs,
                    cache: textureCache,
                    displayMode: plan.targetDisplayMode,
                    cornerRadius: GridVisualConstants.thumbnailCornerRadius,
                    decorations: productionDecorations()
                ).groups
            },
            t: Float(plan.targetOpacity)
        )
        return finishTransitionDraw(uids: uids, slotSidePoints: slotSide, textureCache: textureCache)
    }

    private func transitionGroups(
        draws: [GridTransitionDraw],
        textureCache: MetalGridTextureCache<PhotoUID>,
        displayMode: TileContentDisplayMode
    ) -> [MetalGridRenderGroup] {
        var quads: [MetalGridQuad] = []
        var textures: [MTLTexture] = []
        quads.reserveCapacity(draws.count)
        textures.reserveCapacity(draws.count)
        for draw in draws where draw.index >= 0 && draw.index < itemUIDs.count {
            let uid = itemUIDs[draw.index]
            guard textureCache.isResident(uid) else { continue }
            textureCache.noteUsed(uid)
            let texture = textureCache.texture(for: uid)
            let fit = TileContentFitter.fit(
                slotRect: draw.rect,
                mediaPixelSize: CGSize(width: texture.width, height: texture.height),
                displayMode: displayMode
            )
            let side = min(draw.rect.width, draw.rect.height)
            quads.append(MetalGridQuad(
                rect: fit.contentRect,
                uvMin: fit.uvMin,
                uvMax: fit.uvMax,
                radius: Float(GridCornerRadiusPolicy.radius(forSlotSidePoints: side)),
                alpha: Float(max(0, min(1, draw.alpha)))
            ))
            textures.append(texture)
        }
        return [MetalGridRenderGroup(source: .perQuadTexture(textures), quads: quads)]
    }

    private func streamTransitionTextures(
        uids: [PhotoUID],
        slotSidePoints: CGFloat,
        textureCache: MetalGridTextureCache<PhotoUID>
    ) {
        guard !uids.isEmpty else { return }
        let feed = thumbnailFeed
        let uploadPixels = transitionUploadPixels(slotSidePoints: slotSidePoints, textureCache: textureCache)
        textureCache.setEffectiveMaxTexturePixels(uploadPixels)
        textureCache.beginFrame(pinned: Set(uids))
        textureCache.uploadVisible(wanted: uids) { feed?.memoryCGImage(for: $0) }
    }

    func transitionUploadPixels(
        slotSidePoints: CGFloat,
        textureCache: MetalGridTextureCache<PhotoUID>
    ) -> Int {
        GridTextureUploadSizing.uploadPixels(
            slotSidePoints: slotSidePoints,
            backingScale: metalView.metalLayer.contentsScale,
            headroom: 1.15,
            floor: 64,
            cap: textureCache.maxTexturePixels
        )
    }

    private func renderSlots(from slots: [GridSlot]) -> [GridRenderSlot] {
        slots.map { GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect) }
    }

    private func residentSlotCount(_ slots: [GridRenderSlot], textureCache: MetalGridTextureCache<PhotoUID>) -> Int {
        slots.reduce(into: 0) { count, slot in
            guard slot.index >= 0, slot.index < itemUIDs.count else { return }
            if textureCache.isResident(itemUIDs[slot.index]) { count += 1 }
        }
    }

    func uniqueUIDs(_ uids: [PhotoUID]) -> [PhotoUID] {
        var seen = Set<PhotoUID>()
        return uids.filter { seen.insert($0).inserted }
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
            needsSharperSource: { feed?.decodedNeedsSharperSource($0, forPixels: uploadPixels) ?? false },
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
    func currentGridContext() -> (engine: SquareTileGridEngine, level: Int, profile: GridLevelProfile)? {
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

    // MARK: - Drag selection

    /// The drag-select long press begins ONLY in selection mode, so ordinary browsing (scroll, tap-to-open,
    /// pinch) is completely unaffected. Every other recognizer keeps its default. This doubles as the
    /// `UIGestureRecognizerDelegate` hook for the recognizers on the scroll view (their delegate is `self`), so
    /// it must live in the class body with `override` (it also satisfies `UIView`'s method of the same name).
    public override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer is UILongPressGestureRecognizer {
            return selectionMode
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func handleDragSelect(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began:
            beginDragSelect(contentPoint: gesture.location(in: contentView), viewportPoint: gesture.location(in: self))
        case .changed:
            updateDragSelect(contentPoint: gesture.location(in: contentView), viewportPoint: gesture.location(in: self))
        case .ended, .cancelled, .failed:
            endDragSelect()
        default:
            break
        }
    }

    private func beginDragSelect(contentPoint: CGPoint, viewportPoint: CGPoint) {
        guard selectionMode, let ctx = currentGridContext(),
              let slot = ctx.engine.hitTest(
                  contentPoint: contentPoint, level: ctx.level, width: bounds.width, columnPhase: committedPhase),
              slot.index >= 0, slot.index < itemUIDs.count
        else { return }
        dragActive = true
        dragAnchorIndex = slot.index
        dragCurrentIndex = slot.index
        dragBaseSelection = selectedUIDs
        // Unselected anchor → the drag selects; already-selected anchor → the drag deselects.
        dragSelecting = !selectedUIDs.contains(itemUIDs[slot.index])
        dragLastViewportPoint = viewportPoint
        // The one finger now selects instead of scrolling; edge auto-scroll is driven manually. A programmatic
        // contentOffset write still works while scrolling is disabled.
        scrollView.isScrollEnabled = false
        applyDragSelection()
    }

    private func updateDragSelect(contentPoint: CGPoint, viewportPoint: CGPoint) {
        guard dragActive else { return }
        dragLastViewportPoint = viewportPoint
        resolveDragIndex(contentPoint: contentPoint)
        applyDragSelection()
        updateAutoScroll(viewportY: viewportPoint.y)
    }

    /// Resolve the item index under a content-space point, clamping to the first/last item when the point is
    /// above/below all content and holding the previous index for an inter-row gap — so the swept RANGE never
    /// develops holes as the finger moves or the grid auto-scrolls.
    private func resolveDragIndex(contentPoint: CGPoint) {
        guard let ctx = currentGridContext() else { return }
        if let slot = ctx.engine.hitTest(
            contentPoint: contentPoint, level: ctx.level, width: bounds.width, columnPhase: committedPhase),
           slot.index >= 0, slot.index < itemUIDs.count {
            dragCurrentIndex = slot.index
        } else if contentPoint.y <= 0 {
            dragCurrentIndex = 0
        } else if contentPoint.y >= scrollView.contentSize.height {
            dragCurrentIndex = max(0, itemUIDs.count - 1)
        }
        // else: finger in a gap / a short final row's trailing empty cells — keep the last resolved index.
    }

    private func applyDragSelection() {
        guard let anchor = dragAnchorIndex, let current = dragCurrentIndex else { return }
        let next = GridDragRangeSelection.selection(
            base: dragBaseSelection, orderedIDs: itemUIDs,
            anchorIndex: anchor, currentIndex: current, selecting: dragSelecting
        )
        if dragLiveSelection != next {
            dragLiveSelection = next
            requestRender()
        }
    }

    private func updateAutoScroll(viewportY: CGFloat) {
        let inBand = GridEdgeAutoScrollPolicy.isInEdgeBand(
            touchY: viewportY, viewportHeight: bounds.height, edgeInset: Self.autoScrollEdgeInset)
        if inBand {
            if !autoScrollLink.isRunning {
                autoScrollLastTimestamp = 0
                autoScrollLink.start { [weak self] timestamp in self?.autoScrollTick(timestamp) }
            }
        } else {
            stopAutoScroll()
        }
    }

    private func autoScrollTick(_ timestamp: CFTimeInterval) {
        guard dragActive else { stopAutoScroll(); return }
        let dt: CFTimeInterval = autoScrollLastTimestamp == 0 ? 1.0 / 60.0 : max(0, timestamp - autoScrollLastTimestamp)
        autoScrollLastTimestamp = timestamp
        let velocity = GridEdgeAutoScrollPolicy.velocity(
            touchY: dragLastViewportPoint.y, viewportHeight: bounds.height,
            edgeInset: Self.autoScrollEdgeInset, maxSpeed: Self.autoScrollMaxSpeed)
        guard velocity != 0 else { stopAutoScroll(); return }
        let currentY = scrollView.contentOffset.y
        let newY = min(max(currentY + velocity * CGFloat(dt), 0), maxContentOffsetY)
        // Already pinned to the top/bottom edge — the clamp produced no movement, so there is nothing left to
        // reveal or select. Stop the ramp so neither the auto-scroll link nor the render loop spins at full
        // frame rate doing no-op work at the boundary (a finger held in the band with the grid already at its
        // limit). A later finger move re-enters updateAutoScroll and restarts the link if progress is again
        // possible; the finger's current position was already applied by the triggering `updateDragSelect`.
        guard newY != currentY else { stopAutoScroll(); return }
        isApplyingProgrammaticScroll = true
        scrollView.setContentOffset(CGPoint(x: 0, y: newY), animated: false)
        isApplyingProgrammaticScroll = false
        // Re-resolve the item under the (stationary) finger against the NEW content offset, so the swept range
        // extends into the newly revealed rows with no skipped holes even while the finger doesn't move.
        let contentPoint = CGPoint(
            x: dragLastViewportPoint.x + scrollView.contentOffset.x,
            y: dragLastViewportPoint.y + scrollView.contentOffset.y)
        resolveDragIndex(contentPoint: contentPoint)
        applyDragSelection()
        requestRender()
    }

    private func stopAutoScroll() {
        if autoScrollLink.isRunning { autoScrollLink.stop() }
        autoScrollLastTimestamp = 0
    }

    private func endDragSelect() {
        stopAutoScroll()
        scrollView.isScrollEnabled = true
        guard dragActive else { return }
        dragActive = false
        let committed = dragLiveSelection ?? selectedUIDs
        // Mirror the committed set into the host so decorations stay correct for the frame(s) before SwiftUI's
        // re-configure lands with the same set (no flash), then drop the live overlay and commit ONCE to SwiftUI.
        selectedUIDs = committed
        dragLiveSelection = nil
        dragAnchorIndex = nil
        dragCurrentIndex = nil
        requestRender()
        onDragSelectionChanged?(committed)
    }

    /// Abandon an in-progress drag without committing — used when the surface suspends (tab switch / off-window)
    /// mid-drag, where the long-press recognizer may not deliver a `.cancelled`. Restores scrolling and reverts
    /// the live overlay to the base selection.
    private func cancelDragSelectIfActive() {
        stopAutoScroll()
        guard dragActive else { return }
        dragActive = false
        dragLiveSelection = nil
        dragAnchorIndex = nil
        dragCurrentIndex = nil
        scrollView.isScrollEnabled = true
        requestRender()
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
            // just thumbnails + video badges. While a finger-drag is live its in-progress set is drawn instead of
            // the committed selection, so the drag paints without a per-frame SwiftUI round-trip.
            selected: selectionMode ? (dragLiveSelection ?? selectedUIDs) : [],
            favorites: [],
            isVideo: { [videoUIDs] uid in videoUIDs.contains(uid) }
        )
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
    /// one-finger scroll never contend, and a tap requires no movement. The drag-select long press also begins
    /// alongside the scroll pan (both must track the touch so the press can mature); it disables scrolling itself
    /// once it begins, so the two never move the grid at the same time.
    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                                  shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif
