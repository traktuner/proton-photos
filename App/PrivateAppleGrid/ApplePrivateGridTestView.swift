import AppKit
import SwiftUI
import PhotosCore
import MediaCache

@MainActor
enum ApplePrivateGridWindow {
    private static var controller: NSWindowController?

    static func present(items: [PhotoItem], feed: ThumbnailFeed) {
        let root = ApplePrivateGridTestView(items: items, feed: feed)
            .preferredColorScheme(.dark)
        let hosting = NSHostingController(rootView: root)

        let window: NSWindow
        if let existing = controller?.window {
            window = existing
            window.contentViewController = hosting
        } else {
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "Apple Private Grid Test"
            window.titlebarAppearsTransparent = true
            window.contentViewController = hosting
            controller = NSWindowController(window: window)
        }

        window.center()
        controller?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct ApplePrivateGridStats: Equatable {
    var privateAPIAvailable = false
    var pinchFilterAvailable = false
    var level: CGFloat = 2
    var columns: CGFloat = 6
    var lowColumns = 6
    var highColumns = 6
    var visibleItems = 0
    var frameMillis: Double = 0
    var anchorIndex: Int?
    var pinchDirection = 0
    var diagnostics = ""
}

struct ApplePrivateGridTestView: View {
    let items: [PhotoItem]
    let feed: ThumbnailFeed

    @State private var stats = ApplePrivateGridStats()

    var body: some View {
        VStack(spacing: 0) {
            header
            ApplePrivateGridRepresentable(items: items, feed: feed) { newStats in
                if stats != newStats {
                    stats = newStats
                }
            }
        }
        .background(Color.black)
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Private Grid Test")
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11, weight: .regular).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            stat("Private", stats.privateAPIAvailable ? "on" : "off")
            stat("PinchFilter", stats.pinchFilterAvailable ? "on" : "off")
            stat("Level", String(format: "%.2f", stats.level))
            stat("Cols", String(format: "%.2f (%d/%d)", stats.columns, stats.lowColumns, stats.highColumns))
            stat("Visible", "\(stats.visibleItems)")
            stat("Frame", String(format: "%.1f ms", stats.frameMillis))
            stat("Anchor", stats.anchorIndex.map(String.init) ?? "-")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial)
    }

    private var subtitle: String {
        if items.isEmpty {
            "No loaded Proton timeline items yet, rendering synthetic placeholders through PXGGridLayout."
        } else {
            "\(items.count) Proton items, Apple private runtime loaded; controlled sprite renderer for the pinch surface."
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
        }
    }
}

private struct ApplePrivateGridRepresentable: NSViewRepresentable {
    let items: [PhotoItem]
    let feed: ThumbnailFeed
    let onStats: (ApplePrivateGridStats) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = ApplePrivateGridScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = false
        scrollView.contentView.postsBoundsChangedNotifications = true

        let document = ApplePrivateGridDocumentView(items: items, feed: feed)
        document.statsHandler = onStats
        document.frame = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        document.autoresizingMask = [.width]
        scrollView.documentView = document
        scrollView.privateGridDocumentView = document

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

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let document = scrollView.documentView as? ApplePrivateGridDocumentView else { return }
        document.statsHandler = onStats
        document.updateIfNeeded(items: items, feed: feed)
        document.fitWidth(scrollView.contentView.bounds.width, preservingVisibleTop: true)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        weak var documentView: ApplePrivateGridDocumentView?
        weak var scrollView: NSScrollView?

        @objc func boundsDidChange(_ note: Notification) {
            guard let scrollView, let documentView else { return }
            documentView.visibleRectDidChange(scrollView.contentView.bounds)
        }
    }
}

private final class ApplePrivateGridScrollView: NSScrollView {
    weak var privateGridDocumentView: ApplePrivateGridDocumentView?

    override func layout() {
        super.layout()
        privateGridDocumentView?.fitWidth(contentView.bounds.width, preservingVisibleTop: true)
    }
}

private final class ApplePrivateGridDocumentView: NSView {
    private static let levelSizes: [CGFloat] = [330, 185, 130, 95, 70, 44]
    private static let levelGaps: [CGFloat] = [12, 8, 6, 4, 3, 2]
    private static let syntheticCount = 1600
    private static let maxVisibleImageLoads = 220

    private var items: [PhotoItem]
    private var feed: ThumbnailFeed
    private let pinchFilter = PPApplePrivatePinchFilter()

    var statsHandler: ((ApplePrivateGridStats) -> Void)?

    private var continuousLevel: CGFloat = 2
    private var pinchAccumulatedMagnification: CGFloat = 0
    private var anchorIndex: Int?
    private var anchorUnit = CGPoint(x: 0.5, y: 0.5)
    private var anchorViewportPoint = CGPoint(x: 0, y: 0)
    private var pinchDirection = 0
    private var visibleItemCount = 0
    private var lastFrameMillis: Double = 0
    private var lastPrefetchSignature = ""
    private var lastStatsEmitTime: CFTimeInterval = 0
    private var lastEmittedStats: ApplePrivateGridStats?
    private var settleTimer: Timer?
    private var prefetchTask: Task<Void, Never>?
    private var isPinching = false
    private var loadedImages: [PhotoUID: NSImage] = [:]
    private var loadingUIDs = Set<PhotoUID>()
    private var itemUIDs: [PhotoUID]
    private var feedID: ObjectIdentifier

    init(items: [PhotoItem], feed: ThumbnailFeed) {
        self.items = items
        self.feed = feed
        self.itemUIDs = items.map(\.uid)
        self.feedID = ObjectIdentifier(feed)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        let pinch = NSMagnificationGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
        addGestureRecognizer(pinch)

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        click.numberOfClicksRequired = 1
        addGestureRecognizer(click)

        PPApplePrivateGridRuntime.loadPrivateFrameworks()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }
    private var itemCount: Int { items.isEmpty ? Self.syntheticCount : items.count }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        invalidateVisible(prefetch: true)
        emitStats(force: true)
    }

    func updateIfNeeded(items: [PhotoItem], feed: ThumbnailFeed) {
        let newFeedID = ObjectIdentifier(feed)
        let newUIDs = items.map(\.uid)
        guard newFeedID != feedID || newUIDs != itemUIDs else { return }

        feedID = newFeedID
        itemUIDs = newUIDs
        prefetchTask?.cancel()
        self.items = items
        self.feed = feed
        if !items.isEmpty {
            let validUIDs = Set(items.map(\.uid))
            loadedImages = loadedImages.filter { validUIDs.contains($0.key) }
            loadingUIDs = loadingUIDs.intersection(validUIDs)
        } else {
            loadedImages.removeAll()
            loadingUIDs.removeAll()
        }
        recomputeContentHeight(preservingAnchor: nil)
        invalidateVisible(prefetch: true)
        emitStats(force: true)
    }

    func fitWidth(_ width: CGFloat, preservingVisibleTop: Bool) {
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
        }
        invalidateVisible(prefetch: true)
        emitStats(force: true)
    }

    func visibleRectDidChange(_ rect: CGRect) {
        prefetchVisibleItems(in: rect)
        setNeedsDisplay(expandedViewport(rect))
        emitStats()
    }

    override func draw(_ dirtyRect: NSRect) {
        let start = CACurrentMediaTime()
        NSColor.black.setFill()
        dirtyRect.fill()

        let viewport = expandedViewport(currentViewportRect())
        let clipRect = viewport.intersection(dirtyRect.insetBy(dx: -viewport.width * 0.08, dy: -viewport.height * 0.20))
        guard !clipRect.isNull, !clipRect.isEmpty else { return }
        let entries = visibleEntries(in: clipRect)
        visibleItemCount = entries.count

        for entry in entries {
            drawItem(index: entry.index, frame: entry.frame)
        }

        lastFrameMillis = (CACurrentMediaTime() - start) * 1000
        emitStats()
    }

    private func currentViewportRect() -> CGRect {
        if let clip = enclosingScrollView?.contentView {
            return clip.bounds
        }
        return bounds
    }

    private func expandedViewport(_ rect: CGRect) -> CGRect {
        rect.insetBy(dx: -rect.width * 0.08, dy: -rect.height * 0.30)
    }

    private func invalidateVisible(prefetch: Bool = false) {
        let viewport = currentViewportRect()
        if prefetch { prefetchVisibleItems(in: viewport) }
        setNeedsDisplay(expandedViewport(viewport))
    }

    private func drawItem(index: Int, frame: CGRect) {
        guard frame.width > 1, frame.height > 1 else { return }
        let radius = min(10, max(2, frame.height * 0.06))
        let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
        NSGraphicsContext.saveGraphicsState()
        if !isPinching || frame.width > 90 {
            path.addClip()
        }

        if let image = image(for: index) {
            let interpolation: NSImageInterpolation = isPinching ? .low : .high
            NSGraphicsContext.current?.imageInterpolation = interpolation
            image.draw(
                in: fittedImageFrame(image: image, cell: frame),
                from: .zero,
                operation: .sourceOver,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: interpolation]
            )
        } else {
            if items.isEmpty {
                placeholderColor(for: index).setFill()
                frame.fill()
                drawSyntheticNumber(index, in: frame)
            } else {
                drawLoadingCell(in: frame)
            }
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private func image(for index: Int) -> NSImage? {
        guard !items.isEmpty, index >= 0, index < items.count else { return nil }
        let uid = items[index].uid
        return feed.memoryImage(for: uid) ?? loadedImages[uid]
    }

    private func fittedImageFrame(image: NSImage, cell: CGRect) -> CGRect {
        let imageAspect = image.size.width / max(image.size.height, 1)
        let cellAspect = cell.width / max(cell.height, 1)
        if imageAspect > cellAspect {
            let height = cell.width / max(imageAspect, 0.001)
            return CGRect(x: cell.minX, y: cell.midY - height / 2, width: cell.width, height: height)
        } else {
            let width = cell.height * imageAspect
            return CGRect(x: cell.midX - width / 2, y: cell.minY, width: width, height: cell.height)
        }
    }

    private func placeholderColor(for index: Int) -> NSColor {
        let hue = CGFloat((index * 37) % 360) / 360
        return NSColor(calibratedHue: hue, saturation: 0.20, brightness: 0.18, alpha: 1)
    }

    private func drawLoadingCell(in frame: CGRect) {
        NSColor(calibratedWhite: 0.065, alpha: 1).setFill()
        frame.fill()
        if frame.width > 36, frame.height > 36 {
            NSColor.white.withAlphaComponent(0.035).setStroke()
            let stroke = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: min(10, frame.height * 0.06), yRadius: min(10, frame.height * 0.06))
            stroke.lineWidth = 1
            stroke.stroke()
        }
    }

    private func drawSyntheticNumber(_ index: Int, in frame: CGRect) {
        guard frame.width > 34, frame.height > 24 else { return }
        let text = "\(index)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: min(16, frame.height * 0.18), weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.55)
        ]
        let size = text.size(withAttributes: attrs)
        text.draw(
            at: CGPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2),
            withAttributes: attrs
        )
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
        let visible = clip?.bounds ?? CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: max(bounds.height, 1))
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
            isPinching = true
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
            let target = continuousLevel - delta * 2.25
            setContinuousLevel(target, preservingAnchor: anchorIndex)
        case .ended, .cancelled, .failed:
            isPinching = false
            recognizer.magnification = 0
            settleToNearestLevel()
        default:
            break
        }
    }

    @objc private func handleClick(_ recognizer: NSClickGestureRecognizer) {
        let point = recognizer.location(in: self)
        anchorIndex = itemIndex(at: point)
        if let anchorIndex {
            invalidateVisible()
            emitStats(force: true)
        }
    }

    private func setContinuousLevel(_ level: CGFloat, preservingAnchor anchor: Int?) {
        continuousLevel = min(max(level, 0), CGFloat(Self.levelSizes.count - 1))
        recomputeContentHeight(preservingAnchor: anchor)
        invalidateVisible(prefetch: true)
        emitStats()
    }

    private func settleToNearestLevel() {
        let from = continuousLevel
        let to = min(max(round(from), 0), CGFloat(Self.levelSizes.count - 1))
        guard abs(from - to) > 0.001 else {
            continuousLevel = to
            prefetchVisibleItems(in: currentViewportRect())
            emitStats(force: true)
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
            self.setContinuousLevel(from + (to - from) * eased, preservingAnchor: self.anchorIndex)
            if raw >= 1 {
                timer.invalidate()
                self.continuousLevel = to
                self.prefetchVisibleItems(in: self.currentViewportRect())
                self.emitStats(force: true)
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
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let entries = visibleEntries(in: rect.insetBy(dx: -rect.width * 0.12, dy: -rect.height * 0.55))
            .sorted {
                distanceSquared($0.frame.center, center) < distanceSquared($1.frame.center, center)
            }
        let priorityIndices = Array(entries.map(\.index).prefix(600))
        let decodeIndices = Array(priorityIndices.prefix(Self.maxVisibleImageLoads))
        let signature = "\(priorityIndices.first ?? -1)-\(priorityIndices.last ?? -1)-\(priorityIndices.count)-\(Int(continuousLevel * 100))"
        guard signature != lastPrefetchSignature else { return }
        lastPrefetchSignature = signature
        let priorityUIDs = priorityIndices.compactMap { index -> PhotoUID? in
            guard index >= 0, index < items.count else { return nil }
            return items[index].uid
        }
        let decodeUIDs = decodeIndices.compactMap { index -> PhotoUID? in
            guard index >= 0, index < items.count else { return nil }
            return items[index].uid
        }.filter { imageNeedsLoad($0) }

        guard !priorityUIDs.isEmpty else { return }
        prefetchTask?.cancel()
        loadingUIDs.removeAll()
        for uid in decodeUIDs {
            loadingUIDs.insert(uid)
        }

        let feed = feed
        prefetchTask = Task { [weak self] in
            for uid in priorityUIDs {
                if Task.isCancelled { return }
                await feed.requestPriority(uid)
            }

            var loadedAny = false
            for uid in decodeUIDs {
                if Task.isCancelled { return }
                for _ in 0 ..< 4 {
                    if Task.isCancelled { return }
                    if let image = await feed.cachedImage(for: uid) {
                        await MainActor.run { [weak self] in
                            guard let self else { return }
                            self.loadedImages[uid] = image
                            self.loadingUIDs.remove(uid)
                        }
                        loadedAny = true
                        break
                    }
                    await feed.requestPriority(uid)
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }

            await MainActor.run { [weak self] in
                guard let self else { return }
                for uid in decodeUIDs { self.loadingUIDs.remove(uid) }
                if loadedAny {
                    self.invalidateVisible()
                }
            }
        }
    }

    private func imageNeedsLoad(_ uid: PhotoUID) -> Bool {
        feed.memoryImage(for: uid) == nil && loadedImages[uid] == nil && !loadingUIDs.contains(uid)
    }

    private func emitStats(force: Bool = false) {
        let now = CACurrentMediaTime()
        if !force, now - lastStatsEmitTime < 1.0 / 15.0 { return }

        let geometry = currentGeometry()
        let stats = ApplePrivateGridStats(
            privateAPIAvailable: PPApplePrivateGridRuntime.isGridLayoutAvailable(),
            pinchFilterAvailable: pinchFilter.available,
            level: continuousLevel,
            columns: geometry.columns,
            lowColumns: geometry.lowColumns,
            highColumns: geometry.highColumns,
            visibleItems: visibleItemCount,
            frameMillis: lastFrameMillis,
            anchorIndex: anchorIndex,
            pinchDirection: pinchDirection,
            diagnostics: PPApplePrivateGridRuntime.diagnostics()
        )
        guard force || stats != lastEmittedStats else { return }
        lastStatsEmitTime = now
        lastEmittedStats = stats
        DispatchQueue.main.async { [weak self] in self?.statsHandler?(stats) }
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
