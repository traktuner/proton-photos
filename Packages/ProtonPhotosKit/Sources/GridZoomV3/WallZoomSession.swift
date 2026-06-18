// WallZoomSession.swift  —  GridZoomV3 Lab (Phases 3–6, the per-tick state machine)
//
// PURE value type. NO AppKit. Owns the live gesture state and turns it into a flat list of render nodes
// (each = ONE tile, at ONE layout rect, camera-translated). The AppKit renderer is a thin driver that
// pushes cursor/scale events in and draws the nodes out. Because everything here is a value type with an
// explicit `now`, the anchor / focus-row / rebase invariants are all unit-testable without a window.
//
// Each topology layer (single, or the from/to pair during a rebase) independently pins the ANCHOR TILE
// under the cursor by computing its OWN camera offset from its OWN anchor doc point. So the anchor photo
// (the same UID for the whole gesture) sits under the cursor in every layer — that is the focus anchor.

import CoreGraphics

/// Which topology layer a node belongs to (diagnostic + proves no cross-topology rect blend).
public enum WallRenderLayer: Equatable, Sendable { case single, from, to }

/// One drawn tile. Its rect is its OWN layout's cell rect minus its OWN layer camera — never a blend of
/// two rects (NoRectLerp). `cellScreenRect == imageScreenRect`'s containing cell, used for hit-testing.
public struct WallRenderNode: Equatable, Sendable {
    public let uid: TileUID
    public let index: Int
    public let layer: WallRenderLayer
    public let topologyColumns: Int
    public let cropMode: WallCropMode
    public let cellScreenRect: CGRect
    public let imageScreenRect: CGRect
    public let alpha: CGFloat
    public let z: Int
    public let isAnchor: Bool
    public let isFocusRow: Bool
}

public struct WallRenderFrame: Sendable {
    public let nodes: [WallRenderNode]            // z-sorted ascending: draw in order, last == topmost
    public let plan: WallZoomDirector.Plan
    public let liveTopology: WallZoomDirector.Topology
    public let apparentCellSize: CGFloat
    public let cameraOffset: CGPoint              // the live (to/single) layer camera
    public let anchorScreenPoint: CGPoint         // where the anchor doc point lands (== cursor while pinching)
    public let anchorUID: TileUID?
    public let focusRowUIDs: Set<TileUID>
    public let contentSize: CGSize
    public let isRebasing: Bool

    /// The invariant oracle: the topmost RENDERED node (highest z, alpha above a floor) whose cell contains
    /// the anchor screen point. Must equal `anchorUID` during an active pinch (AnchorTopmostTest). Computed
    /// from the rendered nodes, not from layout math — exactly as the spec demands.
    public func topMostUID(at screenPoint: CGPoint, alphaFloor: CGFloat = 0.5) -> TileUID? {
        var best: WallRenderNode?
        for n in nodes where n.alpha >= alphaFloor && n.cellScreenRect.contains(screenPoint) {
            if best == nil || n.z >= best!.z { best = n }
        }
        return best?.uid
    }
}

/// The anchor: a tile identity plus the unit point inside its displayed image (or cell). Captured ONCE at
/// gesture begin and held for the whole gesture, so the focus photo never changes under the cursor.
public struct WallAnchor: Equatable, Sendable {
    public enum Kind: Sendable { case image, cell, content }
    public var index: Int
    public var localUnit: CGPoint
    public var kind: Kind
    public init(index: Int, localUnit: CGPoint, kind: Kind) {
        self.index = index; self.localUnit = localUnit; self.kind = kind
    }
}

public struct WallZoomSession: Sendable {

    // Immutable wall description
    public let orderedUIDs: [TileUID]
    public let aspectByUID: [TileUID: CGFloat]
    public let detents: [WallZoomDirector.Detent]
    public let minColumns: Int
    public let maxColumns: Int
    public let jitterEpsilon: CGFloat
    public let rebaseDuration: Double

    // Mutable viewport / camera
    public var viewportSize: CGSize
    public var contentInset: CGFloat
    public var topInset: CGFloat

    // Live zoom state
    public private(set) var apparentCellSize: CGFloat
    public private(set) var scrollOffset: CGPoint          // free camera when not pinching (y = scroll)
    public private(set) var anchor: WallAnchor?            // non-nil ⇒ a pinch is active
    public private(set) var cursorViewportPoint: CGPoint
    public private(set) var liveTopology: WallZoomDirector.Topology
    public private(set) var activeRebase: WallZoomDirector.Rebase?
    public private(set) var velocity: CGFloat              // d(apparent)/dt, for settle bias
    private var lastApparent: CGFloat
    private var lastTime: Double

    public init(orderedUIDs: [TileUID],
                aspectByUID: [TileUID: CGFloat] = [:],
                viewportSize: CGSize,
                contentInset: CGFloat = 0,
                topInset: CGFloat = 0,
                detents: [WallZoomDirector.Detent] = WallZoomDirector.defaultDetents,
                minColumns: Int = 1,
                maxColumns: Int = 64,
                jitterEpsilon: CGFloat = 1.5,
                rebaseDuration: Double = 0.22,
                initialDetent: Int = 2) {
        self.orderedUIDs = orderedUIDs
        self.aspectByUID = aspectByUID
        self.viewportSize = viewportSize
        self.contentInset = contentInset
        self.topInset = topInset
        self.detents = detents
        self.minColumns = minColumns
        self.maxColumns = maxColumns
        self.jitterEpsilon = jitterEpsilon
        self.rebaseDuration = rebaseDuration
        let d = detents[min(max(initialDetent, 0), detents.count - 1)]
        let a = WallZoomDirector.detentApparent(d, viewportWidth: viewportSize.width, contentInset: contentInset)
        self.apparentCellSize = a
        self.lastApparent = a
        self.lastTime = 0
        self.scrollOffset = CGPoint(x: 0, y: 0)
        self.cursorViewportPoint = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        self.liveTopology = WallZoomDirector.Topology(columns: d.columns, cropSquare: d.cropSquare)
        self.activeRebase = nil
        self.velocity = 0
    }

    // MARK: - Derived

    public var cropThreshold: CGFloat {
        WallZoomDirector.squareCropThreshold(detents: detents, viewportWidth: viewportSize.width, contentInset: contentInset)
    }
    public var apparentBounds: ClosedRange<CGFloat> {
        WallZoomDirector.apparentBounds(detents: detents, viewportWidth: viewportSize.width, contentInset: contentInset)
    }
    public var isPinching: Bool { anchor != nil }

    private func liveGap(_ a: CGFloat) -> CGFloat { WallZoomDirector.liveGap(apparentCellSize: a) }

    private func config(apparent a: CGFloat, columns: Int?, cropSquare: Bool) -> ContinuousPhotoWallLayoutEngine.Config {
        ContinuousPhotoWallLayoutEngine.Config(
            orderedUIDs: orderedUIDs, aspectByUID: aspectByUID,
            viewportWidth: viewportSize.width, apparentCellSize: a, gap: liveGap(a),
            cropMode: cropSquare ? .squareFill : .aspectFit,
            contentInset: contentInset, topInset: topInset,
            columnsOverride: columns, minColumns: minColumns, maxColumns: maxColumns)
    }

    /// The current resting layout (no pinch) at the live apparent + natural columns.
    public func restingLayout() -> ContinuousPhotoWallLayoutEngine.Layout {
        ContinuousPhotoWallLayoutEngine.layout(config(apparent: apparentCellSize, columns: nil, cropSquare: liveTopology.cropSquare))
    }

    private func anchorDocPoint(in layout: ContinuousPhotoWallLayoutEngine.Layout, anchor: WallAnchor) -> CGPoint {
        let base = anchor.kind == .image ? layout.imageRect(forIndex: anchor.index) : layout.cellRect(forIndex: anchor.index)
        return CGPoint(x: base.minX + anchor.localUnit.x * base.width,
                       y: base.minY + anchor.localUnit.y * base.height)
    }

    // MARK: - Gesture lifecycle

    /// Capture the anchor under the cursor and begin a pinch. The cursor stays fixed for the gesture.
    public mutating func beginPinch(atCursor cursor: CGPoint, now: Double) {
        let layout = restingLayout()
        let docPoint = CGPoint(x: cursor.x + scrollOffset.x, y: cursor.y + scrollOffset.y)
        cursorViewportPoint = cursor
        if let idx = layout.topMostIndex(atDocPoint: docPoint) {
            let imageRect = layout.imageRect(forIndex: idx)
            if imageRect.contains(docPoint) {
                let unit = CGPoint(x: (docPoint.x - imageRect.minX) / max(imageRect.width, 1),
                                   y: (docPoint.y - imageRect.minY) / max(imageRect.height, 1))
                anchor = WallAnchor(index: idx, localUnit: unit, kind: .image)
            } else {
                let cell = layout.cellRect(forIndex: idx)
                let unit = CGPoint(x: (docPoint.x - cell.minX) / max(cell.width, 1),
                                   y: (docPoint.y - cell.minY) / max(cell.height, 1))
                anchor = WallAnchor(index: idx, localUnit: unit, kind: .cell)
            }
        } else {
            // Over a gap/gutter — anchor on the nearest cell's centre, still protect that band.
            let col = min(max(Int(((docPoint.x - layout.leftGutter) / (layout.cellSize + layout.gap)).rounded()), 0), max(layout.columnCount - 1, 0))
            let row = max(Int(((docPoint.y - layout.topInset) / (layout.cellSize + layout.gap)).rounded(.down)), 0)
            let idx = min(row * layout.columnCount + col, orderedUIDs.count - 1)
            anchor = WallAnchor(index: max(idx, 0), localUnit: CGPoint(x: 0.5, y: 0.5), kind: .content)
        }
        lastApparent = apparentCellSize
        lastTime = now
        velocity = 0
    }

    /// Update the live apparent cell size (the ONLY live geometry input — no detent here). `factor` is the
    /// cumulative pinch magnification relative to begin; the caller maps trackpad magnification to it.
    public mutating func setApparent(_ a: CGFloat, now: Double) {
        let clamped = min(max(a, apparentBounds.lowerBound), apparentBounds.upperBound)
        let dt = max(now - lastTime, 1e-4)
        velocity = velocity * 0.6 + ((clamped - lastApparent) / CGFloat(dt)) * 0.4
        lastApparent = clamped
        lastTime = now
        apparentCellSize = clamped
    }

    /// Advance the topology state machine to `now` (drives self-clocked rebase convergence). Returns whether
    /// a rebase is active (so the caller keeps the self-clock ticking even with a paused finger).
    @discardableResult
    public mutating func advance(now: Double) -> Bool {
        let idealColumns = ContinuousPhotoWallLayoutEngine.columnCount(
            apparentCellSize: apparentCellSize, viewportWidth: viewportSize.width,
            gap: liveGap(apparentCellSize), contentInset: contentInset,
            minColumns: minColumns, maxColumns: maxColumns)
        let idealCrop = WallZoomDirector.liveCropSquare(apparentCellSize: apparentCellSize, threshold: cropThreshold)
        let r = WallZoomDirector.planTick(
            apparent: apparentCellSize, viewportWidth: viewportSize.width, contentInset: contentInset,
            live: liveTopology, liveGap: liveGap(apparentCellSize),
            idealColumns: idealColumns, idealCropSquare: idealCrop,
            jitterEpsilon: jitterEpsilon, cropThreshold: cropThreshold,
            active: activeRebase, now: now, duration: rebaseDuration)
        liveTopology = r.live
        activeRebase = r.active
        return r.active != nil
    }

    /// The detent index this gesture would settle to right now.
    public func settleTargetDetent() -> Int {
        WallZoomDirector.snapDetentIndex(apparentCellSize: apparentCellSize, velocity: velocity,
                                         detents: detents, viewportWidth: viewportSize.width, contentInset: contentInset)
    }

    /// End the pinch: bake the anchor-pinned camera into a free scroll offset so subsequent scrolling
    /// continues from exactly where the wall settled (commit origin = the anchor-preserving origin).
    public mutating func endPinch(now: Double) {
        let layout = ContinuousPhotoWallLayoutEngine.layout(
            config(apparent: apparentCellSize, columns: liveTopology.columns, cropSquare: liveTopology.cropSquare))
        if let anchor {
            let docPoint = anchorDocPoint(in: layout, anchor: anchor)
            scrollOffset = ContinuousPhotoWallLayoutEngine.cameraOffset(anchorDocPoint: docPoint, cursorViewportPoint: cursorViewportPoint)
        }
        anchor = nil
        activeRebase = nil
        velocity = 0
    }

    public mutating func setScroll(y: CGFloat) {
        guard !isPinching else { return }
        let layout = restingLayout()
        let maxY = max(0, layout.contentSize.height - viewportSize.height)
        scrollOffset.y = min(max(y, 0), maxY)
    }

    // MARK: - Frame assembly

    private func cameraOffset(for layout: ContinuousPhotoWallLayoutEngine.Layout, anchor: WallAnchor) -> CGPoint {
        ContinuousPhotoWallLayoutEngine.cameraOffset(
            anchorDocPoint: anchorDocPoint(in: layout, anchor: anchor), cursorViewportPoint: cursorViewportPoint)
    }

    private func viewportRect(camera: CGPoint, overscan: CGFloat) -> CGRect {
        CGRect(x: camera.x - overscan, y: camera.y - overscan,
               width: viewportSize.width + 2 * overscan, height: viewportSize.height + 2 * overscan)
    }

    /// Build the render nodes for one topology layer (camera-translated). `alphaFor` maps (index, screenY,
    /// isFocusRow) → alpha; `layerKind`/`isLive` tag the layer.
    private func nodes(layout: ContinuousPhotoWallLayoutEngine.Layout,
                      camera: CGPoint,
                      layer: WallRenderLayer,
                      anchorIndex: Int?,
                      focusRowSet: Set<Int>,
                      anchorScreenY: CGFloat,
                      alphaFor: (_ index: Int, _ screenMidY: CGFloat, _ isFocusRow: Bool, _ isAnchor: Bool) -> CGFloat) -> [WallRenderNode] {
        let overscan = layout.cellSize + layout.gap
        let visible = layout.visibleIndices(in: viewportRect(camera: camera, overscan: overscan))
        var out: [WallRenderNode] = []
        out.reserveCapacity(visible.count)
        for i in visible {
            let cell = layout.cellRect(forIndex: i).offsetBy(dx: -camera.x, dy: -camera.y)
            let image = layout.imageRect(forIndex: i).offsetBy(dx: -camera.x, dy: -camera.y)
            let isFocusRow = focusRowSet.contains(i)
            let isAnchor = (anchorIndex == i)
            let a = alphaFor(i, cell.midY, isFocusRow, isAnchor)
            guard a > 0.003 else { continue }
            out.append(WallRenderNode(
                uid: orderedUIDs[i], index: i, layer: layer,
                topologyColumns: layout.columnCount, cropMode: layout.cropMode,
                cellScreenRect: cell, imageScreenRect: image, alpha: a,
                z: WallZoomDirector.zKey(isAnchor: isAnchor, inFocusBand: isFocusRow),
                isAnchor: isAnchor, isFocusRow: isFocusRow))
        }
        return out
    }

    private func focusRowIndices(layout: ContinuousPhotoWallLayoutEngine.Layout, anchorIndex: Int) -> Set<Int> {
        guard layout.columnCount > 0 else { return [] }
        let row = anchorIndex / layout.columnCount
        let start = row * layout.columnCount
        let end = min(start + layout.columnCount, orderedUIDs.count)
        return Set(start..<end)
    }

    /// Assemble the full frame for `now`. Pure: same state + `now` ⇒ identical frame.
    public func renderFrame(now: Double) -> WallRenderFrame {
        // RESTING (no pinch): one continuous layout, free scroll camera.
        guard let anchor else {
            let layout = restingLayout()
            let nodes = nodes(layout: layout, camera: scrollOffset, layer: .single,
                              anchorIndex: nil, focusRowSet: [], anchorScreenY: 0) { _, _, _, _ in 1 }
                .sorted { $0.z < $1.z }
            return WallRenderFrame(nodes: nodes, plan: .single(liveTopology), liveTopology: liveTopology,
                                   apparentCellSize: apparentCellSize, cameraOffset: scrollOffset,
                                   anchorScreenPoint: cursorViewportPoint, anchorUID: nil, focusRowUIDs: [],
                                   contentSize: layout.contentSize, isRebasing: false)
        }

        let anchorUID = orderedUIDs[anchor.index]
        let plan = WallZoomDirector.planTick(
            apparent: apparentCellSize, viewportWidth: viewportSize.width, contentInset: contentInset,
            live: liveTopology, liveGap: liveGap(apparentCellSize),
            idealColumns: ContinuousPhotoWallLayoutEngine.columnCount(
                apparentCellSize: apparentCellSize, viewportWidth: viewportSize.width,
                gap: liveGap(apparentCellSize), contentInset: contentInset,
                minColumns: minColumns, maxColumns: maxColumns),
            idealCropSquare: WallZoomDirector.liveCropSquare(apparentCellSize: apparentCellSize, threshold: cropThreshold),
            jitterEpsilon: jitterEpsilon, cropThreshold: cropThreshold,
            active: activeRebase, now: now, duration: rebaseDuration).plan

        switch plan {
        case let .single(topo):
            let layout = ContinuousPhotoWallLayoutEngine.layout(
                config(apparent: apparentCellSize, columns: topo.columns, cropSquare: topo.cropSquare))
            let camera = cameraOffset(for: layout, anchor: anchor)
            let focus = focusRowIndices(layout: layout, anchorIndex: anchor.index)
            let nodes = nodes(layout: layout, camera: camera, layer: .single,
                              anchorIndex: anchor.index, focusRowSet: focus, anchorScreenY: cursorViewportPoint.y) { _, _, _, _ in 1 }
                .sorted { $0.z < $1.z }
            return WallRenderFrame(nodes: nodes, plan: plan, liveTopology: topo,
                                   apparentCellSize: apparentCellSize, cameraOffset: camera,
                                   anchorScreenPoint: cursorViewportPoint, anchorUID: anchorUID,
                                   focusRowUIDs: Set(focus.map { orderedUIDs[$0] }),
                                   contentSize: layout.contentSize, isRebasing: false)

        case let .rebasing(rebase, progress):
            // TO layer (the live wall): live apparent, new columns, anchor-pinned, incoming alpha.
            let toLayout = ContinuousPhotoWallLayoutEngine.layout(
                config(apparent: apparentCellSize, columns: rebase.to.columns, cropSquare: rebase.to.cropSquare))
            let toCamera = cameraOffset(for: toLayout, anchor: anchor)
            let toFocus = focusRowIndices(layout: toLayout, anchorIndex: anchor.index)

            // FROM layer (the outgoing wall): FROZEN cell at rebase start, old columns, anchor-pinned, fade out.
            let fromLayout = ContinuousPhotoWallLayoutEngine.layout(
                config(apparent: rebase.fromApparent, columns: rebase.from.columns, cropSquare: rebase.from.cropSquare))
            let fromCamera = cameraOffset(for: fromLayout, anchor: anchor)
            let fromFocus = focusRowIndices(layout: fromLayout, anchorIndex: anchor.index)

            let outA = WallZoomDirector.outgoingAlpha(progress: progress)
            var fromNodes = nodes(layout: fromLayout, camera: fromCamera, layer: .from,
                                  anchorIndex: anchor.index, focusRowSet: fromFocus, anchorScreenY: cursorViewportPoint.y) { _, _, isFocus, isAnchor in
                // The outgoing focus row / anchor stays solid until late (it is the pivot).
                (isFocus || isAnchor) ? 1 : outA
            }
            var toNodes = nodes(layout: toLayout, camera: toCamera, layer: .to,
                                anchorIndex: anchor.index, focusRowSet: toFocus, anchorScreenY: cursorViewportPoint.y) { _, screenMidY, isFocus, _ in
                let inBand = isFocus || WallZoomDirector.inFocusBand(screenY: screenMidY, anchorScreenY: cursorViewportPoint.y, viewportHeight: viewportSize.height)
                return WallZoomDirector.incomingAlpha(progress: progress, inFocusBand: inBand)
            }
            // Painter order: outgoing first (back), incoming next, then focus rows, anchor LAST (topmost).
            // z already encodes focus/anchor; stable-sort by (layer base, z) so the anchor draws on top.
            for k in fromNodes.indices { fromNodes[k] = bump(fromNodes[k], by: 0) }
            for k in toNodes.indices { toNodes[k] = bump(toNodes[k], by: 3) }
            let merged = (fromNodes + toNodes).sorted { $0.z < $1.z }
            return WallRenderFrame(nodes: merged, plan: plan, liveTopology: rebase.to,
                                   apparentCellSize: apparentCellSize, cameraOffset: toCamera,
                                   anchorScreenPoint: cursorViewportPoint, anchorUID: anchorUID,
                                   focusRowUIDs: Set(toFocus.map { orderedUIDs[$0] }).union(fromFocus.map { orderedUIDs[$0] }),
                                   contentSize: toLayout.contentSize, isRebasing: true)
        }
    }

    /// Lift a node's z into a higher layer band while preserving focus/anchor ordering within it.
    private func bump(_ n: WallRenderNode, by base: Int) -> WallRenderNode {
        WallRenderNode(uid: n.uid, index: n.index, layer: n.layer, topologyColumns: n.topologyColumns,
                       cropMode: n.cropMode, cellScreenRect: n.cellScreenRect, imageScreenRect: n.imageScreenRect,
                       alpha: n.alpha, z: base + n.z, isAnchor: n.isAnchor, isFocusRow: n.isFocusRow)
    }

    // MARK: - Settle (Phase 6): drive apparent to the detent along the SAME layout path.

    /// One eased step of `apparentCellSize` toward `targetApparent`. The frame is then assembled by the
    /// exact same `renderFrame` path — no separate release preview wall.
    public mutating func stepSettle(toward targetApparent: CGFloat, fraction: CGFloat, now: Double) {
        let next = apparentCellSize + (targetApparent - apparentCellSize) * min(max(fraction, 0), 1)
        setApparent(next, now: now)
    }

    public func detentApparent(_ index: Int) -> CGFloat {
        let d = detents[min(max(index, 0), detents.count - 1)]
        return WallZoomDirector.detentApparent(d, viewportWidth: viewportSize.width, contentInset: contentInset)
    }
}
