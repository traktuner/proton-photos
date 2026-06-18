import AppKit
import QuartzCore
import SwiftUI
import PhotosCore
import MediaCache

public struct ApplePrivateGridLayerPrototypeStats: Equatable {
    public var privateAPIAvailable = false
    public var pinchFilterAvailable = false
    public var level: CGFloat = 2
    public var columns: CGFloat = 6
    public var lowColumns = 6
    public var highColumns = 6
    public var visibleItems = 0
    public var activeLayerCount = 0
    public var reusableLayerCount = 0
    public var frameMillis: Double = 0
    public var anchorIndex: Int?
    public var pinchDirection = 0
    public var diagnostics = ""

    public init(
        privateAPIAvailable: Bool = false,
        pinchFilterAvailable: Bool = false,
        level: CGFloat = 2,
        columns: CGFloat = 6,
        lowColumns: Int = 6,
        highColumns: Int = 6,
        visibleItems: Int = 0,
        activeLayerCount: Int = 0,
        reusableLayerCount: Int = 0,
        frameMillis: Double = 0,
        anchorIndex: Int? = nil,
        pinchDirection: Int = 0,
        diagnostics: String = ""
    ) {
        self.privateAPIAvailable = privateAPIAvailable
        self.pinchFilterAvailable = pinchFilterAvailable
        self.level = level
        self.columns = columns
        self.lowColumns = lowColumns
        self.highColumns = highColumns
        self.visibleItems = visibleItems
        self.activeLayerCount = activeLayerCount
        self.reusableLayerCount = reusableLayerCount
        self.frameMillis = frameMillis
        self.anchorIndex = anchorIndex
        self.pinchDirection = pinchDirection
        self.diagnostics = diagnostics
    }
}

public struct ApplePrivateGridLayerPrototype: View {
    private let items: [PhotoItem]
    private let feed: ThumbnailFeed
    private let onStats: (ApplePrivateGridLayerPrototypeStats) -> Void

    public init(
        items: [PhotoItem],
        feed: ThumbnailFeed,
        onStats: @escaping (ApplePrivateGridLayerPrototypeStats) -> Void = { _ in }
    ) {
        self.items = items
        self.feed = feed
        self.onStats = onStats
    }

    public var body: some View {
        ApplePrivateGridLayerPrototypeRepresentable(items: items, feed: feed, onStats: onStats)
            .background(Color.black)
    }
}

public struct ApplePrivateGridLayerPrototypeRepresentable: NSViewRepresentable {
    private let items: [PhotoItem]
    private let feed: ThumbnailFeed
    private let onStats: (ApplePrivateGridLayerPrototypeStats) -> Void

    public init(
        items: [PhotoItem],
        feed: ThumbnailFeed,
        onStats: @escaping (ApplePrivateGridLayerPrototypeStats) -> Void = { _ in }
    ) {
        self.items = items
        self.feed = feed
        self.onStats = onStats
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ApplePrivateGridLayerPrototypeScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        let document = ApplePrivateGridLayerPrototypeView(items: items, feed: feed)
        document.statsHandler = onStats
        document.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        document.autoresizingMask = [.width]
        scrollView.documentView = document
        scrollView.layerPrototypeDocumentView = document

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.boundsDidChange(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        context.coordinator.documentView = document
        context.coordinator.scrollView = scrollView
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let document = scrollView.documentView as? ApplePrivateGridLayerPrototypeView else { return }
        document.statsHandler = onStats
        document.update(items: items, feed: feed)
        document.fitWidth(scrollView.contentView.bounds.width, preservingVisibleTop: true)
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator: NSObject {
        fileprivate weak var documentView: ApplePrivateGridLayerPrototypeView?
        fileprivate weak var scrollView: NSScrollView?

        @objc fileprivate func boundsDidChange(_ note: Notification) {
            guard let scrollView, let documentView else { return }
            documentView.visibleRectDidChange(scrollView.contentView.bounds)
        }
    }
}

private final class ApplePrivateGridLayerPrototypeScrollView: NSScrollView {
    weak var layerPrototypeDocumentView: ApplePrivateGridLayerPrototypeView?

    override func layout() {
        super.layout()
        layerPrototypeDocumentView?.fitWidth(contentView.bounds.width, preservingVisibleTop: true)
    }
}

public final class ApplePrivateGridLayerPrototypeView: NSView {
    private static let levelSizes: [CGFloat] = [330, 185, 130, 95, 70, 44]
    private static let levelGaps: [CGFloat] = [12, 8, 6, 4, 3, 2]
    private static let syntheticCount = 1600
    private static let maxVisibleImageLoads = 240

    public var statsHandler: ((ApplePrivateGridLayerPrototypeStats) -> Void)?
    public private(set) var continuousLevel: CGFloat = 2

    private var items: [PhotoItem]
    private var feed: ThumbnailFeed
    private let pinchFilter = PPApplePrivatePinchFilter()

    private let gridLayer = CALayer()
    private var visibleSprites: [Int: GridSprite] = [:]
    private var reusableSprites: [GridSprite] = []
    private var loadedImages: [PhotoUID: NSImage] = [:]
    private var cgImageCache: [PhotoUID: CGImage] = [:]
    private var loadingUIDs = Set<PhotoUID>()

    private var pinchAccumulatedMagnification: CGFloat = 0
    private var anchorIndex: Int?
    private var anchorUnit = CGPoint(x: 0.5, y: 0.5)
    private var anchorViewportPoint = CGPoint(x: 0, y: 0)
    private var pinchDirection = 0
    private var lastFrameMillis: Double = 0
    private var lastPrefetchSignature = ""
    private var lastStatsEmitTime: CFTimeInterval = 0
    private var latestVisibleRect: CGRect?
    private var settleTimer: Timer?

    private var itemCount: Int { items.isEmpty ? Self.syntheticCount : items.count }

    public init(items: [PhotoItem], feed: ThumbnailFeed) {
        self.items = items
        self.feed = feed
        super.init(frame: .zero)

        wantsLayer = true
        configureBackingLayer()
        configureGridLayer()

        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        click.numberOfClicksRequired = 1
        addGestureRecognizer(click)

        PPApplePrivateGridRuntime.loadPrivateFrameworks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    public override var isFlipped: Bool { true }

    public override func makeBackingLayer() -> CALayer {
        let backingLayer = CALayer()
        backingLayer.backgroundColor = NSColor.black.cgColor
        backingLayer.geometryFlipped = true
        backingLayer.actions = Self.disabledActions
        return backingLayer
    }

    public override func layout() {
        super.layout()
        updateLayerScale()
        withoutLayerActions {
            gridLayer.frame = CGRect(origin: .zero, size: bounds.size)
            gridLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        }
        syncVisibleLayers(prefetch: false)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayerScale()
        syncVisibleLayers(prefetch: true, forceStats: true)
    }

    public func update(items: [PhotoItem], feed: ThumbnailFeed) {
        self.items = items
        self.feed = feed
        if !items.isEmpty {
            let validUIDs = Set(items.map(\.uid))
            loadedImages = loadedImages.filter { validUIDs.contains($0.key) }
            cgImageCache = cgImageCache.filter { validUIDs.contains($0.key) }
            loadingUIDs = loadingUIDs.intersection(validUIDs)
        } else {
            loadedImages.removeAll()
            cgImageCache.removeAll()
            loadingUIDs.removeAll()
        }
        recomputeContentHeight(preservingAnchor: nil)
        syncVisibleLayers(prefetch: true, forceStats: true)
    }

    public func fitWidth(_ width: CGFloat, preservingVisibleTop: Bool = true) {
        guard width > 1 else { return }
        if abs(frame.width - width) < 0.5 { return }
        let oldTop = enclosingScrollView?.contentView.bounds.origin.y ?? 0
        var newFrame = frame
        newFrame.size.width = width
        frame = newFrame
        recomputeContentHeight(preservingAnchor: nil)
        if preservingVisibleTop, let clip = enclosingScrollView?.contentView {
            clip.setBoundsOrigin(NSPoint(x: 0, y: min(max(oldTop, 0), max(0, bounds.height - clip.bounds.height))))
            enclosingScrollView?.reflectScrolledClipView(clip)
            latestVisibleRect = clip.bounds
        } else if let clip = enclosingScrollView?.contentView {
            latestVisibleRect = clip.bounds
        }
        syncVisibleLayers(prefetch: true, forceStats: true)
    }

    public func visibleRectDidChange(_ rect: CGRect) {
        latestVisibleRect = rect
        syncVisibleLayers(prefetch: true)
    }

    public func setContinuousLevel(_ level: CGFloat, preservingItemAt anchor: Int? = nil) {
        continuousLevel = min(max(level, 0), CGFloat(Self.levelSizes.count - 1))
        recomputeContentHeight(preservingAnchor: anchor)
        syncVisibleLayers(prefetch: false)
    }

    public func reloadVisibleLayers() {
        syncVisibleLayers(prefetch: true, forceStats: true)
    }

    private func configureBackingLayer() {
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.geometryFlipped = true
        layer?.actions = Self.disabledActions
    }

    private func configureGridLayer() {
        gridLayer.backgroundColor = NSColor.black.cgColor
        gridLayer.geometryFlipped = true
        gridLayer.masksToBounds = false
        gridLayer.actions = Self.disabledActions
        layer?.addSublayer(gridLayer)
    }

    private func updateLayerScale() {
        let scale = backingScale
        layer?.contentsScale = scale
        gridLayer.contentsScale = scale
        for sprite in visibleSprites.values {
            sprite.setContentsScale(scale)
        }
        for sprite in reusableSprites {
            sprite.setContentsScale(scale)
        }
    }

    private var backingScale: CGFloat {
        window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    private func syncVisibleLayers(prefetch: Bool, forceStats: Bool = false) {
        let start = CACurrentMediaTime()
        let viewport = currentViewportRect()
        let entries = visibleEntries(in: expandedViewport(viewport))
        let visibleIndices = Set(entries.map(\.index))
        let scale = backingScale

        withoutLayerActions {
            let staleIndices = visibleSprites.keys.filter { !visibleIndices.contains($0) }
            for index in staleIndices {
                guard let sprite = visibleSprites.removeValue(forKey: index) else { continue }
                sprite.prepareForReuse()
                sprite.layer.removeFromSuperlayer()
                reusableSprites.append(sprite)
            }

            for entry in entries {
                let sprite = visibleSprites[entry.index] ?? dequeueSprite(for: entry.index)
                visibleSprites[entry.index] = sprite
                configure(sprite: sprite, for: entry.index, frame: aligned(entry.frame, scale: scale))
            }
        }

        if prefetch {
            prefetchVisibleItems(in: viewport)
        }
        lastFrameMillis = (CACurrentMediaTime() - start) * 1000
        emitStats(force: forceStats)
    }

    private func dequeueSprite(for index: Int) -> GridSprite {
        let sprite = reusableSprites.popLast() ?? GridSprite()
        sprite.setContentsScale(backingScale)
        sprite.layer.zPosition = CGFloat(index)
        gridLayer.addSublayer(sprite.layer)
        return sprite
    }

    private func configure(sprite: GridSprite, for index: Int, frame: CGRect) {
        sprite.index = index
        sprite.uid = uid(for: index)
        sprite.layer.frame = frame
        sprite.layer.cornerRadius = min(10, max(2, frame.height * 0.06))
        sprite.imageLayer.frame = CGRect(origin: .zero, size: frame.size)

        if let uid = sprite.uid, let image = cgImage(for: uid) {
            sprite.showImage(image)
        } else if items.isEmpty {
            sprite.showSyntheticPlaceholder(color: placeholderColor(for: index))
        } else {
            sprite.showLoadingPlaceholder()
        }
    }

    private func uid(for index: Int) -> PhotoUID? {
        guard !items.isEmpty, index >= 0, index < items.count else { return nil }
        return items[index].uid
    }

    private func cgImage(for uid: PhotoUID) -> CGImage? {
        if let image = cgImageCache[uid] { return image }
        guard let image = feed.memoryImage(for: uid) ?? loadedImages[uid] else { return nil }
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        cgImageCache[uid] = cgImage
        return cgImage
    }

    private func currentViewportRect() -> CGRect {
        if let latestVisibleRect {
            return latestVisibleRect
        }
        if let clip = enclosingScrollView?.contentView {
            return clip.bounds
        }
        return bounds
    }

    private func expandedViewport(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.35)
    }

    private struct VisibleEntry {
        let index: Int
        let frame: CGRect
    }

    private func visibleEntries(in rect: CGRect) -> [VisibleEntry] {
        let geometry = currentGeometry()
        let lowRange = visibleIndexRange(columns: geometry.lowColumns, in: rect, geometry: geometry)
        let highRange = visibleIndexRange(columns: geometry.highColumns, in: rect, geometry: geometry)
        let start = max(0, min(lowRange.lowerBound, highRange.lowerBound))
        let end = min(itemCount, max(lowRange.upperBound, highRange.upperBound))
        guard start < end else { return [] }

        var output: [VisibleEntry] = []
        output.reserveCapacity(end - start)
        for index in start ..< end {
            let frame = frameForItem(index, geometry: geometry)
            if frame.intersects(rect), !frame.isNull {
                output.append(VisibleEntry(index: index, frame: frame))
            }
        }
        return output
    }

    private func visibleIndexRange(columns: Int, in rect: CGRect, geometry: GridGeometry) -> Range<Int> {
        guard itemCount > 0 else { return 0 ..< 0 }
        let pitch = max(geometry.side + geometry.gap, 1)
        let rows = rowCount(columns: columns)
        let firstRow = max(0, Int(floor((rect.minY - geometry.side) / pitch)) - 2)
        let lastRow = min(rows - 1, Int(ceil((rect.maxY + geometry.side) / pitch)) + 2)
        guard firstRow <= lastRow else { return 0 ..< min(itemCount, columns * 4) }
        let start = min(itemCount, firstRow * columns)
        let end = min(itemCount, (lastRow + 1) * columns)
        return start ..< max(start, end)
    }

    private func frameForItem(_ index: Int, geometry: GridGeometry? = nil) -> CGRect {
        let geometry = geometry ?? currentGeometry()
        let low = frameForItem(index, columns: geometry.lowColumns, geometry: geometry)
        if geometry.lowColumns == geometry.highColumns { return low }
        let high = frameForItem(index, columns: geometry.highColumns, geometry: geometry)
        return interpolate(low, high, t: smoothstep(geometry.fraction))
    }

    private func frameForItem(_ index: Int, columns: Int, geometry: GridGeometry) -> CGRect {
        let column = index % columns
        let row = index / columns
        let rowWidth = CGFloat(columns) * geometry.side + CGFloat(max(0, columns - 1)) * geometry.gap
        let width = max(bounds.width, enclosingScrollView?.contentView.bounds.width ?? bounds.width, 1)
        let left = max(0, (width - rowWidth) * 0.5)
        return CGRect(
            x: left + CGFloat(column) * (geometry.side + geometry.gap),
            y: CGFloat(row) * (geometry.side + geometry.gap),
            width: geometry.side,
            height: geometry.side
        )
    }

    private func interpolate(_ a: CGRect, _ b: CGRect, t: CGFloat) -> CGRect {
        CGRect(
            x: a.minX + (b.minX - a.minX) * t,
            y: a.minY + (b.minY - a.minY) * t,
            width: a.width + (b.width - a.width) * t,
            height: a.height + (b.height - a.height) * t
        )
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        let t = min(max(value, 0), 1)
        return t * t * (3 - 2 * t)
    }

    private struct GridGeometry {
        let columns: CGFloat
        let lowColumns: Int
        let highColumns: Int
        let fraction: CGFloat
        let side: CGFloat
        let gap: CGFloat
    }

    private func currentGeometry() -> GridGeometry {
        let width = max(bounds.width, enclosingScrollView?.contentView.bounds.width ?? bounds.width, 1)
        let side = interpolated(Self.levelSizes, level: continuousLevel)
        let gap = interpolated(Self.levelGaps, level: continuousLevel)
        let columns = max(1, (width + gap) / max(side + gap, 1))
        let low = max(1, Int(floor(columns)))
        let high = max(low, Int(ceil(columns)))
        return GridGeometry(columns: columns, lowColumns: low, highColumns: high, fraction: columns - CGFloat(low), side: side, gap: gap)
    }

    private func interpolated(_ values: [CGFloat], level: CGFloat) -> CGFloat {
        let clamped = min(max(level, 0), CGFloat(values.count - 1))
        let low = Int(floor(clamped))
        let high = min(values.count - 1, Int(ceil(clamped)))
        let fraction = clamped - CGFloat(low)
        return values[low] + (values[high] - values[low]) * fraction
    }

    private func rowCount(columns: Int) -> Int {
        max(1, Int(ceil(CGFloat(max(itemCount, 1)) / CGFloat(max(columns, 1)))))
    }

    private func contentHeight(columns: Int, geometry: GridGeometry) -> CGFloat {
        let rows = rowCount(columns: columns)
        return CGFloat(rows) * geometry.side + CGFloat(max(0, rows - 1)) * geometry.gap
    }

    private func recomputeContentHeight(preservingAnchor anchor: Int?) {
        let clip = enclosingScrollView?.contentView
        let visible = clip?.bounds ?? latestVisibleRect ?? CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: max(bounds.height, 1))
        let geometry = currentGeometry()
        let lowHeight = contentHeight(columns: geometry.lowColumns, geometry: geometry)
        let highHeight = geometry.lowColumns == geometry.highColumns ? lowHeight : contentHeight(columns: geometry.highColumns, geometry: geometry)
        let contentHeight = max(visible.height, lowHeight + (highHeight - lowHeight) * smoothstep(geometry.fraction))

        var newFrame = frame
        newFrame.size.width = max(visible.width, 1)
        newFrame.size.height = max(contentHeight, visible.height)
        frame = newFrame

        if let anchor {
            reanchor(to: anchor)
        }
    }

    private func reanchor(to index: Int) {
        guard let clip = enclosingScrollView?.contentView else { return }
        let frame = frameForItem(index)
        let desired = frame.minY + anchorUnit.y * frame.height
        let maxY = max(0, bounds.height - clip.bounds.height)
        let y = min(max(desired - anchorViewportPoint.y, 0), maxY)
        clip.setBoundsOrigin(NSPoint(x: 0, y: y))
        enclosingScrollView?.reflectScrolledClipView(clip)
    }

    @objc private func handlePinch(_ recognizer: NSMagnificationGestureRecognizer) {
        let location = recognizer.location(in: self)
        switch recognizer.state {
        case .began:
            settleTimer?.invalidate()
            pinchFilter.reset()
            pinchDirection = 0
            pinchAccumulatedMagnification = 0
            recognizer.magnification = 0
            anchorIndex = itemIndex(at: location) ?? nearestItem(to: location)
            if let anchorIndex {
                let frame = frameForItem(anchorIndex)
                anchorUnit = CGPoint(
                    x: (location.x - frame.minX) / max(frame.width, 1),
                    y: (location.y - frame.minY) / max(frame.height, 1)
                )
                let origin = enclosingScrollView?.contentView.bounds.origin ?? .zero
                anchorViewportPoint = CGPoint(x: location.x - origin.x, y: location.y - origin.y)
            }
        case .changed:
            let delta = recognizer.magnification
            recognizer.magnification = 0
            pinchAccumulatedMagnification += delta
            let scale = max(0.12, 1 + pinchAccumulatedMagnification)
            let filterResult = pinchFilter.filterScale(Double(scale))
            if filterResult != 0 { pinchDirection = filterResult }
            setContinuousLevel(continuousLevel - delta * 2.25, preservingItemAt: anchorIndex)
        case .ended, .cancelled, .failed:
            recognizer.magnification = 0
            settleToNearestLevel()
        default:
            break
        }
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: self)
        anchorIndex = itemIndex(at: point)
        emitStats(force: true)
    }

    private func settleToNearestLevel() {
        let from = continuousLevel
        let to = min(max(round(from), 0), CGFloat(Self.levelSizes.count - 1))
        guard abs(from - to) > 0.001 else {
            continuousLevel = to
            syncVisibleLayers(prefetch: true, forceStats: true)
            return
        }

        let start = CACurrentMediaTime()
        let duration: CFTimeInterval = 0.22
        settleTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            let raw = min(max((CACurrentMediaTime() - start) / duration, 0), 1)
            let eased = 1 - pow(1 - raw, 3)
            self.setContinuousLevel(from + (to - from) * eased, preservingItemAt: self.anchorIndex)
            if raw >= 1 {
                timer.invalidate()
                self.continuousLevel = to
                self.syncVisibleLayers(prefetch: true, forceStats: true)
            }
        }
        settleTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func itemIndex(at point: CGPoint) -> Int? {
        let rect = CGRect(x: 0, y: point.y - 80, width: max(bounds.width, 1), height: 160)
        for entry in visibleEntries(in: rect) where entry.frame.contains(point) {
            return entry.index
        }
        return nil
    }

    private func nearestItem(to point: CGPoint) -> Int? {
        let rect = CGRect(x: 0, y: point.y - bounds.height * 0.5, width: max(bounds.width, 1), height: bounds.height)
        return visibleEntries(in: rect).min {
            distanceSquared($0.frame.center, point) < distanceSquared($1.frame.center, point)
        }?.index
    }

    private func distanceSquared(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        return dx * dx + dy * dy
    }

    private func prefetchVisibleItems(in rect: CGRect) {
        guard !items.isEmpty else { return }
        let entries = visibleEntries(in: rect.insetBy(dx: -rect.width * 0.1, dy: -rect.height * 0.55))
        let indices = entries.map(\.index).prefix(Self.maxVisibleImageLoads)
        let signature = "\(indices.first ?? -1)-\(indices.last ?? -1)-\(indices.count)"
        guard signature != lastPrefetchSignature else { return }
        lastPrefetchSignature = signature
        let uids = indices.compactMap { index -> PhotoUID? in
            guard index >= 0, index < items.count else { return nil }
            return items[index].uid
        }

        for uid in uids where imageNeedsLoad(uid) {
            loadingUIDs.insert(uid)
            let feed = feed
            Task { [weak self] in
                for _ in 0 ..< 10 {
                    if let image = await feed.cachedImage(for: uid) {
                        await MainActor.run {
                            guard let self else { return }
                            self.loadedImages[uid] = image
                            self.loadingUIDs.remove(uid)
                            self.syncVisibleLayers(prefetch: false)
                        }
                        return
                    }
                    await feed.requestPriority(uid)
                    try? await Task.sleep(for: .milliseconds(120))
                }
                await MainActor.run { [weak self] in
                    self?.loadingUIDs.remove(uid)
                }
            }
        }
    }

    private func imageNeedsLoad(_ uid: PhotoUID) -> Bool {
        feed.memoryImage(for: uid) == nil && loadedImages[uid] == nil && !loadingUIDs.contains(uid)
    }

    private func placeholderColor(for index: Int) -> CGColor {
        let hue = CGFloat((index * 37) % 360) / 360
        return NSColor(calibratedHue: hue, saturation: 0.20, brightness: 0.18, alpha: 1).cgColor
    }

    private func aligned(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let scale = max(scale, 1)
        let minX = floor(rect.minX * scale) / scale
        let minY = floor(rect.minY * scale) / scale
        let maxX = ceil(rect.maxX * scale) / scale
        let maxY = ceil(rect.maxY * scale) / scale
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private func emitStats(force: Bool = false) {
        let now = CACurrentMediaTime()
        if !force, now - lastStatsEmitTime < 1.0 / 15.0 { return }
        lastStatsEmitTime = now

        let geometry = currentGeometry()
        let stats = ApplePrivateGridLayerPrototypeStats(
            privateAPIAvailable: PPApplePrivateGridRuntime.isGridLayoutAvailable(),
            pinchFilterAvailable: pinchFilter.available,
            level: continuousLevel,
            columns: geometry.columns,
            lowColumns: geometry.lowColumns,
            highColumns: geometry.highColumns,
            visibleItems: visibleSprites.count,
            activeLayerCount: visibleSprites.count,
            reusableLayerCount: reusableSprites.count,
            frameMillis: lastFrameMillis,
            anchorIndex: anchorIndex,
            pinchDirection: pinchDirection,
            diagnostics: PPApplePrivateGridRuntime.diagnostics()
        )
        DispatchQueue.main.async { [weak self] in self?.statsHandler?(stats) }
    }

    private func withoutLayerActions(_ updates: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        updates()
        CATransaction.commit()
    }

    private static let disabledAction = DisabledLayerAction()
    fileprivate static let disabledActions: [String: CAAction] = [
        "backgroundColor": disabledAction,
        "bounds": disabledAction,
        "contents": disabledAction,
        "contentsRect": disabledAction,
        "cornerRadius": disabledAction,
        "frame": disabledAction,
        "hidden": disabledAction,
        "opacity": disabledAction,
        "position": disabledAction,
        "sublayers": disabledAction,
        "transform": disabledAction
    ]
}

private final class GridSprite {
    let layer = CALayer()
    let imageLayer = CALayer()
    var index: Int?
    var uid: PhotoUID?

    init() {
        layer.backgroundColor = NSColor(calibratedWhite: 0.065, alpha: 1).cgColor
        layer.masksToBounds = true
        layer.cornerRadius = 8
        layer.geometryFlipped = true
        layer.actions = ApplePrivateGridLayerPrototypeView.disabledActions

        imageLayer.frame = layer.bounds
        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.geometryFlipped = true
        imageLayer.actions = ApplePrivateGridLayerPrototypeView.disabledActions
        layer.addSublayer(imageLayer)
    }

    func setContentsScale(_ scale: CGFloat) {
        layer.contentsScale = scale
        imageLayer.contentsScale = scale
        layer.rasterizationScale = scale
        imageLayer.rasterizationScale = scale
    }

    func showImage(_ image: CGImage) {
        layer.borderWidth = 0
        layer.backgroundColor = NSColor.black.cgColor
        imageLayer.isHidden = false
        imageLayer.contents = image
        imageLayer.contentsGravity = .resizeAspectFill
    }

    func showSyntheticPlaceholder(color: CGColor) {
        layer.borderWidth = 0
        layer.backgroundColor = color
        imageLayer.isHidden = true
        imageLayer.contents = nil
    }

    func showLoadingPlaceholder() {
        layer.backgroundColor = NSColor(calibratedWhite: 0.065, alpha: 1).cgColor
        layer.borderColor = NSColor.white.withAlphaComponent(0.035).cgColor
        layer.borderWidth = layer.bounds.width > 36 && layer.bounds.height > 36 ? 1 : 0
        imageLayer.isHidden = true
        imageLayer.contents = nil
    }

    func prepareForReuse() {
        index = nil
        uid = nil
        layer.borderWidth = 0
        layer.backgroundColor = NSColor(calibratedWhite: 0.065, alpha: 1).cgColor
        imageLayer.isHidden = true
        imageLayer.contents = nil
    }
}

private final class DisabledLayerAction: NSObject, CAAction {
    func run(forKey event: String, object anObject: Any, arguments dict: [AnyHashable: Any]?) {}
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
