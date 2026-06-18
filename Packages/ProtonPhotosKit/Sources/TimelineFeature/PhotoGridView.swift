import SwiftUI
import AppKit
import QuartzCore
import UniformTypeIdentifiers
import PhotosCore
import MediaCache

/// The photo grid (NSCollectionView) with Apple-Photos' 6 discrete resting zoom levels.
/// During pinch, the resting levels are only snap points: the active gesture is rendered as a stable
/// source surface plus target ghosts, then committed atomically to the nearest level.
struct PhotoGridView: NSViewRepresentable {
    let sections: [TimelineSection]
    let allItems: [PhotoItem]
    let feed: ThumbnailFeed
    let sectionAspects: [[CGFloat]]
    @Binding var level: Int
    let onOpen: (PhotoItem, [PhotoItem]) -> Void
    var proxy: GridProxy?
    var selectionMode: Bool = false
    var onSelectionChange: (Set<PhotoUID>) -> Void = { _ in }
    var favoriteUIDs: Set<PhotoUID> = []
    /// Full-media provider used to write the original file when a photo is dragged to Finder.
    var media: FullMediaProvider?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = JustifiedCollectionLayout()
        layout.level = level

        let collectionView = MagnifyingCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.wantsLayer = true            // needed for the live pinch layer-scale
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.dataSource = context.coordinator
        collectionView.delegate = context.coordinator
        collectionView.allowsMultipleSelection = true
        collectionView.register(PhotoGridItem.self, forItemWithIdentifier: PhotoGridItem.identifier)
        collectionView.setDraggingSourceOperationMask(.copy, forLocal: false)   // drag photos to Finder

        let scrollView = NSScrollView()
        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.contentView.postsBoundsChangedNotifications = true
        collectionView.postsFrameChangedNotifications = true

        // Raw magnify events (NOT an NSMagnificationGestureRecognizer): the recognizer waits for a
        // threshold before firing, which makes the pinch feel slow to start and then jump. The override
        // delivers the very first tiny trackpad delta straight to the session.
        collectionView.onMagnify = { [weak coordinator = context.coordinator] event in
            coordinator?.handleRawMagnify(event)
        }
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.userDidScroll),
            name: NSScrollView.willStartLiveScrollNotification, object: scrollView
        )
        // Track the top-visible photo on scroll, and re-anchor it when the grid WIDTH changes
        // (sidebar slide / window resize) so the content rescales around it instead of jumping.
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.clipBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            context.coordinator, selector: #selector(Coordinator.gridFrameChanged),
            name: NSView.frameDidChangeNotification, object: collectionView
        )

        context.coordinator.collectionView = collectionView
        context.coordinator.layout = layout
        context.coordinator.scrollView = scrollView
        context.coordinator.wireProxy(proxy)
        context.coordinator.apply(sections: sections, sectionAspects: sectionAspects)
        DispatchQueue.main.async { [weak coordinator = context.coordinator] in
            MainActor.assumeIsolated { coordinator?.ensureResizeWindowObservers() }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.wireProxy(proxy)
        context.coordinator.setSelectionMode(selectionMode)
        context.coordinator.setFavorites(favoriteUIDs)
        context.coordinator.ensureResizeWindowObservers()
        context.coordinator.apply(sections: sections, sectionAspects: sectionAspects)
        if let layout = context.coordinator.layout, layout.level != level, !context.coordinator.gridZoomBusy {
            context.coordinator.setLevel(level, anchorViewportCenter: true)
        }
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var parent: PhotoGridView
        weak var collectionView: NSCollectionView?
        weak var layout: JustifiedCollectionLayout?
        weak var scrollView: NSScrollView?
        var isPinching = false
        private var isGridZoomSettling = false
        var gridZoomBusy: Bool { isPinching || isGridZoomSettling || pinchSession != nil }
        var stickToBottom = true

        private var sections: [TimelineSection] = []
        private var sectionItemCounts: [Int] = []
        private var lastAspects: [[CGFloat]] = []
        private var indexByUID: [PhotoUID: IndexPath] = [:]
        // Selection mode.
        private var selectionMode = false
        private var selectedUIDs: Set<PhotoUID> = []
        private var favoriteUIDs: Set<PhotoUID> = []
        let promiseHandler = FilePromiseHandler()
        // Month/year labels shown on the square (zoomed-out) levels.
        private var monthMarkers: [(index: Int, text: String)] = []
        private var monthLabels: [MonthLabelView] = []
        /// The gesture focus. The user points at the DISPLAYED PHOTO, not an abstract cell — so when the
        /// cursor is inside the visible (aspect-fit / cropped) image we keep the IMAGE-local point and
        /// anchor on the displayed-image frame at every level (`.assetImage`); inside the cell but on the
        /// letterbox bars we keep the cell-local point (`.assetCell`); in a gap we keep the raw content
        /// point (`.content`). This is what keeps the SAME photo point under the cursor across the gesture.
        private enum ZoomAnchor {
            case assetImage(uid: PhotoUID, imageLocalUnitPoint: CGPoint, cellLocalUnitPoint: CGPoint,
                            imageSize: CGSize, viewportPoint: CGPoint, contentPoint: CGPoint, sourceIndexPath: IndexPath)
            case assetCell(uid: PhotoUID, cellLocalUnitPoint: CGPoint,
                           viewportPoint: CGPoint, contentPoint: CGPoint, sourceIndexPath: IndexPath)
            case content(contentPoint: CGPoint, viewportPoint: CGPoint)

            var viewportPoint: CGPoint {
                switch self {
                case .assetImage(_, _, _, _, let vp, _, _), .assetCell(_, _, let vp, _, _), .content(_, let vp):
                    return vp
                }
            }

            var contentPoint: CGPoint {
                switch self {
                case .assetImage(_, _, _, _, _, let cp, _), .assetCell(_, _, _, let cp, _), .content(let cp, _):
                    return cp
                }
            }

            var uid: PhotoUID? {
                switch self {
                case .assetImage(let uid, _, _, _, _, _, _), .assetCell(let uid, _, _, _, _): return uid
                case .content: return nil
                }
            }
        }

        private struct PinchSession {
            let sourceLevel: Int
            let sourceZoomSize: CGFloat
            let sourceOrigin: CGPoint
            let viewportSize: CGSize
            let anchor: ZoomAnchor
            /// All visible source proxies present on the overlay — page 0 PLUS appended coverage pages
            /// (Phase 2). The commit planner inspects ALL of them, not just page 0, so the chosen origin
            /// preserves the visible neighborhood rather than a single anchor point.
            var sourceSnapshotsByUID: [PhotoUID: GridCellSnapshot]
            var targetLevel: Int
            var progress: CGFloat
            var visualScale: CGFloat
            var apparentSize: CGFloat
            /// Coarse bound of the source sheet (= the occlusion mask's bounding rect). Used for the
            /// gate / coverage math, NOT as the precise occlusion (a single rect over-blocks → black box).
            var sourcePlateRect: CGRect
            /// Union of source thumbnail image frames only. Diagnostics/commit-proxy context.
            var sourceSpriteBounds: CGRect
            /// The PRECISE source occlusion — per-row bands built from the captured cell frames. QUARANTINED
            /// (pass #10): kept only for coverage DIAGNOSTICS; it no longer decides target visibility (the
            /// per-photo focus-row + source-coverage test does). Must never render as a rectangle.
            var occlusionMask: GridZoomMath.SourceOcclusionMask
            /// The PROTECTED focus row: every photo sharing the pointer's row at the source level. During
            /// `.changed` NO target node is drawn for these, and they are the last thing replaced on settle
            /// — so the focused photo/row stays visually stable under the pointer.
            var focusRowUIDs: Set<PhotoUID>
            /// The pointer row's band in source viewport coords (diagnostics / focus-band geometry).
            var sourceRowBand: CGRect?
        }

        // MARK: - Per-cell global compositor (pass #11): two world snapshots → per-photo crossfade nodes

        /// One global, deterministic grid layout — the SOURCE level at begin, or the TARGET detent. The
        /// compositor transitions BETWEEN two of these. Frames are viewport-BASE (before the live scale).
        struct ZoomWorldSnapshot {
            let level: Int
            let origin: CGPoint
            let cropMode: GridCropMode
            let imageByUID: [PhotoUID: CGRect]   // viewport-base displayed-image frame per photo
            let visibleUIDs: [PhotoUID]
        }

        /// One photo's role in the live transition. The renderer draws a SOURCE sprite (scaled by
        /// `sourceScale` around the anchor, opacity `sourceAlpha`) and/or a TARGET sprite (scaled by
        /// `targetScale`, opacity `targetAlpha`). Outside the focus band the two crossfade per cell; inside
        /// it `sourceAlpha == 1` and `targetAlpha == 0` (the focus row stays source-stable).
        struct ZoomVisualNode {
            let uid: PhotoUID
            let sourceImageFrame: CGRect?
            let targetImageFrame: CGRect?
            let isAnchorUID: Bool
            let isFocusRow: Bool
            let isFocusBand: Bool
            let isEdgeOrTargetOnly: Bool
            let sourceAlpha: CGFloat
            let targetAlpha: CGFloat
        }

        /// The whole live transition: two global snapshots, the protected focus set, and the per-photo
        /// nodes. Built fresh each `.changed` tick (CPU compositor — correctness over speed, per the spec).
        struct ZoomWorldTransitionPlan {
            let source: ZoomWorldSnapshot
            let target: ZoomWorldSnapshot?
            let focusRowUIDs: Set<PhotoUID>
            let focusBand: CGRect
            let liveProgress: CGFloat
            let sourceScale: CGFloat
            let targetScale: CGFloat
            var nodes: [ZoomVisualNode]
        }

        private var pinchSession: PinchSession?
        private var deferredApply: (sections: [TimelineSection], sectionAspects: [[CGFloat]])?
        private var lastPinchLogTime: CFTimeInterval = -1000

        init(_ parent: PhotoGridView) {
            self.parent = parent
            super.init()
            resizeHintObserver = NotificationCenter.default.addObserver(
                forName: .protonPhotosGridResizeHint,
                object: nil,
                queue: .main
            ) { [weak self] note in
                let reason = note.userInfo?["reason"] as? String
                let phase = note.userInfo?["phase"] as? String
                MainActor.assumeIsolated {
                    self?.handleResizeHint(reasonRaw: reason, phase: phase)
                }
            }
        }

        deinit {
            let nc = NotificationCenter.default
            resizeWindowObservers.forEach(nc.removeObserver)
            if let resizeHintObserver { nc.removeObserver(resizeHintObserver) }
            resizeCommitWork?.cancel()
        }

        func apply(sections: [TimelineSection], sectionAspects: [[CGFloat]]) {
            let counts = sections.map(\.items.count)
            let structureChanged = counts != sectionItemCounts
            let aspectsChanged = sectionAspects != lastAspects
            // Nothing actually changed (e.g. SwiftUI re-runs updateNSView during the sidebar width
            // animation): do NO work. Re-justifying or pinning to the bottom on every frame here was
            // the source of the sidebar stutter — the width reflow is handled by the layout's own
            // bounds-change invalidation, which is enough.
            guard structureChanged || aspectsChanged else { return }

            if gridZoomBusy {
                deferredApply = (sections, sectionAspects)
                logGridZoom("defer apply during gridZoomBusy=\(gridZoomBusy) settling=\(isGridZoomSettling) structure=\(structureChanged) aspects=\(aspectsChanged)")
                return
            }

            self.sections = sections
            self.sectionItemCounts = counts
            self.lastAspects = sectionAspects
            layout?.sectionAspects = sectionAspects

            if structureChanged {
                rebuildIndex()
                computeMonthMarkers()
                assert(!gridZoomBusy, "reloadData attempted during grid zoom")
                logGridZoom("reloadData structureChanged=\(structureChanged)")
                collectionView?.reloadData()
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.collectionView?.layoutSubtreeIfNeeded()
                    if self.stickToBottom { self.pinToBottom() }
                    self.updateMonthLabels()
                }
            } else {
                // Only aspect ratios were learned — re-justify, but don't fight the user's scroll.
                assert(!gridZoomBusy, "layout invalidation attempted during grid zoom")
                logGridZoom("invalidate layout for aspect update")
                layout?.invalidateLayout()
                DispatchQueue.main.async { [weak self] in self?.updateMonthLabels() }
            }
        }

        private func computeMonthMarkers() {
            monthMarkers.removeAll(keepingCapacity: true)
            guard let items = sections.first?.items, !items.isEmpty else { return }
            let cal = Calendar.current
            let fmt = DateFormatter(); fmt.dateFormat = "LLLL yyyy"
            var lastKey = -1
            for (i, item) in items.enumerated() {
                let c = cal.dateComponents([.year, .month], from: item.captureTime)
                let key = (c.year ?? 0) * 100 + (c.month ?? 0)
                if key != lastKey {
                    lastKey = key
                    monthMarkers.append((i, fmt.string(from: item.captureTime)))
                }
            }
        }

        /// Position the month/year labels at the row where each month starts — only on the square
        /// (zoomed-out) levels, hidden otherwise. They live in the document view so they scroll with
        /// the grid, and sit above the cells via zPosition.
        @MainActor private func updateMonthLabels() {
            guard let cv = collectionView, let layout else { return }
            let show = JustifiedCollectionLayout.levels[min(max(layout.level, 0), JustifiedCollectionLayout.levels.count - 1)].monthLabels
            guard show, !monthMarkers.isEmpty else {
                for v in monthLabels { v.isHidden = true }
                return
            }
            while monthLabels.count < monthMarkers.count {
                let v = MonthLabelView()
                cv.addSubview(v)
                monthLabels.append(v)
            }
            for (i, marker) in monthMarkers.enumerated() {
                let v = monthLabels[i]
                guard let a = layout.layoutAttributesForItem(at: IndexPath(item: marker.index, section: 0)) else {
                    v.isHidden = true; continue
                }
                v.setText(marker.text)
                v.frame = NSRect(x: 6, y: a.frame.minY + 4, width: v.fittingWidth, height: 22)
                v.isHidden = false
            }
            for i in monthMarkers.count ..< monthLabels.count { monthLabels[i].isHidden = true }
        }

        @MainActor private func pinToBottom() {
            guard stickToBottom, !gridZoomBusy,
                  let cv = collectionView, let clip = scrollView?.contentView, let layout else { return }
            cv.layoutSubtreeIfNeeded()
            let maxY = max(0, layout.collectionViewContentSize.height - clip.bounds.height)
            clip.setBoundsOrigin(NSPoint(x: 0, y: maxY))
            scrollView?.reflectScrolledClipView(clip)
        }

        @objc func userDidScroll() { stickToBottom = false }

        // MARK: - Resize/sidebar frozen-surface transition

        private enum ResizeVisualAnchor {
            case item(indexPath: IndexPath, unitPoint: CGPoint, viewportPoint: CGPoint, kind: GridResizeAnchorKind)
            case content(GridResizeAnchor)

            var gridAnchor: GridResizeAnchor {
                switch self {
                case .item(_, _, let viewportPoint, let kind):
                    return GridResizeAnchor(kind: kind, viewportPoint: viewportPoint, contentPoint: .zero)
                case .content(let anchor):
                    return anchor
                }
            }
        }

        private let resizeCoordinator = GridResizeTransitionCoordinator()
        private var resizeVisualAnchor: ResizeVisualAnchor?
        private var resizeOverlayHost: FlippedOverlayView?
        private var resizeOverlayLayer: CALayer?
        private var resizeOverlaySerial = 0
        nonisolated(unsafe) private var resizeCommitWork: DispatchWorkItem?
        private var resizeWindow: NSWindow?
        nonisolated(unsafe) private var resizeWindowObservers: [NSObjectProtocol] = []
        nonisolated(unsafe) private var resizeHintObserver: NSObjectProtocol?
        private var pendingResizeReason: GridResizeTransitionReason?
        private var isWindowLiveResizing = false
        private var lastGridWidth: CGFloat = 0
        private var lastViewportSize: CGSize = .zero
        private var isReanchoring = false

        /// On genuine user scroll, continue prefetching and remembering user intent. During a resize
        /// transaction this deliberately does NOT chase anchors: the transaction's frozen anchor is the
        /// single source of truth until commit.
        @MainActor @objc func clipBoundsChanged() {
            guard !gridZoomBusy else { return }
            if let clip = scrollView?.contentView {
                let size = clip.bounds.size
                if lastViewportSize == .zero {
                    lastViewportSize = size
                    return
                }
                if abs(size.width - lastViewportSize.width) > 0.5 || abs(size.height - lastViewportSize.height) > 0.5 {
                    lastViewportSize = size
                    handleResizeViewportChange(reason: currentResizeReason())
                }
            }
            prefetchAhead()
        }

        // MARK: - Scroll-velocity-aware thumbnail prefetch

        private var lastPrefetchY: CGFloat = -1_000_000

        /// As the user scrolls, bump thumbnail-decode priority for the ~1.5 screens of photos coming
        /// up in the scroll direction, so they're ready before they reach the viewport. Throttled to
        /// roughly every half-screen so it doesn't spam the feed during a fast flick.
        @MainActor private func prefetchAhead() {
            guard !gridZoomBusy, !isReanchoring, let cv = collectionView, let clip = scrollView?.contentView, let layout else { return }
            let y = clip.bounds.origin.y, vh = clip.bounds.height
            guard abs(y - lastPrefetchY) > vh * 0.4 else { return }
            let down = y >= lastPrefetchY
            lastPrefetchY = y
            let lookahead = vh * 1.5
            let rect = down
                ? NSRect(x: 0, y: y + vh, width: cv.bounds.width, height: lookahead)
                : NSRect(x: 0, y: max(0, y - lookahead), width: cv.bounds.width, height: lookahead)
            var uids: [PhotoUID] = []
            for a in layout.layoutAttributesForElements(in: rect) {
                guard let ip = a.indexPath, ip.section < sections.count, ip.item < sections[ip.section].items.count else { continue }
                uids.append(sections[ip.section].items[ip.item].uid)
            }
            let targets = Array(uids.prefix(80)), feed = parent.feed
            Task { for uid in targets { await feed.requestPriority(uid, priority: .nearViewportScrollAhead) } }
        }

        /// On ANY width change (window resize AND sidebar slide), re-pin the scroll to the photo that
        /// was visible BEFORE the resize. The real collection view may relayout underneath, but it is
        /// masked by the resize overlay until the debounce commit restores the anchor and fades out.
        @MainActor @objc func gridFrameChanged() {
            guard let cv = collectionView else { return }
            let w = cv.bounds.width
            if lastGridWidth == 0 {
                lastGridWidth = w
                return
            }
            guard abs(w - lastGridWidth) > 0.5 else { return }
            lastGridWidth = w
            handleResizeViewportChange(reason: currentResizeReason())
        }

        @MainActor func ensureResizeWindowObservers() {
            guard let window = collectionView?.window ?? scrollView?.window, resizeWindow !== window else { return }
            let nc = NotificationCenter.default
            resizeWindowObservers.forEach(nc.removeObserver)
            resizeWindowObservers.removeAll()
            resizeWindow = window
            resizeWindowObservers.append(nc.addObserver(
                forName: NSWindow.willStartLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isWindowLiveResizing = true
                    self?.beginResizeTransaction(reason: .windowResize)
                }
            })
            resizeWindowObservers.append(nc.addObserver(
                forName: NSWindow.didResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleResizeViewportChange(reason: .windowResize)
                }
            })
            resizeWindowObservers.append(nc.addObserver(
                forName: NSWindow.didEndLiveResizeNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.isWindowLiveResizing = false
                    self?.handleResizeViewportChange(reason: .windowResize)
                }
            })
        }

        @MainActor private func handleResizeHint(reasonRaw raw: String?, phase: String?) {
            guard let raw,
                  let reason = GridResizeTransitionReason(rawValue: raw) else { return }
            pendingResizeReason = reason
            if phase == "begin" {
                beginResizeTransaction(reason: reason)
            } else {
                handleResizeViewportChange(reason: reason)
            }
        }

        @MainActor private func currentResizeReason() -> GridResizeTransitionReason {
            if isWindowLiveResizing { return .windowResize }
            return pendingResizeReason ?? .sidebarDrag
        }

        @MainActor private func handleResizeViewportChange(reason: GridResizeTransitionReason) {
            guard !gridZoomBusy else { return }
            guard resizeCoordinator.activeTransaction != nil else {
                beginResizeTransaction(reason: reason)
                return
            }
            if case .committing = resizeCoordinator.state {
                resizeOverlayLayer?.removeAllAnimations()
                resizeOverlayLayer?.opacity = 1
                collectionView?.alphaValue = 0
            }
            guard let viewportSize = scrollView?.contentView.bounds.size else { return }
            let now = CACurrentMediaTime()
            resizeCoordinator.noteSizeChange(
                targetViewportSize: viewportSize,
                sidebarWidth: nil,
                now: now
            )
            updateResizeOverlayFrame()
            scheduleResizeCommit()
        }

        @MainActor private func beginResizeTransaction(reason: GridResizeTransitionReason) {
            guard !gridZoomBusy else { return }
            guard resizeCoordinator.activeTransaction == nil else {
                handleResizeViewportChange(reason: reason)
                return
            }
            guard let cv = collectionView, let clip = scrollView?.contentView, let scrollView else { return }
            let sourceViewport = clip.bounds.size
            guard sourceViewport.width > 1, sourceViewport.height > 1 else { return }
            cv.layoutSubtreeIfNeeded()

            let visible = cv.visibleRect
            guard let rep = cv.bitmapImageRepForCachingDisplay(in: visible) else { return }
            cv.cacheDisplay(in: visible, to: rep)
            guard let snapshot = rep.cgImage else { return }

            let visualAnchor = captureResizeAnchor()
            resizeVisualAnchor = visualAnchor
            let anchor = resolvedGridResizeAnchor(from: visualAnchor)

            resizeOverlayHost?.removeFromSuperview()
            let host = FlippedOverlayView(frame: clip.frame)
            host.wantsLayer = true
            host.layer?.masksToBounds = true
            host.layer?.backgroundColor = NSColor.clear.cgColor
            scrollView.addSubview(host, positioned: .above, relativeTo: nil)

            let layer = CALayer()
            layer.contents = snapshot
            layer.contentsGravity = .resize
            layer.contentsScale = cv.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            layer.minificationFilter = .linear
            layer.magnificationFilter = .linear
            layer.frame = CGRect(origin: .zero, size: sourceViewport)
            host.layer?.addSublayer(layer)
            resizeOverlayHost = host
            resizeOverlayLayer = layer
            resizeOverlaySerial += 1

            let now = CACurrentMediaTime()
            let transaction = resizeCoordinator.begin(
                reason: reason,
                sourceViewportSize: sourceViewport,
                sourceContentOrigin: clip.bounds.origin,
                sourceVisibleRect: visible,
                sourceSnapshotSize: CGSize(width: CGFloat(snapshot.width) / layer.contentsScale, height: CGFloat(snapshot.height) / layer.contentsScale),
                sourceSnapshotFrame: CGRect(origin: .zero, size: sourceViewport),
                anchor: anchor,
                sidebarWidth: nil,
                now: now,
                overlayID: resizeOverlaySerial
            )
            cv.alphaValue = 0
            updateResizeOverlayFrame()
            scheduleResizeCommit()
            logGridResize(
                "state=begin reason=\(reason.rawValue) sourceViewport=\(sizeLog(sourceViewport)) targetViewport=\(sizeLog(transaction.pendingTargetViewportSize)) anchor=\(anchorLog(anchor)) snapshotSize=\(sizeLog(transaction.sourceSnapshotSize)) overlayScale=1.00 commitDebounceMs=\(Int(GridResizeTransitionCoordinator.defaultDebounce * 1000))"
            )
        }

        @MainActor private func updateResizeOverlayFrame() {
            guard let host = resizeOverlayHost, let overlay = resizeOverlayLayer,
                  let clip = scrollView?.contentView,
                  let transaction = resizeCoordinator.activeTransaction else { return }
            host.frame = clip.frame
            let transform = GridResizeTransitionCoordinator.overlayTransform(
                sourceViewportSize: transaction.sourceViewportSize,
                targetViewportSize: clip.bounds.size,
                anchor: transaction.anchor
            )
            overlay.frame = transform.frame
        }

        @MainActor private func scheduleResizeCommit() {
            resizeCommitWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.commitResizeIfSettled() }
            }
            resizeCommitWork = work
            DispatchQueue.main.asyncAfter(
                deadline: .now() + GridResizeTransitionCoordinator.defaultDebounce,
                execute: work
            )
        }

        @MainActor private func commitResizeIfSettled() {
            let now = CACurrentMediaTime()
            guard resizeCoordinator.readyToCommit(now: now) else {
                scheduleResizeCommit()
                return
            }
            guard let transaction = resizeCoordinator.beginCommit(),
                  let cv = collectionView,
                  let clip = scrollView?.contentView,
                  let layout else {
                cleanupResizeOverlay()
                resizeCoordinator.cleanup()
                return
            }

            let before = clip.bounds.origin
            let layoutStart = CACurrentMediaTime()
            isReanchoring = true
            layout.invalidateLayout()
            cv.layoutSubtreeIfNeeded()
            let commitResult = commitResizeAnchor(transaction: transaction)
            cv.layoutSubtreeIfNeeded()
            updateMonthLabels()
            isReanchoring = false
            let layoutMs = (CACurrentMediaTime() - layoutStart) * 1000
            let after = clip.bounds.origin
            cv.alphaValue = 1

            logGridResize(
                "state=commit reason=\(transaction.reason.rawValue) finalViewport=\(sizeLog(clip.bounds.size)) scrollOriginBefore=\(pointLog(before)) scrollOriginAfter=\(pointLog(after)) anchorError=\(pointLog(commitResult.anchorError)) layoutMs=\(fmt(layoutMs)) fadeDuration=\(fmt(GridResizeTransitionCoordinator.defaultFadeDuration))"
            )
            fadeResizeOverlay(transactionID: transaction.id)
        }

        @MainActor private func commitResizeAnchor(transaction: GridResizeTransaction) -> GridResizeCommitResult {
            guard let clip = scrollView?.contentView, let layout else {
                return GridResizeCommitResult(scrollOrigin: .zero, anchorError: .zero)
            }
            let viewport = clip.bounds.size
            let viewportPoint = CGPoint(
                x: min(max(transaction.anchor.viewportPoint.x, 0), viewport.width),
                y: min(max(transaction.anchor.viewportPoint.y, 0), viewport.height)
            )
            let targetContentPoint: CGPoint
            if let resizeVisualAnchor {
                switch resizeVisualAnchor {
                case .item(let indexPath, let unitPoint, _, _):
                    if let attrs = layout.layoutAttributesForItem(at: indexPath) {
                        targetContentPoint = CGPoint(
                            x: attrs.frame.minX + unitPoint.x * attrs.frame.width,
                            y: attrs.frame.minY + unitPoint.y * attrs.frame.height
                        )
                    } else {
                        targetContentPoint = transaction.anchor.contentPoint
                    }
                case .content(let anchor):
                    targetContentPoint = anchor.contentPoint
                }
            } else {
                targetContentPoint = transaction.anchor.contentPoint
            }
            let result = GridResizeTransitionCoordinator.preservedScrollOrigin(
                sourceAnchorContentPoint: targetContentPoint,
                targetAnchorViewportPoint: viewportPoint,
                targetContentSize: layout.collectionViewContentSize,
                targetViewportSize: viewport
            )
            clip.setBoundsOrigin(result.scrollOrigin)
            scrollView?.reflectScrolledClipView(clip)
            return result
        }

        @MainActor private func fadeResizeOverlay(transactionID: Int) {
            guard let overlay = resizeOverlayLayer else {
                finishResizeTransition(transactionID: transactionID)
                return
            }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = GridResizeTransitionCoordinator.defaultFadeDuration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self] in
                MainActor.assumeIsolated {
                    self?.finishResizeTransition(transactionID: transactionID)
                }
            }
            overlay.add(fade, forKey: "gridResizeFade")
            CATransaction.commit()
        }

        @MainActor private func finishResizeTransition(transactionID: Int) {
            guard case let .committing(transaction) = resizeCoordinator.state,
                  transaction.id == transactionID else { return }
            cleanupResizeOverlay()
            resizeCoordinator.finishCommit()
            pendingResizeReason = nil
            logGridResize("state=end removedOverlay=true")
        }

        @MainActor private func cleanupResizeOverlay() {
            resizeCommitWork?.cancel()
            resizeCommitWork = nil
            resizeOverlayLayer?.removeAllAnimations()
            resizeOverlayHost?.removeFromSuperview()
            resizeOverlayHost = nil
            resizeOverlayLayer = nil
            resizeVisualAnchor = nil
            collectionView?.alphaValue = 1
            isReanchoring = false
        }

        @MainActor private func captureResizeAnchor() -> ResizeVisualAnchor {
            guard let cv = collectionView, let clip = scrollView?.contentView, let layout else {
                return .content(GridResizeAnchor(kind: .content, viewportPoint: .zero, contentPoint: .zero))
            }
            let viewport = clip.bounds.size
            let mousePoint = mouseViewportPoint(in: clip)
            if let mousePoint {
                let contentPoint = CGPoint(x: clip.bounds.origin.x + mousePoint.x, y: clip.bounds.origin.y + mousePoint.y)
                if let ip = cv.indexPathForItem(at: contentPoint),
                   let attrs = layout.layoutAttributesForItem(at: ip) {
                    return .item(indexPath: ip, unitPoint: unitPoint(contentPoint, in: attrs.frame), viewportPoint: mousePoint, kind: .mouse)
                }
                return .content(GridResizeAnchor(kind: .mouse, viewportPoint: mousePoint, contentPoint: contentPoint))
            }

            if let selected = selectedUIDs.compactMap({ indexByUID[$0] }).first(where: { indexPath in
                guard let attrs = layout.layoutAttributesForItem(at: indexPath) else { return false }
                return clip.documentVisibleRect.intersects(attrs.frame)
            }), let attrs = layout.layoutAttributesForItem(at: selected) {
                let contentPoint = CGPoint(x: attrs.frame.midX, y: attrs.frame.midY)
                let viewportPoint = CGPoint(x: contentPoint.x - clip.bounds.origin.x, y: contentPoint.y - clip.bounds.origin.y)
                return .item(indexPath: selected, unitPoint: CGPoint(x: 0.5, y: 0.5), viewportPoint: viewportPoint, kind: .selectedItem)
            }

            let viewportPoint = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
            let contentPoint = CGPoint(x: clip.bounds.origin.x + viewportPoint.x, y: clip.bounds.origin.y + viewportPoint.y)
            if let ip = cv.indexPathForItem(at: contentPoint),
               let attrs = layout.layoutAttributesForItem(at: ip) {
                return .item(indexPath: ip, unitPoint: unitPoint(contentPoint, in: attrs.frame), viewportPoint: viewportPoint, kind: .viewportCenter)
            }
            return .content(GridResizeAnchor(kind: .viewportCenter, viewportPoint: viewportPoint, contentPoint: contentPoint))
        }

        @MainActor private func resolvedGridResizeAnchor(from visual: ResizeVisualAnchor) -> GridResizeAnchor {
            guard let layout else { return visual.gridAnchor }
            switch visual {
            case .item(let indexPath, let unitPoint, let viewportPoint, let kind):
                let attrs = layout.layoutAttributesForItem(at: indexPath)
                let contentPoint = CGPoint(
                    x: (attrs?.frame.minX ?? 0) + unitPoint.x * (attrs?.frame.width ?? 0),
                    y: (attrs?.frame.minY ?? 0) + unitPoint.y * (attrs?.frame.height ?? 0)
                )
                return GridResizeAnchor(kind: kind, viewportPoint: viewportPoint, contentPoint: contentPoint)
            case .content(let anchor):
                return anchor
            }
        }

        @MainActor private func mouseViewportPoint(in clip: NSClipView) -> CGPoint? {
            guard let window = clip.window else { return nil }
            let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            let point = clip.convert(windowPoint, from: nil)
            guard clip.bounds.contains(point) else { return nil }
            return CGPoint(x: point.x, y: point.y)
        }

        private func unitPoint(_ point: CGPoint, in rect: CGRect) -> CGPoint {
            CGPoint(
                x: min(max((point.x - rect.minX) / max(rect.width, 1), 0), 1),
                y: min(max((point.y - rect.minY) / max(rect.height, 1), 0), 1)
            )
        }

        private func logGridResize(_ message: String) {
            #if DEBUG
            print("[GridResize] \(message)")
            #endif
        }

        private func sizeLog(_ size: CGSize) -> String {
            "(\(fmt(size.width)),\(fmt(size.height)))"
        }

        private func pointLog(_ point: CGPoint) -> String {
            "(\(fmt(point.x)),\(fmt(point.y)))"
        }

        private func anchorLog(_ anchor: GridResizeAnchor) -> String {
            "\(anchor.kind.rawValue):viewport=\(pointLog(anchor.viewportPoint)):content=\(pointLog(anchor.contentPoint))"
        }

        // MARK: - Shared-element transition support

        private func rebuildIndex() {
            indexByUID.removeAll(keepingCapacity: true)
            for (s, section) in sections.enumerated() {
                for (i, item) in section.items.enumerated() {
                    indexByUID[item.uid] = IndexPath(item: i, section: s)
                }
            }
        }

        func wireProxy(_ proxy: GridProxy?) {
            guard let proxy else { return }
            proxy.windowFrameForItem = { [weak self] item in self?.windowFrame(for: item) }
            proxy.scrollToItem = { [weak self] item in self?.scrollToItem(item) }
            // The + / − buttons call the SAME discrete step functions the trackpad pinch calls.
            proxy.zoomIn = { [weak self] in self?.zoomInStep() }
            proxy.zoomOut = { [weak self] in self?.zoomOutStep() }
        }

        /// The photo's cell frame in the window's content coordinate space (top-left origin), or nil
        /// if the cell isn't currently visible. `cv.convert(_:to:nil)` handles scroll + sidebar +
        /// toolbar automatically; we only flip Y (AppKit window coords are bottom-left) to match
        /// SwiftUI's top-left so the zoom overlay can use the rect verbatim.
        private func windowFrame(for item: PhotoItem) -> CGRect? {
            guard let cv = collectionView, let win = cv.window, let clip = scrollView?.contentView,
                  let layout, let ip = indexByUID[item.uid],
                  let a = layout.layoutAttributesForItem(at: ip),
                  clip.documentVisibleRect.intersects(a.frame) else { return nil }
            let inWindow = cv.convert(a.frame, to: nil)            // window coords, bottom-left origin
            let contentH = win.contentView?.bounds.height ?? win.frame.height
            return CGRect(x: inWindow.minX, y: contentH - inWindow.maxY, width: inWindow.width, height: inWindow.height)
        }

        private func scrollToItem(_ item: PhotoItem) {
            guard let cv = collectionView, let clip = scrollView?.contentView, let layout,
                  let ip = indexByUID[item.uid], let a = layout.layoutAttributesForItem(at: ip) else { return }
            stickToBottom = false
            let target = a.frame.midY - clip.bounds.height / 2
            let maxY = max(0, layout.collectionViewContentSize.height - clip.bounds.height)
            clip.setBoundsOrigin(NSPoint(x: 0, y: min(max(0, target), maxY)))
            scrollView?.reflectScrolledClipView(clip)
            cv.layoutSubtreeIfNeeded()
        }

        // MARK: Data source

        func numberOfSections(in collectionView: NSCollectionView) -> Int { sections.count }

        func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
            sections[section].items.count
        }

        private var currentCropMode: GridCropMode {
            JustifiedCollectionLayout.levels[min(max(layout?.level ?? JustifiedCollectionLayout.defaultLevel, 0), JustifiedCollectionLayout.levels.count - 1)].cropMode
        }

        /// Update visible cells' crop mode after the level commits (square-fill levels crop to fill);
        /// cells aren't reloaded on a level change, so their contents-gravity must be refreshed in place.
        @MainActor private func updateVisibleCellCropMode() {
            guard let cv = collectionView else { return }
            let mode = currentCropMode
            for ip in cv.indexPathsForVisibleItems() {
                (cv.item(at: ip) as? PhotoGridItem)?.setCropMode(mode)
            }
        }

        func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let item = collectionView.makeItem(withIdentifier: PhotoGridItem.identifier, for: indexPath) as! PhotoGridItem
            let photo = sections[indexPath.section].items[indexPath.item]
            item.configure(photo: photo, feed: parent.feed, cropMode: currentCropMode)
            item.setChecked(selectedUIDs.contains(photo.uid), mode: selectionMode)
            item.setFavorite(favoriteUIDs.contains(photo.uid))
            return item
        }

        func setFavorites(_ set: Set<PhotoUID>) {
            guard set != favoriteUIDs else { return }
            favoriteUIDs = set
            guard let cv = collectionView else { return }
            for ip in cv.indexPathsForVisibleItems() {
                guard ip.section < sections.count, ip.item < sections[ip.section].items.count else { continue }
                let uid = sections[ip.section].items[ip.item].uid
                (cv.item(at: ip) as? PhotoGridItem)?.setFavorite(set.contains(uid))
            }
        }

        // MARK: Delegate

        func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard let indexPath = indexPaths.first,
                  indexPath.section < sections.count, indexPath.item < sections[indexPath.section].items.count else { return }
            let photo = sections[indexPath.section].items[indexPath.item]
            collectionView.deselectItems(at: indexPaths)   // we drive both opening and selection ourselves
            if selectionMode {
                if selectedUIDs.contains(photo.uid) { selectedUIDs.remove(photo.uid) } else { selectedUIDs.insert(photo.uid) }
                (collectionView.item(at: indexPath) as? PhotoGridItem)?.setChecked(selectedUIDs.contains(photo.uid), mode: true)
                parent.onSelectionChange(selectedUIDs)
            } else {
                parent.onOpen(photo, parent.allItems)
            }
        }

        // MARK: Selection mode

        func setSelectionMode(_ on: Bool) {
            guard on != selectionMode else { return }
            selectionMode = on
            if !on { selectedUIDs.removeAll(); parent.onSelectionChange([]) }
            guard let cv = collectionView else { return }
            for ip in cv.indexPathsForVisibleItems() {
                guard ip.section < sections.count, ip.item < sections[ip.section].items.count else { continue }
                let uid = sections[ip.section].items[ip.item].uid
                (cv.item(at: ip) as? PhotoGridItem)?.setChecked(selectedUIDs.contains(uid), mode: on)
            }
        }

        // MARK: Drag to Finder (file promise → downloads the original on drop)

        func collectionView(_ collectionView: NSCollectionView, canDragItemsAt indexPaths: Set<IndexPath>, with event: NSEvent) -> Bool { true }

        func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            guard indexPath.section < sections.count, indexPath.item < sections[indexPath.section].items.count else { return nil }
            let photo = sections[indexPath.section].items[indexPath.item]
            promiseHandler.media = parent.media
            let type = UTType(mimeType: photo.mediaType) ?? .jpeg
            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: promiseHandler)
            provider.userInfo = photo
            return provider
        }

        // MARK: Pinch — frozen source surface + target ghosts

        private var pinchBaseMag: CGFloat = 0
        private var pinchCommitLevel = JustifiedCollectionLayout.defaultLevel
        // Discrete snap model: the live fractional level position + its velocity (levels/sec), updated
        // every `.changed`, consumed once on release by `GridZoomMath.snapLevel`.
        private var liveLevelPosition: CGFloat = 0
        private var lastLevelPosTime: CFTimeInterval = 0
        private var levelVelocity: CGFloat = 0
        private var transitionFromLevel = JustifiedCollectionLayout.defaultLevel
        private var transitionToLevel = JustifiedCollectionLayout.defaultLevel
        private var transitionProgress: CGFloat = 0
        private var transitionAtlasPrepared = false
        private var transitionCanvas: GridSpriteTransitionView?
        /// Phase 5: controlled edge/far-band TARGET FILL during `.changed` (NOT the old global target-ghost
        /// path). Fills what source pages cannot — the left/right zoom-out margins beyond the finite source
        /// content width, and far bands — with scale-exempt target-level proxies. On by default.
        private let gridZoomUseTargetFillDuringChanged = true
        private var lastOverlayAnchorDiagnostic = ""
        private var didRunOrientationProbe = false
        private var pinchAccumulatedMag: CGFloat = 0          // raw magnify events are incremental → accumulate
        private var pinchBeganAt: CFTimeInterval = 0
        private var timeToFirstChangedDrawn: CFTimeInterval?
        // Coverage top-up throttling (append-only source pages when zoom-out exposes uncaptured area).
        private var lastCoverageTopUpAt: CFTimeInterval = -1000
        private var lastCoverageLogAt: CFTimeInterval = -1000
        private var coverageTopUpInFlight = false
        private var coverageTopUpGeneration = 0   // invalidates async top-ups after release / new pinch
        // Target-fill throttling (rebuild only when target level/origin moves, or every ~100 ms).
        private var lastTargetFillAt: CFTimeInterval = -1000
        private var lastTargetFillLogAt: CFTimeInterval = -1000
        private var lastTargetFillLevel = -1
        private var lastTargetFillOriginY: CGFloat = .greatestFiniteMagnitude
        private var lastTargetFillProgress: CGFloat = -1
        private var backdropFrozenLevel: Int?
        private var backdropFrozenOrigin: CGPoint?
        private var backdropFrozenUIDSet: Set<PhotoUID> = []
        private var targetPreviewBuilt = false    // true once the settle target-preview overlay is up

        // ── Continuous Day-Sectioned V2: topology-rebase state machine ──────────────────────────────────────
        // The live wall is ONE topology (`liveTopology`). A column/crop step fires a short, TIME-CLOCKED
        // rebase (`activeRebase`) — never a persistent positional blend. `rebaseTickGeneration` tokens the
        // self-clock so a paused finger still converges and stale ticks no-op. During the settle the topology
        // is PINNED to the detent (`forcedColumns`) so the final overlay frame == the committed grid exactly.
        private var liveTopology: ContinuousDaySectionedGridLayoutEngine.Topology?
        private var activeRebase: ContinuousDaySectionedGridLayoutEngine.Rebase?
        private var rebaseTickGeneration = 0
        private var lastRenderedColumns = 0       // the column count actually drawn last frame (commit-match)
        private var forcedColumns: Int?           // settle pins the topology to the detent; nil during .changed
        /// Crop dead-band centre: nearest-detent crop flips between aspectFit and squareFill around here.
        private let v2CropThreshold: CGFloat = 82
        /// Symmetric trigger dead-band (px of apparent) — kills threshold jitter without a hysteretic count.
        private let v2JitterEpsilon: CGFloat = 2
        private let v2RebaseDuration: Double = 0.18
        private var gridZoomPerfFrame = 0
        private var layoutSnapshotBuildCount = 0
        private var slotBuildCount = 0
        private var sourceSnapshotBuildCount = 0
        private var targetSnapshotBuildCount = 0
        private var framePrepareDurationsMs: [Double] = []

        // MARK: - Discrete pinch → mirrors the + / − buttons (no continuous live zoom)

        private var pinchDetector = PinchStepDetector()
        private var lastPinchStepAt: CFTimeInterval = -1000

        /// Trackpad pinch path. A pinch is treated as a DISCRETE intent: we accumulate the raw
        /// `event.magnification` deltas and, the moment the threshold is crossed, fire EXACTLY ONE zoom
        /// step (same as pressing + / −) — then ignore the rest of the gesture. There is no continuous
        /// scaling and no live layout. Positive magnification → zoom-in; negative → zoom-out.
        @MainActor func handleRawMagnify(_ event: NSEvent) {
            switch event.phase {
            case .began:
                pinchDetector.begin()
            case .ended, .cancelled:
                pinchDetector.end()
            default:
                guard let direction = pinchDetector.accumulate(event.magnification) else { return }
                guard CACurrentMediaTime() - lastPinchStepAt >= DiscreteGridZoomTuning.pinchCooldown else { return }
                lastPinchStepAt = CACurrentMediaTime()
                let anchorPoint = pinchAnchorViewportPoint(for: event)
                switch direction {
                case .zoomIn:  zoomInStep(anchorPoint: anchorPoint)
                case .zoomOut: zoomOutStep(anchorPoint: anchorPoint)
                }
            }
        }

        /// The pinch focus in viewport coordinates (document point − scroll origin), so the zoom can
        /// keep the photo under the fingers near the same screen spot. nil if the views are gone.
        @MainActor private func pinchAnchorViewportPoint(for event: NSEvent) -> CGPoint? {
            guard let cv = collectionView, let clip = scrollView?.contentView else { return nil }
            let contentPoint = cv.convert(event.locationInWindow, from: nil)
            return CGPoint(x: contentPoint.x - clip.bounds.origin.x, y: contentPoint.y - clip.bounds.origin.y)
        }

        /// One discrete zoom-IN step (bigger thumbnails). Shared by the `+` button (anchor = viewport
        /// centre) and trackpad pinch-in (anchor = the gesture point). This IS the `+` path.
        @MainActor func zoomInStep(anchorPoint: CGPoint? = nil) {
            guard let layout else { return }
            let target = steppedGridLevel(current: layout.level, direction: .zoomIn, count: JustifiedCollectionLayout.levels.count)
            requestDiscreteZoom(to: target, trigger: anchorPoint == nil ? .buttonPlus : .pinchIn, anchorPoint: anchorPoint)
        }

        /// One discrete zoom-OUT step (smaller thumbnails). Shared by the `−` button and pinch-out.
        @MainActor func zoomOutStep(anchorPoint: CGPoint? = nil) {
            guard let layout else { return }
            let target = steppedGridLevel(current: layout.level, direction: .zoomOut, count: JustifiedCollectionLayout.levels.count)
            requestDiscreteZoom(to: target, trigger: anchorPoint == nil ? .buttonMinus : .pinchOut, anchorPoint: anchorPoint)
        }

        // ===========================================================================================
        // QUARANTINED LIVE-ZOOM PATH (continuous pinch). Everything below — frozen source surface,
        // continuous apparentCellSize layout, topology rebase, target fill/backdrop, source plate,
        // settle/commit planner — is UNREACHABLE from production: `handleRawMagnify` no longer calls
        // `beginPinch`/`updatePinchTransition`/`endPinch`. Kept temporarily to keep the diff reviewable;
        // the tripwire below makes any accidental re-entry crash loudly in DEBUG. Do NOT wire these back.
        // ===========================================================================================

        @MainActor private func oldLiveZoomTripwire(_ fn: String) {
            DiscreteGridZoomDiagnostics.oldLiveZoomPathInvocations += 1
            logGridZoom("ERROR old live zoom path reached: \(fn) (should be unreachable)")
            assertionFailure("old live zoom path reached: \(fn)")
        }

        /// Raw trackpad magnify path. `event.magnification` is the per-event DELTA → accumulate it.
        /// `event.phase` drives the session. No recognition threshold → responds to the first tiny move.
        @MainActor private func handleRawMagnifyLive(_ event: NSEvent) {
            switch event.phase {
            case .began:
                beginPinch(at: event)
            case .changed:
                guard pinchSession != nil else { beginPinch(at: event); return }
                pinchAccumulatedMag += event.magnification
                updatePinchTransition(magnification: pinchAccumulatedMag)
            case .ended, .cancelled:
                guard pinchSession != nil else { return }
                endPinch(cancelled: event.phase == .cancelled)
            default:
                if pinchSession == nil {
                    beginPinch(at: event)
                } else {
                    pinchAccumulatedMag += event.magnification
                    updatePinchTransition(magnification: pinchAccumulatedMag)
                }
            }
        }

        @MainActor private func beginPinch(at event: NSEvent) {
            oldLiveZoomTripwire("beginPinch")
            guard let layout, let cv = collectionView, let clip = scrollView?.contentView else { return }
            PhotoDiagnostics.shared.setActivePinch(true)
            Task { await parent.feed.setUserInteractionActive(true) }
            clearSpriteTransition(restoringGrid: true)
            cv.layoutSubtreeIfNeeded()
            isPinching = true
            isGridZoomSettling = false
            stickToBottom = false
            pinchAccumulatedMag = 0
            pinchBaseMag = 0
            liveLevelPosition = CGFloat(layout.level)
            lastLevelPosTime = 0
            levelVelocity = 0
            pinchCommitLevel = layout.level
            transitionFromLevel = layout.level
            transitionToLevel = layout.level
            transitionProgress = 0
            pinchBeganAt = CACurrentMediaTime()
            timeToFirstChangedDrawn = nil
            resetGridZoomPerfCounters()

            let sourceOrigin = clip.bounds.origin
            let viewportSize = clip.bounds.size
            let contentPoint = cv.convert(event.locationInWindow, from: nil)
            let viewportPoint = CGPoint(x: contentPoint.x - sourceOrigin.x, y: contentPoint.y - sourceOrigin.y)
            let anchor = captureZoomAnchor(contentPoint: contentPoint, viewportPoint: viewportPoint)

            let captureStart = CACurrentMediaTime()
            let sourceSnapshots = captureSourceSnapshots(origin: sourceOrigin, viewportSize: viewportSize)
            let captureEnd = CACurrentMediaTime()
            // Occlusion = per-row bands from the captured CELL frames (tight to real content), NOT a fixed
            // margin rectangle. `gapPad` ≈ 0.6·gap so adjacent bands overlap and cover the row gaps.
            let gap = JustifiedCollectionLayout.levels[min(max(layout.level, 0), JustifiedCollectionLayout.levels.count - 1)].gap
            let occlusionMask = GridZoomMath.SourceOcclusionMask(
                rowBands: GridZoomMath.sourceRowBands(cellFrames: sourceSnapshots.values.map(\.cellFrame), gapPad: gap * 0.6))
            let sourceSpriteBounds = sourceSnapshots.values.reduce(CGRect.null) { $0.union($1.imageFrame) }
            let sourcePlateRect = occlusionMask.boundingRect.isNull ? initialSourcePlateRect(viewportSize: viewportSize) : occlusionMask.boundingRect
            // The PROTECTED focus row: photos sharing the pointer's row at the source level (viewport
            // coords; the snapshot cell frames are already viewport-relative). No target content is drawn
            // over these during `.changed`, and they are replaced last on settle.
            var focusRowUIDs: Set<PhotoUID> = []
            var sourceRowBand: CGRect? = nil
            if let anchorUID = anchor.uid, let anchorCell = sourceSnapshots[anchorUID]?.cellFrame {
                let cells = sourceSnapshots.map { (id: $0.key, frame: $0.value.cellFrame) }
                focusRowUIDs = Set(GridZoomMath.focusRowIDs(cells: cells, anchorFrame: anchorCell, gapPad: gap * 0.6))
                sourceRowBand = anchorCell.insetBy(dx: 0, dy: -gap * 0.6)
            }

            let session = PinchSession(
                sourceLevel: layout.level,
                sourceZoomSize: JustifiedCollectionLayout.levels[layout.level].size,
                sourceOrigin: sourceOrigin,
                viewportSize: viewportSize,
                anchor: anchor,
                sourceSnapshotsByUID: sourceSnapshots,
                targetLevel: layout.level,
                progress: 0,
                visualScale: 1,
                apparentSize: JustifiedCollectionLayout.levels[layout.level].size,
                sourcePlateRect: sourcePlateRect,
                sourceSpriteBounds: sourceSpriteBounds,
                occlusionMask: occlusionMask,
                focusRowUIDs: focusRowUIDs,
                sourceRowBand: sourceRowBand
            )
            pinchSession = session

            // V2: the live wall starts ON the source level's topology (its column count / gap / crop). Every
            // subsequent column or crop step rebases from here. No rebase is in flight at begin.
            let srcCfg = JustifiedCollectionLayout.levels[min(max(layout.level, 0), JustifiedCollectionLayout.levels.count - 1)]
            let srcCols = layout.columnCount(forLevel: layout.level, width: cv.bounds.width)
            liveTopology = ContinuousDaySectionedGridLayoutEngine.Topology(columns: srcCols, gap: srcCfg.gap, cropSquare: srcCfg.cropMode == .squareFill)
            activeRebase = nil
            forcedColumns = nil
            rebaseTickGeneration += 1

            let atlasStart = CACurrentMediaTime()
            beginFrozenSourceSurface(session: session)
            let atlasEnd = CACurrentMediaTime()

            logGridZoom("begin \(anchorLog(anchor)) sourceLevel=\(layout.level) snapshots=\(sourceSnapshots.count) captureMs=\(fmt((captureEnd - captureStart) * 1000)) atlasMs=\(fmt((atlasEnd - atlasStart) * 1000)) totalMs=\(fmt((atlasEnd - captureStart) * 1000)) timeToFirstOverlayMs=\(fmt((atlasEnd - pinchBeganAt) * 1000))")
        }

        @MainActor private func endPinch(cancelled: Bool) {
            oldLiveZoomTripwire("endPinch")
            guard let session = pinchSession else { isPinching = false; isGridZoomSettling = false; finishGridZoom(); return }
            // Discrete snap: continue the anchored zoom to a resting level (NOT the loose per-tick
            // commit level, NOT a neighborhood best-fit). Tiny movement returns to source.
            let snap = GridZoomMath.snapLevel(
                sourceLevel: session.sourceLevel, livePosition: liveLevelPosition,
                velocity: levelVelocity, levelCount: JustifiedCollectionLayout.levels.count)
            // The release SNAP is the only source of truth for the resting level. A target surface shown
            // during `.changed` must NEVER decide the final level — the live plan may only be REUSED (its
            // origin, via `commitOrigin`) when it already matches the snap. Cancelled → source.
            let finalLevel = GridZoomMath.resolveFinalLevel(cancelled: cancelled, sourceLevel: session.sourceLevel, snapLevel: snap)
            let reason = cancelled ? "cancelled" : (finalLevel == session.sourceLevel ? "tiny/return" : "snap")
            // Discard a live plan that no longer matches the snapped level so the commit rebuilds a fresh
            // detent plan for `finalLevel` (no stale origin from a level we are not landing on).
            if let plan = liveTargetPlan, plan.targetLevel != finalLevel {
                logGridZoom("liveTargetPlan discarded planLevel=\(plan.targetLevel) finalLevel=\(finalLevel)")
                liveTargetPlan = nil
            }
            logGridZoom("snap source=\(session.sourceLevel) livePos=\(fmt(liveLevelPosition)) direction=\(liveLevelPosition >= CGFloat(session.sourceLevel) ? "out" : "in") velocity=\(fmt(levelVelocity)) final=\(finalLevel) reason=\(reason)")
            isPinching = false
            isGridZoomSettling = true
            settlePinchSession(to: finalLevel)
        }

        /// Build the frozen source surface in the Metal overlay ONCE and hide the live grid behind it.
        @MainActor private func beginFrozenSourceSurface(session: PinchSession) {
            guard let cv = collectionView, let clip = scrollView?.contentView, let canvas = ensureTransitionCanvas(in: clip) else { return }
            let descriptors = frozenSourceDescriptors(session: session)
            cv.alphaValue = 0
            canvas.alphaValue = 1
            transitionFromLevel = session.sourceLevel
            transitionToLevel = session.sourceLevel
            if !didRunOrientationProbe {
                didRunOrientationProbe = true
                logGridZoom("orientation \(canvas.runOrientationSelfTest())")
            }
            canvas.configureFrozenSource(sprites: descriptors, anchor: session.anchor.viewportPoint, rebuildAtlas: true)
            // No visible opaque plate is drawn: the backdrop is clipped to OUTSIDE the scaled source
            // sheet, so nothing leaks through the source gaps and there is no dark plate box. The
            // `sourcePlateRect` geometry is still used for coverage / gating / clipping.
            canvas.setSourceScale(1)
            transitionAtlasPrepared = true
            let spriteBounds = descriptors.reduce(CGRect.null) { $0.union($1.fromFrame) }
            pinchSession?.sourceSpriteBounds = spriteBounds
            lastCoverageTopUpAt = -1000
            lastCoverageLogAt = -1000
            coverageTopUpInFlight = false
            coverageTopUpGeneration += 1
            resetBackdropFrozenState()
            logGridZoom("sourcePlateDrawn=false sourcePlateRect=\(rectLog(session.sourcePlateRect)) sourceSpriteBounds=\(rectLog(spriteBounds)) backdropMode=edgeFillOutsidePlate backdropLeakThroughSourceGaps=false")
            logLayoutMetrics()   // Phase 6: record the current level's structure for later layout work
            let feed = parent.feed
            let priorityUIDs = Array(session.sourceSnapshotsByUID.keys).prefix(240)
            Task { for uid in priorityUIDs { await feed.requestPriority(uid, priority: .zoomAnchorAndFocusRow) } }
        }

        @MainActor private func ensureTransitionCanvas(in clip: NSClipView) -> GridSpriteTransitionView? {
            let canvas = transitionCanvas ?? GridSpriteTransitionView(frame: viewportFrame(in: clip))
            guard canvas.isReady else {
                collectionView?.alphaValue = 0
                logGridZoom("ERROR grid sprite canvas unavailable; live grid hidden")
                return nil
            }
            positionTransitionCanvas(canvas, in: clip)
            canvas.autoresizingMask = []
            if canvas.superview !== clip {
                canvas.removeFromSuperview()
                clip.addSubview(canvas)
            }
            transitionCanvas = canvas
            return canvas
        }

        private func initialSourcePlateRect(viewportSize: CGSize) -> CGRect {
            CGRect(origin: .zero, size: viewportSize)
                .insetBy(dx: -viewportSize.width * 0.10, dy: -viewportSize.height * 0.25)
        }

        // NOTE: no opaque "source plate" image/descriptor exists. `sourcePlateRect` is pure CLIP/gating
        // geometry (where source content is), and the backdrop is clipped to OUTSIDE it — so there is no
        // dark quad to ever render as a visible black box. Do NOT reintroduce a drawn opaque plate.

        private func resetBackdropFrozenState() {
            lastTargetFillAt = -1000
            lastTargetFillLevel = -1
            lastTargetFillOriginY = .greatestFiniteMagnitude
            lastTargetFillProgress = -1
            backdropFrozenLevel = nil
            backdropFrozenOrigin = nil
            backdropFrozenUIDSet.removeAll()
            liveTargetPlan = nil
        }

        /// Source snapshots → static (scale-1) sprite descriptors. The renderer applies the live scale.
        private func frozenSourceDescriptors(session: PinchSession) -> [GridTransitionSpriteDescriptor] {
            let viewport = CGRect(origin: .zero, size: session.viewportSize)
            let expanded = viewport.insetBy(dx: -viewport.width * 0.35, dy: -viewport.height * 0.55)
            var out: [GridTransitionSpriteDescriptor] = []
            out.reserveCapacity(session.sourceSnapshotsByUID.count)
            for snapshot in session.sourceSnapshotsByUID.values {
                guard snapshot.imageFrame.intersects(expanded) else { continue }
                out.append(GridTransitionSpriteDescriptor(
                    key: spriteKey(role: "source", key: snapshot.key),
                    image: snapshot.image,
                    imageSize: snapshot.imageSize,
                    fromFrame: snapshot.imageFrame,
                    toFrame: snapshot.imageFrame,
                    fromAlpha: 1,
                    toAlpha: 1,
                    priority: snapshot.priority,
                    fillSquare: snapshot.fillSquare
                ))
            }
            return out.isEmpty ? placeholderSprites(viewportSize: session.viewportSize) : out.sorted { $0.priority < $1.priority }
        }

        /// `.changed` is now just: map the accumulated magnification to a live scale and push it as a
        /// single uniform. No descriptor/atlas/vertex work per frame.
        @MainActor private func updatePinchTransition(magnification mag: CGFloat) {
            oldLiveZoomTripwire("updatePinchTransition")
            guard var session = pinchSession else { return }
            let model = liveZoom(magnification: mag, session: session)
            // Track the live fractional level position + smoothed velocity (levels/sec) for the release
            // snap (GridZoomMath.snapLevel). pinchCommitLevel below is only the backdrop-density hint.
            let tickNow = CACurrentMediaTime()
            if lastLevelPosTime > 0 {
                let dt = max(tickNow - lastLevelPosTime, 0.001)
                let instantaneous = (model.levelPosition - liveLevelPosition) / dt
                levelVelocity = levelVelocity * 0.6 + instantaneous * 0.4
            }
            liveLevelPosition = model.levelPosition
            lastLevelPosTime = tickNow
            // Hysteresis (NOT raw nearest): a sub-threshold pinch resolves to the SOURCE level, so a tiny
            // finger movement can't flip the commit level and trigger a spurious full target-preview wall
            // on release. A deliberate level crossing still flips.
            let commitLevel = stableTargetLevel(apparentSize: model.apparentSize, session: session)
            let previousScale = session.visualScale
            session.targetLevel = session.sourceLevel
            session.progress = 0
            session.visualScale = model.visualScale
            session.apparentSize = model.apparentSize
            pinchCommitLevel = commitLevel
            pinchSession = session

            // HARD RESET: one continuous grid world driven by apparentCellSize. The whole grid scales with
            // the global zoom transform about the cursor (a single layout) between column-flips; only inside
            // a narrow band at each column change do two adjacent column layouts alpha-crossfade (fixed
            // rects, NO rect morph). Identical path for pinch-in and pinch-out.
            if gridZoomUseTargetFillDuringChanged {
                updateContinuousGrid(session: session, apparent: model.apparentSize)
            }
            assertGridHiddenDuringZoom()

            if timeToFirstChangedDrawn == nil {
                timeToFirstChangedDrawn = CACurrentMediaTime()
                logGridZoom("first changed drawn at +\(fmt((timeToFirstChangedDrawn! - pinchBeganAt) * 1000))ms")
            }

            let now = CACurrentMediaTime()
            if now - lastPinchLogTime > 0.10 {
                lastPinchLogTime = now
                let error = anchorError(for: session.anchor)
                logGridZoom(
                    "change rawMag=\(fmt(mag)) deltaMag=\(fmt(mag - pinchBaseMag)) shaped=\(fmt(model.shapedDelta)) levelPos=\(fmt(model.levelPosition)) apparent=\(fmt(model.apparentSize)) scale=\(fmt(model.visualScale)) dScale=\(fmt(model.visualScale - previousScale)) source=\(session.sourceLevel) commit=\(commitLevel) sourceSprites=\(session.sourceSnapshotsByUID.count) renderStats=[\(transitionCanvas?.stats.summary ?? "n/a")] drawMs=\(fmt(transitionCanvas?.lastDrawMs ?? 0)) cvAlpha=\(fmt(collectionView?.alphaValue ?? -1)) targetGhosts=0 liveAnchorError=(\(fmt(error.x)),\(fmt(error.y)))"
                )
                logGridZoom(focusAnchorStatus(session: session, visualScale: model.visualScale))
            }
        }

        // MARK: Per-cell compositor (pass #11) — see `updateWorldCompositor`

        /// Gather the uncaptured photos in the needed region (the live layout is still at the SOURCE
        /// level during a pinch, so its frames line up with page 0 exactly), warm their decoded
        /// thumbnails, append them as a `.sourceCoverage` page, AND record them in the session proxy map
        /// (Phase 2) so the commit planner sees them. Per-band diagnostics (Phase 1) log whether a band
        /// is source-width-limited — i.e. beyond the finite source content width, so source can never
        /// fill it and target fill must. Throttled + bounded; never reflows existing sprites.
        @MainActor private func maybeTopUpCoverage(session: PinchSession, needed: CGRect, coverage cov: GridZoomMath.Coverage, anchor: CGPoint, logBands: Bool) {
            guard let layout, let cv = collectionView else { return }
            let origin = session.sourceOrigin
            let contentWidth = cv.bounds.width

            // Phase 1: per-band candidate count + source-width-limited flag.
            if logBands {
                func reportBand(_ name: String, _ band: CGRect, leftSide: Bool, rightSide: Bool) {
                    guard !band.isNull, band.width > 1, band.height > 1 else { return }
                    let doc = band.offsetBy(dx: origin.x, dy: origin.y)
                    var count = 0
                    for attr in layout.layoutAttributesForElements(in: doc) {
                        guard let ip = attr.indexPath, ip.section < sections.count, ip.item < sections[ip.section].items.count else { continue }
                        let base = attr.frame.offsetBy(dx: -origin.x, dy: -origin.y)
                        if session.sourcePlateRect.contains(CGPoint(x: base.midX, y: base.midY)) { continue }
                        count += 1
                    }
                    let widthLimited = (leftSide && doc.minX < 0) || (rightSide && doc.maxX > contentWidth)
                    logGridZoom("band \(name) rect=\(rectLog(band)) sourceCandidates=\(count) sourceWidthLimited=\(widthLimited)")
                }
                reportBand("Top", cov.missingTop, leftSide: false, rightSide: false)
                reportBand("Bottom", cov.missingBottom, leftSide: false, rightSide: false)
                reportBand("Left", cov.missingLeft, leftSide: true, rightSide: false)
                reportBand("Right", cov.missingRight, leftSide: false, rightSide: true)
            }

            let now = CACurrentMediaTime()
            guard !coverageTopUpInFlight, now - lastCoverageTopUpAt > 0.08 else { return }
            let docNeeded = needed.offsetBy(dx: origin.x, dy: origin.y)
            var candidates: [(uid: PhotoUID, baseFrame: CGRect, distance: CGFloat)] = []
            for attr in layout.layoutAttributesForElements(in: docNeeded) {
                guard let ip = attr.indexPath, ip.section < sections.count, ip.item < sections[ip.section].items.count else { continue }
                let base = attr.frame.offsetBy(dx: -origin.x, dy: -origin.y)
                if session.sourcePlateRect.contains(CGPoint(x: base.midX, y: base.midY)) { continue }   // already covered by the source sheet
                let uid = sections[ip.section].items[ip.item].uid
                candidates.append((uid, base, hypot(base.midX - anchor.x, base.midY - anchor.y)))
            }
            guard !candidates.isEmpty else { return }
            candidates.sort { $0.distance < $1.distance }   // fill nearest-the-anchor first
            let batch = Array(candidates.prefix(140))

            coverageTopUpInFlight = true
            lastCoverageTopUpAt = now
            let generation = coverageTopUpGeneration
            let feed = parent.feed
            let uids = batch.map(\.uid)
            Task { @MainActor in
                let warm = await feed.warmDecoded(uids, limit: 160)
                guard generation == coverageTopUpGeneration, isPinching, let canvas = transitionCanvas, pinchSession != nil else {
                    coverageTopUpInFlight = false
                    return
                }
                var descriptors: [GridTransitionSpriteDescriptor] = []
                var newSnapshots: [PhotoUID: GridCellSnapshot] = [:]
                var appendedRect = CGRect.null
                let appendedPlateRect = batch.reduce(CGRect.null) { $0.union($1.baseFrame) }
                var decodeHits = 0
                let sourceSquare = JustifiedCollectionLayout.levels[min(max(session.sourceLevel, 0), JustifiedCollectionLayout.levels.count - 1)].cropMode == .squareFill
                for (uid, baseFrame, _) in batch {
                    guard let ns = feed.memoryImage(for: uid),
                          let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
                    decodeHits += 1
                    let imageSize = CGSize(width: cg.width, height: cg.height)
                    let imageFrame = sourceSquare ? baseFrame : fittedImageFrame(in: baseFrame, imageSize: imageSize)
                    descriptors.append(GridTransitionSpriteDescriptor(
                        key: spriteKey(role: "source", key: key(for: uid)),
                        image: cg, imageSize: imageSize,
                        fromFrame: imageFrame, toFrame: imageFrame,
                        fromAlpha: 1, toAlpha: 1, priority: 0, fillSquare: sourceSquare
                    ))
                    newSnapshots[uid] = GridCellSnapshot(uid: uid, key: key(for: uid), cellFrame: baseFrame, imageFrame: imageFrame, image: cg, imageSize: imageSize, priority: 0, fillSquare: sourceSquare, isPlaceholder: false)
                    appendedRect = appendedRect.union(imageFrame)
                }
                // Append the real source thumbnails (no visible plate page). `sourcePlateRect` geometry
                // still grows so coverage/gating/clip use the extended source sheet.
                let result = descriptors.isEmpty
                    ? (rendered: 0, skippedNil: 0, skippedDup: 0, pageCount: canvas.frozenPageCount)
                    : canvas.appendFrozenSourcePage(sprites: descriptors, role: .sourceCoverage, pageAlpha: 1, sourceRect: needed)
                if var updated = pinchSession {
                    if !appendedRect.isNull { updated.sourceSpriteBounds = updated.sourceSpriteBounds.union(appendedRect) }
                    for (uid, snap) in newSnapshots { updated.sourceSnapshotsByUID[uid] = snap }   // Phase 2: track appended proxies
                    // Rebuild the row-band occlusion from ALL source cells (incl. the appended rows) so
                    // the backdrop clip + gate follow the grown source sheet precisely.
                    let gap = JustifiedCollectionLayout.levels[min(max(updated.sourceLevel, 0), JustifiedCollectionLayout.levels.count - 1)].gap
                    updated.occlusionMask = GridZoomMath.SourceOcclusionMask(
                        rowBands: GridZoomMath.sourceRowBands(cellFrames: updated.sourceSnapshotsByUID.values.map(\.cellFrame), gapPad: gap * 0.6))
                    if !updated.occlusionMask.boundingRect.isNull { updated.sourcePlateRect = updated.occlusionMask.boundingRect }
                    pinchSession = updated
                }
                logGridZoom("pageAppend rect=\(rectLog(needed)) sourcePlateGrow=\(rectLog(appendedPlateRect)) requested=\(uids.count) rendered=\(result.rendered) skippedNil=\(result.skippedNil) decodeHits=\(decodeHits) decodeMisses=\(warm.queuedNetwork + warm.missing) pageCount=\(result.pageCount) warm=[already=\(warm.alreadyDecoded) disk=\(warm.decodedFromDisk) net=\(warm.queuedNetwork)] backdropLeakThroughSourceGaps=false")
                coverageTopUpInFlight = false
            }
        }

        /// A small neutral (dark-gray) placeholder so a not-yet-decoded target cell reads as an unloaded
        /// thumbnail, NEVER a black square or a transparent hole. Shared by all missing cells (one atlas
        /// placement via the "__ph__" key); replaced by the real image once decoded (key changes → atlas
        /// rebuild). Built once.
        private static let placeholderImage: CGImage? = GridThumbnailFallback.placeholderImage

        /// Single source of truth for the candidate target DETENT surface and the eventual commit. The
        /// live `.changed` surface, the settle, and the real-grid commit all use the SAME `targetLevel`
        /// and `origin` from this plan → the images shown during the gesture are exactly the images the
        /// real grid reveals (identity preserved). Scales are refreshed each tick from `apparentSize`.
        struct TargetDetentPlan: Equatable {
            let sourceLevel: Int
            let targetLevel: Int
            let origin: CGPoint
            let sourceLevelSize: CGFloat
            let targetLevelSize: CGFloat
            var apparentSize: CGFloat
            var sourceScale: CGFloat
            var targetScale: CGFloat
            /// Plan identity (what the commit must match) — level + origin, ignoring the live scales.
            func sameDetent(as other: TargetDetentPlan) -> Bool {
                targetLevel == other.targetLevel && abs(origin.y - other.origin.y) < 1 && abs(origin.x - other.origin.x) < 1
            }
        }
        private var liveTargetPlan: TargetDetentPlan?

        /// The candidate target detent if the user released NOW: snap level (NOT raw nearest), its
        /// anchor-only origin, and the two detent scales. Returns nil for a tiny gesture that would snap
        /// back to source (no target content) or a zoom-in.
        @MainActor private func makeTargetDetentPlan(session: PinchSession, apparentSize: CGFloat) -> TargetDetentPlan? {
            let levelCount = JustifiedCollectionLayout.levels.count
            let candidate = GridZoomMath.snapLevel(sourceLevel: session.sourceLevel, livePosition: liveLevelPosition, velocity: levelVelocity, levelCount: levelCount)
            guard candidate != session.sourceLevel else { return nil }   // tiny / snaps back to source
            let origin = anchoredOrigin(for: session.anchor, level: candidate, fallback: session.sourceOrigin, projected: true)
            let targetSize = JustifiedCollectionLayout.levels[min(max(candidate, 0), levelCount - 1)].size
            let scales = GridZoomMath.detentScales(apparentSize: apparentSize, sourceLevelSize: session.sourceZoomSize, targetLevelSize: targetSize)
            return TargetDetentPlan(sourceLevel: session.sourceLevel, targetLevel: candidate, origin: origin,
                                    sourceLevelSize: session.sourceZoomSize, targetLevelSize: targetSize,
                                    apparentSize: apparentSize, sourceScale: scales.source, targetScale: scales.target)
        }

        private struct TargetSurface {
            var descriptors: [GridTransitionSpriteDescriptor] = []
            var uids: [PhotoUID] = []      // every in-band uid (for warm decode)
            var needed = 0                 // every cell in the (inverse-scaled) overscan viewport
            var drawn = 0                  // sprites emitted (real, source-captured, or placeholder)
            var realCount = 0              // RAM-decoded real thumbnail
            var sourceFallbackCount = 0    // same photo's source-captured image (lower fidelity)
            var placeholderCount = 0       // neutral dark-gray placeholder
            var edgeOpaque = 0             // cells outside the on-screen source sheet (the edge fill)
            var focusSuppressed = 0        // alpha ≈ 0 (masked surfaces only) → source shows through
            var insideSourceSkipped = 0    // cells inside the source sheet, NOT drawn (source covers them)
            var baseRect: CGRect = .null   // the inverse-scaled base-space rect cells were requested for
            var nodes: [ZoomVisualNode] = []   // the per-photo TARGET nodes (pass #11 compositor model)
            var transparentHoles: Int { max(0, needed - drawn - focusSuppressed) }   // must be 0
            var fallbackRatio: Double { drawn == 0 ? 0 : Double(sourceFallbackCount + placeholderCount) / Double(drawn) }
        }

        /// Build the target DETENT surface at `level`/`origin` — the FUTURE resting grid rendered early.
        /// The global target detent rendered as INDIVIDUAL photo nodes (pass #10 — never a plate/wall/
        /// rectangle). Cells are requested for the inverse viewport at `targetScale` (NOT sourceScale), so
        /// after the shader scales the page by `targetScale` they cover the viewport like a target grid.
        /// Every drawn cell falls back real RAM image → the same photo's source-captured image → neutral
        /// placeholder, so missing thumbnails are never holes. With `focusProtected` (the live `.changed`
        /// world), a node is dropped if it is in the protected focus row OR a source photo currently covers
        /// it (per-PHOTO depth occlusion — NOT the old rectangular `occlusionMask`/`sourcePlateRect`).
        /// Without it (settle reveal) every cell is opaque (the focus row is dissolved last by the settle).
        @MainActor private func buildTargetSurface(
            level: Int, origin: CGPoint, viewport: CGRect, role: String,
            session: PinchSession, sourceScale: CGFloat, targetScale: CGFloat, focusProtected: Bool, progress: CGFloat = 1
        ) -> TargetSurface {
            var out = TargetSurface()
            guard let layout, let cv = collectionView else { return out }
            let square = JustifiedCollectionLayout.levels[min(max(level, 0), JustifiedCollectionLayout.levels.count - 1)].cropMode == .squareFill
            let anchor = session.anchor.viewportPoint
            let overscan = CGSize(width: viewport.width * 0.25, height: viewport.height * 0.28)
            // Enumerate the target cells for a FIXED region (viewport + overscan at scale 1), independent
            // of the live `targetScale` — so the cell SET (and the atlas) stays stable across the gesture
            // (only per-cell ALPHA changes each tick). Since zoom-out keeps `targetScale >= 1`, scaling
            // these cells up by `targetScale` more than covers the viewport.
            let baseRect = GridZoomMath.sourceRectNeededForFrozenScale(viewport: viewport, anchor: anchor, scale: 1, margin: overscan)
            out.baseRect = baseRect
            let docRect = baseRect.offsetBy(dx: origin.x, dy: origin.y)
            // Screen-band protection only when there is a real focused photo (a gap/`.content` anchor has
            // no row to protect, and band-suppressing there could leave a hole).
            let hasFocus = session.anchor.uid != nil
            for (ip, docFrame) in layout.projectedFramesForElements(in: docRect, level: level, width: cv.bounds.width) {
                guard ip.section < sections.count, ip.item < sections[ip.section].items.count else { continue }
                let base = CGRect(x: docFrame.minX - origin.x, y: docFrame.minY - origin.y, width: docFrame.width, height: docFrame.height)
                let uid = sections[ip.section].items[ip.item].uid
                let alpha: CGFloat
                if focusProtected {
                    let targetScreenRect = GridZoomMath.scaledRect(base, anchor: anchor, scale: targetScale)
                    // PER-CELL CROSSFADE (pass #11) — NOT the old "target only where source does not cover"
                    // gate (that produced the opaque source rectangle). The target photo FADES IN per cell
                    // (replacementAlpha); the source photo fades OUT in lockstep (the source compositor).
                    // Inside the focus band targetAlpha == 0 (the focus row stays source). EVERY cell is
                    // emitted (no skip) so the keyset/atlas is stable — only the alpha changes each tick.
                    let inBand = session.focusRowUIDs.contains(uid)
                        || (hasFocus && GridZoomMath.inFocusBand(screenY: targetScreenRect.midY, anchorY: anchor.y, viewportHeight: viewport.height))
                    let dist = abs(targetScreenRect.midY - anchor.y)
                    let isEdge = session.sourceSnapshotsByUID[uid] == nil   // target-only (no captured source) → fades in early
                    alpha = inBand ? 0 : GridZoomMath.targetNodeAlpha(progress: progress, distanceFromFocus: dist, viewportHeight: viewport.height, inFocusBand: false, isEdgeOrTargetOnly: isEdge)
                    if inBand { out.focusSuppressed += 1 } else if isEdge { out.edgeOpaque += 1 }
                } else {
                    alpha = 1
                }
                out.needed += 1
                out.uids.append(uid)

                let realCG = parent.feed.memoryImage(for: uid)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                let sourceCG = realCG == nil ? session.sourceSnapshotsByUID[uid]?.image : nil
                let isPlaceholder = realCG == nil && sourceCG == nil
                let cg = realCG ?? sourceCG ?? Self.placeholderImage
                if realCG != nil { out.realCount += 1 } else if sourceCG != nil { out.sourceFallbackCount += 1 } else { out.placeholderCount += 1 }
                out.drawn += 1
                let imageSize = cg.map { CGSize(width: $0.width, height: $0.height) } ?? base.size
                let useSquare = square && !isPlaceholder    // never crop the tiny placeholder
                let imageFrame = useSquare ? base : (isPlaceholder ? base : fittedImageFrame(in: base, imageSize: imageSize))
                let spriteId = isPlaceholder ? "__ph__" : spriteKey(role: role, key: key(for: uid))   // shared placeholder key
                out.descriptors.append(GridTransitionSpriteDescriptor(
                    key: spriteId, image: cg, imageSize: imageSize,
                    fromFrame: imageFrame, toFrame: imageFrame,
                    fromAlpha: Float(alpha), toAlpha: Float(alpha), priority: 0, fillSquare: useSquare
                ))
                if focusProtected {
                    out.nodes.append(ZoomVisualNode(
                        uid: uid, sourceImageFrame: session.sourceSnapshotsByUID[uid]?.imageFrame, targetImageFrame: imageFrame,
                        isAnchorUID: uid == session.anchor.uid,
                        isFocusRow: session.focusRowUIDs.contains(uid),
                        isFocusBand: alpha <= 0.001,
                        isEdgeOrTargetOnly: session.sourceSnapshotsByUID[uid] == nil,
                        sourceAlpha: 0, targetAlpha: alpha))
                }
            }
            return out
        }

        // (deleted: GridSlotCompositor slot-lerp model — updateSlotCompositor / levelSnapshot / pushSlotPage.
        //  Superseded by the continuous-grid engine. The rect-interpolation code is GONE, not just unused.)

        /// Best image for a slot uid: decoded RAM thumbnail → the captured source image → neutral placeholder.
        private func slotImage(_ uid: PhotoUID, session: PinchSession) -> SlotImageChoice? {
            if let cg = parent.feed.memoryImage(for: uid)?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                return SlotImageChoice(
                    cg: cg,
                    size: CGSize(width: cg.width, height: cg.height),
                    isPlaceholder: false,
                    visualState: .realImageDrawn,
                    context: "zoomOverlay.ramDecodedHit"
                )
            }
            if let snapshot = session.sourceSnapshotsByUID[uid], let cg = snapshot.image {
                return SlotImageChoice(
                    cg: cg,
                    size: CGSize(width: cg.width, height: cg.height),
                    isPlaceholder: snapshot.isPlaceholder,
                    visualState: snapshot.isPlaceholder ? placeholderState(for: uid) : .realImageDrawn,
                    context: snapshot.isPlaceholder ? "zoomOverlay.sourcePlaceholder" : "zoomOverlay.sourceCapturedFallback"
                )
            }
            if let cg = Self.placeholderImage {
                return SlotImageChoice(
                    cg: cg,
                    size: CGSize(width: cg.width, height: cg.height),
                    isPlaceholder: true,
                    visualState: placeholderState(for: uid),
                    context: "zoomOverlay.sharedPlaceholder"
                )
            }
            return nil
        }

        private func placeholderState(for uid: PhotoUID) -> ThumbnailVisualState {
            switch parent.feed.knownDiskThumbnailPresent(for: uid) {
            case .some(true): return .diskHitRamMissing
            case .some(false): return .diskMissing
            case .none: return .placeholderDrawn
            }
        }

        private func cropMode(at level: Int) -> GridCropMode {
            JustifiedCollectionLayout.levels[min(max(level, 0), JustifiedCollectionLayout.levels.count - 1)].cropMode
        }

        /// The gap to use for a given column count: the gap of the LEVEL whose column count is nearest. At a
        /// detent (cols == a level's column count) this equals the committed grid's gap, so the overlay and
        /// the committed grid use identical geometry (commit == renderer). Between detents it steps.
        @MainActor private func v2Gap(cols: Int, width: CGFloat) -> CGFloat {
            guard let jcl = layout else { return 4 }
            var bestGap = JustifiedCollectionLayout.levels[0].gap
            var bestDelta = Int.max
            for (i, lvl) in JustifiedCollectionLayout.levels.enumerated() {
                let d = abs(jcl.columnCount(forLevel: i, width: width) - cols)
                if d < bestDelta { bestDelta = d; bestGap = lvl.gap }
            }
            return bestGap
        }

        // MARK: - Continuous Day-Sectioned V2: one wall + time-clocked topology rebase

        private enum V2LayerRole { case single, outgoing, incoming }

        /// Live `.changed`: ONE continuous day-sectioned wall driven by `apparentCellSize`. The pure engine
        /// decides whether this tick is a plain scaling of the current topology or a SHORT time-clocked rebase
        /// to a stepped column/crop topology. Pinch-in and pinch-out take this identical path; the six levels
        /// are only detents (applied on release via `forcedColumns`). No positional blend, no ghost wall.
        @MainActor private func updateContinuousGrid(session: PinchSession, apparent: CGFloat) {
            guard let canvas = transitionCanvas, let cv = collectionView else { return }
            let viewport = CGRect(origin: .zero, size: session.viewportSize)
            let W = cv.bounds.width
            typealias EE = ContinuousDaySectionedGridLayoutEngine

            // SETTLE: the topology is PINNED to the detent — render exactly one layout (no rebase) so the final
            // overlay frame is byte-identical to the committed grid (commit == renderer).
            if let forced = forcedColumns {
                // Crop is PINNED to the detent's crop (set in settlePinchSession), NOT recomputed from
                // `apparent` — otherwise the easing `apparent` crossing the crop threshold mid-settle would
                // flip the anchor's framing (a per-frame crop pop). The pinned crop also matches the committed
                // grid's cropMode → commit-match holds for crop too.
                let crop = liveTopology?.cropSquare ?? (apparent < v2CropThreshold)
                let topo = EE.Topology(columns: forced, gap: v2Gap(cols: forced, width: W), cropSquare: crop)
                renderTopologyPlan(.single(topo), session: session, apparent: apparent, canvas: canvas, viewport: viewport)
                return
            }
            guard let live = liveTopology else { return }

            // Ideal topology for THIS apparent — a pure function of apparent (fixed nominal gap → no direction
            // dependence), so the same value resolves identically whether pinching in or out (SamePathInOut).
            let idealCols = EE.columnCount(apparentCellSize: apparent, viewportWidth: W, gap: 4)
            let idealCrop = JustifiedCollectionLayout.levels[nearestLevel(forApparentSize: apparent, fallback: live.cropSquare ? JustifiedCollectionLayout.levels.count - 1 : 0)].cropMode == .squareFill
            let stepped = EE.steppedColumnCount(current: live.columns, ideal: idealCols)

            let result = EE.planTick(apparent: apparent, viewportWidth: W, live: live,
                                     idealColumns: idealCols, idealCropSquare: idealCrop,
                                     steppedGap: v2Gap(cols: stepped, width: W),
                                     cropThreshold: v2CropThreshold, jitterEpsilon: v2JitterEpsilon,
                                     active: activeRebase, now: CACurrentMediaTime(), duration: v2RebaseDuration)
            liveTopology = result.live
            activeRebase = result.active
            if result.started {                          // a NEW rebase began → self-clock it to completion
                rebaseTickGeneration += 1
                scheduleRebaseTick(generation: rebaseTickGeneration)
            }
            renderTopologyPlan(result.plan, session: session, apparent: apparent, canvas: canvas, viewport: viewport)
        }

        /// Self-clock: a rebase is time-based but the live `.changed` path is event-driven, so a paused finger
        /// would freeze a half-blend (the ghost wall). This main-loop tick advances the rebase to completion
        /// using the LAST held `apparent`, independent of further NSEvents; a generation token makes stale ticks
        /// no-op and prevents double chains. It NEVER starts a new rebase (planTick refuses while one is active).
        @MainActor private func scheduleRebaseTick(generation: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
                MainActor.assumeIsolated { self?.advanceRebaseTick(generation: generation) }
            }
        }
        @MainActor private func advanceRebaseTick(generation: Int) {
            guard generation == rebaseTickGeneration, isPinching, !isGridZoomSettling,
                  let session = pinchSession, activeRebase != nil else { return }
            updateContinuousGrid(session: session, apparent: session.apparentSize)
            if activeRebase != nil { scheduleRebaseTick(generation: generation) }
        }

        /// Render a plan into the flat slot page: one layout for `.single`, two fixed-rect layers (from fading
        /// out, to fading in) for `.rebasing`. Sprites are z-sorted so the anchor + focus row are the topmost
        /// quads (anchor-topmost invariant), and every sprite keeps `fromFrame == toFrame` (no rect lerp).
        @MainActor private func renderTopologyPlan(_ plan: ContinuousDaySectionedGridLayoutEngine.RebasePlan,
                                                   session: PinchSession, apparent: CGFloat,
                                                   canvas: GridSpriteTransitionView, viewport: CGRect) {
            let prepareStart = CACurrentMediaTime()
            var sprites: [GridTransitionSpriteDescriptor] = []
            var primaryVisibleUIDs: [PhotoUID] = []
            var renderedColumns = 0
            var anchorRect: CGRect? = nil    // the SOURCE (single/outgoing) anchor's actual drawn rect, or nil
            var rebasing = false
            switch plan {
            case .single(let topo):
                let r = renderLayer(session: session, topology: topo, apparent: apparent, role: .single, t: 1)
                sprites = r.sprites; primaryVisibleUIDs = r.visibleUIDs; renderedColumns = topo.columns; anchorRect = r.anchorRect
            case .rebasing(let rb, let alpha):
                rebasing = true
                let out = renderLayer(session: session, topology: rb.from, apparent: apparent, role: .outgoing, t: alpha)
                let inc = renderLayer(session: session, topology: rb.to, apparent: apparent, role: .incoming, t: alpha)
                sprites = out.sprites + inc.sprites
                primaryVisibleUIDs = out.visibleUIDs
                renderedColumns = rb.to.columns          // the topology we are landing on
                anchorRect = out.anchorRect              // the source (outgoing) anchor is the topmost quad
            }
            // Painter z-order: array order IS z (later = front). Low priority first → anchor (z=2) + focus row
            // (z=1) drawn last, on top of the dissolving non-focus rows. Stable sort preserves within-z order.
            sprites = sprites.enumerated().sorted { $0.element.priority != $1.element.priority ? $0.element.priority < $1.element.priority : $0.offset < $1.offset }.map(\.element)
            // True anchor-topmost diagnostic: the anchor sprite is the UNIQUE max-priority quad, so wherever its
            // own rect covers the cursor it IS the topmost covering quad. Report PASS only if the anchor was
            // actually drawn (alpha>0, image present) AND covers the cursor — a content anchor has no photo to
            // pin, so it trivially passes. No false PASS when the anchor was skipped.
            let anchorScreen = session.anchor.viewportPoint
            let anchorTop = session.anchor.uid == nil ? true : (anchorRect?.contains(anchorScreen) ?? false)

            if let bad = sprites.first(where: { $0.fromFrame != $0.toFrame }) {
                logGridZoom("INVARIANT FAIL: continuous-grid node rect interpolates (fromFrame != toFrame) key=\(bad.key)")
                assertionFailure("continuous-grid node rect interpolates — rect morphing is forbidden")
            }
            lastRenderedColumns = renderedColumns
            slotBuildCount += 1
            let replaceStats = canvas.replaceWorldSlots(sprites: sprites, sourceRect: viewport)
            if replaceStats.missingImage > 0 || replaceStats.blackTileCount > 0 {
                PhotoDiagnostics.shared.emit("ThumbHealth", [
                    "phase": "pinchChanged",
                    "missingImage": "\(replaceStats.missingImage)",
                    "blackTileCount": "\(replaceStats.blackTileCount)",
                    "droppedSpriteBecauseMissingImage": "0",
                ], throttleSeconds: 0.25)
            }
            backdropFrozenUIDSet = Set(primaryVisibleUIDs)

            let feed = parent.feed
            let missing = primaryVisibleUIDs.filter { feed.memoryImage(for: $0) == nil }
            if !missing.isEmpty { Task { _ = await feed.warmDecoded(Array(missing.prefix(220)), limit: 240) } }

            let prepareMs = (CACurrentMediaTime() - prepareStart) * 1000
            let prepareStats = recordGridZoomPrepare(ms: prepareMs)
            gridZoomPerfFrame += 1
            let renderStats = canvas.stats
            if renderStats.atlasMissingUV > 0 {
                PhotoDiagnostics.shared.classifyThumbnail(ThumbnailVisualClassification(
                    uid: nil,
                    rect: viewport,
                    state: .atlasMissing,
                    phase: "pinchChanged",
                    context: "worldSlots.atlasMissingUV count=\(renderStats.atlasMissingUV)"
                ))
            }
            PhotoDiagnostics.shared.recordFrame(FrameHealthMetric(
                phase: "pinchChanged",
                frameTimeMs: renderStats.mainThreadMs,
                pinchChangedDurationMs: prepareMs,
                layoutComputeMs: prepareMs,
                overlayRenderMs: renderStats.cpuPrepareMs,
                metalDrawMs: renderStats.metalDrawMs,
                textureUploadMs: renderStats.textureUploadMs,
                atlasBuildMs: renderStats.atlasBuildMs,
                vertexBuildMs: renderStats.vertexBuildMs,
                timeToFirstOverlayMs: timeToFirstChangedDrawn.map { ($0 - pinchBeganAt) * 1000 } ?? 0
            ))
            PhotoDiagnostics.shared.emit("GridZoomPerf", [
                "frame": "\(gridZoomPerfFrame)",
                "spriteCount": "\(sprites.count)",
                "slotCount": "\(renderStats.slotCount)",
                "pageCount": "\(renderStats.pageCount)",
                "textureCount": "\(renderStats.textureCount)",
                "atlasCount": "\(renderStats.atlasCount)",
                "atlasRebuildCount": "\(renderStats.atlasBuildCount)",
                "vertexRebuildCount": "\(renderStats.vertexBuildCount)",
                "gpuTextureMiss": "\(renderStats.gpuTextureMiss)",
                "atlasMissingUV": "\(renderStats.atlasMissingUV)",
                "placeholderTextureUsed": "\(renderStats.placeholderTextureUsed)",
                "drawMs": fmt(renderStats.metalDrawMs),
                "cpuPrepareMs": fmt(prepareMs),
                "mainThreadMs": fmt(prepareMs + renderStats.metalDrawMs),
                "layoutSnapshotBuildCount": "\(layoutSnapshotBuildCount)",
                "slotBuildCount": "\(slotBuildCount)",
                "sourceSnapshotBuildCount": "\(sourceSnapshotBuildCount)",
                "targetSnapshotBuildCount": "\(targetSnapshotBuildCount)",
                "vertexBufferRebuildCount": "\(renderStats.vertexBuildCount)",
                "perFrameAllocationBytes": "\(renderStats.perFrameAllocationBytes)",
                "maxFramePrepareMs": fmt(prepareStats.max),
                "p95FramePrepareMs": fmt(prepareStats.p95),
            ], throttleSeconds: 0.10)
            PhotoDiagnostics.shared.emitThumbHealthSummary(phase: "pinchChanged", reset: true, throttleSeconds: 0.50)
            PhotoDiagnostics.shared.emitGridZoomHotPath(reset: false, throttleSeconds: 0.50)

            let now = CACurrentMediaTime()
            guard now - lastTargetFillLogAt > 0.10 else { return }
            lastTargetFillLogAt = now
            logGridZoom("continuousGrid apparent=\(fmt(apparent)) cols=\(renderedColumns) rebasing=\(rebasing) sprites=\(sprites.count) live=\(liveTopology?.columns ?? -1)/\(liveTopology.map { $0.cropSquare ? "sq" : "fit" } ?? "?") renderStats=[\(renderStats.summary)]")
            logGridZoom("focusAnchor anchorUID=\(session.anchor.uid.map { key(for: $0) } ?? "content") anchorTopmostStatus=\(anchorTop ? "PASS" : "FAIL")")
            if !anchorTop { logGridZoom("INVARIANT FAIL: topUIDAtAnchor != anchorUID during active pinch") }
        }

        /// Render ONE topology layer as screen-space sprites: every visible photo at its FIXED day-sectioned
        /// rect put through the global zoom transform about the cursor (`screenRect` — a pure scale, never a
        /// lerp of two rects). The role picks the alpha curve: `.single` = opaque; `.outgoing` fades (focus row
        /// held opaque until the incoming takes over); `.incoming` fades in (suppressed in the focus band until
        /// very late). `priority` is the painter z-key so the anchor/focus row land on top.
        @MainActor private func renderLayer(session: PinchSession, topology: ContinuousDaySectionedGridLayoutEngine.Topology,
                                            apparent: CGFloat, role: V2LayerRole, t: CGFloat)
            -> (sprites: [GridTransitionSpriteDescriptor], visibleUIDs: [PhotoUID], anchorRect: CGRect?) {
            guard let cv = collectionView, let jcl = layout else { return ([], [], nil) }
            layoutSnapshotBuildCount += 1
            typealias EE = ContinuousDaySectionedGridLayoutEngine
            let viewport = CGRect(origin: .zero, size: session.viewportSize)
            let anchorScreen = session.anchor.viewportPoint
            let W = cv.bounds.width
            let cols = max(topology.columns, 1)
            let gap = topology.gap
            // DAY-SECTIONED geometry at this topology — IDENTICAL to what the committed grid shows at the same
            // column count (commit == renderer). The live grid is a pure SCALE of these fixed rects about the
            // cursor; the crop (`fillSquare`) is the topology's crop (only ever changes via a rebase, never per
            // frame), so the anchor's framing does not pop at the crop boundary.
            let side = max((W - gap * CGFloat(cols - 1)) / CGFloat(cols), 1)
            let scale = apparent / side
            let square = topology.cropSquare
            let focusHalf = GridZoomMath.focusBandHalfHeight(viewportHeight: viewport.height)

            let anchorIP = session.anchor.uid.flatMap { indexByUID[$0] }
            let anchorDoc: CGPoint
            if let ip = anchorIP, let r = jcl.projectedFrameForItem(at: ip, cols: cols, gap: gap, width: W) {
                anchorDoc = CGPoint(x: r.midX, y: r.midY)
            } else { anchorDoc = anchorScreen }

            let halfW = viewport.width / max(scale, 0.001) * 0.5 + side
            let halfH = viewport.height / max(scale, 0.001) * 0.5 + side
            let docRegion = CGRect(x: anchorDoc.x - halfW, y: anchorDoc.y - halfH, width: halfW * 2, height: halfH * 2)

            var sprites: [GridTransitionSpriteDescriptor] = []
            var visibleUIDs: [PhotoUID] = []
            var anchorRect: CGRect? = nil    // set ONLY when the anchor sprite is actually drawn (alpha>0, image)
            let cull = viewport.insetBy(dx: -side * scale, dy: -side * scale)
            for (ip, docFrame) in jcl.projectedFramesForElements(in: docRegion, cols: cols, gap: gap, width: W) {
                guard ip.section < sections.count, ip.item < sections[ip.section].items.count else { continue }
                let screen = EE.screenRect(docRect: docFrame, anchorDoc: anchorDoc, anchorScreen: anchorScreen, scale: scale)
                let uid = sections[ip.section].items[ip.item].uid
                let intersectsViewport = screen.intersects(viewport)
                guard screen.intersects(cull) else {
                    if intersectsViewport {
                        PhotoDiagnostics.shared.classifyThumbnail(ThumbnailVisualClassification(
                            uid: uid,
                            rect: screen,
                            state: .geometryHole,
                            phase: "pinchChanged",
                            context: "zoomOverlay.culledVisibleRect"
                        ))
                    }
                    continue
                }
                let isAnchor = session.anchor.uid == uid
                let inBand = session.anchor.uid != nil && abs(screen.midY - anchorScreen.y) < focusHalf
                let alpha: CGFloat
                switch role {
                case .single:   alpha = 1
                case .outgoing: alpha = inBand ? (1 - EE.rebaseIncomingAlpha(inFocusBand: true, t: t)) : EE.rebaseOutgoingAlpha(t)
                case .incoming: alpha = EE.rebaseIncomingAlpha(inFocusBand: inBand, t: t)
                }
                guard alpha > 0.01 else {
                    if intersectsViewport {
                        PhotoDiagnostics.shared.classifyThumbnail(ThumbnailVisualClassification(
                            uid: uid,
                            rect: screen,
                            state: .intentionallyClipped,
                            phase: "pinchChanged",
                            context: "zoomOverlay.alphaSuppressed"
                        ))
                    }
                    continue
                }
                visibleUIDs.append(uid)
                guard let img = slotImage(uid, session: session) else {
                    if intersectsViewport {
                        PhotoDiagnostics.shared.classifyThumbnail(ThumbnailVisualClassification(
                            uid: uid,
                            rect: screen,
                            state: .unknownBug,
                            phase: "pinchChanged",
                            context: "placeholderInvariant violation; no slot image"
                        ))
                        PhotoDiagnostics.shared.emit("ThumbHealth", [
                            "placeholderInvariant": "violation",
                            "uid": key(for: uid),
                            "rect": rectLog(screen),
                            "phase": "pinchChanged",
                        ], throttleSeconds: 0.1)
                    }
                    continue
                }
                if intersectsViewport {
                    PhotoDiagnostics.shared.classifyThumbnail(ThumbnailVisualClassification(
                        uid: uid,
                        rect: screen,
                        state: img.visualState,
                        phase: "pinchChanged",
                        context: img.context
                    ))
                }
                let z = EE.zKey(isAnchor: isAnchor, inFocusBand: inBand)
                let bias = z >= 1 ? (role == .incoming ? 0 : 1) : (role == .incoming ? 1 : 0)
                sprites.append(GridTransitionSpriteDescriptor(
                    key: img.isPlaceholder ? "__ph__" : key(for: uid), image: img.cg, imageSize: img.size,
                    fromFrame: screen, toFrame: screen, fromAlpha: Float(alpha), toAlpha: Float(alpha),
                    priority: CGFloat(z * 10 + bias), fillSquare: square && !img.isPlaceholder))
                // The anchor (z=2) is the UNIQUE highest-priority quad: wherever its own rect covers the cursor
                // it is the topmost covering quad (nothing can overdraw it). Record its drawn rect — only for
                // the source (non-incoming) layer, and only now that it is actually appended (alpha>0, image).
                if isAnchor, role != .incoming { anchorRect = screen }
            }
            return (sprites, visibleUIDs, anchorRect)
        }

        /// Phase 6: record the current level's visible structure (read-only; no behaviour change) so the
        /// later layout-model pass has concrete numbers to compare against the Apple reference.
        @MainActor private func logLayoutMetrics() {
            guard let layout, let cv = collectionView else { return }
            let lvl = min(max(layout.level, 0), JustifiedCollectionLayout.levels.count - 1)
            let cfg = JustifiedCollectionLayout.levels[lvl]
            let width = cv.bounds.width
            let cols = max(1, Int((width + cfg.gap) / (cfg.size + cfg.gap)))
            let side = (width - cfg.gap * CGFloat(cols - 1)) / CGFloat(cols)
            let gapRatio = side > 0 ? cfg.gap / side : 0
            let visible = cv.indexPathsForVisibleItems().count
            logGridZoom("layoutMetrics level=\(lvl) square=\(cfg.square) targetSize=\(fmt(cfg.size)) cols=\(cols) side=\(fmt(side)) gap=\(fmt(cfg.gap)) gapRatio=\(fmt(gapRatio)) cropMode=\(cfg.square ? "aspectFit(square-cell)" : "justified") visibleItems=\(visible)")
        }

        /// Guardrail: while a grid zoom is active with an overlay, the real collection view MUST stay
        /// hidden. Surfaced (not fatal) so a regression shows up loudly in the pinch log.
        @MainActor private func assertGridHiddenDuringZoom() {
            #if DEBUG
            if gridZoomBusy, transitionCanvas != nil, let a = collectionView?.alphaValue, a != 0 {
                logGridZoom("INVARIANT VIOLATION cv.alpha=\(fmt(a)) while gridZoomBusy with overlay present")
            }
            #endif
        }

        /// Continuous zoom-position model: shape the magnification delta (responsive near zero), convert
        /// to a fractional grid-level position, and log-interpolate the thumbnail size between levels. A
        /// tiny finger delta produces a small, smooth scale change; the final SNAP still uses `nearestLevel`.
        private func liveZoom(magnification mag: CGFloat, session: PinchSession) -> (apparentSize: CGFloat, visualScale: CGFloat, levelPosition: CGFloat, shapedDelta: CGFloat) {
            let levels = JustifiedCollectionLayout.levels
            let delta = mag - pinchBaseMag
            let exponent = CGFloat(AnimationTuning.shared.pinchLiveExponent)
            let sensitivity = CGFloat(AnimationTuning.shared.pinchLiveSensitivity)
            let shaped = signedPow(delta, exponent: exponent)
            let levelDelta = shaped * sensitivity
            // Fingers spread (positive magnification) → larger thumbnails → SMALLER level index.
            let position = min(max(CGFloat(session.sourceLevel) - levelDelta, 0), CGFloat(levels.count - 1))
            let apparentSize = logInterpolatedSize(at: position)
            let visualScale = apparentSize / max(session.sourceZoomSize, 1)
            return (apparentSize, visualScale, position, shaped)
        }

        private func signedPow(_ x: CGFloat, exponent: CGFloat) -> CGFloat {
            x == 0 ? 0 : (x > 0 ? 1 : -1) * pow(abs(x), exponent)
        }

        private func logInterpolatedSize(at position: CGFloat) -> CGFloat {
            let levels = JustifiedCollectionLayout.levels
            let maxIndex = levels.count - 1
            let lo = min(max(Int(floor(position)), 0), maxIndex)
            let hi = min(max(Int(ceil(position)), 0), maxIndex)
            if lo == hi { return levels[lo].size }
            let t = position - CGFloat(lo)
            let a = log(levels[lo].size)
            let b = log(levels[hi].size)
            return exp(a + (b - a) * t)
        }

        private func nearestLevel(forApparentSize apparentSize: CGFloat, fallback: Int) -> Int {
            JustifiedCollectionLayout.levels.indices.min {
                abs(JustifiedCollectionLayout.levels[$0].size - apparentSize)
                    < abs(JustifiedCollectionLayout.levels[$1].size - apparentSize)
            } ?? fallback
        }

        private func stableTargetLevel(apparentSize: CGFloat, session: PinchSession) -> Int {
            let nearest = nearestLevel(forApparentSize: apparentSize, fallback: session.sourceLevel)
            let current = session.targetLevel
            guard nearest != current else { return current }
            let levels = JustifiedCollectionLayout.levels
            let currentDistance = abs(levels[current].size - apparentSize)
            let nearestDistance = abs(levels[nearest].size - apparentSize)
            let hysteresis = max(2, session.sourceZoomSize * 0.035)
            return nearestDistance + hysteresis < currentDistance ? nearest : current
        }

        private func progressFor(apparentSize: CGFloat, sourceLevel: Int, targetLevel: Int) -> CGFloat {
            guard sourceLevel != targetLevel else { return 0 }
            let levels = JustifiedCollectionLayout.levels
            let source = levels[sourceLevel].size
            let target = levels[targetLevel].size
            let raw = (apparentSize - source) / max(abs(target - source), 0.001) * (target >= source ? 1 : -1)
            return max(0, min(1, raw))
        }

        @MainActor private func captureZoomAnchor(contentPoint: CGPoint, viewportPoint: CGPoint) -> ZoomAnchor {
            guard let cv = collectionView, let layout,
                  let indexPath = cv.indexPathForItem(at: contentPoint),
                  indexPath.section < sections.count,
                  indexPath.item < sections[indexPath.section].items.count,
                  let attributes = layout.layoutAttributesForItem(at: indexPath) else {
                return .content(contentPoint: contentPoint, viewportPoint: viewportPoint)
            }
            let uid = sections[indexPath.section].items[indexPath.item].uid
            let cellFrame = attributes.frame
            let cellLocal = CGPoint(
                x: max(0, min(1, (contentPoint.x - cellFrame.minX) / max(cellFrame.width, 1))),
                y: max(0, min(1, (contentPoint.y - cellFrame.minY) / max(cellFrame.height, 1)))
            )
            // The displayed-image frame inside the cell at the SOURCE level: aspectFit letterboxes,
            // squareFill fills the cell. If the cursor is on the visible photo, anchor on the IMAGE.
            let sourceCrop = JustifiedCollectionLayout.levels[min(max(layout.level, 0), JustifiedCollectionLayout.levels.count - 1)].cropMode
            let image = liveLayerImage(at: indexPath)
                ?? parent.feed.memoryImage(for: uid)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let imageSize = image.map { CGSize(width: $0.width, height: $0.height) } ?? cellFrame.size
            if image == nil {
                logGridZoom("anchor imageSizeFallback uid=\(key(for: uid)) usingCellFrame")
            }
            let imageFrame = displayedImageFrame(cellFrame: cellFrame, imageSize: imageSize, cropMode: sourceCrop)
            if imageFrame.contains(contentPoint) {
                let imageLocal = CGPoint(
                    x: max(0, min(1, (contentPoint.x - imageFrame.minX) / max(imageFrame.width, 1))),
                    y: max(0, min(1, (contentPoint.y - imageFrame.minY) / max(imageFrame.height, 1)))
                )
                return .assetImage(uid: uid, imageLocalUnitPoint: imageLocal, cellLocalUnitPoint: cellLocal,
                                   imageSize: imageSize, viewportPoint: viewportPoint, contentPoint: contentPoint,
                                   sourceIndexPath: indexPath)
            }
            return .assetCell(uid: uid, cellLocalUnitPoint: cellLocal, viewportPoint: viewportPoint,
                              contentPoint: contentPoint, sourceIndexPath: indexPath)
        }

        /// The displayed-image frame inside a cell (delegates to the pure helper). aspectFit → letterbox
        /// fitted rect; squareFill → the cell (image crops to fill). Falls back to the cell when imageSize
        /// is unknown.
        private func displayedImageFrame(cellFrame: CGRect, imageSize: CGSize, cropMode: GridCropMode) -> CGRect {
            GridZoomMath.displayedImageFrame(cellFrame: cellFrame, imageSize: imageSize, cropMode: cropMode)
        }

        private struct GridCellSnapshot {
            let uid: PhotoUID
            let key: String
            let cellFrame: CGRect
            let imageFrame: CGRect
            let image: CGImage?
            let imageSize: CGSize
            let priority: CGFloat
            var fillSquare: Bool = false   // source level is `squareFill` → center-crop to the square cell
            var isPlaceholder: Bool = false
        }

        private struct SlotImageChoice {
            let cg: CGImage
            let size: CGSize
            let isPlaceholder: Bool
            let visualState: ThumbnailVisualState
            let context: String
        }

        @MainActor private func captureSourceSnapshots(origin: CGPoint, viewportSize: CGSize) -> [PhotoUID: GridCellSnapshot] {
            guard let layout else { return [:] }
            sourceSnapshotBuildCount += 1
            let cropMode = JustifiedCollectionLayout.levels[min(max(layout.level, 0), JustifiedCollectionLayout.levels.count - 1)].cropMode
            let viewport = CGRect(origin: .zero, size: viewportSize)
            let viewportCenter = CGPoint(x: viewport.midX, y: viewport.midY)
            // Small synchronous capture window so `.began` returns within ~a frame — large margins were
            // the startup-latency cost. Edge blanks in source-only diagnostic mode are acceptable.
            let rect = NSRect(origin: origin, size: viewportSize)
                .insetBy(dx: -viewportSize.width * 0.10, dy: -viewportSize.height * 0.25)
            var snapshots: [PhotoUID: GridCellSnapshot] = [:]
            var skippedOffscreenNil = 0
            for attributes in layout.layoutAttributesForElements(in: rect) {
                guard let indexPath = attributes.indexPath,
                      indexPath.section < sections.count,
                      indexPath.item < sections[indexPath.section].items.count else { continue }
                let photo = sections[indexPath.section].items[indexPath.item]
                let docFrame = attributes.frame
                let cellFrame = CGRect(
                    x: docFrame.minX - origin.x,
                    y: docFrame.minY - origin.y,
                    width: docFrame.width,
                    height: docFrame.height
                )
                let isVisible = viewport.intersects(cellFrame)
                // HOT-PATH FAST capture only: the live cell's already-decoded layer image, else the cached
                // thumbnail. No `cacheDisplay` (it's the expensive per-cell render that slowed `.began`).
                let realImage = liveLayerImage(at: indexPath)
                    ?? parent.feed.memoryImage(for: photo.uid)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                if realImage == nil && !isVisible {
                    skippedOffscreenNil += 1   // no image + off-screen → no black placeholder tile
                    continue
                }
                let image = realImage ?? GridThumbnailFallback.placeholderImage
                if realImage == nil, isVisible {
                    PhotoDiagnostics.shared.logThumbHealth(
                        uid: photo.uid,
                        rect: cellFrame,
                        reason: "sourceCaptureRamMissShowingPlaceholder",
                        phase: "pinchBegin"
                    )
                }
                let imageSize = CGSize(width: image.width, height: image.height)
                let fillSquare = cropMode == .squareFill && realImage != nil          // dense level → crop to the square cell
                let imageFrame = (realImage == nil || fillSquare) ? cellFrame : fittedImageFrame(in: cellFrame, imageSize: imageSize)
                let dx = imageFrame.midX - viewportCenter.x
                let dy = imageFrame.midY - viewportCenter.y
                let offscreenPenalty: CGFloat = isVisible ? 0 : max(viewport.width, viewport.height) * 4
                let snapshot = GridCellSnapshot(
                    uid: photo.uid,
                    key: key(for: photo.uid),
                    cellFrame: cellFrame,
                    imageFrame: imageFrame,
                    image: image,
                    imageSize: imageSize,
                    priority: dx * dx + dy * dy + offscreenPenalty,
                    fillSquare: fillSquare,
                    isPlaceholder: realImage == nil
                )
                if let existing = snapshots[photo.uid] {
                    if snapshot.priority < existing.priority || (existing.image == nil && snapshot.image != nil) {
                        snapshots[photo.uid] = snapshot
                    }
                } else {
                    snapshots[photo.uid] = snapshot
                }
            }
            if skippedOffscreenNil > 0 {
                logGridZoom("capture snapshots=\(snapshots.count) skippedOffscreenNil=\(skippedOffscreenNil)")
            }
            return snapshots
        }

        /// Fast: the live cell's decoded layer thumbnail (a CGImage), or nil if the cell isn't realized.
        @MainActor private func liveLayerImage(at indexPath: IndexPath) -> CGImage? {
            guard let contents = (collectionView?.item(at: indexPath) as? PhotoGridItem)?.view.layer?.contents else { return nil }
            let cf = contents as CFTypeRef
            return CFGetTypeID(cf) == CGImage.typeID ? (contents as! CGImage) : nil
        }

        @MainActor private func buildSpriteTransition(
            session: PinchSession,
            targetLevel: Int,
            progress: CGFloat,
            visualScale: CGFloat,
            includeTargetGhosts: Bool,
            rebuildAtlas: Bool
        ) {
            guard let cv = collectionView, let clip = scrollView?.contentView else { return }
            let viewportSize = clip.bounds.size
            let targetCells: [PhotoUID: GridCellSnapshot]
            if includeTargetGhosts {
                let targetOrigin = anchoredOrigin(for: session.anchor, level: targetLevel, fallback: session.sourceOrigin, projected: true)
                let targetRect = NSRect(origin: targetOrigin, size: viewportSize)
                    .insetBy(dx: -viewportSize.width * 0.14, dy: -viewportSize.height * 0.35)
                targetCells = projectedSnapshots(level: targetLevel, origin: targetOrigin, rect: targetRect)
            } else {
                targetCells = [:]
            }
            var descriptors = continuitySprites(
                source: session.sourceSnapshotsByUID,
                target: targetCells,
                viewportSize: viewportSize,
                anchor: session.anchor.viewportPoint,
                visualScale: visualScale,
                sourceOnly: !includeTargetGhosts
            )
            if descriptors.isEmpty {
                logGridZoom("ERROR empty overlay descriptors while gridZoomBusy; drawing placeholder and keeping live grid hidden")
                descriptors = placeholderSprites(viewportSize: viewportSize)
            }

            let canvas = transitionCanvas ?? GridSpriteTransitionView(frame: viewportFrame(in: clip))
            guard canvas.isReady else {
                cv.alphaValue = 0
                logGridZoom("ERROR grid sprite canvas unavailable; live grid remains hidden")
                return
            }
            positionTransitionCanvas(canvas, in: clip)
            canvas.autoresizingMask = []
            if canvas.superview !== clip {
                canvas.removeFromSuperview()
                clip.addSubview(canvas)
            }
            transitionCanvas = canvas
            if !didRunOrientationProbe {
                didRunOrientationProbe = true
                logGridZoom("orientation \(canvas.runOrientationSelfTest())")
            }
            transitionFromLevel = session.sourceLevel
            transitionToLevel = targetLevel
            transitionProgress = progress
            cv.alphaValue = 0
            canvas.alphaValue = 1
            canvas.configure(sprites: descriptors, progress: progress, rebuildAtlas: rebuildAtlas)
            transitionAtlasPrepared = true
            lastOverlayAnchorDiagnostic = overlayAnchorDiagnostic(
                session: session,
                visualScale: visualScale,
                descriptors: descriptors,
                canvas: canvas
            )

            let feed = parent.feed
            let priorityUIDs = Array(Set(session.sourceSnapshotsByUID.keys).union(targetCells.keys)).prefix(240)
            Task { for uid in priorityUIDs { await feed.requestPriority(uid, priority: .zoomAnchorAndFocusRow) } }
        }

        // MARK: Visual commit plan + target-preview settle

        struct ZoomCommitPlan {
            let level: Int
            let origin: CGPoint
            let anchorOnlyOrigin: CGPoint
            let visualBestOrigin: CGPoint
            let weightedVisibleCount: Int
            let anchorError: CGPoint
        }

        /// Choose the committed content-origin by preserving the visible NEIGHBORHOOD, not just the one
        /// anchor point (anchor-only origin replaces the whole neighborhood → snap). Each visible source
        /// proxy (page 0 + appended coverage, Phase 2) votes for the originY that would land ITS target
        /// frame at its current on-screen position; the anchor is weighted ≫ others so its error stays
        /// bounded. A weighted median (robust to a few outliers) picks the origin. X stays anchor-derived
        /// (the grid has no horizontal scroll).
        @MainActor private func makeZoomCommitPlan(session: PinchSession, finalLevel: Int) -> ZoomCommitPlan {
            // Origin IDENTITY: if the live `.changed` surface froze a TargetDetentPlan and the release
            // snaps to that SAME level, commit to the plan's EXACT origin — the precise content the gesture
            // previewed. Otherwise derive the anchor-only origin from the TARGET level's PROJECTED geometry
            // (projectedFrameForItem / projectedContentSize at finalLevel), NOT the current/source-level
            // layout. The real grid commits to the target level (commitRealGrid sets layout.level AFTER
            // this), so `projected: false` solved the anchor in source-level frames → positional drift.
            let anchorOnly = GridZoomMath.commitOrigin(
                livePlanTargetLevel: liveTargetPlan?.targetLevel,
                livePlanOrigin: liveTargetPlan?.origin,
                finalLevel: finalLevel
            ) ?? anchoredOrigin(for: session.anchor, level: finalLevel, fallback: session.sourceOrigin, projected: true)
            guard let cv = collectionView, let layout, let clip = scrollView?.contentView else {
                return ZoomCommitPlan(level: finalLevel, origin: anchorOnly, anchorOnlyOrigin: anchorOnly, visualBestOrigin: anchorOnly, weightedVisibleCount: 0, anchorError: .zero)
            }
            let viewport = CGRect(origin: .zero, size: session.viewportSize)
            let anchor = session.anchor.viewportPoint
            let anchorUID = session.anchor.uid
            let focusHalf = GridZoomMath.focusBandHalfHeight(viewportHeight: viewport.height)
            var votes: [GridZoomMath.OriginVote] = []
            var count = 0
            for (uid, snapshot) in session.sourceSnapshotsByUID {
                let scaledFrame = scaledAround(snapshot.imageFrame, anchor: anchor, scale: session.visualScale)
                guard scaledFrame.intersects(viewport) else { continue }
                guard let ip = indexByUID[uid],
                      let targetFrame = layout.projectedFrameForItem(at: ip, level: finalLevel, width: cv.bounds.width) else { continue }
                let weight: CGFloat = (uid == anchorUID) ? 10 : (abs(scaledFrame.midY - anchor.y) < focusHalf ? 4 : 1)
                votes.append(GridZoomMath.originVote(sourceScreenMidY: scaledFrame.midY, targetDocMidY: targetFrame.midY, weight: weight))
                count += 1
            }
            // The COMMITTED origin is ANCHOR-ONLY — release continues the user's anchored zoom, it does
            // NOT auto-align/recenter to a best-fit neighborhood. The weighted median is computed only as
            // a diagnostic (visualBestOrigin / logged delta), never shipped.
            let visualBestY = GridZoomMath.weightedMedian(votes) ?? anchorOnly.y
            let contentSize = layout.projectedContentSize(level: finalLevel, width: cv.bounds.width)
            let clampedVisualBest = clampedOrigin(CGPoint(x: anchorOnly.x, y: visualBestY), contentSize: contentSize, viewportSize: clip.bounds.size)
            logGridZoom("commitPlan originMode=anchorOnly visualBestDeltaY=\(fmt(clampedVisualBest.y - anchorOnly.y)) visibleVoteCount=\(count)")
            return ZoomCommitPlan(
                level: finalLevel,
                origin: anchorOnly,
                anchorOnlyOrigin: anchorOnly,
                visualBestOrigin: clampedVisualBest,
                weightedVisibleCount: count,
                anchorError: anchorErrorForOrigin(anchorOnly, level: finalLevel, session: session)
            )
        }

        /// Where the anchor item's local point would land (viewport space) vs the cursor, if the grid
        /// were committed at `origin`/`level`. Used to report the plan's residual anchor error.
        @MainActor private func anchorErrorForOrigin(_ origin: CGPoint, level: Int, session: PinchSession) -> CGPoint {
            guard let cv = collectionView, let layout else { return .zero }
            // image anchor → image-local point on the displayed-image frame; cell anchor → cell-local on
            // the cell frame; content/gap → no asset-relative error.
            let uid: PhotoUID, local: CGPoint, useImage: Bool, imageSize: CGSize, viewportPoint: CGPoint
            switch session.anchor {
            case .assetImage(let u, let il, _, let isz, let vp, _, _):
                (uid, local, useImage, imageSize, viewportPoint) = (u, il, true, isz, vp)
            case .assetCell(let u, let cl, let vp, _, _):
                (uid, local, useImage, imageSize, viewportPoint) = (u, cl, false, .zero, vp)
            case .content:
                return .zero
            }
            guard let ip = indexByUID[uid],
                  let cellFrame = layout.projectedFrameForItem(at: ip, level: level, width: cv.bounds.width) else { return .zero }
            let cropMode = JustifiedCollectionLayout.levels[min(max(level, 0), JustifiedCollectionLayout.levels.count - 1)].cropMode
            let frame = useImage ? displayedImageFrame(cellFrame: cellFrame, imageSize: imageSize, cropMode: cropMode) : cellFrame
            let screenX = frame.minX + local.x * frame.width - origin.x
            let screenY = frame.minY + local.y * frame.height - origin.y
            return CGPoint(x: screenX - viewportPoint.x, y: screenY - viewportPoint.y)
        }

        private func planLog(_ p: ZoomCommitPlan) -> String {
            "commitPlan level=\(p.level) anchorOnlyY=\(fmt(p.anchorOnlyOrigin.y)) visualBestY=\(fmt(p.visualBestOrigin.y)) chosenY=\(fmt(p.origin.y)) weightedVisibleCount=\(p.weightedVisibleCount) anchorError=(\(fmt(p.anchorError.x)),\(fmt(p.anchorError.y)))"
        }

        /// On release: ease the continuous bracket — drive `apparent` from its release value to the snapped
        /// level's cell size, rebuilding the slot page each frame so the grid re-justifies to land EXACTLY
        /// on `finalLevel`, then commit the real grid underneath at the same anchored origin. IDENTICAL for
        /// every snap (including a same-level return); only the target size differs.
        @MainActor private func settlePinchSession(to finalLevel: Int) {
            coverageTopUpGeneration += 1   // invalidate any in-flight async work
            let settleGeneration = coverageTopUpGeneration   // a new pinch bumps this → abandon this settle
            guard let session = pinchSession else { finishGridZoom(); return }
            let plan = makeZoomCommitPlan(session: session, finalLevel: finalLevel)
            logGridZoom(planLog(plan))
            guard let canvas = transitionCanvas, canvas.isReady else {
                collectionView?.alphaValue = 0
                logGridZoom("ERROR grid sprite canvas unavailable during settle; committing hidden grid")
                completeGridZoom(plan: plan, anchor: session.anchor, canvas: nil)
                return
            }
            collectionView?.alphaValue = 0
            canvas.alphaValue = 1
            transitionFromLevel = session.sourceLevel
            transitionToLevel = finalLevel
            targetPreviewBuilt = true
            // The detent is a COLUMN COUNT (the committed grid's column count at finalLevel); its apparent
            // cell size is that count's natural (viewport-filling) size, so the continuous grid eases to a
            // clean column boundary (scale 1) — no half-transition state at commit.
            let W = collectionView?.bounds.width ?? session.viewportSize.width
            // The detent column count is exactly the committed grid's column count at finalLevel; its gap is
            // that level's gap → the overlay lands on the SAME day-sectioned geometry the commit reveals.
            let detentColumns = layout?.columnCount(forLevel: finalLevel, width: W) ?? ContinuousGridLayoutEngine.columnCount(apparentCellSize: session.apparentSize, viewportWidth: W, gap: 4)
            // EXACT committed gap (not v2Gap's nearest-match) so the settle lands on the literal geometry the
            // commit reveals — independent of whether two levels collapse to the same column count.
            let detentGap = JustifiedCollectionLayout.levels[min(max(finalLevel, 0), JustifiedCollectionLayout.levels.count - 1)].gap
            let detentApparent = ContinuousGridLayoutEngine.naturalCellSize(columns: detentColumns, viewportWidth: W, gap: detentGap, insets: 0)
            let remaining = abs(session.apparentSize - detentApparent) / max(session.sourceZoomSize, 1)
            let duration = max(0.12, min(0.32, AnimationTuning.shared.pinchSettle * max(remaining, 0.35)))
            // FORCE-RESOLVE the topology to the detent: clear any in-flight rebase and PIN the live topology to
            // the committed column count + gap + crop, and bump the rebase-tick generation so a self-clock tick
            // can't re-render a stale rebase during the settle. From here the settle is an `apparent` ramp ONLY;
            // every settle frame renders ONE layout at `detentColumns`, so the final overlay frame is identical
            // to the committed grid (no reveal pop, even if the finger lifted mid-dissolve).
            let detentCrop = JustifiedCollectionLayout.levels[min(max(finalLevel, 0), JustifiedCollectionLayout.levels.count - 1)].cropMode == .squareFill
            activeRebase = nil
            rebaseTickGeneration += 1
            forcedColumns = detentColumns
            liveTopology = ContinuousDaySectionedGridLayoutEngine.Topology(columns: detentColumns, gap: detentGap, cropSquare: detentCrop)
            logGridZoom("settle mode=continuous finalLevel=\(finalLevel) fromApparent=\(fmt(session.apparentSize)) toApparent=\(fmt(detentApparent)) detentColumns=\(detentColumns) durMs=\(fmt(duration * 1000)) topologyPinned=true")
            runContinuousSettle(session: session, toApparent: detentApparent, commitPlan: plan, canvas: canvas, generation: settleGeneration, fromApparent: session.apparentSize, duration: duration)
        }

        /// Ease `apparent` from its release value to the detent's natural cell size over `duration` (per-frame
        /// rebuild on the main run loop), re-rendering the SAME continuous grid each frame, then commit +
        /// reveal. Abandoned if a new pinch bumps the generation. This is the live path, animated.
        @MainActor private func runContinuousSettle(session: PinchSession, toApparent: CGFloat, commitPlan: ZoomCommitPlan, canvas: GridSpriteTransitionView, generation: Int, fromApparent: CGFloat, duration: TimeInterval) {
            let start = CACurrentMediaTime()
            let dur = max(0.10, duration)
            func step() {
                guard generation == coverageTopUpGeneration, pinchSession != nil, isGridZoomSettling else { return }
                let raw = CGFloat(min(1, (CACurrentMediaTime() - start) / dur))
                let e = raw * raw * (3 - 2 * raw)   // smoothstep
                let apparent = fromApparent + (toApparent - fromApparent) * e
                updateContinuousGrid(session: session, apparent: apparent)
                if raw >= 1 {
                    completeGridZoom(plan: commitPlan, anchor: session.anchor, canvas: canvas)
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) { MainActor.assumeIsolated { step() } }
                }
            }
            step()
        }

        @MainActor private func finishGridZoom() {
            PhotoDiagnostics.shared.setActivePinch(false)
            Task { await parent.feed.setUserInteractionActive(false) }
            transitionCanvas?.removeFromSuperview()
            transitionCanvas = nil
            transitionAtlasPrepared = false
            transitionProgress = 0
            if deferredApply != nil {
                collectionView?.alphaValue = 0
            }
            resetBackdropFrozenState()
            pinchSession = nil
            isPinching = false
            isGridZoomSettling = false
            // V2: clear the topology state machine so the next pinch starts clean.
            liveTopology = nil
            activeRebase = nil
            forcedColumns = nil
            rebaseTickGeneration += 1
            applyDeferredIfNeeded()
            collectionView?.layoutSubtreeIfNeeded()
            collectionView?.alphaValue = 1
        }

        /// Commit + reveal. The real grid stays hidden until it is committed to EXACTLY the plan's
        /// (= the target preview's) level+origin, so the reveal lands under an already-identical overlay.
        @MainActor private func completeGridZoom(plan: ZoomCommitPlan, anchor: ZoomAnchor, canvas: GridSpriteTransitionView?) {
            let hadDeferred = deferredApply != nil
            let sourceLevel = pinchSession?.sourceLevel ?? plan.level
            // COMMIT-MATCH (blocker #4): the last overlay frame's topology MUST equal the grid we are about to
            // commit — same column count, no rebase in flight — or the reveal pops. The settle pins the topology
            // to the detent, so this should always hold; surfaced loudly if it ever drifts.
            let W = collectionView?.bounds.width ?? 0
            let committedColumns = layout?.columnCount(forLevel: plan.level, width: W) ?? lastRenderedColumns
            if activeRebase != nil || (lastRenderedColumns != committedColumns && W > 1) {
                logGridZoom("INVARIANT FAIL: reveal columns mismatch overlay=\(lastRenderedColumns) commit=\(committedColumns) activeRebase=\(activeRebase != nil)")
                assertionFailure("commit-match: overlay topology != committed topology at reveal")
            }
            forcedColumns = nil                  // settle done — the topology pin is released
            activeRebase = nil
            commitRealGrid(level: plan.level, origin: plan.origin)
            applyDeferredHidden(origin: plan.origin, level: plan.level)
            collectionView?.layoutSubtreeIfNeeded()
            let committed = scrollView?.contentView.bounds.origin ?? .zero
            let originMatch = abs(committed.x - plan.origin.x) < 0.5 && abs(committed.y - plan.origin.y) < 0.5
            let cvAlphaBeforeReveal = collectionView?.alphaValue ?? -1
            let cfg = JustifiedCollectionLayout.levels[min(max(plan.level, 0), JustifiedCollectionLayout.levels.count - 1)]
            if plan.level != sourceLevel, !targetPreviewBuilt {
                logGridZoom("ERROR revealing without target preview (finalLevel != sourceLevel) — expect snap")
            }
            // The real grid + the preview both use this level's descriptor, so cropMode/gap match by
            // construction — logged so the identity is provable from the trace.
            logGridZoom("commit hiddenApply=\(hadDeferred) level=\(plan.level) origin=(\(fmt(plan.origin.x)),\(fmt(plan.origin.y))) committed=(\(fmt(committed.x)),\(fmt(committed.y))) originMatch=\(originMatch) cropMode=\(cfg.cropMode == .squareFill ? "squareFill" : "aspectFit") gap=\(fmt(cfg.gap)) usesTargetPlan=\(liveTargetPlan != nil) anchorError=(\(fmt(plan.anchorError.x)),\(fmt(plan.anchorError.y))) cvAlphaBeforeReveal=\(fmt(cvAlphaBeforeReveal))")
            // Reveal identity: the target-surface UIDs shown during the gesture must match the real grid
            // UIDs now visible (same plan level+origin). Logged so identity drift across gestures shows up.
            let targetVisibleUIDs = backdropFrozenUIDSet
            var realVisibleUIDs = Set<PhotoUID>()
            if let cv = collectionView {
                for ip in cv.indexPathsForVisibleItems() where ip.section < sections.count && ip.item < sections[ip.section].items.count {
                    realVisibleUIDs.insert(sections[ip.section].items[ip.item].uid)
                }
            }
            let overlap = targetVisibleUIDs.isEmpty ? 1 : Double(targetVisibleUIDs.intersection(realVisibleUIDs).count) / Double(targetVisibleUIDs.count)
            logGridZoom("revealIdentity targetVisibleUIDs=\(targetVisibleUIDs.count) realVisibleUIDs=\(realVisibleUIDs.count) overlapRatio=\(fmt(CGFloat(overlap)))")
            // Reveal must not change the photo under the cursor: the real cell now under the pointer must
            // be the anchor photo (the committed origin was solved to land the anchor there).
            if let cv = collectionView, let anchorUID = anchor.uid {
                let contentAtPointer = CGPoint(x: committed.x + anchor.viewportPoint.x, y: committed.y + anchor.viewportPoint.y)
                let revealUID = cv.indexPathForItem(at: contentAtPointer).flatMap { ip -> PhotoUID? in
                    (ip.section < sections.count && ip.item < sections[ip.section].items.count) ? sections[ip.section].items[ip.item].uid : nil
                }
                let same = revealUID == anchorUID
                if !same { logGridZoom("INVARIANT FAIL: reveal changed topUIDAtAnchor (anchor=\(key(for: anchorUID)) reveal=\(revealUID.map { key(for: $0) } ?? "none"))") }
                logGridZoom("revealTopUIDAtAnchor anchor=\(key(for: anchorUID)) reveal=\(revealUID.map { key(for: $0) } ?? "none") status=\(same ? "PASS" : "FAIL")")
            }
            updateVisibleCellCropMode()
            collectionView?.alphaValue = 1
            canvas?.removeFromSuperview()
            transitionCanvas?.removeFromSuperview()
            transitionCanvas = nil
            transitionAtlasPrepared = false
            transitionProgress = 0
            targetPreviewBuilt = false
            resetBackdropFrozenState()
            lastOverlayAnchorDiagnostic = ""
            pinchSession = nil
            isPinching = false
            isGridZoomSettling = false
            PhotoDiagnostics.shared.setActivePinch(false)
            Task { await parent.feed.setUserInteractionActive(false) }
        }

        /// Commit the real grid to an EXPLICIT origin (the commit plan's), not an anchor recomputation.
        @MainActor private func commitRealGrid(level: Int, origin requestedOrigin: CGPoint) {
            guard let cv = collectionView, let layout, let clip = scrollView?.contentView else { return }
            cv.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layout.level = level
                parent.level = level
                cv.layoutSubtreeIfNeeded()
                let origin = clampedOrigin(requestedOrigin, contentSize: layout.collectionViewContentSize, viewportSize: clip.bounds.size)
                clip.setBoundsOrigin(origin)
                scrollView?.reflectScrolledClipView(clip)
                cv.layoutSubtreeIfNeeded()
                updateMonthLabels()
                CATransaction.commit()
            }
        }

        @MainActor private func commitRealGrid(level: Int, anchor: ZoomAnchor) {
            guard let cv = collectionView, let layout, let clip = scrollView?.contentView else { return }
            cv.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layout.level = level
                parent.level = level
                cv.layoutSubtreeIfNeeded()
                let origin = anchoredOrigin(for: anchor, level: level, fallback: clip.bounds.origin, projected: false)
                clip.setBoundsOrigin(origin)
                scrollView?.reflectScrolledClipView(clip)
                cv.layoutSubtreeIfNeeded()
                updateMonthLabels()
                CATransaction.commit()
            }
            let error = anchorError(for: anchor)
            logGridZoom("commit level=\(level) \(anchorLog(anchor)) anchorErrorX=\(fmt(error.x)) anchorErrorY=\(fmt(error.y))")
        }

        @MainActor private func abandonSpriteTransition() {
            guard let canvas = transitionCanvas else {
                finishGridZoom()
                return
            }
            transitionAtlasPrepared = false
            canvas.animate(to: 0, duration: 0.08) { [weak self, weak canvas] in
                Task { @MainActor in
                    canvas?.removeFromSuperview()
                    self?.finishGridZoom()
                }
            }
        }

        @MainActor private func clearSpriteTransition(restoringGrid: Bool) {
            transitionCanvas?.removeFromSuperview()
            transitionCanvas = nil
            transitionAtlasPrepared = false
            if restoringGrid { collectionView?.alphaValue = 1 }
        }

        private func viewportFrame(in clip: NSClipView) -> CGRect {
            CGRect(origin: clip.bounds.origin, size: clip.bounds.size)
        }

        @MainActor private func positionTransitionCanvas(_ canvas: GridSpriteTransitionView, in clip: NSClipView) {
            canvas.frame = viewportFrame(in: clip)
        }

        private func anchoredOrigin(
            for anchor: ZoomAnchor,
            level: Int,
            fallback: CGPoint,
            projected: Bool
        ) -> CGPoint {
            guard let cv = collectionView, let layout, let clip = scrollView?.contentView else { return fallback }
            let contentSize = projected
                ? layout.projectedContentSize(level: level, width: cv.bounds.width)
                : layout.collectionViewContentSize
            let cropMode = JustifiedCollectionLayout.levels[min(max(level, 0), JustifiedCollectionLayout.levels.count - 1)].cropMode
            // The asset's cell frame at the requested target level (document space).
            func targetCellFrame(_ indexPath: IndexPath) -> CGRect? {
                projected
                    ? layout.projectedFrameForItem(at: indexPath, level: level, width: cv.bounds.width)
                    : layout.layoutAttributesForItem(at: indexPath)?.frame
            }
            let contentPoint: CGPoint
            switch anchor {
            case .assetImage(let uid, let imageLocal, _, let imageSize, _, let fallbackContentPoint, _):
                // Anchor on the DISPLAYED-IMAGE frame at the target level (letterbox-aware), not the cell —
                // so the same image-local point stays under the cursor across aspectFit↔squareFill changes.
                if let indexPath = indexByUID[uid], let cellFrame = targetCellFrame(indexPath) {
                    let imageFrame = displayedImageFrame(cellFrame: cellFrame, imageSize: imageSize, cropMode: cropMode)
                    contentPoint = CGPoint(x: imageFrame.minX + imageLocal.x * imageFrame.width,
                                           y: imageFrame.minY + imageLocal.y * imageFrame.height)
                } else {
                    contentPoint = fallbackContentPoint
                }
            case .assetCell(let uid, let cellLocal, _, let fallbackContentPoint, _):
                if let indexPath = indexByUID[uid], let cellFrame = targetCellFrame(indexPath) {
                    contentPoint = CGPoint(x: cellFrame.minX + cellLocal.x * cellFrame.width,
                                           y: cellFrame.minY + cellLocal.y * cellFrame.height)
                } else {
                    contentPoint = fallbackContentPoint
                }
            case .content(let rawContentPoint, _):
                contentPoint = rawContentPoint
            }
            return clampedOrigin(
                CGPoint(
                    x: contentPoint.x - anchor.viewportPoint.x,
                    y: contentPoint.y - anchor.viewportPoint.y
                ),
                contentSize: contentSize,
                viewportSize: clip.bounds.size
            )
        }

        private func projectedSnapshots(level: Int, origin: CGPoint, rect: CGRect) -> [PhotoUID: GridCellSnapshot] {
            guard let cv = collectionView, let layout, let clip = scrollView?.contentView else { return [:] }
            targetSnapshotBuildCount += 1
            let viewport = CGRect(origin: .zero, size: clip.bounds.size)
            let viewportCenter = CGPoint(x: viewport.midX, y: viewport.midY)
            var snapshots: [PhotoUID: GridCellSnapshot] = [:]
            for (indexPath, docFrame) in layout.projectedFramesForElements(in: rect, level: level, width: cv.bounds.width) {
                guard indexPath.section < sections.count, indexPath.item < sections[indexPath.section].items.count else { continue }
                let photo = sections[indexPath.section].items[indexPath.item]
                let cellFrame = CGRect(
                    x: docFrame.minX - origin.x,
                    y: docFrame.minY - origin.y,
                    width: docFrame.width,
                    height: docFrame.height
                )
                let nsImage = parent.feed.memoryImage(for: photo.uid)
                let realCGImage = nsImage?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                let cgImage = realCGImage ?? GridThumbnailFallback.placeholderImage
                let imageSize = CGSize(width: cgImage.width, height: cgImage.height)
                let imageFrame = realCGImage == nil ? cellFrame : fittedImageFrame(in: cellFrame, imageSize: imageSize)
                let dx = imageFrame.midX - viewportCenter.x
                let dy = imageFrame.midY - viewportCenter.y
                let offscreenPenalty: CGFloat = viewport.intersects(imageFrame) ? 0 : max(viewport.width, viewport.height) * 4
                let key = key(for: photo.uid)
                snapshots[photo.uid] = GridCellSnapshot(
                    uid: photo.uid,
                    key: key,
                    cellFrame: cellFrame,
                    imageFrame: imageFrame,
                    image: cgImage,
                    imageSize: imageSize,
                    priority: dx * dx + dy * dy + offscreenPenalty,
                    isPlaceholder: realCGImage == nil
                )
            }
            return snapshots
        }

        private func continuitySprites(
            source: [PhotoUID: GridCellSnapshot],
            target: [PhotoUID: GridCellSnapshot],
            viewportSize: CGSize,
            anchor: CGPoint,
            visualScale: CGFloat,
            sourceOnly: Bool
        ) -> [GridTransitionSpriteDescriptor] {
            let viewport = CGRect(origin: .zero, size: viewportSize)
            let expandedViewport = viewport.insetBy(dx: -viewport.width * 0.35, dy: -viewport.height * 0.55)
            var descriptors: [GridTransitionSpriteDescriptor] = []
            descriptors.reserveCapacity(source.count + target.count)
            for uid in Set(source.keys).union(target.keys) {
                let sourceCell = source[uid]
                let targetCell = target[uid]
                guard sourceCell != nil || targetCell != nil else { continue }
                let spriteIdentity = (sourceCell ?? targetCell)?.key ?? key(for: uid)

                let referenceY = sourceCell?.imageFrame.midY ?? targetCell?.imageFrame.midY ?? anchor.y
                let (phaseStart, phaseEnd) = ghostPhase(forY: referenceY, anchorY: anchor.y, viewportHeight: viewport.height)

                if let sourceCell {
                    let sourceFrame = scaledAround(sourceCell.imageFrame, anchor: anchor, scale: visualScale)
                    if sourceFrame.intersects(expandedViewport) {
                        descriptors.append(GridTransitionSpriteDescriptor(
                            key: spriteKey(role: "source", key: spriteIdentity),
                            image: sourceCell.image,
                            imageSize: sourceCell.imageSize,
                            fromFrame: sourceFrame,
                            toFrame: sourceFrame,
                            fromAlpha: 1,
                            toAlpha: sourceOnly ? 1 : (targetCell == nil ? 0 : 0.08),
                            priority: sourceCell.priority,
                            phaseStart: sourceOnly ? 0 : phaseStart,
                            phaseEnd: sourceOnly ? 1 : phaseEnd
                        ))
                    }
                }

                if !sourceOnly, let targetCell {
                    let targetFrame = targetCell.imageFrame
                    if targetFrame.intersects(expandedViewport) {
                        let image = targetCell.image ?? sourceCell?.image ?? GridThumbnailFallback.placeholderImage
                        let imageSize = targetCell.image == nil && sourceCell?.image == nil
                            ? GridThumbnailFallback.placeholderSize
                            : (targetCell.image == nil ? sourceCell?.imageSize ?? targetCell.imageSize : targetCell.imageSize)
                        descriptors.append(GridTransitionSpriteDescriptor(
                            key: targetCell.image == nil && sourceCell?.image == nil ? "__ph__" : spriteKey(role: "target", key: spriteIdentity),
                            image: image,
                            imageSize: imageSize,
                            fromFrame: targetFrame,
                            toFrame: targetFrame,
                            fromAlpha: sourceCell == nil ? 0.04 : 0,
                            toAlpha: 1,
                            priority: (targetCell.priority + 0.1),
                            phaseStart: phaseStart,
                            phaseEnd: phaseEnd
                        ))
                    }
                }
            }
            return descriptors.sorted { $0.priority < $1.priority }
        }

        private func ghostPhase(forY y: CGFloat, anchorY: CGFloat, viewportHeight: CGFloat) -> (start: CGFloat, end: CGFloat) {
            let distance = abs(y - anchorY)
            let normalized = min(1, distance / max(viewportHeight * 0.52, 1))
            let start = 0.16 + (1 - normalized) * 0.52
            return (start, min(1, start + 0.26))
        }

        private func placeholderSprites(viewportSize: CGSize) -> [GridTransitionSpriteDescriptor] {
            let viewport = CGRect(origin: .zero, size: viewportSize)
            return [
                GridTransitionSpriteDescriptor(
                    key: "__ph__",
                    image: GridThumbnailFallback.placeholderImage,
                    imageSize: GridThumbnailFallback.placeholderSize,
                    fromFrame: viewport,
                    toFrame: viewport,
                    fromAlpha: 1,
                    toAlpha: 1,
                    priority: -1
                )
            ]
        }

        private func overlayAnchorDiagnostic(
            session: PinchSession,
            visualScale: CGFloat,
            descriptors: [GridTransitionSpriteDescriptor],
            canvas: GridSpriteTransitionView
        ) -> String {
            // Use coordinate systems consistently: image anchor → image-local on the source IMAGE frame;
            // cell anchor → cell-local on the source CELL frame. Mixing them mis-reports the anchor error.
            let uid: PhotoUID, local: CGPoint, useImage: Bool, viewportPoint: CGPoint
            switch session.anchor {
            case .assetImage(let u, let il, _, _, let vp, _, _): (uid, local, useImage, viewportPoint) = (u, il, true, vp)
            case .assetCell(let u, let cl, let vp, _, _): (uid, local, useImage, viewportPoint) = (u, cl, false, vp)
            case .content: return "overlayAnchor=content"
            }
            guard let snapshot = session.sourceSnapshotsByUID[uid] else {
                return "overlayAnchorUID=\(key(for: uid)) sourceSnapshot=missing"
            }
            let spriteKey = spriteKey(role: "source", key: snapshot.key)
            let baseFrame = useImage ? snapshot.imageFrame : snapshot.cellFrame
            let scaledFrame = scaledAround(baseFrame, anchor: viewportPoint, scale: visualScale)
            let visualPoint = CGPoint(
                x: scaledFrame.minX + local.x * scaledFrame.width,
                y: scaledFrame.minY + local.y * scaledFrame.height
            )
            let error = CGPoint(x: visualPoint.x - viewportPoint.x, y: visualPoint.y - viewportPoint.y)
            let descriptorExists = descriptors.contains { $0.key == spriteKey }
            let atlasExists = canvas.containsAtlasKey(spriteKey)
            return "overlaySourceFrame=\(rectLog(snapshot.imageFrame)) scaled=\(rectLog(scaledFrame)) visualAnchorError=(\(fmt(error.x)),\(fmt(error.y))) anchorDescriptor=\(descriptorExists) anchorAtlas=\(atlasExists)"
        }

        private func scaledAround(_ frame: CGRect, anchor: CGPoint, scale: CGFloat) -> CGRect {
            CGRect(
                x: anchor.x + (frame.minX - anchor.x) * scale,
                y: anchor.y + (frame.minY - anchor.y) * scale,
                width: frame.width * scale,
                height: frame.height * scale
            )
        }

        /// FOCUS-ANCHOR identity diagnostic: the topmost photo node covering the pointer must be the
        /// anchor photo (source occludes target; the protected focus row keeps the anchor source). Logged
        /// each `.changed`; an INVARIANT FAIL is logged if it is ever NOT the anchor photo.
        @MainActor private func focusAnchorStatus(session: PinchSession, visualScale: CGFloat) -> String {
            guard let anchorUID = session.anchor.uid else { return "focusAnchor kind=content status=NA" }
            let vp = session.anchor.viewportPoint
            // Coverage uses the CELL region a photo owns (not just its letterboxed image), so an anchor on
            // a letterbox bar still resolves to its photo rather than a spurious miss.
            let sourceRects = session.sourceSnapshotsByUID.map { (id: $0.key, rect: scaledAround($0.value.cellFrame, anchor: vp, scale: visualScale)) }
            let covering = sourceRects.filter { $0.rect.contains(vp) }
            let topIsAnchor = covering.contains { $0.id == anchorUID }
            let topUID = topIsAnchor ? anchorUID : covering.first?.id
            if !topIsAnchor {
                logGridZoom("INVARIANT FAIL: topUIDAtAnchor changed during active pinch (anchor=\(key(for: anchorUID)) top=\(topUID.map { key(for: $0) } ?? "none"))")
            }
            return "focusAnchor uid=\(key(for: anchorUID)) topUIDAtAnchor=\(topUID.map { key(for: $0) } ?? "none") sourceCovering=\(covering.count) focusRowUIDs=\(session.focusRowUIDs.count) status=\(topIsAnchor ? "PASS" : "FAIL")"
        }

        private func fittedImageFrame(in cellFrame: CGRect, imageSize: CGSize) -> CGRect {
            GridZoomMath.aspectFitRect(in: cellFrame, imageSize: imageSize)
        }

        private func scaled(_ frame: CGRect, by scale: CGFloat) -> CGRect {
            frame.insetBy(dx: frame.width * (1 - scale) / 2, dy: frame.height * (1 - scale) / 2)
        }

        private func key(for uid: PhotoUID) -> String {
            "\(uid.volumeID)~\(uid.nodeID)"
        }

        private func spriteKey(role: String, key: String) -> String {
            "\(role):\(key)"
        }

        private func clampedOrigin(_ origin: CGPoint, contentSize: CGSize, viewportSize: CGSize) -> CGPoint {
            CGPoint(
                x: min(max(origin.x, 0), max(0, contentSize.width - viewportSize.width)),
                y: min(max(origin.y, 0), max(0, contentSize.height - viewportSize.height))
            )
        }

        private func anchorError(for anchor: ZoomAnchor) -> CGPoint {
            guard let layout, let clip = scrollView?.contentView else { return .zero }
            let currentCrop = JustifiedCollectionLayout.levels[min(max(layout.level, 0), JustifiedCollectionLayout.levels.count - 1)].cropMode
            let contentPoint: CGPoint
            switch anchor {
            case .assetImage(let uid, let imageLocal, _, let imageSize, _, let fallbackContentPoint, _):
                if let indexPath = indexByUID[uid], let cellFrame = layout.layoutAttributesForItem(at: indexPath)?.frame {
                    let imageFrame = displayedImageFrame(cellFrame: cellFrame, imageSize: imageSize, cropMode: currentCrop)
                    contentPoint = CGPoint(x: imageFrame.minX + imageLocal.x * imageFrame.width,
                                           y: imageFrame.minY + imageLocal.y * imageFrame.height)
                } else {
                    contentPoint = fallbackContentPoint
                }
            case .assetCell(let uid, let cellLocal, _, let fallbackContentPoint, _):
                if let indexPath = indexByUID[uid], let cellFrame = layout.layoutAttributesForItem(at: indexPath)?.frame {
                    contentPoint = CGPoint(x: cellFrame.minX + cellLocal.x * cellFrame.width,
                                           y: cellFrame.minY + cellLocal.y * cellFrame.height)
                } else {
                    contentPoint = fallbackContentPoint
                }
            case .content(let rawContentPoint, _):
                contentPoint = rawContentPoint
            }
            return CGPoint(
                x: contentPoint.x - clip.bounds.origin.x - anchor.viewportPoint.x,
                y: contentPoint.y - clip.bounds.origin.y - anchor.viewportPoint.y
            )
        }

        @MainActor private func applyDeferredIfNeeded() {
            guard !gridZoomBusy else {
                logGridZoom("blocked applyDeferredIfNeeded while gridZoomBusy")
                return
            }
            guard let deferredApply else { return }
            self.deferredApply = nil
            apply(sections: deferredApply.sections, sectionAspects: deferredApply.sectionAspects)
        }

        @MainActor private func applyDeferredHidden(origin requestedOrigin: CGPoint, level: Int) {
            guard let deferredApply else { return }
            self.deferredApply = nil
            guard let cv = collectionView, let layout, let clip = scrollView?.contentView else {
                apply(sections: deferredApply.sections, sectionAspects: deferredApply.sectionAspects)
                return
            }
            let counts = deferredApply.sections.map(\.items.count)
            let structureChanged = counts != sectionItemCounts
            let aspectsChanged = deferredApply.sectionAspects != lastAspects
            guard structureChanged || aspectsChanged else { return }

            logGridZoom("apply deferred while hidden structure=\(structureChanged) aspects=\(aspectsChanged)")
            cv.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                context.allowsImplicitAnimation = false
                CATransaction.begin()
                CATransaction.setDisableActions(true)

                self.sections = deferredApply.sections
                self.sectionItemCounts = counts
                self.lastAspects = deferredApply.sectionAspects
                layout.sectionAspects = deferredApply.sectionAspects
                layout.level = level
                parent.level = level

                if structureChanged {
                    rebuildIndex()
                    computeMonthMarkers()
                    cv.reloadData()
                } else {
                    layout.invalidateLayout()
                }
                cv.layoutSubtreeIfNeeded()
                let origin = clampedOrigin(requestedOrigin, contentSize: layout.collectionViewContentSize, viewportSize: clip.bounds.size)
                clip.setBoundsOrigin(origin)
                scrollView?.reflectScrolledClipView(clip)
                cv.layoutSubtreeIfNeeded()
                updateMonthLabels()

                CATransaction.commit()
            }
            let committed = scrollView?.contentView.bounds.origin ?? .zero
            logGridZoom("deferred hidden committed=(\(fmt(committed.x)),\(fmt(committed.y)))")
        }

        private func anchorLog(_ anchor: ZoomAnchor) -> String {
            switch anchor {
            case .assetImage(let uid, let imageLocal, let cellLocal, _, let viewport, _, _):
                return "anchor kind=image uid=\(key(for: uid)) imageLocal=(\(fmt(imageLocal.x)),\(fmt(imageLocal.y))) cellLocal=(\(fmt(cellLocal.x)),\(fmt(cellLocal.y))) viewport=(\(Int(viewport.x)),\(Int(viewport.y)))"
            case .assetCell(let uid, let cellLocal, let viewport, _, _):
                return "anchor kind=cell uid=\(key(for: uid)) cellLocal=(\(fmt(cellLocal.x)),\(fmt(cellLocal.y))) viewport=(\(Int(viewport.x)),\(Int(viewport.y)))"
            case .content(let content, let viewport):
                return "anchor kind=content content=(\(Int(content.x)),\(Int(content.y))) viewport=(\(Int(viewport.x)),\(Int(viewport.y)))"
            }
        }

        private func fmt(_ value: CGFloat) -> String {
            String(format: "%.2f", value)
        }

        private func fmt(_ value: Double) -> String {
            String(format: "%.2f", value)
        }

        private func resetGridZoomPerfCounters() {
            gridZoomPerfFrame = 0
            layoutSnapshotBuildCount = 0
            slotBuildCount = 0
            sourceSnapshotBuildCount = 0
            targetSnapshotBuildCount = 0
            framePrepareDurationsMs.removeAll(keepingCapacity: true)
            _ = PhotoDiagnostics.shared.hotPathCounters(reset: true)
            _ = PhotoDiagnostics.shared.thumbHealthCounters(reset: true)
        }

        private func recordGridZoomPrepare(ms: Double) -> (max: Double, p95: Double) {
            framePrepareDurationsMs.append(ms)
            if framePrepareDurationsMs.count > 600 {
                framePrepareDurationsMs.removeFirst(framePrepareDurationsMs.count - 600)
            }
            return (framePrepareDurationsMs.max() ?? 0, percentile(framePrepareDurationsMs, p: 0.95))
        }

        private func percentile(_ values: [Double], p: Double) -> Double {
            guard !values.isEmpty else { return 0 }
            let sorted = values.sorted()
            let index = min(max(Int(Double(sorted.count - 1) * p), 0), sorted.count - 1)
            return sorted[index]
        }

        private func rectLog(_ rect: CGRect) -> String {
            if rect.isNull || rect.isEmpty { return "∅" }
            return "(\(fmt(rect.minX)),\(fmt(rect.minY)),\(fmt(rect.width)),\(fmt(rect.height)))"
        }

        private func logGridZoom(_ message: String) {
            #if DEBUG
            print("[GridZoom] \(message)")
            #endif
        }

        // MARK: - Discrete zoom transition (snapshot → commit target level → full-grid crossfade)

        private var discrete = DiscreteZoomController()

        /// The single funnel for EVERY zoom change — the + / − buttons, the trackpad pinch, and the
        /// external `level` binding all land here. Starts the transition immediately when idle; while a
        /// crossfade is running it queues exactly the latest target, which `finishDiscreteTransition`
        /// runs next. Never starts two transitions at once.
        @MainActor private func requestDiscreteZoom(to newLevel: Int, trigger: GridZoomTrigger, anchorPoint: CGPoint?) {
            guard let layout else { return }
            let from = layout.level
            let target = clampGridLevel(newLevel, count: JustifiedCollectionLayout.levels.count)
            guard discrete.requestTransition(from: from, to: target) else {
                if target != from { logGridZoom("mode=discreteStep busy → queued target=\(target) (transition in flight)") }
                return
            }
            performDiscreteTransition(from: from, to: target, trigger: trigger, anchorPoint: anchorPoint)
        }

        /// Snapshot the current grid, commit the REAL grid to `target` with an anchor-preserving scroll
        /// origin while the snapshot still covers it, then crossfade the old snapshot out over the
        /// already-correct new grid. No per-photo motion, no morph, no scaling — the whole old grid
        /// dissolves into the whole new grid.
        @MainActor private func performDiscreteTransition(from: Int, to target: Int, trigger: GridZoomTrigger, anchorPoint: CGPoint?) {
            guard let cv = collectionView, let clip = scrollView?.contentView else { finishDiscreteTransition(); return }
            logGridZoom("mode=discreteStep sourceLevel=\(from) targetLevel=\(target) trigger=\(trigger.rawValue)")
            logGridZoom("oldLiveZoomPathUsed=false")

            // 1. Freeze the visible grid as a bitmap overlay (the "old grid").
            let viewport = clip.bounds.size
            let visible = cv.visibleRect
            var snapshot: CGImage?
            if let rep = cv.bitmapImageRepForCachingDisplay(in: visible) {
                cv.cacheDisplay(in: visible, to: rep)
                snapshot = rep.cgImage
            }

            // 2. Anchor: keep the photo (or content point) under the cursor / viewport-centre near the
            //    same screen position after the level change. SAME logic for buttons and pinch — only
            //    the input point differs (centre for buttons, the gesture point for pinch).
            let viewportPoint = anchorPoint ?? CGPoint(x: viewport.width / 2, y: viewport.height / 2)
            let contentPoint = CGPoint(x: clip.bounds.origin.x + viewportPoint.x, y: clip.bounds.origin.y + viewportPoint.y)
            let anchor = captureZoomAnchor(contentPoint: contentPoint, viewportPoint: viewportPoint)

            // 3. Apply the target level + anchored origin to the real grid. It is correct and interactive
            //    immediately; the snapshot above hides the change until the crossfade reveals it.
            commitRealGrid(level: target, anchor: anchor)
            updateVisibleCellCropMode()
            cv.alphaValue = 1
            let targetOrigin = clip.bounds.origin
            logGridZoom("anchor uid=\(anchor.uid.map { key(for: $0) } ?? "none") viewportPoint=(\(fmt(viewportPoint.x)),\(fmt(viewportPoint.y))) targetOrigin=(\(fmt(targetOrigin.x)),\(fmt(targetOrigin.y)))")

            // 4. Dissolve the old snapshot away (or finish now if the snapshot capture failed).
            if let snapshot {
                crossfadeGrid(snapshot, viewport: viewport)
            } else {
                finishDiscreteTransition()
            }
        }

        /// Full-grid crossfade: an opacity-only fade of the old-grid snapshot over the already-correct
        /// new grid. No scale, no translation, no per-photo animation — the old grid simply dissolves.
        @MainActor private func crossfadeGrid(_ snapshot: CGImage, viewport: CGSize) {
            guard let scrollView, let clip = scrollView.contentView as NSClipView? else { finishDiscreteTransition(); return }
            let host = FlippedOverlayView(frame: clip.frame)
            host.wantsLayer = true
            scrollView.addSubview(host)
            let overlay = CALayer()
            overlay.contents = snapshot
            overlay.contentsGravity = .resize
            overlay.frame = CGRect(origin: .zero, size: viewport)   // identity placement: no move, no scale
            host.layer?.addSublayer(overlay)
            let duration = DiscreteGridZoomTuning.crossfadeDuration
            logGridZoom("crossfade begin duration=\(fmt(duration))")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1
            fade.toValue = 0
            fade.duration = duration
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            fade.isRemovedOnCompletion = false
            fade.fillMode = .forwards
            CATransaction.begin()
            CATransaction.setCompletionBlock { [weak self, weak host] in
                host?.removeFromSuperview()
                self?.finishDiscreteTransition()
            }
            overlay.add(fade, forKey: "xfade")
            CATransaction.commit()
        }

        /// Crossfade finished (or the transition failed). Clear the overlay, return the machine to idle,
        /// run any queued latest step, and ALWAYS leave the real grid visible + interactive.
        @MainActor private func finishDiscreteTransition() {
            logGridZoom("crossfade end")
            collectionView?.alphaValue = 1
            let next = discrete.finishTransition()
            if let next, let layout, next != layout.level {
                let trigger: GridZoomTrigger = next < layout.level ? .buttonPlus : .buttonMinus
                requestDiscreteZoom(to: next, trigger: trigger, anchorPoint: nil)
            }
        }

        /// External `level`-binding changes (e.g. restored state) route through the same discrete path.
        /// The + / − buttons and pinch call `zoomInStep`/`zoomOutStep` directly, not this.
        @MainActor func setLevel(_ newLevel: Int, anchorCursor: Bool = false, anchorViewportCenter: Bool = false) {
            guard let layout, layout.level != newLevel else { return }
            let trigger: GridZoomTrigger = newLevel < layout.level ? .buttonPlus : .buttonMinus
            requestDiscreteZoom(to: newLevel, trigger: trigger, anchorPoint: nil)
        }
    }
}

/// Writes a dragged photo's ORIGINAL file to wherever it's dropped (Finder/Desktop). Runs off the
/// main actor — AppKit invokes the promise delegate on a background queue. The photo is carried in
/// the provider's `userInfo`; the original is downloaded on demand only when the drop is committed.
final class FilePromiseHandler: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    var media: FullMediaProvider?
    private let queue: OperationQueue = {
        let q = OperationQueue(); q.qualityOfService = .userInitiated; return q
    }()

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        let photo = filePromiseProvider.userInfo as? PhotoItem
        let ext = UTType(fileType)?.preferredFilenameExtension ?? "jpg"
        let base = photo.map { String($0.uid.nodeID.prefix(8)) } ?? "photo"
        return "\(base).\(ext)"
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue { queue }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, writePromiseTo url: URL,
                            completionHandler: @escaping (Error?) -> Void) {
        guard let photo = filePromiseProvider.userInfo as? PhotoItem, let media else {
            completionHandler(CocoaError(.featureUnsupported)); return
        }
        // This runs on a background promise queue, so block it on the async download (capturing only
        // Sendable values in the Task — not the completion handler) and finish on this thread.
        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        Task {
            do { box.url = try await media.downloadOriginal(for: photo.uid) }
            catch { box.error = error }
            sem.signal()
        }
        sem.wait()
        if let src = box.url {
            do {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.copyItem(at: src, to: url)
                completionHandler(nil)
            } catch { completionHandler(error) }
        } else {
            completionHandler(box.error ?? CocoaError(.fileWriteUnknown))
        }
    }
}

private final class ResultBox: @unchecked Sendable {
    var url: URL?
    var error: Error?
}

/// Forwards raw trackpad magnify events to a handler (bypassing `NSMagnificationGestureRecognizer`'s
/// recognition threshold) so the pinch responds to the first, smallest finger movement. `event.phase`
/// drives begin/changed/ended; `event.magnification` is the per-event delta (accumulated by the handler).
final class MagnifyingCollectionView: NSCollectionView {
    var onMagnify: ((NSEvent) -> Void)?
    override func magnify(with event: NSEvent) {
        onMagnify?(event)
        // Intentionally NOT calling super — we own the zoom; the scroll view's own magnification is off.
    }
}

final class FlippedOverlayView: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Small Liquid-Glass pill showing the month + year, overlaid on the grid at the square levels.
final class MonthLabelView: NSView {
    private let blur = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.zPosition = 100          // stay above the photo cells
        blur.material = .hudWindow
        blur.blendingMode = .withinWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 8
        blur.layer?.masksToBounds = true
        blur.translatesAutoresizingMaskIntoConstraints = false
        addSubview(blur)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .white
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: trailingAnchor),
            blur.topAnchor.constraint(equalTo: topAnchor),
            blur.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func setText(_ t: String) { label.stringValue = t }
    var fittingWidth: CGFloat { label.intrinsicContentSize.width + 16 }
}
