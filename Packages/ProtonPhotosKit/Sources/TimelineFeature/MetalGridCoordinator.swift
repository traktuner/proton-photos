import AppKit
import MetalKit
import CoreGraphics
import simd
import PhotosCore

/// Bridges scroll position + geometry + texture cache + renderer for the Metal grid. It is the
/// `MTKView` delegate: every frame it reads the clip view's scroll origin, queries the visible square
/// slots from the canonical `SquareTileGridEngine`, uploads a bounded number of newly-available
/// thumbnails, draws the viewport, and emits diagnostics. Only items intersecting the (overscan-expanded)
/// visible rect are ever touched — never all 20k.
@MainActor
final class MetalGridCoordinator: NSObject, MTKViewDelegate {
    private let renderer: MetalGridRenderer
    private let cache: MetalGridTextureCache
    private var dataSource: MetalGridDataSource
    private let budget: MetalGridBudget

    weak var clipView: NSClipView?
    weak var metalView: MTKView?

    var level: Int = 3 {                       // medium density; clamped to the engine ladder in didSet
        didSet {
            level = engine.clampLevel(level)
            if level != oldValue { onContentSizeChange?(contentSize()) }
        }
    }

    // MARK: - Canonical geometry engine (single source of truth)
    //
    // `SquareTileGridEngine` owns ALL grid geometry: square slot rects, per-level gap/pitch, columns,
    // content size, the visible-slot query, hit testing, and the zoom frame plan (continuous apparent
    // metrics + anchor preservation). The coordinator ONLY converts the engine's `GridFramePlan` into Metal
    // quads — it never invents layout, never computes edge-fill, never scales a second surface. THE
    // canonical production path: input → engine → GridFramePlan → renderer draws exactly that plan.
    private(set) var engine = SquareTileGridEngine(sectionCounts: [])
    /// When true, render the SYNTHETIC square grid: one colored square per visible slot, straight from
    /// `GridSlot.viewportRect`, no textures/aspect. Lets the geometry be validated without thumbnails.
    var debugSyntheticGrid = MetalGridDebugGridFlag.isEnabled

    // MARK: - Live zoom transaction (engine-owned; focus-row stable)
    //
    // A live pinch is a `GridZoomTransaction` captured at gesture start, NOT a per-frame stateless re-resolve
    // (which rewraps the focus row). While a transaction is active, `draw` renders its frame at the current
    // continuous level; the row under the cursor keeps its photos. On release the host commits to a settled
    // detent (cursor re-anchored).
    private var zoomTransaction: GridZoomTransaction?
    private var zoomTransactionLevel: CGFloat = 0
    /// True while a live focus-row zoom is in flight (the host freezes scroll while this holds).
    var isZoomingLive: Bool { zoomTransaction != nil }
    /// The live continuous level position (for the host's snap-on-release).
    var liveZoomLevel: CGFloat { zoomTransactionLevel }

    // The settled grid is always BOTTOM-RIGHT anchored (newest in the corner, the only partial row is the
    // OLDEST at the top-left). A cursor-aligned "column phase" was tried for a seamless live-zoom commit but
    // is incompatible with bottom-right anchoring (it moves the partial row to the bottom-right → black
    // there), so the engine has no phase concept.

    // MARK: - Commit bridge (transaction-final → settled, geometry-only)
    //
    // The live transaction pins the anchor at the CURSOR column; the settled grid is BOTTOM-RIGHT anchored.
    // They share metrics at the committed level but differ in column PHASE, so the anchor's column (and the
    // focus band's identities) shift on release — measured at up to ~9 columns. Committing directly would
    // SNAP. Instead a short (~160 ms) bridge interpolates every visible item's viewport rect from its
    // transaction-final position to its settled position (easeOut), so the phase reflow is a smooth SLIDE:
    // the anchor item stays itself and slides to its settled slot, no crossfade / no photo replacement.
    private var bridgeTransaction: GridZoomTransaction?
    private var bridgeLevel = 0
    private var bridgeScrollY: CGFloat = 0
    /// 0→1, advanced by the host's display-link tick; eased in `drawCommitBridge`.
    var commitBridgeProgress: CGFloat = 0
    /// Measured at release for diagnostics + the `end` log.
    private var bridgeDelta: GridZoomCommitDelta?
    var isCommitBridging: Bool { bridgeTransaction != nil }

    // MARK: - Camera column phase (persistent, cursor-anchor preserving)
    //
    // The persistent COLUMN PHASE the settled grid is rendered with (engine-owned; single continuous run). On
    // a zoom commit it is set so the anchor item lands in the cursor's column — so the photo under the cursor
    // does NOT fly across the grid on release. It PERSISTS across scroll (the next frame keeps it, no snap back
    // to canonical). nil = the default BOTTOM-RIGHT phase (newest in the corner) — used on open / bottom pin /
    // data rebuild. Every settled query below threads `currentPhase()`.
    private var committedPhase: Int?
    func currentPhase() -> Int? { committedPhase }
    /// Reset to the canonical bottom-right phase (newest in the corner). Called on bottom-pin / data rebuild.
    func resetCommittedPhase() { committedPhase = nil; requestRedraw() }

    // The current gesture's anchor identity, for the `[GridZoomAnchor]` trace (pinch = cursor item; +/- = the
    // viewport-centre item). Used to assert the item under the anchor survives the whole zoom.
    private var gestureTrigger: GridZoomTrigger = .pinch
    private var gestureCursorVP: CGPoint = .zero
    private var gestureAnchorIndex: Int?

    // MARK: - Content display mode (aspect/square toggle) — fitting INSIDE the square slot ONLY.
    //
    // The toggle is a TileContentFitter mode switch, NOT a layout switch: it changes only the thumbnail's
    // contentRect/UV and NEVER the slot, columns, gap, pitch, content size, hit testing, anchor, or phase.
    // `preferredNormalLevelContentMode` is the user's choice for NORMAL levels (L0–L3); the EFFECTIVE mode
    // forces squareFillCrop on the dense overview levels (L4–L5, which support only that). The preference is
    // remembered, so returning from an overview to a normal level restores the user's aspect/square choice.
    // INITIAL DEFAULT = aspectFitInsideSquare (explicit app choice; matches the normal levels in the reference
    // clip — NOT a claim about Apple's own default).
    private(set) var preferredNormalLevelContentMode: TileContentDisplayMode = .aspectFitInsideSquare

    /// The mode actually used to fit content at `level`: the preference where the level supports it, else
    /// squareFillCrop (the only mode the overview levels offer).
    func effectiveDisplayMode(for level: Int) -> TileContentDisplayMode {
        engine.effectiveContentMode(preferred: preferredNormalLevelContentMode, level: level)
    }
    var effectiveDisplayMode: TileContentDisplayMode { effectiveDisplayMode(for: level) }

    /// Whether the aspect/square toggle is meaningful at a level (both modes supported → the normal levels L0–L3).
    func aspectToggleAvailable(for level: Int) -> Bool { engine.contentModeToggleAvailable(level: level) }
    var aspectToggleAvailable: Bool { aspectToggleAvailable(for: level) }

    /// Set the NORMAL-level content-mode preference (toolbar/keyboard/tests). Pure content-fit change: it does
    /// NOT mutate level, zoom, scroll, phase, or any grid geometry — only the next frame's thumbnail fit.
    func setPreferredNormalLevelContentMode(_ mode: TileContentDisplayMode) {
        guard mode != preferredNormalLevelContentMode else { return }
        preferredNormalLevelContentMode = mode
        requestRedraw()
    }

    /// Flip the NORMAL-level content-mode preference (aspect ↔ square). Same purity guarantee as above.
    func toggleContentMode() {
        setPreferredNormalLevelContentMode(preferredNormalLevelContentMode == .squareFillCrop ? .aspectFitInsideSquare : .squareFillCrop)
    }

    /// Pushed (throttled) so the SwiftUI HUD can mirror live stats.
    var onHUD: ((MetalGridHUD) -> Void)?
    /// Called when the content size changes (level / width) so the host can resize the document view.
    var onContentSizeChange: ((CGSize) -> Void)?

    // Diagnostics state
    private var lastHUDPushDetent: CFTimeInterval = 0
    private var lastCommitFrameLog: CFTimeInterval = 0

    /// True when some VISIBLE cell still lacks a real texture — the host keeps ticking redraws while this
    /// holds (so placeholders swap to thumbnails without needing a scroll), and goes idle once false.
    private(set) var hasPendingVisibleThumbnails = false

    init?(device: MTLDevice, dataSource: MetalGridDataSource, budget: MetalGridBudget = .default) {
        guard let renderer = MetalGridRenderer(device: device),
              let cache = MetalGridTextureCache(device: device, budget: budget) else { return nil }
        self.renderer = renderer
        self.cache = cache
        self.dataSource = dataSource
        self.budget = budget
        super.init()
        rebuildIndex()
    }

    func setDataSource(_ newSource: MetalGridDataSource) {
        dataSource = newSource
        rebuildIndex()
        onContentSizeChange?(contentSize())
        requestRedraw()
    }

    var totalItems: Int { dataSource.flatUIDs.count }
    var orderedUIDs: [PhotoUID] { dataSource.flatUIDs }

    // MARK: - Production decorations + selection state (lab leaves `decorationsEnabled` false)

    /// When true, selection outlines + favorite/check/video badges are drawn for visible cells.
    var decorationsEnabled = false
    private(set) var selectedUIDs: Set<PhotoUID> = []
    private(set) var favoriteUIDs: Set<PhotoUID> = []
    private(set) var selectionMode = false
    private var indexByUID: [PhotoUID: Int] = [:]

    func setSelection(_ uids: Set<PhotoUID>) { selectedUIDs = uids; requestRedraw() }
    func setFavorites(_ uids: Set<PhotoUID>) { favoriteUIDs = uids; requestRedraw() }
    func setSelectionMode(_ on: Bool) { selectionMode = on; requestRedraw() }
    func requestRedraw() { metalView?.needsDisplay = true }

    private func rebuildIndex() {
        var map: [PhotoUID: Int] = [:]
        map.reserveCapacity(dataSource.flatUIDs.count)
        for (i, uid) in dataSource.flatUIDs.enumerated() { map[uid] = i }
        indexByUID = map
        // Rebuild the canonical engine from the new section structure (single source of truth).
        engine = SquareTileGridEngine(sectionCounts: dataSource.sectionCounts)
        committedPhase = nil                      // a stale phase could point past the new data → canonical
    }

    func flatIndex(forUID uid: PhotoUID) -> Int? { indexByUID[uid] }
    func uid(atFlatIndex index: Int) -> PhotoUID? {
        let uids = dataSource.flatUIDs
        return (index >= 0 && index < uids.count) ? uids[index] : nil
    }

    /// The photo cell + its flat index under a CONTENT-space point (for click/selection).
    func hitTestCell(contentPoint: CGPoint) -> (flatIndex: Int, uid: PhotoUID)? {
        let width = metalView?.bounds.width ?? clipView?.bounds.width ?? 0
        guard width > 1, let slot = engine.hitTest(contentPoint: contentPoint, level: level, width: width, columnPhase: currentPhase()),
              let uid = uid(atFlatIndex: slot.index) else { return nil }
        return (slot.index, uid)
    }

    var levelCount: Int { engine.levelCount }
    func clampLevel(_ l: Int) -> Int { engine.clampLevel(l) }

    /// Scroll Y that keeps the item under `cursorContentPoint` at the same viewport position after changing
    /// to `newLevel` (zoom toward the cursor — the Apple rule). The engine owns the capture + rebase; this
    /// just supplies the live view width + scroll origin. nil if no item resolvable.
    func cursorAnchoredScrollOffsetY(toLevel newLevel: Int, cursorContentPoint: CGPoint) -> CGFloat? {
        let width = metalView?.bounds.width ?? clipView?.bounds.width ?? 1
        let originY = clipView?.bounds.origin.y ?? 0
        return engine.cursorAnchoredScrollOffsetY(levelChangeFrom: level, to: newLevel, width: width,
                                                  cursorContentPoint: cursorContentPoint, sourceScrollOriginY: originY)
    }

    // MARK: - Live focus-row zoom transaction (driven by the host's trackpad pinch)

    /// Begin a live zoom anchored at the item under (or nearest to) the cursor. `viewportPoint` is where to
    /// hold it (the cursor in viewport coords). The engine captures the transaction; the row under the cursor
    /// is then preserved as the level position changes.
    func beginLiveZoom(cursorContentPoint: CGPoint, viewportPoint: CGPoint) {
        let width = metalView?.bounds.width ?? clipView?.bounds.width ?? 1
        // The item the user SEES under the cursor (displayed = current level + committed phase).
        let hovered = engine.hitTest(contentPoint: cursorContentPoint, level: level, width: width, columnPhase: currentPhase())?.index
        zoomTransaction = engine.beginZoomTransaction(cursorContentPoint: cursorContentPoint,
                                                      viewportPoint: viewportPoint, level: level, width: width,
                                                      columnPhase: currentPhase())   // resolve in the DISPLAYED (phased) grid
        zoomTransactionLevel = CGFloat(level)
        gestureTrigger = .pinch
        gestureCursorVP = viewportPoint
        gestureAnchorIndex = zoomTransaction?.anchorGlobalIndex
        GridZoomAnchorLog.begin(trigger: .pinch, cursorViewportPoint: viewportPoint, cursorContentPoint: cursorContentPoint,
                                hoveredIndexAtBegin: hovered, transactionAnchorIndex: gestureAnchorIndex, level: level)
        if let tx = zoomTransaction {
            GridZoomCommitLog.begin(sourceLevel: level, anchorGlobalIndex: tx.anchorGlobalIndex,
                                    anchorViewportPoint: tx.anchorViewportPoint,
                                    focusRow: tx.frame(continuousLevel: CGFloat(level), viewportSize: viewportSize, overscan: 0).focusRow)
        }
        requestRedraw()
    }

    /// The item under a viewport point in the CURRENT settled grid (current level + committed phase + scroll) —
    /// THE acceptance probe: it must equal the gesture anchor before and after commit.
    func indexUnderCursorViewport(_ vp: CGPoint) -> Int? {
        let width = metalView?.bounds.width ?? clipView?.bounds.width ?? 0
        guard width > 1 else { return nil }
        let scrollY = clipView?.bounds.origin.y ?? 0
        return engine.hitTest(contentPoint: CGPoint(x: vp.x, y: vp.y + scrollY), level: level, width: width, columnPhase: currentPhase())?.index
    }

    /// Update the live continuous level position (fractional = mid-pinch).
    func updateLiveZoom(continuousLevel x: CGFloat) {
        guard zoomTransaction != nil else { return }
        zoomTransactionLevel = min(max(x, 0), CGFloat(engine.levelCount - 1))
        requestRedraw()
    }

    /// Begin the commit BRIDGE: capture the live transaction as the bridge's source, rebase the scroll offset
    /// from the anchor (clamped to content), commit the settled `finalLevel`, and clear the live transaction.
    /// Returns the (clamped) scroll Y the host should scroll to; the bridge then slides transaction→settled.
    /// nil only if no live transaction. Logs the `[GridZoomCommit] release` seam measurement.
    func beginCommitBridge(finalLevel: Int) -> CGFloat? {
        guard let tx = zoomTransaction else { return nil }
        let width = metalView?.bounds.width ?? clipView?.bounds.width ?? 1
        let lv = engine.clampLevel(finalLevel)
        // PHASE: land the anchor item in the CURSOR's column at the target level, so the photo under the cursor
        // does not fly across the grid on release. This phase is committed NOW — every settled query (incl. the
        // first post-commit frame + all scroll frames) uses it immediately; it never snaps back to canonical.
        let metrics = engine.resolvedMetrics(level: lv, width: width)
        let desiredColumn = engine.cursorColumn(viewportX: tx.anchorViewportPoint.x, level: lv, width: width)
        let phase = engine.columnPhase(forItem: tx.anchorGlobalIndex, targetColumn: desiredColumn, level: lv, width: width)
        committedPhase = phase
        let rawY = engine.anchoredScrollOffset(flatIndex: tx.anchorGlobalIndex, localFraction: tx.anchorLocalFraction,
                                               viewportPoint: tx.anchorViewportPoint, level: lv, width: width, columnPhase: phase).y
        let content = engine.contentSize(level: lv, width: width, columnPhase: phase)
        let clipH = clipView?.bounds.height ?? metalView?.bounds.height ?? 0
        let clampedY = min(max(0, rawY), max(0, content.height - clipH))
        let overscan = budget.overscanFraction * viewportSize.height
        let delta = engine.commitDelta(transaction: tx, targetLevel: lv, viewportSize: viewportSize, columnPhase: phase)
        // The MAX horizontal move any matched index would undergo (with the phase, a uniform sub-cell residual).
        let maxMove = GridZoomCommitBridge.maxMatchedIndexMoveX(transaction: tx, engine: engine, targetLevel: lv,
                                                               viewportSize: viewportSize, scrollY: clampedY, overscan: overscan, columnPhase: phase)
        let tolerance = GridZoomCommitBridge.tolerance(targetPitch: metrics.pitch)
        let bridgeIt = maxMove <= tolerance                 // bridge only a tiny sub-cell residual; else commit instantly

        // Diagnostics.
        let selectedIdx = selectedUIDs.count == 1 ? selectedUIDs.first.flatMap { indexByUID[$0] } : nil
        let anchorDeltaColumns = metrics.pitch > 0 ? Int((delta.anchorDelta.width / metrics.pitch).rounded()) : 0
        GridZoomCommitLog.release(anchorGlobalIndex: tx.anchorGlobalIndex, hoveredGlobalIndex: tx.anchorGlobalIndex,
                                  selectedGlobalIndex: selectedIdx, targetLevel: lv, targetColumns: metrics.columns,
                                  desiredCursorColumn: desiredColumn, computedColumnPhase: phase, delta: delta,
                                  anchorDeltaColumns: anchorDeltaColumns)
        GridZoomCommitLog.bridge(maxMatchedIndexMovePx: maxMove,
                                 maxMatchedIndexMoveColumns: metrics.pitch > 0 ? Double(maxMove / metrics.pitch) : 0,
                                 largeMoveRejected: !bridgeIt)
        // The transaction pins the anchor at the cursor, so the item under the cursor before commit IS the anchor.
        GridZoomAnchorLog.release(targetLevel: lv, cursorViewportPoint: tx.anchorViewportPoint,
                                  indexUnderCursorBeforeCommit: tx.anchorGlobalIndex, transactionAnchorIndex: tx.anchorGlobalIndex,
                                  committedPhase: phase, targetScrollY: clampedY, bridgeWillRun: bridgeIt)

        level = lv                       // settled metrics/content for the target (didSet recomputes content size)
        zoomTransaction = nil
        if bridgeIt {
            bridgeTransaction = tx
            bridgeLevel = lv
            bridgeScrollY = clampedY
            bridgeDelta = delta
            commitBridgeProgress = 0
        } else {
            // Residual exceeds tolerance → do NOT animate it (no rect lerp). Commit instantly to the phased plan.
            bridgeTransaction = nil
            GridZoomCommitLog.end(settledUsesCommittedPhase: committedPhase == phase)
        }
        requestRedraw()
        return clampedY
    }

    /// Override the bridge's settled scroll Y (e.g. when the host pins to the bottom instead of the rebased Y).
    func setCommitBridgeScrollY(_ y: CGFloat) { bridgeScrollY = y }

    /// VIEWPORT-RESIZE REBASE (window resize / sidebar toggle — NOT zoom). Same level/phase/mode/columns/gap;
    /// only slotSide/pitch/contentSize recompute from the new width. Returns the rebased scroll Y so the SAME
    /// logical region stays visible; preserves `committedPhase` (never reset). The host applies the result
    /// BEFORE the first frame after resize. Logs `[GridResize]`.
    private var lastResizeDiagTime: Date = .distantPast
    /// VIEWPORT-RESIZE REBASE (window resize / sidebar — NOT zoom). The host passes the grid viewport frame in
    /// SCREEN coords (old + new) so the engine can tell WHICH edge moved; the stationary edge holds the anchor.
    /// Preserves `committedPhase` (passed, never reset). Returns the rebased scroll Y; logs `[GridResize]`.
    func rebaseForViewportChange(oldFrame: CGRect, newFrame: CGRect, oldScrollY: CGFloat,
                                 wasBottomPinned: Bool) -> GridViewportResizeResult? {
        let count = totalItems
        guard count > 0 else { return nil }
        let lvl = level
        let phase = currentPhase()
        let input = GridViewportResizeInput(oldViewportFrame: oldFrame, newViewportFrame: newFrame, oldScrollY: oldScrollY,
                                            level: lvl, committedPhase: phase, itemCount: count,
                                            wasBottomPinned: wasBottomPinned,
                                            anchorFractionY: 0.5)   // normalized viewport-centre camera anchor
        let t0 = Date()
        let r = engine.rebasedScrollOffsetForViewportChange(input)            // cheap: 1 anchorItem + 1 slotRect
        let layoutMs = Date().timeIntervalSince(t0) * 1000
        // Diagnostics THROTTLED to ~3×/s: a live drag fires layout() per frame and `emit` prints synchronously
        // in DEBUG, so emitting (+ the 2× framePlan overlap) every frame is the jank.
        let now = Date()
        if now.timeIntervalSince(lastResizeDiagTime) > 0.33 {
            lastResizeDiagTime = now
            let delta = GridViewportResizeDelta(old: oldFrame, new: newFrame)
            let reason: String = wasBottomPinned ? "bottomPinned"
                : (delta.heightChanged && delta.movedTopEdge && !delta.movedBottomEdge) ? "windowHeightTopEdge"
                : (delta.heightChanged && delta.movedBottomEdge && !delta.movedTopEdge) ? "windowHeightBottomEdge"
                : (delta.widthChanged && !delta.heightChanged) ? "windowWidth"
                : delta.heightChanged ? "windowResizeUnknownEdge" : "unknown"
            let oldVP = CGSize(width: max(oldFrame.width, 1), height: max(oldFrame.height, 0))
            let newVP = CGSize(width: max(newFrame.width, 1), height: max(newFrame.height, 0))
            let mOld = engine.resolvedMetrics(level: lvl, width: oldVP.width)
            let mNew = engine.resolvedMetrics(level: lvl, width: newVP.width)
            let oldContent = engine.contentSize(level: lvl, width: oldVP.width, columnPhase: phase)
            let visBefore = Set(engine.framePlan(level: lvl, viewportSize: oldVP, scrollOffset: CGPoint(x: 0, y: oldScrollY), overscan: 0, columnPhase: phase).visibleSlots.map(\.index))
            let visAfter = Set(engine.framePlan(level: lvl, viewportSize: newVP, scrollOffset: CGPoint(x: 0, y: r.newScrollY), overscan: 0, columnPhase: phase).visibleSlots.map(\.index))
            let anchorVY: CGFloat = newVP.height * r.anchorFractionY   // the normalized anchor's viewport y
            GridResizeLog.begin(reason: reason, oldFrame: oldFrame, newFrame: newFrame, delta: delta, level: lvl, phase: phase,
                                wasBottomPinned: wasBottomPinned, result: r, anchorViewportY: anchorVY,
                                oldScrollY: oldScrollY, oldContentSize: oldContent)
            GridResizeLog.end(result: r, anchorViewportYAfter: anchorVY)
            GridResizeLog.validation(visibleBefore: visBefore.count, visibleAfter: visAfter.count,
                                     visibleOverlap: visBefore.intersection(visAfter).count,
                                     columnsBefore: mOld.columns, columnsAfter: mNew.columns,
                                     slotSideBefore: mOld.slotSide, slotSideAfter: mNew.slotSide, gapBefore: mOld.gap, gapAfter: mNew.gap)
            // Perf signpost: the rebase is O(1)-ish; metrics/contentSize recompute ONLY when width changed.
            MetalGridPerfLog.resizeFrame(layoutMs: layoutMs, visibleSlotCount: visAfter.count, renderQuadCount: visAfter.count,
                                         textureUploadCount: cache.uploadsThisFrame, widthChanged: delta.widthChanged,
                                         heightChanged: delta.heightChanged, metricsRecomputed: delta.widthChanged,
                                         contentSizeRecomputed: delta.widthChanged)
        }
        return r
    }

    /// End the bridge → normal settled rendering at the committed level. Logs `[GridZoomCommit] end`.
    func endCommitBridge() {
        GridZoomCommitLog.end(settledUsesCommittedPhase: committedPhase != nil)
        bridgeTransaction = nil
        bridgeDelta = nil
        logPostCommitAnchor()
        requestRedraw()
    }

    /// `[GridZoomAnchor] postCommit`: probe the item under the gesture cursor in the now-settled grid (current
    /// scroll + committed phase). `anchorStillUnderCursor=false` flags a 24→18 swap. Call AFTER the commit scroll.
    func logPostCommitAnchor() {
        GridZoomAnchorLog.postCommit(cursorViewportPoint: gestureCursorVP,
                                     indexUnderCursorAfterCommit: indexUnderCursorViewport(gestureCursorVP),
                                     transactionAnchorIndex: gestureAnchorIndex ?? -1,
                                     scrollY: clipView?.bounds.origin.y ?? 0, phase: currentPhase())
    }


    /// A discrete +/- (or programmatic) level change that keeps the item under `anchorContentPoint` at the
    /// same viewport point (zoom toward the cursor) AND lands it in the cursor's column (cursor-aligned phase),
    /// so +/- zoom is also fly-free. Returns the scroll Y to apply; nil if no item resolvable.
    func settleScrollOffsetY(toLevel newLevel: Int, anchorContentPoint: CGPoint, viewportPoint: CGPoint,
                             trigger: GridZoomTrigger = .toolbarPlus) -> CGFloat? {
        let width = metalView?.bounds.width ?? clipView?.bounds.width ?? 1
        guard let a = engine.anchorItem(nearContentPoint: anchorContentPoint, level: level, width: width, columnPhase: currentPhase()) else {
            level = engine.clampLevel(newLevel); return nil
        }
        // +/- anchors at the viewport CENTRE (passed by the host); record it for the anchor trace.
        gestureTrigger = trigger
        gestureCursorVP = viewportPoint
        gestureAnchorIndex = a.flatIndex
        GridZoomAnchorLog.begin(trigger: trigger, cursorViewportPoint: viewportPoint, cursorContentPoint: anchorContentPoint,
                                hoveredIndexAtBegin: a.flatIndex, transactionAnchorIndex: a.flatIndex, level: level)
        let lv = engine.clampLevel(newLevel)
        let desiredColumn = engine.cursorColumn(viewportX: viewportPoint.x, level: lv, width: width)
        committedPhase = engine.columnPhase(forItem: a.flatIndex, targetColumn: desiredColumn, level: lv, width: width)
        level = lv
        return engine.anchoredScrollOffset(flatIndex: a.flatIndex, localFraction: a.localFraction,
                                           viewportPoint: viewportPoint, level: lv, width: width, columnPhase: committedPhase).y
    }

    /// A photo's cell rect in CONTENT coordinates at the current level/width (nil if unknown).
    func cellContentRect(forUID uid: PhotoUID) -> CGRect? {
        guard let index = indexByUID[uid] else { return nil }
        return cellContentRect(forFlatIndex: index)
    }

    func cellContentRect(forFlatIndex index: Int) -> CGRect? {
        let width = metalView?.bounds.width ?? clipView?.bounds.width ?? 0
        guard width > 1 else { return nil }
        return engine.slotRect(flatIndex: index, level: level, width: width, columnPhase: currentPhase())
    }

    /// Whether the current level shows month/year labels (the dense overview levels).
    var showsMonthLabels: Bool { engine.metrics(level: level).monthLabels }

    var scrollOriginY: CGFloat { clipView?.bounds.origin.y ?? 0 }
    var viewportSize: CGSize { metalView?.bounds.size ?? clipView?.bounds.size ?? .zero }

    /// Visible cells (flat index + content rect) for the accessibility provider / header positioning.
    func visibleCells() -> [(flatIndex: Int, rect: CGRect)] {
        guard let view = metalView, let clip = clipView, view.bounds.width > 1 else { return [] }
        let plan = engine.framePlan(level: level, viewportSize: view.bounds.size, scrollOffset: clip.bounds.origin, overscan: 0, columnPhase: currentPhase())
        return plan.visibleSlots.map { ($0.index, $0.slotRect) }
    }

    /// The first visible cell + how far its top sits below the viewport top — captured before a level
    /// change so the same photo can be re-pinned afterward (anchor preservation).
    func anchorAtViewportTop() -> (uid: PhotoUID, offset: CGFloat)? {
        guard let clip = clipView, let view = metalView, view.bounds.width > 1 else { return nil }
        let origin = clip.bounds.origin
        let plan = engine.framePlan(level: level, viewportSize: view.bounds.size, scrollOffset: origin, overscan: 0, columnPhase: currentPhase())
        guard let top = plan.visibleSlots.min(by: { $0.slotRect.minY < $1.slotRect.minY }),
              let uid = uid(atFlatIndex: top.index) else { return nil }
        return (uid, top.slotRect.minY - origin.y)
    }

    func contentSize() -> CGSize {
        let width = metalView?.bounds.width ?? clipView?.bounds.width ?? 0
        guard width > 1 else { return .zero }
        return engine.contentSize(level: level, width: width, columnPhase: currentPhase())
    }

    /// Debug hit test: a viewport point → the photo UID under it (or nil for a gap).
    func hitTest(viewportPoint: CGPoint) -> PhotoUID? {
        guard let clip = clipView else { return nil }
        let content = MetalGridGeometry.contentPoint(viewportPoint: viewportPoint, visibleOrigin: clip.bounds.origin)
        return hitTest(contentPoint: content)
    }

    /// Debug hit test from a CONTENT-space point (e.g. a mouse location in the document spacer).
    func hitTest(contentPoint: CGPoint) -> PhotoUID? {
        let width = metalView?.bounds.width ?? clipView?.bounds.width ?? 0
        guard width > 1, let slot = engine.hitTest(contentPoint: contentPoint, level: level, width: width, columnPhase: currentPhase()),
              slot.index < dataSource.flatUIDs.count else { return nil }
        return dataSource.flatUIDs[slot.index]
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        onContentSizeChange?(contentSize())
    }

    func draw(in view: MTKView) {
        guard let clip = clipView else { return }
        let viewportSize = view.bounds.size
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }
        let now = CACurrentMediaTime()
        // Commit bridge (post-release geometry settle) takes precedence over the settled render.
        if isCommitBridging {
            drawCommitBridge(in: view, viewportSize: viewportSize, now: now)
            return
        }
        // THE canonical production path: input → engine → GridFramePlan → renderer draws exactly that plan.
        drawEngineFrame(in: view, clip: clip, viewportSize: viewportSize, now: now)
    }

    /// The geometry-only commit bridge: smooth only the SUB-CELL residual between the transaction-final frame
    /// and the cursor-aligned PHASED settled plan (the multi-column phase mismatch is removed structurally by
    /// `committedPhase`, so nothing flies across columns). At p=0 this equals the live transaction's final
    /// frame; at p=1 it equals the settled (phased) `GridFramePlan`. No crossfade, no photo replacement.
    private func drawCommitBridge(in view: MTKView, viewportSize: CGSize, now: CFTimeInterval) {
        guard let tx = bridgeTransaction else { return }
        let overscan = budget.overscanFraction * viewportSize.height
        let scrollOffset = CGPoint(x: 0, y: bridgeScrollY)
        // ONE source of truth for the bridge geometry (also what the tests assert against): per-globalIndex
        // viewport rects eased from the transaction-final frame to the settled (phased) `GridFramePlan`.
        let slots = GridZoomCommitBridge.frame(transaction: tx, engine: engine, targetLevel: bridgeLevel,
                                               viewportSize: viewportSize, scrollY: bridgeScrollY,
                                               overscan: overscan, progress: commitBridgeProgress, columnPhase: currentPhase())
        let settledContentSize = engine.contentSize(level: bridgeLevel, width: viewportSize.width, columnPhase: currentPhase())

        if debugSyntheticGrid {
            renderSyntheticSlots(in: view, slots: slots, viewportSize: viewportSize)
            hasPendingVisibleThumbnails = false
            publishLightDiagnostics(visibleCount: slots.count, realCount: slots.count, cellCount: slots.count,
                                    visibleRect: CGRect(origin: scrollOffset, size: viewportSize),
                                    contentSize: settledContentSize, now: now)
            return
        }
        let pureViewport = CGRect(origin: .zero, size: viewportSize)
        let flatUIDs = dataSource.flatUIDs
        var visibleUIDs: [PhotoUID] = []
        var overscanUIDs: [PhotoUID] = []
        for s in slots where s.index < flatUIDs.count {
            if s.rect.intersects(pureViewport) { visibleUIDs.append(flatUIDs[s.index]) } else { overscanUIDs.append(flatUIDs[s.index]) }
        }
        streamTextures(visibleUIDs: visibleUIDs, overscanUIDs: overscanUIDs)
        let realCount = renderRealSlots(in: view, slots: slots, flatUIDs: flatUIDs, viewportSize: viewportSize)
        hasPendingVisibleThumbnails = visibleUIDs.contains { !cache.isResident($0) }
        publishLightDiagnostics(visibleCount: visibleUIDs.count, realCount: realCount, cellCount: slots.count,
                                visibleRect: CGRect(origin: scrollOffset, size: viewportSize),
                                contentSize: settledContentSize, now: now)
    }

    // MARK: - Canonical engine render: GridFramePlan → Metal quads (no edge-fill, no second surface)

    /// THE production render. Resolves a `GridFramePlan` from the engine and draws exactly its square
    /// slots. Settled → free scroll origin. Live pinch → the engine computes the anchored scroll offset and
    /// the width-filling apparent grid itself, so left/right always carry real slots (never a black strip).
    private func drawEngineFrame(in view: MTKView, clip: NSClipView, viewportSize: CGSize, now: CFTimeInterval) {
        let overscan = budget.overscanFraction * viewportSize.height
        // Render in VIEWPORT space. Both paths produce `GridRenderSlot` (viewport-space); the engine's
        // content-space `GridSlot.slotRect` is mapped to a viewport rect here, never reused with a live rect.
        let slots: [GridRenderSlot]
        let contentSizeForDiag: CGSize
        if let tx = zoomTransaction {
            // LIVE zoom: an engine-owned transaction with a STABLE focus row. The grid is laid out relative
            // to the anchor under the cursor — NOT a per-frame stateless re-resolve — so the row under the
            // cursor keeps its photos (zoom-in drops edge neighbours, zoom-out adds them), never re-wrapping.
            let frame = tx.frame(continuousLevel: zoomTransactionLevel, viewportSize: viewportSize, overscan: overscan)
            slots = frame.visibleSlots
            contentSizeForDiag = CGSize(width: viewportSize.width, height: frame.pitch * CGFloat(max(1, slots.count / max(frame.columns, 1))))
            if now - lastCommitFrameLog > 0.1 {        // ~10 Hz: trace the live focus row + anchor rect
                lastCommitFrameLog = now
                let anchorRect = frame.visibleSlots.first { $0.index == tx.anchorGlobalIndex }?.rect ?? .zero
                GridZoomCommitLog.frame(progress: zoomTransactionLevel, anchorViewportRect: anchorRect,
                                        focusRow: frame.focusRow, focusRowStable: frame.focusRow.contains(tx.anchorGlobalIndex))
            }
        } else {
            // SETTLED: clamp the camera to the content extent (the window is a camera over the wall; it can't
            // leave the wall — pull it back if a zoom-out shrank the content below the scroll position). The
            // committed column phase keeps the anchor in the cursor's column where the last zoom left it.
            let phase = currentPhase()
            let content = engine.contentSize(level: level, width: viewportSize.width, columnPhase: phase)
            let maxY = max(0, content.height - viewportSize.height)
            let rawOrigin = clip.bounds.origin
            let clampedY = min(max(0, rawOrigin.y), maxY)
            if abs(clampedY - rawOrigin.y) > 0.5 {
                clip.scroll(to: CGPoint(x: rawOrigin.x, y: clampedY))
                clip.enclosingScrollView?.reflectScrolledClipView(clip)
            }
            let plan = engine.framePlan(level: level, viewportSize: viewportSize,
                                        scrollOffset: CGPoint(x: rawOrigin.x, y: clampedY), overscan: overscan, columnPhase: phase)
            slots = plan.visibleSlots.map { GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect) }
            contentSizeForDiag = plan.contentSize
        }

        if debugSyntheticGrid {
            renderSyntheticSlots(in: view, slots: slots, viewportSize: viewportSize)
            hasPendingVisibleThumbnails = false
            publishLightDiagnostics(visibleCount: slots.count, realCount: slots.count, cellCount: slots.count,
                                    visibleRect: CGRect(origin: clip.bounds.origin, size: viewportSize),
                                    contentSize: contentSizeForDiag, now: now)
            return
        }

        let pureViewport = CGRect(origin: .zero, size: viewportSize)
        let flatUIDs = dataSource.flatUIDs
        var visibleUIDs: [PhotoUID] = []
        var overscanUIDs: [PhotoUID] = []
        for s in slots where s.index < flatUIDs.count {
            if s.rect.intersects(pureViewport) { visibleUIDs.append(flatUIDs[s.index]) }
            else { overscanUIDs.append(flatUIDs[s.index]) }
        }
        streamTextures(visibleUIDs: visibleUIDs, overscanUIDs: overscanUIDs)
        let realCount = renderRealSlots(in: view, slots: slots, flatUIDs: flatUIDs, viewportSize: viewportSize)
        hasPendingVisibleThumbnails = visibleUIDs.contains { !cache.isResident($0) }
        publishLightDiagnostics(visibleCount: visibleUIDs.count, realCount: realCount, cellCount: slots.count,
                                visibleRect: CGRect(origin: clip.bounds.origin, size: viewportSize),
                                contentSize: contentSizeForDiag, now: now)
    }

    /// Real thumbnails: a square outer card + the image cover-filled INSIDE the square slot (aspect only via
    /// the UV window — never changes the slot), plus production decorations. Returns the real-texture count.
    @discardableResult
    private func renderRealSlots(in view: MTKView, slots: [GridRenderSlot], flatUIDs: [PhotoUID], viewportSize: CGSize) -> Int {
        let cardRadius = Float(GridVisualConstants.thumbnailCornerRadius)
        let accent = Self.colorVector(.controlAccentColor)
        var backgrounds: [MetalGridQuad] = []
        var images: [MetalGridQuad] = []
        var imageTextures: [MTLTexture] = []
        var outlineQuads: [MetalGridQuad] = []
        var favoriteQuads: [MetalGridQuad] = []
        var checkFilledQuads: [MetalGridQuad] = []
        var checkEmptyQuads: [MetalGridQuad] = []
        var videoQuads: [MetalGridQuad] = []
        backgrounds.reserveCapacity(slots.count)
        var realCount = 0
        let displayMode = effectiveDisplayMode               // aspect/square toggle — same for every slot this frame
        for s in slots where s.index < flatUIDs.count {
            let uid = flatUIDs[s.index]
            let cell = s.rect                               // viewport-space, ALWAYS square (engine guarantee)
            let r = cellRadius(cardRadius, cell: cell)
            if cache.isResident(uid) {
                cache.noteUsed(uid)
                let texture = cache.texture(for: uid)
                // Compose: square slot rect + content fit (TileContentFitter) + texture (cache). The fitter is
                // the ONLY thing that sees media aspect; the slot is square regardless. `displayMode` is the
                // aspect/square toggle (forced to squareFillCrop on the overview levels). NO per-cell card: the
                // rounded thumbnail sits directly on the uniform background, so gaps + aspectFit letterbox show
                // the same surface (no visible grid cells / lines).
                let fit = TileContentFitter.fit(slotRect: cell,
                                                mediaPixelSize: CGSize(width: texture.width, height: texture.height),
                                                displayMode: displayMode)
                images.append(MetalGridQuad(rect: fit.contentRect, uvMin: fit.uvMin, uvMax: fit.uvMax, radius: r))
                imageTextures.append(texture)
                realCount += 1
            } else {
                // Only a genuinely MISSING image gets a placeholder card (a loading tile shouldn't be a hole).
                backgrounds.append(MetalGridQuad(rect: cell, radius: r))
            }
            if decorationsEnabled {
                appendDecorations(uid: uid, cell: cell, displayed: cell, cardRadius: r, accent: accent,
                                  outline: &outlineQuads, favorite: &favoriteQuads,
                                  checkFilled: &checkFilledQuads, checkEmpty: &checkEmptyQuads, video: &videoQuads)
            }
        }
        cache.evictToBudget()
        var groups: [MetalGridRenderGroup] = [
            MetalGridRenderGroup(source: .sharedTexture(cache.placeholderTexture), quads: backgrounds),
            MetalGridRenderGroup(source: .perQuadTexture(imageTextures), quads: images),
        ]
        if !outlineQuads.isEmpty { groups.append(MetalGridRenderGroup(source: .sharedTexture(cache.placeholderTexture), quads: outlineQuads)) }
        if !videoQuads.isEmpty, let t = cache.glyphTexture(symbol: "video.fill", color: .white) { groups.append(MetalGridRenderGroup(source: .sharedTexture(t), quads: videoQuads)) }
        if !favoriteQuads.isEmpty, let t = cache.glyphTexture(symbol: "heart.fill", color: .white) { groups.append(MetalGridRenderGroup(source: .sharedTexture(t), quads: favoriteQuads)) }
        if !checkEmptyQuads.isEmpty, let t = cache.glyphTexture(symbol: "circle", color: .white) { groups.append(MetalGridRenderGroup(source: .sharedTexture(t), quads: checkEmptyQuads)) }
        if !checkFilledQuads.isEmpty, let t = cache.glyphTexture(symbol: "checkmark.circle.fill", color: .controlAccentColor) { groups.append(MetalGridRenderGroup(source: .sharedTexture(t), quads: checkFilledQuads)) }
        renderer.render(in: view, viewportSize: viewportSize, groups: groups)
        return realCount
    }

    /// Synthetic debug grid: one solid colored square per visible slot (geometry only — no textures, no
    /// media aspect). Proves the grid (square slots, consistent gaps, both edges filled) without thumbnails.
    private func renderSyntheticSlots(in view: MTKView, slots: [GridRenderSlot], viewportSize: CGSize) {
        let cardRadius = Float(GridVisualConstants.thumbnailCornerRadius)
        var quads: [MetalGridQuad] = []
        quads.reserveCapacity(slots.count)
        for cmd in SquareGridDebugMode.commands(forSlots: slots) {
            let r = cellRadius(cardRadius, cell: cmd.rect)
            quads.append(MetalGridQuad(rect: cmd.rect, radius: r, color: cmd.color, mode: .solid))
        }
        cache.evictToBudget()
        renderer.render(in: view, viewportSize: viewportSize,
                        groups: [MetalGridRenderGroup(source: .sharedTexture(cache.placeholderTexture), quads: quads)])
    }

    // MARK: - Decorations (selection outline + badges, production only)

    private func appendDecorations(
        uid: PhotoUID, cell: CGRect, displayed: CGRect, cardRadius: Float, accent: SIMD4<Float>,
        outline: inout [MetalGridQuad], favorite: inout [MetalGridQuad],
        checkFilled: inout [MetalGridQuad], checkEmpty: inout [MetalGridQuad], video: inout [MetalGridQuad]
    ) {
        let side = cell.height
        let badge = min(22, max(11, side * 0.3))
        let pad = max(3, side * 0.06)
        // Blue selection outline hugging the displayed image (border mode → no layout impact).
        if selectedUIDs.contains(uid) {
            let radius = min(cardRadius, Float(min(displayed.width, displayed.height) * 0.5))
            outline.append(MetalGridQuad(rect: displayed, radius: radius, color: accent, mode: .border, borderWidth: 3.5))
        }
        // Favorite heart, bottom-left.
        if favoriteUIDs.contains(uid) {
            favorite.append(MetalGridQuad(rect: CGRect(x: cell.minX + pad, y: cell.maxY - badge - pad, width: badge, height: badge), radius: 0))
        }
        let brCorner = CGRect(x: cell.maxX - badge - pad, y: cell.maxY - badge - pad, width: badge, height: badge)
        if selectionMode {
            // Checkmark badge, bottom-right (filled+accent when selected, empty circle otherwise).
            if selectedUIDs.contains(uid) { checkFilled.append(MetalGridQuad(rect: brCorner, radius: 0)) }
            else { checkEmpty.append(MetalGridQuad(rect: brCorner, radius: 0)) }
        } else if dataSource.isVideo(uid) {
            // Video marker, bottom-right (no duration text in this pass — see report).
            video.append(MetalGridQuad(rect: brCorner, radius: 0))
        }
    }

    private static func colorVector(_ color: NSColor) -> SIMD4<Float> {
        let c = color.usingColorSpace(.sRGB) ?? color
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), Float(c.alphaComponent))
    }

}

// MARK: - Canonical render helpers (shared by the engine draw path)

extension MetalGridCoordinator {

    /// Clamp the card corner radius so it never exceeds half the (square) slot — keeps tiny dense cells round.
    private func cellRadius(_ base: Float, cell: CGRect) -> Float {
        min(base, Float(min(cell.width, cell.height) * 0.5))
    }

    // MARK: Texture streaming (visible-first upload + off-main warm)

    private func streamTextures(visibleUIDs: [PhotoUID], overscanUIDs: [PhotoUID]) {
        cache.beginFrame(pinned: Set(visibleUIDs))
        let priority = visibleUIDs + overscanUIDs
        var wanted: [PhotoUID] = []
        for uid in priority where !cache.isResident(uid) && dataSource.hasImage(for: uid) { wanted.append(uid) }
        cache.uploadVisible(wanted: wanted) { [dataSource] uid in dataSource.image(for: uid) }
        var warm: [PhotoUID] = []
        for uid in priority where !cache.isResident(uid) && !cache.isInFlight(uid) && !dataSource.hasImage(for: uid) { warm.append(uid) }
        if !warm.isEmpty { dataSource.warm(warm) }
    }

    private func publishLightDiagnostics(visibleCount: Int, realCount: Int, cellCount: Int, visibleRect: CGRect, contentSize: CGSize, now: CFTimeInterval) {
        guard now - lastHUDPushDetent > 0.1 else { return }
        lastHUDPushDetent = now
        var stats = MetalGridStats()
        stats.visibleItems = visibleCount
        stats.realTextureItems = realCount
        stats.placeholderItems = max(0, cellCount - realCount)
        stats.drawCalls = renderer.lastDrawCalls
        stats.instanceCount = renderer.lastInstanceCount
        var hud = MetalGridHUD()
        hud.stats = stats
        hud.level = level
        hud.totalItems = totalItems
        hud.dataSource = dataSource.label
        onHUD?(hud)
    }

}
