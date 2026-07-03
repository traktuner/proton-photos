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
    private let onFirstContentReady: (() -> Void)?
    private let onOpenPhoto: ((PhotoItem) -> Void)?

    public init(
        items: [PhotoItem],
        thumbnailFeed: UIKitThumbnailFeed,
        level: Int? = nil,
        displayMode: TileContentDisplayMode = .squareFillCrop,
        onFirstContentReady: (() -> Void)? = nil,
        onOpenPhoto: ((PhotoItem) -> Void)? = nil
    ) {
        self.items = items
        self.thumbnailFeed = thumbnailFeed
        self.level = level
        self.displayMode = displayMode
        self.onFirstContentReady = onFirstContentReady
        self.onOpenPhoto = onOpenPhoto
    }

    @MainActor
    public func makeUIView(context: Context) -> UIKitTimelineGridHostView {
        let view = UIKitTimelineGridHostView()
        view.onFirstContentReady = onFirstContentReady
        view.onOpenPhoto = onOpenPhoto
        view.configure(items: items, thumbnailFeed: thumbnailFeed, level: level, displayMode: displayMode)
        return view
    }

    @MainActor
    public func updateUIView(_ uiView: UIKitTimelineGridHostView, context: Context) {
        uiView.onFirstContentReady = onFirstContentReady
        uiView.onOpenPhoto = onOpenPhoto
        uiView.configure(items: items, thumbnailFeed: thumbnailFeed, level: level, displayMode: displayMode)
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
    private var displayMode: TileContentDisplayMode = .squareFillCrop
    private var warmTask: Task<Void, Never>?
    private var lastWarmIDs: [PhotoUID] = []
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
        displayMode: TileContentDisplayMode = .squareFillCrop
    ) {
        let newUIDs = items.map(\.uid)
        let uidsChanged = itemUIDs != newUIDs
        let shouldOpenAtNewest = uidsChanged && !newUIDs.isEmpty && !userHasScrolledTimeline
        self.items = items
        self.itemUIDs = newUIDs
        self.thumbnailFeed = thumbnailFeed
        // An explicit external level is authoritative: it clears any pinch-driven level so the host follows the
        // caller again (a nil level leaves the user's pinch level in place).
        if let level, level != levelOverride { interactiveLevel = nil }
        self.levelOverride = level
        self.displayMode = displayMode
        if uidsChanged {
            itemIndexByUID = Dictionary(
                newUIDs.enumerated().map { ($0.element, $0.offset) },
                uniquingKeysWith: { _, latest in latest }
            )
            lastWarmIDs = []
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
            displayLink.stop()
            warmTask?.cancel()
        } else {
            metalView.updateDrawableSize()
            requestRender()
        }
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
        // gesture. The tap requires no movement (never fights a scroll); the pinch drives a discrete, focal-anchored
        // density step through the shared GridCore geometry — no bespoke iOS layout math.
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
        textureCache = UIKitMetalGridTextureCacheFactory.makeCache(device: device, policy: policy)
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
        let profile = profileAdapter.profile(for: metalView)
        let level = activeLevel(profile: profile)
        let engine = SquareTileGridEngine(sectionCounts: [items.count], profile: profile)
        let content = engine.contentSize(level: level, width: bounds.width)
        return CGSize(width: max(bounds.width, content.width), height: max(bounds.height + 1, content.height))
    }

    private func activeLevel(profile: GridLevelProfile) -> Int {
        profile.clampLevel(interactiveLevel ?? levelOverride ?? profile.defaultLevel)
    }

    // MARK: - Coalesced render loop

    /// Mark the on-screen state dirty and make sure the display link is ticking. All invalidations funnel
    /// through here; actual drawing happens only in `tick`, at most once per vsync.
    private func requestRender() {
        guard isMetal3Capable else { return }
        framePump.invalidate()
        guard window != nil else { return }   // didMoveToWindow re-arms the loop on re-attach
        if !displayLink.isRunning {
            displayLink.start { [weak self] _ in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard framePump.shouldTick else {
            displayLink.stop()
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
        let profile = profileAdapter.profile(for: metalView)
        let level = activeLevel(profile: profile)
        let engine = SquareTileGridEngine(sectionCounts: [items.count], profile: profile)
        let overscan = texturePolicy.budget.overscanFraction * viewportSize.height
        let plan = engine.framePlan(
            level: level,
            viewportSize: viewportSize,
            scrollOffset: scrollView.contentOffset,
            overscan: overscan
        )

        let uploadPixels = GridTextureUploadSizing.uploadPixels(
            slotSidePoints: plan.slotSide,
            backingScale: metalView.metalLayer.contentsScale,
            headroom: 1.15,
            floor: 64,
            cap: textureCache.maxTexturePixels
        )

        // Same universal composition sequence the macOS host uses (MetalGridFrameComposer), so a
        // streaming/rendering fix lands on both platforms at once. This host owns only the iOS plumbing:
        // the CAMetalLayer drawable, the level-aware upload size, the CADisplayLink, and the warm pump.
        let renderSlots = plan.visibleSlots.map {
            GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect)
        }
        let ids = MetalGridFrameComposer.classifyVisibility(
            slots: renderSlots, flatUIDs: itemUIDs, viewportSize: viewportSize)
        let feed = thumbnailFeed
        let streamResult = MetalGridFrameComposer.stream(
            cache: textureCache,
            visibleIDs: ids.visible,
            overscanIDs: ids.overscan,
            pinOverscan: true,
            effectiveUploadPixels: uploadPixels,
            allowUpgrade: false,
            hasImage: { feed?.memoryCGImage(for: $0) != nil },
            canRetry: { !(feed?.isKnownUnfetchable($0) ?? false) },
            provideImage: { feed?.memoryCGImage(for: $0) }
        )
        let groups = MetalGridFrameComposer.buildGroups(
            slots: MetalGridFrameComposer.viewportDrawSlots(renderSlots, viewportSize: viewportSize),
            flatUIDs: itemUIDs,
            cache: textureCache,
            displayMode: displayMode,
            cornerRadius: GridVisualConstants.thumbnailCornerRadius,
            decorations: nil
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
        if !firstContentReported, !ids.visible.isEmpty, missingVisible.isEmpty {
            firstContentReported = true
            if let onFirstContentReady {
                DispatchQueue.main.async { onFirstContentReady() }
            }
        }
        scheduleWarmIfNeeded(missingVisible, pixelSize: uploadPixels)
        let hasPendingWork = (!missingVisible.isEmpty && !textureCache.residencySaturatedThisFrame)
            || streamResult.pendingVisibleQualityUpgrade
        perf.noteDraw(visible: ids.visible.count, missing: missingVisible.count, cache: textureCache)
        return .drawn(hasPendingWork: hasPendingWork)
    }

    /// The resolved grid geometry for the current viewport + active level, or nil when there is nothing to lay
    /// out. Built the same way `renderNow` builds it, so hit-testing and rendering never diverge.
    private func currentGridContext() -> (engine: SquareTileGridEngine, level: Int, profile: GridLevelProfile)? {
        guard bounds.width > 0, !items.isEmpty else { return nil }
        let profile = profileAdapter.profile(for: metalView)
        let level = activeLevel(profile: profile)
        let engine = SquareTileGridEngine(sectionCounts: [items.count], profile: profile)
        return (engine, level, profile)
    }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        // A tap that merely halts a decelerating scroll must not also open a photo.
        guard gesture.state == .ended, !scrollView.isDecelerating,
              let onOpenPhoto, let ctx = currentGridContext() else { return }
        // contentView spans the full content size at origin .zero, so its coordinate space IS the engine's
        // content space (y down, origin at the library top).
        let contentPoint = gesture.location(in: contentView)
        guard let slot = ctx.engine.hitTest(contentPoint: contentPoint, level: ctx.level, width: bounds.width),
              slot.index >= 0, slot.index < items.count
        else { return }
        onOpenPhoto(items[slot.index])
    }

    @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
        guard let ctx = currentGridContext() else { return }
        switch gesture.state {
        case .began:
            pinchStartLevel = ctx.level
            // Engage the user so the newest-bottom auto-pin never fights the zoom.
            userHasScrolledTimeline = true
        case .changed:
            guard let startLevel = pinchStartLevel else { return }
            // Pinch-out (scale > 1) → zoom in → fewer columns → LOWER level. The shared policy owns how much
            // finger motion one density step costs (tested in GridCore) — the recognizer only reports scale.
            let steps = GridPinchDensityPolicy.levelSteps(pinchScale: gesture.scale)
            let target = ctx.profile.clampLevel(startLevel - steps)
            guard target != ctx.level else { return }
            let focusViewportY = gesture.location(in: self).y
            let sourceOffsetY = scrollView.contentOffset.y
            applyLevelChange(
                from: ctx.level,
                to: target,
                cursorContentPoint: CGPoint(x: 0, y: focusViewportY + sourceOffsetY),
                sourceOffsetY: sourceOffsetY
            )
        case .ended, .cancelled, .failed:
            pinchStartLevel = nil
        default:
            break
        }
    }

    /// Applies a discrete density change, carrying the pinch focal point across the level boundary via the shared
    /// engine so the photo under the fingers stays put (no jump to top/newest).
    private func applyLevelChange(from sourceLevel: Int, to targetLevel: Int,
                                  cursorContentPoint: CGPoint, sourceOffsetY: CGFloat) {
        let profile = profileAdapter.profile(for: metalView)
        let engine = SquareTileGridEngine(sectionCounts: [items.count], profile: profile)
        let anchoredY = engine.cursorAnchoredScrollOffsetY(
            levelChangeFrom: sourceLevel,
            to: targetLevel,
            width: bounds.width,
            cursorContentPoint: cursorContentPoint,
            sourceScrollOriginY: sourceOffsetY
        )
        interactiveLevel = targetLevel
        refreshContentSize()   // content size follows the new level; needsInitialNewestViewport is already spent
        if let anchoredY {
            isApplyingProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: 0, y: min(max(anchoredY, 0), maxContentOffsetY)), animated: false)
            isApplyingProgrammaticScroll = false
        }
        requestRender()
    }

    private func newestFirst(_ uids: [PhotoUID]) -> [PhotoUID] {
        uids.sorted { lhs, rhs in
            (itemIndexByUID[lhs] ?? -1) > (itemIndexByUID[rhs] ?? -1)
        }
    }

    private func scheduleWarmIfNeeded(_ uids: [PhotoUID], pixelSize: Int) {
        guard !uids.isEmpty, let thumbnailFeed else { return }
        var seen = Set<PhotoUID>()
        let unique = uids.filter { seen.insert($0).inserted }
        guard unique != lastWarmIDs else { return }
        lastWarmIDs = unique
        warmTask?.cancel()
        let requests = unique.map { ThumbnailRequest(uid: $0, pixelSize: pixelSize, cropMode: displayMode.rawValue) }
        warmTask = Task { [weak self, thumbnailFeed] in
            _ = await thumbnailFeed.warmDecoded(requests, priority: .visibleNow, limit: max(1, requests.count))
            await MainActor.run { self?.requestRender() }
        }
    }
}

extension UIKitTimelineGridHostView: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !isApplyingProgrammaticScroll,
           scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating {
            userHasScrolledTimeline = true
        }
        // Scroll deltas arrive faster than vsync — mark dirty only; the display link draws exactly once
        // per frame with whatever offset is current by then.
        perf.noteScrollEvent()
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

/// One-second aggregation window for the render loop, logged at `.debug` (visible only with the category
/// enabled — silent in normal use). One line per second while the loop runs answers the perf questions
/// directly: how many input events were coalesced into how many draws, whether drawable acquisition ever
/// failed, and what the streaming pipeline did (uploads / deferrals / residency).
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
    private var lastVisible = 0
    private var lastMissing = 0
    private var lastResidentBytes = 0

    mutating func noteScrollEvent() {
        scrollEvents += 1
    }

    mutating func noteDraw<ID>(visible: Int, missing: Int, cache: MetalGridTextureCache<ID>?) {
        draws += 1
        lastVisible = visible
        lastMissing = missing
        if let cache {
            uploads += cache.uploadsThisFrame
            uploadMs += cache.uploadMsThisFrame
            deferredUploads += cache.deferredUploadsThisFrame
            lastResidentBytes = cache.residentBytes
        }
    }

    mutating func noteTick(drawableFailed: Bool) {
        ticks += 1
        if drawableFailed { drawableFailures += 1 }
        let now = CACurrentMediaTime()
        if windowStart == 0 { windowStart = now }
        if now - windowStart >= 1.0 {
            flush(reason: "window")
            windowStart = now
        }
    }

    mutating func flush(reason: String) {
        guard ticks > 0 else { return }
        let (t, d, s, f) = (ticks, draws, scrollEvents, drawableFailures)
        let (u, um, du) = (uploads, String(format: "%.2f", uploadMs), deferredUploads)
        let (vis, mis, mb) = (lastVisible, lastMissing, lastResidentBytes / 1_048_576)
        Self.logger.debug("""
        [MobileGridPerf] \(reason, privacy: .public) ticks=\(t) draws=\(d) scrollEvents=\(s) \
        drawableFail=\(f) uploads=\(u) uploadMs=\(um, privacy: .public) deferred=\(du) \
        visible=\(vis) missing=\(mis) residentMB=\(mb)
        """)
        scrollEvents = 0
        ticks = 0
        draws = 0
        drawableFailures = 0
        uploads = 0
        uploadMs = 0
        deferredUploads = 0
    }
}
#endif
