#if canImport(UIKit)
import CoreGraphics
import GridCore
import MediaCacheUIKitAdapter
import Metal
import MetalGridTextureCore
import MetalGridTextureUIKitAdapter
import MetalRenderingCore
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

    public init(
        items: [PhotoItem],
        thumbnailFeed: UIKitThumbnailFeed,
        level: Int? = nil,
        displayMode: TileContentDisplayMode = .squareFillCrop
    ) {
        self.items = items
        self.thumbnailFeed = thumbnailFeed
        self.level = level
        self.displayMode = displayMode
    }

    @MainActor
    public func makeUIView(context: Context) -> UIKitTimelineGridHostView {
        let view = UIKitTimelineGridHostView()
        view.configure(items: items, thumbnailFeed: thumbnailFeed, level: level, displayMode: displayMode)
        return view
    }

    @MainActor
    public func updateUIView(_ uiView: UIKitTimelineGridHostView, context: Context) {
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
    private var levelOverride: Int?
    private var displayMode: TileContentDisplayMode = .squareFillCrop
    private var warmTask: Task<Void, Never>?
    private var lastWarmIDs: [PhotoUID] = []

    public private(set) var isMetal3Capable = false

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
        let oldUIDs = self.items.map(\.uid)
        self.items = items
        self.thumbnailFeed = thumbnailFeed
        self.levelOverride = level
        self.displayMode = displayMode
        if oldUIDs != items.map(\.uid) {
            Task { await thumbnailFeed.startPrefetch(items.map(\.uid)) }
            lastWarmIDs = []
        }
        refreshContentSize()
        renderNow()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalView.frame = bounds
        scrollView.frame = bounds
        metalView.updateDrawableSize()
        refreshTextureCacheIfNeeded()
        refreshContentSize()
        renderNow()
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            displayLink.stop()
            warmTask?.cancel()
        } else {
            metalView.updateDrawableSize()
            renderNow()
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
    }

    private func configureMetal() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            isMetal3Capable = false
            return
        }
        isMetal3Capable = device.supportsFamily(.apple7)
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

    private func refreshContentSize() {
        let size = resolvedContentSize()
        scrollView.contentSize = size
        contentView.frame = CGRect(origin: .zero, size: size)
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
        profile.clampLevel(levelOverride ?? profile.defaultLevel)
    }

    private func renderNow() {
        guard isMetal3Capable,
              bounds.width > 0,
              bounds.height > 0,
              let renderer,
              let textureCache,
              let texturePolicy,
              let target = MetalGridDrawableTarget(layer: metalView.metalLayer)
        else { return }

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
        textureCache.setEffectiveMaxTexturePixels(uploadPixels)

        let ids = classifyUIDs(in: plan.visibleSlots, viewportSize: viewportSize)
        let window = GridTextureStreamingPolicy.window(
            visibleIDs: ids.visible,
            overscanIDs: ids.overscan,
            maxPinned: textureCache.maxSafePinnedCount
        )

        textureCache.beginFrame(pinned: window.pinned)
        if let thumbnailFeed {
            textureCache.uploadVisible(wanted: window.priority) { uid in
                thumbnailFeed.memoryCGImage(for: uid)
            }
        }

        let groups = buildGroups(slots: viewportSlots(plan.visibleSlots, viewportSize: viewportSize), cache: textureCache)
        textureCache.evictToBudget()
        renderer.render(to: target, viewportSize: viewportSize, groups: groups)

        let missingVisible = ids.visible.filter { uid in
            !textureCache.isResident(uid) && !(thumbnailFeed?.isKnownUnfetchable(uid) ?? false)
        }
        scheduleWarmIfNeeded(missingVisible, pixelSize: uploadPixels)
        updateDisplayLink(shouldRun: !missingVisible.isEmpty && !textureCache.residencySaturatedThisFrame)
    }

    private func classifyUIDs(in slots: [GridSlot], viewportSize: CGSize) -> (visible: [PhotoUID], overscan: [PhotoUID]) {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        var visible: [PhotoUID] = []
        var overscan: [PhotoUID] = []
        visible.reserveCapacity(slots.count)
        overscan.reserveCapacity(slots.count)
        for slot in slots where slot.index < items.count {
            let uid = items[slot.index].uid
            if slot.viewportRect.intersects(viewport) { visible.append(uid) }
            else { overscan.append(uid) }
        }
        return (visible, overscan)
    }

    private func viewportSlots(_ slots: [GridSlot], viewportSize: CGSize) -> [GridSlot] {
        let viewport = CGRect(origin: .zero, size: viewportSize)
        return slots.filter { $0.viewportRect.intersects(viewport) }
    }

    private func buildGroups(slots: [GridSlot], cache: MetalGridTextureCache<PhotoUID>) -> [MetalGridRenderGroup] {
        var quads: [MetalGridQuad] = []
        var textures: [MTLTexture] = []
        quads.reserveCapacity(slots.count)
        textures.reserveCapacity(slots.count)

        for slot in slots where slot.index < items.count {
            let uid = items[slot.index].uid
            guard cache.isResident(uid) else { continue }
            cache.noteUsed(uid)
            let texture = cache.texture(for: uid)
            let fit = TileContentFitter.fit(
                slotRect: slot.viewportRect,
                mediaPixelSize: CGSize(width: texture.width, height: texture.height),
                displayMode: displayMode
            )
            quads.append(MetalGridQuad(rect: fit.contentRect, uvMin: fit.uvMin, uvMax: fit.uvMax, radius: 6))
            textures.append(texture)
        }

        guard !quads.isEmpty else { return [] }
        return [MetalGridRenderGroup(source: .perQuadTexture(textures), quads: quads)]
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
            await MainActor.run { self?.renderNow() }
        }
    }

    private func updateDisplayLink(shouldRun: Bool) {
        if shouldRun {
            guard !displayLink.isRunning else { return }
            displayLink.start { [weak self] _ in
                self?.renderNow()
            }
        } else {
            displayLink.stop()
        }
    }
}

extension UIKitTimelineGridHostView: UIScrollViewDelegate {
    public func scrollViewDidScroll(_ scrollView: UIScrollView) {
        renderNow()
    }
}
#endif
