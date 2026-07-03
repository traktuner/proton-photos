import AppKit
import MetalKit
import CoreGraphics
import MetalGridComposeCore
import MetalRenderingCore
import MetalGridTextureCore
import MetalGridTextureAppKitAdapter
import simd
import PhotosCore
import GridCore

/// Bridges scroll position + geometry + texture cache + renderer for the Metal grid. It is the
/// `MTKView` delegate: every frame it reads the clip view's scroll origin, queries the visible square
/// slots from the canonical `SquareTileGridEngine`, uploads a bounded number of newly-available
/// thumbnails, draws the viewport, and emits diagnostics. Only items intersecting the (overscan-expanded)
/// visible rect are ever touched - never the whole library.
@MainActor
final class MetalGridCoordinator: NSObject, MTKViewDelegate {
    private let renderer: MetalGridRenderer
    private let cache: MetalGridTextureCache<PhotoUID>
    private var dataSource: MetalGridDataSource
    private let budget: MetalGridBudget
    private(set) var gridProfile: GridLevelProfile

    /// Fired ONCE, the first time every visible cell is GPU-resident (the first fully-drawn frame). The shell
    /// holds the launch veil until this so it never lifts onto blank thumbnails. See `streamTextures`.
    var onFirstContentReady: (() -> Void)?
    private var firstContentReported = false
    /// One-shot cold-start `[FirstContent]` trace state: the wall-clock of the first on-screen frame with real
    /// visible cells, used to report how long the grid stayed on placeholders before it became resident.
    private var firstContentTraced = false
    private var firstGridFrameAt: CFTimeInterval = 0

    weak var clipView: NSClipView?
    weak var metalView: MTKView?

    var level: Int {                           // clamped to the injected engine ladder in didSet
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
    // quads - it never invents layout, never computes edge-fill, never scales a second surface. THE
    // canonical production path: input → engine → GridFramePlan → renderer draws exactly that plan.
    private(set) var engine: SquareTileGridEngine

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

    // MARK: - Single Presentation Lattice Transition
    //
    // The transition layer is a SEPARATE module that consumes the engine's GridFramePlan; it never
    // touches engine geometry, the fitter, or resize. This is the production effect path (no
    // feature flag): it is attempted for every eligible normal-level +/- and pinch, falling back to the
    // stable instant snap / transaction reflow ONLY when the geometry is ineligible (invalid case), never as a
    // switch. The clean instant settle remains the fallback for those invalid cases.
    let gridTransition = GridTransitionController(telemetrySink: { event in
        PhotoDiagnostics.shared.emit(event.name, event.fields)
    })
    private var transitionPrevNow: CFTimeInterval = 0
    private var selectedFlatIndices: Set<Int> { Set(selectedUIDs.compactMap { indexByUID[$0] }) }

    // Live pinch (continuous multi-level): each adjacent segment is a `.pinch` single-lattice plan driven
    // by the host's scrub driver (`setPinchProgress`). Nothing is committed until release; segments rebuild
    // seamlessly as the finger crosses detents (a shared detent's frame is deterministic, so prev-q=1 == next-q=0).
    //
    // Per-detent frames: the gesture-START detent uses the ACTUAL on-screen state (so q at the start matches the
    // live screen and a return lands exactly back); every OTHER detent uses the cursor-aligned phase + anchored
    // scroll (so the photo under the cursor stays pinned through the whole chain). Captured at gesture start:
    private var pinchStartLevel: Int = 0
    private var pinchStartPhase: Int?
    private var pinchStartScrollY: CGFloat = 0
    /// The segment currently built into `gridTransition` (source = denser end, target = larger-tile end).
    private(set) var pinchSegmentSource: Int?
    private(set) var pinchSegmentTarget: Int?

    // Overview layer dissolve: two complete settled grids blended by opacity via
    // the offscreen compositor. Active during L3↔L4 / L4↔L5 gestures and discrete +/- clicks. Separate from
    // `gridTransition` - it NEVER uses the relocation lattice. nil ⇒ inactive.
    private(set) var overviewDissolve: OverviewLayerDissolvePlan?
    var isOverviewDissolving: Bool { overviewDissolve != nil }
    var isOverviewClickDissolving: Bool { overviewClickDissolveActive }
    private var overviewClickDissolveActive = false
    private var overviewClickDissolveStart: CFTimeInterval = 0
    private let overviewClickDissolveDuration: CFTimeInterval = 0.18

    // The settled grid is always BOTTOM-RIGHT anchored (newest in the corner, the only partial row is the
    // OLDEST at the top-left). A cursor-aligned "column phase" was tried for a seamless live-zoom commit but
    // is incompatible with bottom-right anchoring (it moves the partial row to the bottom-right → black
    // there), so the engine has no phase concept.

    // MARK: - Commit bridge (transaction-final → settled, geometry-only)
    //
    // The live transaction pins the anchor at the CURSOR column; the settled grid is BOTTOM-RIGHT anchored.
    // They share metrics at the committed level but differ in column PHASE, so the anchor's column (and the
    // focus band's identities) shift on release - measured at up to ~9 columns. Committing directly would
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

    // MARK: - Scroll rebase bridge (edge/corner clamp → animated, never an instant snap)
    //
    // When a commit (or a content-shrinking zoom-out) leaves the camera at an out-of-bounds scroll, the
    // SETTLED grid must move from the gesture/anchored scroll to the legal clamped scroll. Rather than snap
    // (`scroll(to:)`), the settled render draws the grid at a short ease-out interpolation of the scroll Y
    // (`GridScrollRebase`), ending exactly at the legal value. Uniform translation ⇒ identity-stable. The
    // engine stays the source of truth; this only eases the camera Y between two engine-derived scrolls.
    private var rebaseActive = false
    private var rebaseFromY: CGFloat = 0
    private var rebaseToY: CGFloat = 0
    private var rebaseStart: CFTimeInterval = 0
    var isScrollRebasing: Bool { rebaseActive }

    /// Arm a scroll-rebase: the settled grid slides from `fromY` (gesture/anchored) to `toY` (legal clamped).
    /// No-op (returns false) when the delta is imperceptible - the caller then settles instantly.
    @discardableResult
    func beginScrollRebase(fromY: CGFloat, toY: CGFloat) -> Bool {
        guard GridScrollRebase.shouldArm(fromY: fromY, toY: toY) else { rebaseActive = false; return false }
        rebaseFromY = fromY; rebaseToY = toY; rebaseStart = CACurrentMediaTime(); rebaseActive = true
        requestRedraw()
        return true
    }

    // MARK: - Camera column phase (persistent, cursor-anchor preserving)
    //
    // The persistent COLUMN PHASE the settled grid is rendered with (engine-owned; single continuous run). On
    // a zoom commit it is set so the anchor item lands in the cursor's column - so the photo under the cursor
    // does NOT fly across the grid on release. It PERSISTS across scroll (the next frame keeps it, no snap back
    // to canonical). nil = the default BOTTOM-RIGHT phase (newest in the corner) - used on open / bottom pin /
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

    // MARK: - Content display mode (aspect/square toggle) - fitting INSIDE the square slot ONLY.
    //
    // The toggle is a TileContentFitter mode switch, NOT a layout switch: it changes only the thumbnail's
    // contentRect/UV and NEVER the slot, columns, gap, pitch, content size, hit testing, anchor, or phase.
    // `preferredNormalLevelContentMode` is the user's choice for NORMAL levels (L0–L3); the EFFECTIVE mode
    // forces squareFillCrop on the dense overview levels (L4–L5, which support only that). The preference is
    // remembered, so returning from an overview to a normal level restores the user's aspect/square choice.
    // INITIAL DEFAULT = aspectFitInsideSquare (explicit app choice; matches the normal levels in the reference
    // clip - NOT a claim about Apple's own default).
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
    /// NOT mutate level, zoom, scroll, phase, or any grid geometry - only the next frame's thumbnail fit.
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
    private var lastPerfDiagnosticsLog: CFTimeInterval = 0
    private var lastCommitFrameLog: CFTimeInterval = 0

    /// True when some VISIBLE cell still lacks a real texture - the host keeps ticking redraws while this
    /// holds (so placeholders swap to thumbnails without needing a scroll), and goes idle once false.
    /// Forced false while the resident texture budget is saturated: those placeholders cannot fill until
    /// the window changes, and scroll/zoom/image-arrival all trigger their own redraws, so ticking would
    /// only busy-spin the display link.
    private(set) var hasPendingVisibleThumbnails = false

    // MARK: - Level-aware upload sizing
    //
    // Thumbnails upload at the on-screen slot's native pixel size (slot points × display backing scale),
    // not a fixed 320 px, so the dense overview levels - where a tile is physically ~39–94 px - stop wasting
    // 11–33× the texels they can display. Sparse levels saturate at the adapter's `maxTexturePixels`, so their
    // quality is unchanged. The pure sizing math lives in `GridCore.GridTextureUploadSizing`; here we only
    // supply the current level's slot side + the live backing scale.

    /// Live display backing scale (drawable px per point), refreshed from the MTKView each frame: 2 on a Retina
    /// display, 1 on a non-Retina external monitor. 2 is a safe default until the first `draw(in:)`.
    private var backingScale: CGFloat = 2
    /// Supersampling headroom over a slot's native pixel size when choosing upload resolution. > 1 spends a
    /// little VRAM to cut minification shimmer on the mip-less grid textures; at sparse levels the result
    /// saturates at `maxTexturePixels` anyway, so those keep full quality.
    private static let uploadPixelsHeadroom: CGFloat = 1.25
    /// Never upload a thumbnail below this, even for a physically tiny dense-overview slot - a crispness floor.
    private static let uploadPixelsFloor = 96

    /// The effective upload cap for the CURRENT settled level: native slot pixels clamped to the adapter cap.
    private func effectiveUploadPixels() -> Int {
        let (_, slotSide, _, _) = engine.resolvedMetrics(level: level, width: layoutWidth)
        return GridTextureUploadSizing.uploadPixels(
            slotSidePoints: slotSide,
            backingScale: backingScale,
            headroom: Self.uploadPixelsHeadroom,
            floor: Self.uploadPixelsFloor,
            cap: cache.maxTexturePixels
        )
    }

    /// Wires the composer's upload/upgrade work into this host's `Grid` signpost category so the
    /// `streamTextures.upload` / `streamTextures.upgrade` Instruments intervals survive the extraction. The iOS
    /// host omits this (the no-op default) - it has no signpost instrumentation yet.
    private var composeSignposts: MetalGridComposeSignposts {
        MetalGridComposeSignposts(
            uploadInterval: { PhotoPerformanceSignposts.grid.interval("streamTextures.upload", $0) },
            upgradeInterval: { PhotoPerformanceSignposts.grid.interval("streamTextures.upgrade", $0) }
        )
    }

    init?(device: MTLDevice, dataSource: MetalGridDataSource, budget: MetalGridBudget = .default,
          gridProfile: GridLevelProfile, memoryGovernor: MemoryPressureGovernor? = nil) {
        let texturePolicy = AppKitMetalGridTexturePolicies.policy(budget: budget)
        guard let renderer = MetalGridRenderer(device: device, clearColor: MetalGridPalette.clearColor),
              let cache = AppKitMetalGridTextureCacheFactory.makeCache(
                  device: device,
                  policy: texturePolicy
              ) as MetalGridTextureCache<PhotoUID>? else { return nil }
        self.renderer = renderer
        self.cache = cache
        self.dataSource = dataSource
        self.budget = budget
        self.gridProfile = gridProfile
        self.level = gridProfile.defaultLevel
        self.engine = SquareTileGridEngine(sectionCounts: dataSource.sectionCounts, profile: gridProfile)
        super.init()
        rebuildIndex()
        // Register the GPU texture cache with the injected memory governor (nil in tests — they never
        // touch the shared governor). Weak capture means an orphaned coordinator's handler no-ops, so
        // no deinit bookkeeping is needed. On pressure the cache sheds offscreen residency but never the
        // visible pinned set, so what is on screen stays drawable.
        memoryGovernor?.register { [weak cache] tier in
            cache?.setResidencyPressureScale(tier.budgetScale)
        }
    }

    func setDataSource(_ newSource: MetalGridDataSource) {
        dataSource = newSource
        rebuildIndex()
        onContentSizeChange?(contentSize())
        requestRedraw()
    }

    var totalItems: Int { dataSource.flatUIDs.count }
    var orderedUIDs: [PhotoUID] { dataSource.flatUIDs }
    var gridProfileID: String { gridProfile.id }

    @discardableResult
    func applyGridProfile(_ newProfile: GridLevelProfile,
                          oldFrame: CGRect,
                          newFrame: CGRect,
                          oldScrollY: CGFloat,
                          wasBottomPinned: Bool,
                          targetCommittedPhase: Int? = nil,
                          levelMapping: GridProfileRebaseLevelMapping = .closestVisualMatch) -> GridProfileRebaseResult? {
        guard newProfile.id != gridProfile.id else { return nil }
        var targetEngine = SquareTileGridEngine(sectionCounts: dataSource.sectionCounts, profile: newProfile)
        targetEngine.topInset = topBarInset
        let result = engine.rebasedScrollOffsetForProfileChange(GridProfileRebaseInput(
            targetEngine: targetEngine,
            oldViewportFrame: oldFrame,
            newViewportFrame: newFrame,
            oldScrollY: oldScrollY,
            sourceLevel: level,
            sourceCommittedPhase: currentPhase(),
            targetCommittedPhase: targetCommittedPhase,
            wasBottomPinned: wasBottomPinned,
            levelMapping: levelMapping
        ))

        gridProfile = newProfile
        engine = targetEngine
        committedPhase = result.targetCommittedPhase
        level = result.targetLevel
        onContentSizeChange?(contentSize())
        requestRedraw()
        return result
    }

    // MARK: - Production decorations + selection state (lab leaves `decorationsEnabled` false)

    /// When true, selection outlines + favorite/check/video badges are drawn for visible cells.
    var decorationsEnabled = false
    private(set) var selectedUIDs: Set<PhotoUID> = []
    private(set) var favoriteUIDs: Set<PhotoUID> = []
    private(set) var selectionMode = false
    private var indexByUID: [PhotoUID: Int] = [:]

    // Equality-guarded so a no-op SwiftUI `updateNSView` pass (frequent) does not force an otherwise-idle GPU
    // frame: each setter redraws ONLY when its value actually changed.
    func setSelection(_ uids: Set<PhotoUID>) { guard uids != selectedUIDs else { return }; selectedUIDs = uids; requestRedraw() }
    func setFavorites(_ uids: Set<PhotoUID>) { guard uids != favoriteUIDs else { return }; favoriteUIDs = uids; requestRedraw() }
    func setSelectionMode(_ on: Bool) { guard on != selectionMode else { return }; selectionMode = on; requestRedraw() }
    func requestRedraw() { metalView?.needsDisplay = true }

    private func rebuildIndex() {
        var map: [PhotoUID: Int] = [:]
        map.reserveCapacity(dataSource.flatUIDs.count)
        for (i, uid) in dataSource.flatUIDs.enumerated() { map[uid] = i }
        indexByUID = map
        // Rebuild the canonical engine from the new section structure (single source of truth).
        engine = SquareTileGridEngine(sectionCounts: dataSource.sectionCounts, profile: gridProfile)
        engine.topInset = topBarInset             // a fresh engine resets topInset → re-apply the toolbar margin
        committedPhase = nil                      // a stale phase could point past the new data → canonical
    }

    func flatIndex(forUID uid: PhotoUID) -> Int? { indexByUID[uid] }
    func uid(atFlatIndex index: Int) -> PhotoUID? {
        let uids = dataSource.flatUIDs
        return (index >= 0 && index < uids.count) ? uids[index] : nil
    }

    /// The photo cell + its flat index under a CONTENT-space point (for click/selection).
    func hitTestCell(contentPoint: CGPoint) -> (flatIndex: Int, uid: PhotoUID)? {
        let width = layoutWidth
        guard width > 1, let slot = engine.hitTest(contentPoint: contentPoint, level: level, width: width, columnPhase: currentPhase()),
              let uid = uid(atFlatIndex: slot.index) else { return nil }
        return (slot.index, uid)
    }

    /// The UIDs whose cells intersect a CONTENT-space rect - the marquee (drag-rectangle) selection set.
    func uids(intersecting contentRect: CGRect) -> Set<PhotoUID> {
        let width = layoutWidth
        guard width > 1 else { return [] }
        let slots = engine.slots(intersecting: contentRect, level: level, width: width, columnPhase: currentPhase())
        return Set(slots.compactMap { uid(atFlatIndex: $0.index) })
    }

    var levelCount: Int { engine.levelCount }
    func clampLevel(_ l: Int) -> Int { engine.clampLevel(l) }

    /// Scroll Y that keeps the item under `cursorContentPoint` at the same viewport position after changing
    /// to `newLevel` (zoom toward the cursor - the Apple rule). The engine owns the capture + rebase; this
    /// just supplies the live view width + scroll origin. nil if no item resolvable.
    func cursorAnchoredScrollOffsetY(toLevel newLevel: Int, cursorContentPoint: CGPoint) -> CGFloat? {
        let width = layoutWidth
        let originY = clipView?.bounds.origin.y ?? 0
        return engine.cursorAnchoredScrollOffsetY(levelChangeFrom: level, to: newLevel, width: width,
                                                  cursorContentPoint: cursorContentPoint, sourceScrollOriginY: originY)
    }

    // MARK: - Live focus-row zoom transaction (driven by the host's trackpad pinch)

    /// Begin a live zoom anchored at the item under (or nearest to) the cursor. `viewportPoint` is where to
    /// hold it (the cursor in viewport coords). The engine captures the transaction; the row under the cursor
    /// is then preserved as the level position changes.
    func beginLiveZoom(cursorContentPoint: CGPoint, viewportPoint: CGPoint) {
        let width = layoutWidth
        // The item the user SEES under the cursor (displayed = current level + committed phase).
        let hovered = engine.hitTest(contentPoint: cursorContentPoint, level: level, width: width, columnPhase: currentPhase())?.index
        zoomTransaction = engine.beginZoomTransaction(cursorContentPoint: cursorContentPoint,
                                                      viewportPoint: viewportPoint, level: level, width: width,
                                                      columnPhase: currentPhase())   // resolve in the DISPLAYED (phased) grid
        zoomTransactionLevel = CGFloat(level)
        // Capture the gesture-start state; the start detent uses this frame in every segment.
        pinchStartLevel = level
        pinchStartPhase = currentPhase()
        pinchStartScrollY = clipView?.bounds.origin.y ?? 0
        pinchSegmentSource = nil
        pinchSegmentTarget = nil
        gestureTrigger = .pinch
        gestureCursorVP = viewportPoint
        gestureAnchorIndex = zoomTransaction?.anchorGlobalIndex
        GridZoomAnchorLog.begin(trigger: .pinch, cursorViewportPoint: viewportPoint, cursorContentPoint: cursorContentPoint,
                                hoveredIndexAtBegin: hovered, transactionAnchorIndex: gestureAnchorIndex, level: level)
        if let tx = zoomTransaction {
            GridZoomCommitLog.begin(sourceLevel: level, anchorGlobalIndex: tx.anchorGlobalIndex,
                                    anchorViewportPoint: tx.anchorViewportPoint,
                                    focusRow: tx.frame(continuousLevel: CGFloat(level), viewportSize: layoutViewportSize, overscan: 0).focusRow)
        }
        requestRedraw()
    }

    /// The item under a viewport point in the CURRENT settled grid (current level + committed phase + scroll) -
    /// THE acceptance probe: it must equal the gesture anchor before and after commit.
    func indexUnderCursorViewport(_ vp: CGPoint) -> Int? {
        let width = layoutWidth
        guard width > 1 else { return nil }
        let scrollY = clipView?.bounds.origin.y ?? 0
        return engine.hitTest(contentPoint: CGPoint(x: vp.x, y: vp.y + scrollY), level: level, width: width, columnPhase: currentPhase())?.index
    }

    /// Update the live continuous level position (fractional = mid-pinch) from a RAW pinch level. Past the
    /// largest detent (raw level < 0) the visual level carries a bounded ELASTIC overshoot - the rubber-band -
    /// instead of being hard-clamped to 0. The committed level stays clamped to valid detents separately.
    func updateLiveZoom(continuousLevel x: CGFloat) {
        guard zoomTransaction != nil else { return }
        zoomTransactionLevel = GridLiveZoomBounds.visualLevel(rawLevel: x, levelCount: engine.levelCount)
        requestRedraw()
    }

    /// Set the live VISUAL level directly (already resolved, e.g. by the release spring-back), clamped to the
    /// safe live range `[-maxOverZoom, densest]`. Distinct from `updateLiveZoom`, which resists a RAW level.
    func setLiveVisualLevel(_ v: CGFloat) {
        guard zoomTransaction != nil else { return }
        zoomTransactionLevel = GridLiveZoomBounds.clampVisual(v, levelCount: engine.levelCount)
        requestRedraw()
    }

    /// Begin the commit BRIDGE: capture the live transaction as the bridge's source, rebase the scroll offset
    /// from the anchor (clamped to content), commit the settled `finalLevel`, and clear the live transaction.
    /// Returns the (clamped) scroll Y the host should scroll to; the bridge then slides transaction→settled.
    /// nil only if no live transaction. Logs the `[GridZoomCommit] release` seam measurement.
    func beginCommitBridge(finalLevel: Int) -> CGFloat? {
        guard let tx = zoomTransaction else { return nil }
        let width = layoutWidth
        let lv = engine.clampLevel(finalLevel)
        // PHASE: land the anchor item in the CURSOR's column at the target level, so the photo under the cursor
        // does not fly across the grid on release. This phase is committed NOW - every settled query (incl. the
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
        let delta = engine.commitDelta(transaction: tx, targetLevel: lv, viewportSize: layoutViewportSize, columnPhase: phase)
        // The MAX horizontal move any matched index would undergo (with the phase, a uniform sub-cell residual).
        let maxMove = GridZoomCommitBridge.maxMatchedIndexMoveX(transaction: tx, engine: engine, targetLevel: lv,
                                                               viewportSize: layoutViewportSize, scrollY: clampedY, overscan: overscan, columnPhase: phase)
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

    /// VIEWPORT-RESIZE REBASE (window resize / sidebar toggle - NOT zoom). Same level/phase/mode/columns/gap;
    /// only slotSide/pitch/contentSize recompute from the new width. Returns the rebased scroll Y so the SAME
    /// logical region stays visible; preserves `committedPhase` (never reset). The host applies the result
    /// BEFORE the first frame after resize. Logs `[GridResize]`.
    private var lastResizeDiagTime: Date = .distantPast
    /// VIEWPORT-RESIZE REBASE (window resize / sidebar - NOT zoom). The host passes the grid viewport frame in
    /// SCREEN coords (old + new) so the engine can tell WHICH edge moved; the stationary edge holds the anchor.
    /// Preserves `committedPhase` (passed, never reset). Returns the rebased scroll Y; logs `[GridResize]`.
    func rebaseForViewportChange(oldFrame: CGRect, newFrame: CGRect, oldScrollY: CGFloat,
                                 wasBottomPinned: Bool) -> GridViewportResizeResult? {
        let count = totalItems
        guard count > 0 else { return nil }
        let lvl = level
        let phase = currentPhase()
        let delta = GridViewportResizeDelta(old: oldFrame, new: newFrame)
        let anchorFractionY = resizeAnchorFraction(for: delta)
        let input = GridViewportResizeInput(oldViewportFrame: oldFrame, newViewportFrame: newFrame, oldScrollY: oldScrollY,
                                            level: lvl, committedPhase: phase, itemCount: count,
                                            wasBottomPinned: wasBottomPinned,
                                            anchorFractionY: anchorFractionY)
        let t0 = Date()
        let r = engine.rebasedScrollOffsetForViewportChange(input)            // cheap: 1 anchorItem + 1 slotRect
        let layoutMs = Date().timeIntervalSince(t0) * 1000
        // Diagnostics THROTTLED to ~3×/s: a live drag fires layout() per frame and `emit` prints synchronously
        // in DEBUG, so emitting (+ the 2× framePlan overlap) every frame is the jank.
        let now = Date()
        if now.timeIntervalSince(lastResizeDiagTime) > 0.33 {
            lastResizeDiagTime = now
            let reason: String = wasBottomPinned ? "bottomPinned"
                : (delta.widthChanged && delta.movedLeftEdge && !delta.heightChanged) ? "sidebarWidth"
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

    /// Runtime policy for resize/sidebar animation: hold the stationary vertical edge when one is obvious.
    /// Width-only changes (window side drag / sidebar reveal) preserve the viewport top so resizing clips or
    /// reveals instead of re-centering the camera every frame. The engine remains generic; this is host policy.
    private func resizeAnchorFraction(for delta: GridViewportResizeDelta) -> CGFloat {
        if delta.heightChanged {
            if delta.movedBottomEdge && !delta.movedTopEdge { return 0 }
            if delta.movedTopEdge && !delta.movedBottomEdge { return 1 }
            return 0.5
        }
        return 0
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
        let width = layoutWidth
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
        let width = layoutWidth
        guard width > 1 else { return nil }
        return engine.slotRect(flatIndex: index, level: level, width: width, columnPhase: currentPhase())
    }

    /// Whether the current level shows month/year labels (the dense overview levels).
    var showsMonthLabels: Bool { engine.metrics(level: level).monthLabels }

    var scrollOriginY: CGFloat { clipView?.bounds.origin.y ?? 0 }
    var viewportSize: CGSize { metalView?.bounds.size ?? clipView?.bounds.size ?? .zero }

    // MARK: - Leading obstruction inset (native floating sidebar)
    //
    // The detail MTKView renders FULL-WIDTH (under the floating sidebar), but the grid is LAID OUT only in the
    // unobscured area to its right. ONE value drives all three concerns: (1) the engine layout width, (2) the
    // render-space X translation of every emitted rect, (3) event exclusion (the host declines hit-testing for
    // x < inset). Set by the host from the sidebar's leading safe-area inset; mirrored from `eventLeadingInset`.
    // There are two X spaces - LAYOUT space (engine/anchor/phase/column math, width = `layoutWidth`) and RENDER
    // space (AppKit / on-screen, width = full viewport). All engine input + transition-plan construction use
    // layout space; rects are translated by `+inset` exactly once at the final draw chokepoint. At inset 0 the
    // grid is plain full-width and every path reduces to identity.
    /// The sidebar obstruction width (points) - the floating sidebar's leading safe-area inset. Set by the host.
    var sidebarObstructionInset: CGFloat = 0 {
        didSet { if sidebarObstructionInset != oldValue { requestRedraw() } }
    }

    /// The window's translucent toolbar height. Mirrored onto the engine's `topInset` so the first grid row rests
    /// below the toolbar instead of under it (set by the host, plumbed from `MainView`). Re-applied on every
    /// engine rebuild (`rebuildIndex`) so a data change never silently drops it.
    var topBarInset: CGFloat = 0 {
        didSet { if topBarInset != oldValue { engine.topInset = topBarInset; requestRedraw() } }
    }
    /// Extra leading breathing room for the NORMAL levels (L0–L3) ONLY, so landscape thumbnails don't butt up
    /// against the sidebar. Removed on the dense square overviews (L4–L5, which go edge-to-edge) and when no
    /// sidebar is present. Set by the host.
    var normalLevelLeadingGap: CGFloat = 0 {
        didSet { if normalLevelLeadingGap != oldValue { onContentSizeChange?(contentSize()); requestRedraw() } }
    }
    /// THE effective leading inset at a given level: the sidebar obstruction plus, for a normal level with a
    /// visible sidebar, the small breathing gap (`monthLabels` marks the dense overviews L4–L5 → no gap), plus the
    /// standard outer LEFT margin (`gridHorizontalMargin`). The right margin is taken off `layoutWidth`.
    func effectiveLeadingInset(forLevel lvl: Int) -> CGFloat {
        let gap = (sidebarObstructionInset > 0 && !engine.metrics(level: lvl).monthLabels) ? normalLevelLeadingGap : 0
        return sidebarObstructionInset + gap + gridHorizontalMargin(forLevel: lvl)
    }
    /// Standard OUTER left/right margin (gutter) so the edge columns don't butt against the window edge / sidebar.
    /// CONSTANT across the normal levels - deliberately NOT the per-level inter-tile gap. A LEVEL-DEPENDENT gutter
    /// makes `layoutWidth` level-dependent, and the pinch/± commit computes the anchored scroll at the gesture-START
    /// level's width while the settled grid renders at the TARGET level's width: that width gap accumulates over the
    /// rows and drifts the anchor by many rows deep in the library (the reported release jump - tiny near the top,
    /// large far down). A constant gutter keeps `layoutWidth` level-independent so the commit lands exactly. Applied
    /// to the NORMAL levels only (the dense square overviews L4–L5 stay edge-to-edge). The engine is unchanged: this
    /// is purely a render inset + width trim, so the live-zoom lattice, transitions, and settled grid stay lock-step.
    private func gridHorizontalMargin(forLevel lvl: Int) -> CGFloat {
        engine.metrics(level: lvl).monthLabels ? 0 : Self.standardOuterMargin
    }
    /// The constant outer gutter (points) for the normal photo levels - see `gridHorizontalMargin` for why it must
    /// not vary by level.
    static let standardOuterMargin: CGFloat = 12
    /// Render/layout bounds for one level. The source of the insets stays adapter-owned; the mapping itself is a
    /// pure GridCore value so overview boundaries can resolve source and target independently.
    func renderBounds(forLevel lvl: Int) -> GridRenderBounds {
        GridRenderBounds(
            fullWidth: fullViewportWidth,
            leadingInset: effectiveLeadingInset(forLevel: lvl),
            trailingInset: gridHorizontalMargin(forLevel: lvl)
        )
    }
    /// The effective inset at the CURRENT level - THE value every layout/render/input path reads.
    var leadingObstructionInset: CGFloat { renderBounds(forLevel: level).leadingInset }
    /// The full on-screen viewport WIDTH (render space) - the MTKView's actual width (no inset removed).
    private var fullViewportWidth: CGFloat { metalView?.bounds.width ?? clipView?.bounds.width ?? 0 }
    /// The width the ENGINE lays out a GIVEN level in: full render width minus that level's leading inset + outer
    /// margin. Per-level because the overview levels are edge-to-edge (no margin/gap) while the normal levels carry
    /// the gutter - so a transition that crosses that boundary (L3↔L4) must lay each level out at its OWN width.
    func layoutWidth(forLevel lvl: Int) -> CGFloat {
        renderBounds(forLevel: lvl).layoutWidth
    }
    /// The width the ENGINE lays out the CURRENT level in. Every engine / anchor / phase / column calculation uses
    /// THIS - never the full width.
    var layoutWidth: CGFloat { layoutWidth(forLevel: level) }
    /// The viewport the engine lays out in: `layoutWidth` × full height.
    var layoutViewportSize: CGSize { renderBounds(forLevel: level).viewport(height: viewportSize.height) }

    /// Translate engine/layout-space render slots into RENDER space - the single, final draw chokepoint where
    /// the inset is applied (exactly once per path). A no-op at inset 0 (byte-identical full-width output).
    private func renderTranslate(_ slots: [GridRenderSlot]) -> [GridRenderSlot] {
        renderBounds(forLevel: level).translate(slots)
    }

    /// Map a dissolve's TARGET layer into its own settled render bounds. The target plan is already built in
    /// `renderBounds(forLevel: target).layoutWidth`; scaling it again reopens the L3/L4 edge pop. Rendering only
    /// translates layout-space slots by the target's leading inset, exactly like a settled target frame.
    private func mapDissolveTargetLayer(_ slots: [GridRenderSlot], targetBounds: GridRenderBounds) -> [GridRenderSlot] {
        targetBounds.translate(slots)
    }

    /// How many of `slots` currently have a resident (real, non-placeholder) texture. Used by the overview
    /// dissolve to detect when a layer's content changed (a wanted thumbnail streamed in) so only that layer is
    /// re-rasterized - a cheap `isResident` dict lookup per slot, far below re-running `buildRealGroups` + a
    /// full offscreen pass every frame.
    private func residentSlotCount(_ slots: [GridRenderSlot], flatUIDs: [PhotoUID]) -> Int {
        var count = 0
        for slot in slots where slot.index < flatUIDs.count {
            if cache.isResident(flatUIDs[slot.index]) { count += 1 }
        }
        return count
    }

    /// Visible cells (flat index + content rect) for the accessibility provider / header positioning.
    func visibleCells() -> [(flatIndex: Int, rect: CGRect)] {
        guard let clip = clipView, metalView != nil, layoutWidth > 1 else { return [] }
        let plan = engine.framePlan(level: level, viewportSize: layoutViewportSize, scrollOffset: clip.bounds.origin, overscan: 0, columnPhase: currentPhase())
        return plan.visibleSlots.map { ($0.index, $0.slotRect) }
    }

    /// The first visible cell + how far its top sits below the viewport top - captured before a level
    /// change so the same photo can be re-pinned afterward (anchor preservation).
    func anchorAtViewportTop() -> (uid: PhotoUID, offset: CGFloat)? {
        guard let clip = clipView, metalView != nil, layoutWidth > 1 else { return nil }
        let origin = clip.bounds.origin
        let plan = engine.framePlan(level: level, viewportSize: layoutViewportSize, scrollOffset: origin, overscan: 0, columnPhase: currentPhase())
        guard let top = plan.visibleSlots.min(by: { $0.slotRect.minY < $1.slotRect.minY }),
              let uid = uid(atFlatIndex: top.index) else { return nil }
        return (uid, top.slotRect.minY - origin.y)
    }

    func contentSize() -> CGSize {
        let width = layoutWidth
        guard width > 1 else { return .zero }
        // HEIGHT is engine-derived from the LAYOUT width (inset removed), but the scroll document spacer stays
        // FULL-width so pointer events are captured across the whole rendered area (the host declines x < inset).
        let height = engine.contentSize(level: level, width: width, columnPhase: currentPhase()).height
        return CGSize(width: fullViewportWidth, height: height)
    }

    // MARK: - Live resize / sidebar presentation
    //
    // During a live WINDOW resize the grid must behave like a STABLE rendered surface, not a per-frame
    // re-resolving grid (re-resolving recomputes every tile position each tick → the tiles REFLOW, which reads as
    // rearranging - exactly what Apple does NOT do). On gesture begin we snapshot the settled render slots ONCE
    // (generous overscan ABOVE so a narrow / scale-down reveals already-laid-out older rows, never blank), and each
    // frame we present that snapshot UNIFORMLY SCALED to the current width about the stationary LEFT edge + viewport
    // BOTTOM - ONE coherent surface, square tiles preserved, no engine resolve / group rebuild / texture churn. On
        // gesture end the host settles once, bottom-anchored: under the fixed-columns model the release-width
    // settled layout uses the same column count as the live snapshot, so no column reflow or detent correction is
    // expected.

    private(set) var presentationResizeActive = false
    /// Leading obstruction inset (sidebar overlap) + layout width captured at gesture start: the scale anchors the
    /// content's LEFT edge at `inset` and scales by `currentLayoutWidth / startLayoutWidth`.
    private var presentationStartInset: CGFloat = 0
    private var presentationStartLayoutWidth: CGFloat = 1
    /// The settled render slots snapshotted ONCE at gesture start (+ their display mode). Each frame these are
    /// presented uniformly SCALED - one coherent surface - never re-resolved (re-resolving would reflow).
    private var presentationSnapshotSlots: [GridRenderSlot] = []
    private var presentationSnapshotDisplayMode: TileContentDisplayMode = .aspectFitInsideSquare
    /// The item pinned to the viewport BOTTOM (+ its in-cell Y fraction). Used by the SIDEBAR settle
    /// (`bottomAnchoredScroll`) so a toggle while scrolled to the newest end keeps the bottom row pinned. -1 ⇒ none.
    private var presentationBottomAnchorIndex = -1
    private var presentationBottomAnchorFracY: CGFloat = 1
    /// The item under the viewport CENTRE at gesture start (+ its in-cell Y fraction): a window resize scales the
    /// snapshot about the centre so the item you are looking at stays put, and the release scroll re-centres it
    /// (`centerAnchoredScroll`). -1 ⇒ none. This replaces the old bottom-anchored window-resize model.
    private var presentationCenterAnchorIndex = -1
    private var presentationCenterAnchorFracY: CGFloat = 0.5
    /// True for the duration of a window resize that began at the newest (bottom) end: the scale + settle then
    /// hold the LAST row at the viewport bottom instead of the centre, so scaling never opens an empty band below.
    private var presentationResizeBottomPinned = false
    /// The clip scroll captured at gesture start - the reference the VERTICAL settle counter-scrolls from.
    private(set) var presentationStartScrollY: CGFloat = 0
    /// VERTICAL drag offset (viewport pixels, y-down) the host applies to the snapshot each tick: a vertical resize
    /// keeps the tile SIZE (no scale) and slides the grid so the dragging edge clips while the opposite edge gives
    /// up a fraction (Apple's shared-loss counter-scroll). 0 for a pure-horizontal drag. Set by the host.
    var presentationVerticalShift: CGFloat = 0

    /// True only when the presentation can run (no zoom / transition / dissolve / commit / sidebar-anim in flight).
    var canPresentResize: Bool {
        zoomTransaction == nil && !gridTransition.isActive && overviewDissolve == nil && !isCommitBridging && !presentationSidebarActive
    }

    /// Snapshot the settled render slots ONCE (generous overscan so a scale-down reveals real older rows) plus the
    /// box they were laid out in (layout width, inset) and the start scroll. A presentation/sidebar transition then
    /// presents these SCALED - never re-resolved.
    private func captureSnapshot() {
        guard let clip = clipView, let view = metalView else { return }
        let viewportSize = view.bounds.size
        let w = layoutWidth
        let scrollY = clip.bounds.origin.y
        let phase = currentPhase()
        let overscan = max(budget.overscanFraction, 1.5) * viewportSize.height
        let lvp = CGSize(width: w, height: viewportSize.height)
        let plan = engine.framePlan(level: level, viewportSize: lvp, scrollOffset: CGPoint(x: 0, y: scrollY), overscan: overscan, columnPhase: phase)
        presentationSnapshotSlots = renderTranslate(plan.visibleSlots.map { GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect) })
        presentationSnapshotDisplayMode = effectiveDisplayMode
        presentationStartLayoutWidth = w
        presentationStartInset = leadingObstructionInset
        presentationStartScrollY = scrollY
    }

    /// Begin the live horizontal-resize presentation: snapshot the settled slots ONCE and capture the item at the
    /// viewport BOTTOM so it stays pinned there through the scale. Idempotent within a gesture.
    func beginPresentationResize() {
        guard !presentationResizeActive, let clip = clipView, let view = metalView else { return }
        if presentationSidebarActive { cancelSidebarResize() }   // a window resize supersedes a sidebar scale
        if resizeSettleActive { endResizeSettle() }              // a fresh drag during a settle supersedes it
        guard canPresentResize else { return }
        let viewportSize = view.bounds.size
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }
        // At the newest (bottom) end ⇒ hold the LAST row at the viewport bottom (else scaling about the centre opens
        // an empty band below it); otherwise hold the centre (the item you are looking at stays put). Capture BOTH
        // anchors so the release can settle whichever the gesture used.
        presentationResizeBottomPinned = Self.resizeIsBottomPinned(scrollY: clip.bounds.origin.y,
                                                                   contentHeight: contentSize().height,
                                                                   viewportHeight: viewportSize.height)
        captureBottomAnchor()
        captureCenterAnchor()
        captureSnapshot()
        presentationVerticalShift = 0
        presentationResizeActive = true
    }

    /// Capture the item at the viewport BOTTOM (+ its in-cell Y fraction) so a width change can keep it pinned at
    /// the bottom (the scale is bottom-anchored vertically; the settle bottom-anchors to match). -1 ⇒ none.
    private func captureBottomAnchor() {
        guard let clip = clipView, let view = metalView else { presentationBottomAnchorIndex = -1; return }
        let w = layoutWidth
        let scrollY = clip.bounds.origin.y
        if let a = engine.anchorItem(nearContentPoint: CGPoint(x: w / 2, y: scrollY + view.bounds.height - 1),
                                     level: level, width: w, columnPhase: currentPhase()) {
            presentationBottomAnchorIndex = a.flatIndex
            presentationBottomAnchorFracY = a.localFraction.y
        } else {
            presentationBottomAnchorIndex = -1
        }
    }

    /// Capture the item under the viewport CENTRE (+ its in-cell Y fraction) so a window resize keeps it pinned at
    /// the centre through the scale and re-centres it on release (Apple-style: the thing you look at stays put).
    private func captureCenterAnchor() {
        guard let clip = clipView, let view = metalView else { presentationCenterAnchorIndex = -1; return }
        let w = layoutWidth
        let scrollY = clip.bounds.origin.y
        let H = view.bounds.height
        if let a = engine.anchorItem(nearContentPoint: CGPoint(x: w / 2, y: scrollY + H / 2),
                                     level: level, width: w, columnPhase: currentPhase()) {
            presentationCenterAnchorIndex = a.flatIndex
            presentationCenterAnchorFracY = a.localFraction.y
        } else {
            presentationCenterAnchorIndex = -1
        }
    }

    /// The bottom-anchored scroll for the captured anchor at the CURRENT layout width (clamped). Falls back to the
    /// gesture-start scroll when no anchor. Used by the sidebar settle so a toggle while scrolled to the newest end
    /// keeps the bottom row pinned (no jump) instead of reusing the frozen start scroll.
    private func bottomAnchoredScroll() -> CGFloat {
        guard presentationBottomAnchorIndex >= 0, let view = metalView else { return presentationStartScrollY }
        let H = view.bounds.height
        let y = engine.anchoredScrollOffsetY(flatIndex: presentationBottomAnchorIndex, relInCellY: presentationBottomAnchorFracY,
                                             contentFractionY: 1, viewportPointY: H, level: level, width: layoutWidth, columnPhase: currentPhase())
        return engine.clampScrollOffsetY(y, level: level, width: layoutWidth, viewportHeight: H, columnPhase: currentPhase())
    }

    /// The settled scroll that re-centres the captured CENTRE anchor at the CURRENT layout width (clamped). Falls
    /// back to the gesture-start scroll when no anchor. The host applies this ONCE on release of a window resize, so
    /// the item the user was looking at stays under the viewport centre - there is no per-frame re-anchor (which
    /// drifted vertically as the tiles scaled with width).
    func centerAnchoredScroll() -> CGFloat {
        guard presentationCenterAnchorIndex >= 0, let view = metalView else { return presentationStartScrollY }
        let H = view.bounds.height
        let y = engine.anchoredScrollOffsetY(flatIndex: presentationCenterAnchorIndex, relInCellY: presentationCenterAnchorFracY,
                                             contentFractionY: 0.5, viewportPointY: H / 2, level: level, width: layoutWidth, columnPhase: currentPhase())
        return engine.clampScrollOffsetY(y, level: level, width: layoutWidth, viewportHeight: H, columnPhase: currentPhase())
    }

    /// The settle scroll the host applies on release of a WIDTH/corner window resize: bottom-pinned ⇒ keep the LAST
    /// row at the viewport bottom (no empty band); otherwise re-centre the centre anchor. (A pure-vertical resize
    /// settles via the host's counter-scroll, not this.)
    func windowResizeReleaseScrollY() -> CGFloat {
        presentationResizeBottomPinned ? bottomAnchoredScroll() : centerAnchoredScroll()
    }

    /// End the presentation; the host syncs the clip to `centerAnchoredScroll()` and redraws the settled grid.
    func endPresentationResize() {
        presentationResizeActive = false
        presentationSnapshotSlots = []
        presentationVerticalShift = 0
    }

    // MARK: - Sidebar resize (open/close scales the grid like a left-edge resize - RIGHT-anchored, inset-driven)
    //
    // The floating sidebar is FIXED-width, so open/close changes the grid's leading inset by a known amount. Rather
    // than reflow, this presents the gesture-start snapshot SCALED right-anchored to fill [inset(t), V] as the inset
    // animates `from` → `to` over the slide duration (a timed "virtual drag", host-driven). The end commits the
    // engine inset and settles via the SAME detent fly-into-place as a window resize (until sticky columns make a
    // width change reflow-free, after which the settle is a no-op).
    private(set) var presentationSidebarActive = false
    var isSidebarResizing: Bool { presentationSidebarActive }
    /// from/to are LAYOUT insets (sidebar width + the normal-level gap) - what the scale fills to; `toEventInset`
    /// is the raw sidebar width committed to `sidebarObstructionInset` (the gap is re-added by the engine).
    private var presentationSidebarFromInset: CGFloat = 0
    private var presentationSidebarToInset: CGFloat = 0
    private var presentationSidebarToEventInset: CGFloat = 0
    private var presentationSidebarViewportWidth: CGFloat = 1
    private var presentationSidebarBottomPinned = false
    /// 0→1, advanced by the host's display-link tick; eased in `drawSidebarResize`.
    var presentationSidebarProgress: CGFloat = 0

    /// The LAYOUT inset (points) for a given sidebar obstruction width = the width plus, for a normal level with a
    /// sidebar, the breathing gap, plus the standard outer LEFT margin - so the scale fills to EXACTLY where the
    /// engine will lay the grid out (mirrors `effectiveLeadingInset`). Omitting the margin here left a margin-sized
    /// re-alignment at the end of the slide.
    private func sidebarLayoutInset(forWidth sidebarInset: CGFloat) -> CGFloat {
        let gap = (sidebarInset > 0 && !engine.metrics(level: level).monthLabels) ? normalLevelLeadingGap : 0
        return sidebarInset + gap + gridHorizontalMargin(forLevel: level)
    }

    /// Arm the sidebar scale: snapshot at the OLD inset (the engine inset must still be `fromInset` here), then
    /// present it RIGHT-anchored, scaling to [inset(t), V]. `fromInset`/`toInset` are the host's sidebar WIDTHS.
    /// Returns false (⇒ caller settles instantly) when it can't run.
    @discardableResult
    func beginSidebarResize(fromInset: CGFloat, toInset: CGFloat) -> Bool {
        if presentationSidebarActive { cancelSidebarResize() }   // a new toggle SUPERSEDES the in-flight scale
        guard canPresentResize, !presentationResizeActive, let view = metalView, let clip = clipView else { return false }
        let viewportSize = view.bounds.size
        guard viewportSize.width > 1, viewportSize.height > 1 else { return false }
        if resizeSettleActive { endResizeSettle() }
        presentationSidebarBottomPinned = Self.resizeIsBottomPinned(
            scrollY: clip.bounds.origin.y,
            contentHeight: contentSize().height,
            viewportHeight: viewportSize.height
        )
        captureBottomAnchor()
        captureCenterAnchor()
        captureSnapshot()
        presentationSidebarFromInset = sidebarLayoutInset(forWidth: fromInset)   // == presentationStartInset (old layout inset)
        presentationSidebarToInset = sidebarLayoutInset(forWidth: toInset)
        presentationSidebarToEventInset = toInset
        // The right-anchor is the content's RIGHT edge = full width − the right margin (not the window edge), so the
        // scaled frame's right edge lands exactly where the settled grid's does (no end-of-slide re-alignment).
        presentationSidebarViewportWidth = viewportSize.width - gridHorizontalMargin(forLevel: level)
        presentationSidebarProgress = 0
        presentationSidebarActive = true
        return true
    }

    /// Settle the sidebar scale at `toInset`: commit the engine inset and, if the new layout reflowed (a column
    /// detent crossed), arm the fly-into-place morph from the last (right-anchored) scaled frame to the settled
    /// layout. Returns true if a settle animation was armed (host drives `resizeSettleProgress`); false ⇒ instant.
    func endSidebarResize() -> (scroll: CGFloat, animating: Bool) {
        let V = presentationSidebarViewportWidth
        let H = metalView?.bounds.height ?? 1
        let startLayoutW = max(1, V - presentationSidebarFromInset)
        let toLayoutW = max(1, V - presentationSidebarToInset)
        let k = toLayoutW / startLayoutW
        let anchorY = presentationSidebarBottomPinned ? H : H / 2
        // SOURCE - the last scaled frame (q=1): the snapshot scaled right-anchored to [toInset, V].
        let source = presentationSnapshotSlots.map { s in
            GridRenderSlot(index: s.index, column: s.column, row: s.row,
                           rect: Self.presentationScaledRectRightAnchored(s.rect, scale: k, rightX: V, anchorY: anchorY))
        }
        presentationSidebarActive = false
        sidebarObstructionInset = presentationSidebarToEventInset   // commit the WIDTH (engine re-adds the gap)
        // Match the presentation's vertical anchor: bottom only at the newest end, centre in the middle of the
        // timeline.
        let scroll = presentationSidebarBottomPinned ? bottomAnchoredScroll() : centerAnchoredScroll()
        // TARGET - the settled layout (sticky columns ⇒ same count, tile filled) at the new inset + scroll.
        let phase = currentPhase()
        let overscan = max(budget.overscanFraction, 1.5) * H
        let plan = engine.framePlan(level: level, viewportSize: CGSize(width: toLayoutW, height: H), scrollOffset: CGPoint(x: 0, y: scroll), overscan: overscan, columnPhase: phase)
        let target = renderTranslate(plan.visibleSlots.map { GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect) })
        presentationSnapshotSlots = []
        let startCols = engine.resolvedMetrics(level: level, width: startLayoutW).columns
        let delta = Self.maxIndexedRectDelta(source: source, target: target)
        guard plan.columns != startCols, delta > 1.5 else {
            resizeSettleActive = false
            return (scroll, false)
        }
        resizeSettleSource = source
        resizeSettleTarget = target
        resizeSettleProgress = 0
        resizeSettleActive = true
        return (scroll, true)
    }

    /// Finalize an in-flight sidebar scale IMMEDIATELY - commit its target inset (engine re-adds the gap), drop the
    /// snapshot, and commit the inset. Used when a new toggle or a window resize supersedes it, so the engine inset
    /// can never end out of sync with the sidebar's actual state.
    func cancelSidebarResize() {
        guard presentationSidebarActive else { return }
        presentationSidebarActive = false
        sidebarObstructionInset = presentationSidebarToEventInset
        presentationSnapshotSlots = []
        presentationSidebarBottomPinned = false
    }

    /// Present the snapshot SCALED right-anchored to fill [inset(t), V] for the current sidebar progress. Coherent
    /// scale (one surface) - never re-resolved - so the grid scales exactly like a left-edge window drag.
    private func drawSidebarResize(in view: MTKView, viewportSize: CGSize) {
        let scaled = sidebarPresentationSlots(viewportSize: viewportSize, progress: presentationSidebarProgress)
        let (groups, _) = buildRealGroups(slots: scaled, flatUIDs: dataSource.flatUIDs, viewportSize: viewportSize, displayMode: presentationSnapshotDisplayMode)
        renderer.render(in: view, viewportSize: viewportSize, groups: groups)
    }

    /// Present the gesture-start snapshot as ONE coherent surface, UNIFORMLY SCALED to the current width about the
    /// stationary LEFT edge (x = inset) and the viewport CENTRE. Scaling a single snapshot moves every tile
    /// together (a smooth zoom), where re-resolving the engine per tick would recompute positions and REFLOW. The
    /// item under the centre stays pinned (no vertical drift while dragging the side edge); rows scale out
    /// symmetrically. No engine resolve / group rebuild / texture churn per tick.
    private func drawPresentationResize(in view: MTKView, viewportSize: CGSize) {
        let scaled = resizePresentationSlots(viewportSize: viewportSize)
        let (groups, _) = buildRealGroups(slots: scaled, flatUIDs: dataSource.flatUIDs, viewportSize: viewportSize, displayMode: presentationSnapshotDisplayMode)
        renderer.render(in: view, viewportSize: viewportSize, groups: groups)
        // The settle scroll is resolved ONCE on release (`windowResizeReleaseScrollY`), never re-anchored per frame -
        // that bottom-anchored recompute drifted vertically as the tiles scaled with width.
    }

    /// Pure geometry for the live window-resize presentation. Kept as a named entry point so tests can exercise
    /// the same rect path the renderer uses: captured slots → one uniform scale/slide → rendered slots.
    func resizePresentationSlots(viewportSize: CGSize) -> [GridRenderSlot] {
        let H = viewportSize.height
        let inset = presentationStartInset
        // Subtract the RIGHT gutter too (the LEFT gutter is already folded into `inset`): otherwise the snapshot
        // scales to fill width−inset and the standard outer margin VANISHES during the drag (photos stick to the
        // right edge), then snaps back when the settled grid (which has the margin) renders on release.
        let curLayoutW = max(1, viewportSize.width - inset - gridHorizontalMargin(forLevel: level))
        let k = curLayoutW / max(1, presentationStartLayoutWidth)
        let dy = presentationVerticalShift   // VERTICAL counter-scroll (pure-vertical only); tiles keep their size
        let anchorY = presentationResizeBottomPinned ? H : H / 2   // hold the last row at the bottom, else the centre
        let scaled = presentationSnapshotSlots.map { s in
            GridRenderSlot(index: s.index, column: s.column, row: s.row,
                           rect: Self.presentationScaledRect(s.rect, scale: k, insetX: inset, anchorY: anchorY).offsetBy(dx: 0, dy: dy))
        }
        return scaled
    }

    /// Pure geometry for the sidebar open/close presentation. `progress` is the host-driven 0→1 animation value;
    /// this returns the exact right-anchored slots the renderer draws.
    func sidebarPresentationSlots(viewportSize: CGSize, progress: CGFloat) -> [GridRenderSlot] {
        let H = viewportSize.height
        let V = presentationSidebarViewportWidth
        let q = Self.easeInOutCubic(min(1, max(0, progress)))
        let inset = presentationSidebarFromInset + (presentationSidebarToInset - presentationSidebarFromInset) * q
        let startLayoutW = max(1, V - presentationSidebarFromInset)
        let k = max(1, V - inset) / startLayoutW
        let anchorY = presentationSidebarBottomPinned ? H : H / 2
        return presentationSnapshotSlots.map { s in
            GridRenderSlot(index: s.index, column: s.column, row: s.row,
                           rect: Self.presentationScaledRectRightAnchored(s.rect, scale: k, rightX: V, anchorY: anchorY))
        }
    }

    /// Scale a viewport rect (top-down pixel space, y = 0 at top) by `k` about the stationary left edge (x = insetX)
    /// and a stationary horizontal anchor line (y = anchorY): the content at the anchor stays put, the left content
    /// edge stays at the inset, and squares stay square (X and Y scale equally). A window resize passes the viewport
    /// CENTRE (anchorY = H/2). `k = 1` is the identity.
    nonisolated static func presentationScaledRect(_ r: CGRect, scale k: CGFloat, insetX: CGFloat, anchorY: CGFloat) -> CGRect {
        CGRect(x: insetX + (r.minX - insetX) * k,
               y: anchorY + (r.minY - anchorY) * k,
               width: r.width * k,
               height: r.height * k)
    }

    /// Scale a viewport rect about the stationary RIGHT edge (x = rightX) and a vertical anchor line - for a sidebar
    /// open/close (a LEFT-edge resize of the grid): the content's right edge stays put while its left edge moves to
    /// the new inset and the tiles scale (square). `k = 1` is the identity.
    nonisolated static func presentationScaledRectRightAnchored(_ r: CGRect, scale k: CGFloat, rightX V: CGFloat, anchorY: CGFloat) -> CGRect {
        CGRect(x: V - (V - r.minX) * k,
               y: anchorY + (r.minY - anchorY) * k,
               width: r.width * k,
               height: r.height * k)
    }

    /// The VERTICAL counter-scroll slide (viewport pixels, y-down) for a height change of `dH` (= startH − curH,
    /// shrink positive). The DRAGGING edge clips the majority; the OPPOSITE edge gives up fraction `f`. A bottom-
    /// edge drag slides up by f·dH (older rows leave the top); a top-edge drag slides up by (1−f)·dH (the bottom
    /// stays put). `f = 0` ⇒ pure edge-anchor (all loss at the dragging edge); `f = 1` ⇒ the opposite edge anchors.
    nonisolated static func verticalCounterScrollShift(dH: CGFloat, topEdgeDrag: Bool, fraction f: CGFloat) -> CGFloat {
        topEdgeDrag ? -(1 - f) * dH : -f * dH
    }

    /// A window resize is BOTTOM-PINNED when the grid is scrolled to within ~a row of the newest (bottom) end. There
    /// the scale + settle must hold the LAST row at the viewport bottom (anchorY = H, `bottomAnchoredScroll`) rather
    /// than the centre - otherwise scaling about the centre opens an empty band below the last row. Pure + testable.
    nonisolated static func resizeIsBottomPinned(scrollY: CGFloat, contentHeight: CGFloat, viewportHeight: CGFloat) -> Bool {
        let maxScroll = max(0, contentHeight - viewportHeight)
        return scrollY >= maxScroll - 2
    }

    // MARK: - Resize settle (reserved for release-time column-count changes)
    //
    // A live resize SCALES the snapshot at the gesture-start column count. With fixed columns, release normally
    // resolves to the same column count and this morph is not armed. The path is retained defensively for any future
    // responsive policy that changes columns at release: every visible item's viewport rect eases from the last
    // scaled position to the settled position instead of snapping.
    private(set) var resizeSettleActive = false
    var isResizeSettling: Bool { resizeSettleActive }
    private var resizeSettleSource: [GridRenderSlot] = []
    private var resizeSettleTarget: [GridRenderSlot] = []
    /// 0→1, advanced by the host's display-link tick; eased in `drawResizeSettle`.
    var resizeSettleProgress: CGFloat = 0

    /// Arm the release settle: SOURCE = the last scaled presentation frame; TARGET = the settled fixed-column
    /// layout at the release width, bottom-anchored to `targetScrollY` (the scroll the host is about to apply).
    /// Returns false (⇒ caller settles instantly) unless the release layout genuinely changed column count.
    @discardableResult
    func beginResizeSettle(targetScrollY: CGFloat) -> Bool {
        guard presentationResizeActive, let view = metalView else { resizeSettleActive = false; return false }
        let viewportSize = view.bounds.size
        let H = viewportSize.height
        let inset = presentationStartInset
        let curLayoutW = max(1, viewportSize.width - inset - gridHorizontalMargin(forLevel: level))   // right gutter too
        // SOURCE - exactly the scaled + vertically-slid snapshot the last live frame presented (what the user sees);
        // same anchor as `drawPresentationResize` so the settle starts from the on-screen frame.
        let source = resizePresentationSlots(viewportSize: viewportSize)
        // TARGET - the settled fixed-column layout at the release width + the scroll the host will apply.
        let phase = currentPhase()
        let overscan = max(budget.overscanFraction, 1.5) * H
        let lvp = CGSize(width: curLayoutW, height: H)
        let plan = engine.framePlan(level: level, viewportSize: lvp, scrollOffset: CGPoint(x: 0, y: targetScrollY), overscan: overscan, columnPhase: phase)
        let target = renderTranslate(plan.visibleSlots.map { GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect) })
        // FIXED COLUMNS: a width change never changes the column count ⇒ NO reflow ⇒ the fly-into-place morph is not
        // needed. The only source↔target difference is the snapshot's uniformly-SCALED gaps vs the settled CONSTANT
        // gaps (≤ a few px); animating THAT over ~220 ms is the "rebuild/scroll-around" glitch on release. Only arm
        // the morph for a genuine column reflow (which fixed-columns never produces); otherwise the host snaps.
        let startCols = engine.resolvedMetrics(level: level, width: presentationStartLayoutWidth).columns
        let delta = Self.maxIndexedRectDelta(source: source, target: target)
        guard plan.columns != startCols, delta > 1.5 else { resizeSettleActive = false; return false }
        resizeSettleSource = source
        resizeSettleTarget = target
        resizeSettleProgress = 0
        resizeSettleActive = true
        return true
    }

    func endResizeSettle() {
        resizeSettleActive = false
        resizeSettleSource = []
        resizeSettleTarget = []
    }

    /// Render the settle: each settled (target) slot eased from its SCALED (source) position by `easeOut(progress)`.
    /// A target item with no source match (newly revealed at an edge) appears at its settled rect. Textures stream
    /// + decorations draw via the canonical real-slot path.
    private func drawResizeSettle(in view: MTKView, viewportSize: CGSize, now: CFTimeInterval) {
        let q = Self.easeOutCubic(min(1, max(0, resizeSettleProgress)))
        var srcByIndex: [Int: CGRect] = [:]
        srcByIndex.reserveCapacity(resizeSettleSource.count)
        for s in resizeSettleSource { srcByIndex[s.index] = s.rect }
        let slots: [GridRenderSlot] = resizeSettleTarget.map { t in
            guard let s = srcByIndex[t.index] else { return t }
            let r = CGRect(x: s.minX + (t.rect.minX - s.minX) * q,
                           y: s.minY + (t.rect.minY - s.minY) * q,
                           width: s.width + (t.rect.width - s.width) * q,
                           height: s.height + (t.rect.height - s.height) * q)
            return GridRenderSlot(index: t.index, column: t.column, row: t.row, rect: r)
        }
        let pureViewport = CGRect(origin: .zero, size: viewportSize)
        let flatUIDs = dataSource.flatUIDs
        var visibleUIDs: [PhotoUID] = []
        var overscanUIDs: [PhotoUID] = []
        for s in slots where s.index < flatUIDs.count {
            if s.rect.intersects(pureViewport) { visibleUIDs.append(flatUIDs[s.index]) } else { overscanUIDs.append(flatUIDs[s.index]) }
        }
        streamTextures(visibleUIDs: visibleUIDs, overscanUIDs: overscanUIDs)
        _ = renderRealSlots(in: view, slots: slots, flatUIDs: flatUIDs, viewportSize: viewportSize)
        hasPendingVisibleThumbnails = !cache.residencySaturatedThisFrame && hasRetryableMissingVisibleTexture(visibleUIDs)
    }

    /// Max per-item rect delta (L1 of origin + size) between two index-keyed slot sets - 0 when every shared item
    /// sits in the same place, large when a future responsive policy reflows the same indexed items.
    nonisolated static func maxIndexedRectDelta(source: [GridRenderSlot], target: [GridRenderSlot]) -> CGFloat {
        var src: [Int: CGRect] = [:]
        src.reserveCapacity(source.count)
        for s in source { src[s.index] = s.rect }
        var maxD: CGFloat = 0
        for t in target {
            guard let r = src[t.index] else { continue }
            let d = abs(r.minX - t.rect.minX) + abs(r.minY - t.rect.minY) + abs(r.width - t.rect.width) + abs(r.height - t.rect.height)
            if d > maxD { maxD = d }
        }
        return maxD
    }

    /// easeOutCubic - fast start, gentle landing: the "fly into place" the resize settle wants.
    nonisolated static func easeOutCubic(_ q: CGFloat) -> CGFloat { let p = 1 - q; return 1 - p * p * p }

    /// easeInOutCubic - slow ends, fast middle: matches a sidebar slide's acceleration.
    nonisolated static func easeInOutCubic(_ q: CGFloat) -> CGFloat {
        if q < 0.5 { return 4 * q * q * q }
        let u = -2 * q + 2
        return 1 - u * u * u / 2
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        onContentSizeChange?(contentSize())
    }

    func draw(in view: MTKView) {
        guard let clip = clipView else { return }
        let viewportSize = view.bounds.size
        guard viewportSize.width > 1, viewportSize.height > 1 else { return }
        // Refresh the display backing scale from the live drawable (invariant to window size - the ratio is the
        // Retina factor). Set before any early-returning branch so every path that reaches `streamTextures`
        // sizes uploads against the current display.
        if view.bounds.width > 0, view.drawableSize.width > 0 {
            backingScale = max(1, view.drawableSize.width / view.bounds.width)
        }
        // LIVE WINDOW RESIZE: scale the gesture-start snapshot about the viewport centre (fixed columns, no reflow;
        // the clip is frozen - the host re-centres it ONCE on release). Armed for a horizontal/corner drag.
        if presentationResizeActive {
            drawPresentationResize(in: view, viewportSize: viewportSize)
            return
        }
        // SIDEBAR open/close: present the snapshot SCALED right-anchored to the animating inset (a left-edge resize
        // of the grid) - the same coherent scale as a window drag, host-driven over the slide duration.
        if presentationSidebarActive {
            drawSidebarResize(in: view, viewportSize: viewportSize)
            return
        }
        let now = CACurrentMediaTime()
        // RELEASE SETTLE: a detent-crossing resize morphs the scaled frame into the settled layout (the tiles fly
        // into their new grid positions). Sub-detent resizes never arm this (the host settled instantly).
        if resizeSettleActive {
            drawResizeSettle(in: view, viewportSize: viewportSize, now: now)
            return
        }
        // OVERVIEW LAYER DISSOLVE (offscreen two-layer mix) - active during L3↔L4 / L4↔L5 gestures and the
        // discrete +/- overview click fade.
        if let plan = overviewDissolve {
            if overviewClickDissolveActive {
                let q = advanceClickOverviewDissolve(now: now)
                if q >= 1 {
                    finishClickOverviewDissolve()
                } else if let updated = overviewDissolve {
                    drawOverviewDissolve(in: view, plan: updated, viewportSize: viewportSize, now: now)
                    view.setNeedsDisplay(view.bounds)
                    return
                }
            } else {
                drawOverviewDissolve(in: view, plan: plan, viewportSize: viewportSize, now: now)
                return
            }
        }
        // Single-lattice transition. q is HOST-owned: advanced by this display tick's wall-clock delta
        // (the same host-clock model the commit bridge uses), NOT a component-local timer; component
        // localProgress is a pure function of q.
        if gridTransition.isActive {
            // LIVE PINCH (V3.8): q is HOST-driven via `setPinchProgress` (the scrub driver), NOT a timer -
            // render at the current q and stop. The host paces redraws (magnify events + the settle tick)
            // and ends the plan on commit; there is no self-looping setNeedsDisplay here.
            if gridTransition.activeKind == .pinch {
                drawTransition(in: view, viewportSize: viewportSize, now: now)
                return
            }
            // CLICK: q is the host-clock trapezoidal profile advanced per display tick.
            let dt = transitionPrevNow == 0 ? 1.0 / 60.0 : max(0, now - transitionPrevNow)
            transitionPrevNow = now
            if gridTransition.advanceClick(bySeconds: dt) {
                drawTransition(in: view, viewportSize: viewportSize, now: now)
                view.setNeedsDisplay(view.bounds)        // keep ticking while the transition runs
                return
            }
            // settled this tick (q==1, controller ended itself) → fall through to the canonical render
        }
        // Commit bridge (post-release geometry settle) takes precedence over the settled render.
        if isCommitBridging {
            drawCommitBridge(in: view, viewportSize: viewportSize, now: now)
            return
        }
        // THE canonical production path: input → engine → GridFramePlan → renderer draws exactly that plan.
        drawEngineFrame(in: view, clip: clip, viewportSize: viewportSize, now: now)
    }

    // MARK: - Single-lattice transition render

    /// Try to start a CLICKV2_420_FULLER_CORNER click transition
    /// for a toolbar/keyboard +/- to `newLevel`, pinning `anchorIndex` at `viewportPoint`. Commits the
    /// settled level/phase (so the post-settle frame is the target) and overlays the crossfade for the
    /// duration. Returns the target scroll-Y to apply if started, else nil ⇒ caller uses the stable snap.
    func tryBeginClickTransition(toLevel newLevel: Int, anchorContentPoint: CGPoint,
                                 viewportPoint: CGPoint, viewportSize: CGSize) -> CGFloat? {
        let lv = engine.clampLevel(newLevel)
        guard abs(lv - level) == 1 else { return nil }                       // single-level steps only
        let lo = min(lv, level)
        guard engine.metrics(level: lo).transitionKindToNext == .focusRowRelayout else { return nil }  // normal-level scope
        let width = layoutWidth                       // engine input is layout-space (inset removed)
        let lvp = layoutViewportSize
        guard let a = engine.anchorItem(nearContentPoint: anchorContentPoint, level: level, width: width,
                                        columnPhase: currentPhase()) else { return nil }
        let overscan = budget.overscanFraction * viewportSize.height
        let srcScroll = clipView?.bounds.origin ?? .zero
        let src = engine.framePlan(level: level, viewportSize: lvp, scrollOffset: srcScroll,
                                   overscan: overscan, columnPhase: currentPhase())
        let desiredColumn = engine.cursorColumn(viewportX: viewportPoint.x, level: lv, width: width)
        let tgtPhase = engine.columnPhase(forItem: a.flatIndex, targetColumn: desiredColumn, level: lv, width: width)
        let tgtScroll = engine.anchoredScrollOffset(flatIndex: a.flatIndex, localFraction: a.localFraction,
                                                    viewportPoint: viewportPoint, level: lv, width: width, columnPhase: tgtPhase)
        let tgt = engine.framePlan(level: lv, viewportSize: lvp, scrollOffset: CGPoint(x: 0, y: tgtScroll.y),
                                   overscan: overscan, columnPhase: tgtPhase)
        let began = PhotoPerformanceSignposts.grid.interval("transition.planBuild") {
            gridTransition.beginClick(source: src, target: tgt, anchorIndex: a.flatIndex,
                                      viewportSize: lvp, selection: selectedFlatIndices)
        }
        guard began else { return nil }
        committedPhase = tgtPhase                 // commit settled target state (post-transition frame is the target)
        level = lv
        transitionPrevNow = 0
        metalView?.setNeedsDisplay(metalView?.bounds ?? .zero)
        return tgtScroll.y
    }

    /// Discrete +/- transition for overview boundaries (L3↔L4 / L4↔L5): a fast dissolve between two complete
    /// grid layers. This intentionally does NOT use the per-photo relocation lattice.
    func tryBeginClickOverviewDissolve(toLevel newLevel: Int, anchorContentPoint: CGPoint,
                                       viewportPoint: CGPoint, viewportSize: CGSize) -> CGFloat? {
        let sourceLevel = level
        let targetLevel = engine.clampLevel(newLevel)
        guard abs(sourceLevel - targetLevel) == 1,
              engine.isOverviewBoundary(sourceLevel, targetLevel) else { return nil }
        let sourceScrollY = clipView?.bounds.origin.y ?? 0
        let overscan = budget.overscanFraction * viewportSize.height
        let targetViewportSize = CGSize(width: layoutWidth(forLevel: targetLevel), height: layoutViewportSize.height)
        guard let plan = engine.overviewLayerDissolvePlan(
            from: sourceLevel, to: targetLevel,
            viewportSize: layoutViewportSize, targetViewportSize: targetViewportSize,
            sourceScrollY: sourceScrollY, sourceColumnPhase: currentPhase(),
            preferredNormalMode: preferredNormalLevelContentMode,
            anchorContentPoint: anchorContentPoint, anchorViewportPoint: viewportPoint, overscan: overscan)
        else { return nil }
        overviewDissolve = plan
        renderer.invalidateDissolveLayers()   // new plan → re-raster both layers on the first dissolve frame
        overviewClickDissolveActive = true
        overviewClickDissolveStart = 0
        committedPhase = plan.targetColumnPhase
        level = targetLevel
        requestRedraw()
        return plan.targetScrollY
    }

    private func advanceClickOverviewDissolve(now: CFTimeInterval) -> Double {
        if overviewClickDissolveStart == 0 { overviewClickDissolveStart = now }
        let elapsed = max(0, now - overviewClickDissolveStart)
        let q = overviewClickDissolveDuration > 0 ? min(1, elapsed / overviewClickDissolveDuration) : 1
        if let plan = overviewDissolve { overviewDissolve = plan.withProgress(q) }
        return q
    }

    private func finishClickOverviewDissolve() {
        overviewDissolve = nil
        renderer.endLayerDissolve()   // free the two offscreen dissolve textures; settled render doesn't use them
        overviewClickDissolveActive = false
        overviewClickDissolveStart = 0
        requestRedraw()
    }

    // MARK: - Live pinch single-lattice transition

    /// The contiguous adjacent-step band around the current `level` that is lattice-eligible (every step
    /// `lo→lo+1` is `.focusRowRelayout`). For the normal levels this is `[0, 3]`; an overview start gives a
    /// degenerate band (`lo == hi`) ⇒ the host uses the `GridZoomTransaction` reflow (`transactionReflow`). The host chains within this band.
    func eligiblePinchChainBand() -> (lo: Int, hi: Int) {
        var lo = level, hi = level
        while lo > 0, engine.metrics(level: lo - 1).transitionKindToNext == .focusRowRelayout { lo -= 1 }
        while hi < engine.levelCount - 1, engine.metrics(level: hi).transitionKindToNext == .focusRowRelayout { hi += 1 }
        return (lo, hi)
    }

    /// The presentation frame parameters for one detent in the current gesture: the gesture-START detent keeps
    /// the ACTUAL on-screen (phase, scroll) - so q matches the live screen there and a return lands exactly -
    /// while every OTHER detent is cursor-aligned (anchor pinned under the cursor). Because these are a pure
    /// function of the (fixed) anchor + the detent, ANY two adjacent segments sharing a detent get the IDENTICAL
    /// frame for it ⇒ the inter-segment seam (prev q=1 == next q=0) is exact by construction.
    private func pinchDetentParams(level lv: Int, viewportSize: CGSize) -> (phase: Int?, scrollY: CGFloat) {
        if lv == pinchStartLevel { return (pinchStartPhase, pinchStartScrollY) }
        guard let tx = zoomTransaction else { return (currentPhase(), pinchStartScrollY) }
        let width = layoutWidth
        let col = engine.cursorColumn(viewportX: tx.anchorViewportPoint.x, level: lv, width: width)
        let phase = engine.columnPhase(forItem: tx.anchorGlobalIndex, targetColumn: col, level: lv, width: width)
        let y = engine.anchoredScrollOffset(flatIndex: tx.anchorGlobalIndex, localFraction: tx.anchorLocalFraction,
                                            viewportPoint: tx.anchorViewportPoint, level: lv, width: width, columnPhase: phase).y
        let clampedY = engine.clampScrollOffsetY(y, level: lv, width: width,
                                                 viewportHeight: viewportSize.height, columnPhase: phase)
        return (phase, clampedY)
    }

    /// Build (or rebuild) the `.pinch` plan for one adjacent segment `[source → target]` (source = denser end).
    /// Both detents resolve through `pinchDetentParams`, so a rebuild at a detent crossing is seam-continuous
    /// with the previous segment. NOTHING is committed (level/phase/scroll stay at the gesture-start state; the
    /// actual scroll view stays frozen) - the plan renders the crossfade in viewport space. Returns false ⇒
    /// the host uses the `GridZoomTransaction` reflow (`transactionReflow`) (only happens outside the eligible band).
    func tryBuildPinchSegment(source: Int, target: Int, viewportSize: CGSize) -> Bool {
        guard zoomTransaction != nil else { return false }
        let s = engine.clampLevel(source), t = engine.clampLevel(target)
        guard abs(s - t) == 1 else { return false }
        guard engine.metrics(level: min(s, t)).transitionKindToNext == .focusRowRelayout else { return false }
        let overscan = budget.overscanFraction * viewportSize.height
        let lvp = layoutViewportSize                  // engine + transition plan are layout-space
        let sp = pinchDetentParams(level: s, viewportSize: lvp)
        let tp = pinchDetentParams(level: t, viewportSize: lvp)
        let srcPlan = engine.framePlan(level: s, viewportSize: lvp, scrollOffset: CGPoint(x: 0, y: sp.scrollY),
                                       overscan: overscan, columnPhase: sp.phase)
        let tgtPlan = engine.framePlan(level: t, viewportSize: lvp, scrollOffset: CGPoint(x: 0, y: tp.scrollY),
                                       overscan: overscan, columnPhase: tp.phase)
        guard let tx = zoomTransaction else { return false }
        let began = PhotoPerformanceSignposts.grid.interval("transition.planBuild") {
            gridTransition.beginPinch(source: srcPlan, target: tgtPlan, anchorIndex: tx.anchorGlobalIndex,
                                      viewportSize: lvp, selection: selectedFlatIndices)
        }
        guard began else { return false }
        pinchSegmentSource = s
        pinchSegmentTarget = t
        // Anticipatory prefetch: decode the FULL target-level visible set NOW, at segment build - the decode
        // pipeline then has the entire gesture as head-start, so the target tiles are RAM-resident by commit
        // instead of popping in black afterward (the banded fill). Independent of the per-frame warm pump, which
        // only streams the live crossfade subset (~50-60% of the committed viewport).
        let targetUIDs = tgtPlan.visibleSlots.compactMap { slot -> PhotoUID? in
            let i = slot.index
            return (i >= 0 && i < dataSource.flatUIDs.count) ? dataSource.flatUIDs[i] : nil
        }
        dataSource.prefetchWarm(targetUIDs)
        requestRedraw()
        return true
    }

    /// Drive the active segment's progress (the scrub driver's `segmentQ`). q is authoritative; the plan's
    /// per-component crossfade is a pure function of it (reversible).
    func setPinchProgress(_ q: Double) {
        guard gridTransition.activeKind == .pinch else { return }
        gridTransition.setProgress(q)
        requestRedraw()
    }

    /// Commit the chain to the settled detent `finalLevel` (the level the gesture landed on): adopt that
    /// detent's (phase, scroll), end the plan, clear the transaction. Returns the scroll-Y the host scrolls to
    /// - the settled frame then matches the plan's `finalLevel` endpoint exactly (no seam). For the gesture
    /// START detent this is the actual scroll (a no-op return-to-start). `logPostCommitAnchor` after scrolling.
    @discardableResult
    func commitPinchChain(toLevel finalLevel: Int, viewportSize: CGSize) -> CGFloat {
        let lv = engine.clampLevel(finalLevel)
        let p = pinchDetentParams(level: lv, viewportSize: viewportSize)
        if lv != pinchStartLevel {
            committedPhase = p.phase
            level = lv
        }
        gridTransition.end()
        zoomTransaction = nil
        endPinchTransition()
        requestRedraw()
        return p.scrollY
    }

    /// End the active pinch plan WITHOUT committing a level change, keeping the live `GridZoomTransaction` so
    /// the host can hand off to the `GridZoomTransaction` reflow (`transactionReflow`). Defensive: only reachable if a mid-chain segment build ever
    /// fails (the eligible band guarantees it does not), so this prevents a stranded/frozen plan in that case.
    func abortPinchPlan() {
        gridTransition.end()
        endPinchTransition()
        requestRedraw()
    }

    private func endPinchTransition() {
        pinchSegmentSource = nil
        pinchSegmentTarget = nil
        transitionPrevNow = 0
    }

    // MARK: - Overview layer dissolve

    /// Begin an overview layer dissolve for an overview-boundary step `s→t`. Builds the two SETTLED plans once
    /// (source = the current on-screen grid; target = the adjacent overview, cursor-anchored, square). The live
    /// transaction (captured at gesture start in `beginLiveZoom`) supplies the cursor anchor. Returns false ⇒
    /// caller falls back to the `GridZoomTransaction` reflow (`transactionReflow`). Nothing is committed (scroll stays frozen).
    func beginOverviewDissolve(sourceLevel s: Int, targetLevel t: Int, viewportSize: CGSize) -> Bool {
        guard let tx = zoomTransaction,
              engine.isOverviewBoundary(s, t) else { return false }
        let srcScrollY = clipView?.bounds.origin.y ?? 0
        let overscan = budget.overscanFraction * viewportSize.height
        let cursorContent = CGPoint(x: tx.anchorViewportPoint.x, y: tx.anchorViewportPoint.y + srcScrollY)
        let targetViewportSize = CGSize(width: layoutWidth(forLevel: t), height: layoutViewportSize.height)
        guard let plan = engine.overviewLayerDissolvePlan(
            from: s, to: t, viewportSize: layoutViewportSize, targetViewportSize: targetViewportSize,
            sourceScrollY: srcScrollY, sourceColumnPhase: currentPhase(),
            preferredNormalMode: preferredNormalLevelContentMode,
            anchorContentPoint: cursorContent, anchorViewportPoint: tx.anchorViewportPoint, overscan: overscan)
        else { return false }
        overviewDissolve = plan
        renderer.invalidateDissolveLayers()   // new plan → re-raster both layers on the first dissolve frame
        requestRedraw()
        return true
    }

    /// Update the dissolve progress (0 = source, 1 = target). Rebuilds nothing - only the blend moves.
    func setOverviewDissolveProgress(_ q: Double) {
        guard let d = overviewDissolve else { return }
        overviewDissolve = d.withProgress(q)
        requestRedraw()
    }

    /// Commit the dissolve to source (no change) or target (adopt the target level/phase + anchored scroll).
    /// Returns the scroll-Y to settle at; the settled render then matches the chosen endpoint exactly.
    @discardableResult
    func commitOverviewDissolve(toTarget: Bool, viewportSize: CGSize) -> CGFloat {
        let srcScrollY = clipView?.bounds.origin.y ?? 0
        guard let d = overviewDissolve else { return srcScrollY }
        let scrollY: CGFloat
        if toTarget {
            committedPhase = d.targetColumnPhase
            level = d.targetLevel
            scrollY = d.targetScrollY
        } else {
            scrollY = srcScrollY
        }
        overviewDissolve = nil
        renderer.endLayerDissolve()   // free the two offscreen dissolve textures; settled render doesn't use them
        overviewClickDissolveActive = false
        overviewClickDissolveStart = 0
        zoomTransaction = nil
        requestRedraw()
        return scrollY
    }

    /// Render the active dissolve: build each layer's settled groups (source keeps its mode; target square),
    /// stream both layers' textures, and hand them to the offscreen compositor as `mix(source, target, ease(q))`.
    private func drawOverviewDissolve(in view: MTKView, plan: OverviewLayerDissolvePlan, viewportSize: CGSize, now: CFTimeInterval) {
        let flatUIDs = dataSource.flatUIDs
        let srcSlots = renderTranslate(plan.source.visibleSlots.map { GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect) })
        // Target layer → its OWN settled bounds, so the L3↔L4 gap pinches continuously and the commit never pops.
        let tgtSlots = mapDissolveTargetLayer(
            plan.target.visibleSlots.map { GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect) },
            targetBounds: renderBounds(forLevel: plan.targetLevel)
        )
        var uids: [PhotoUID] = []
        for s in srcSlots where s.index < flatUIDs.count { uids.append(flatUIDs[s.index]) }
        for s in tgtSlots where s.index < flatUIDs.count { uids.append(flatUIDs[s.index]) }
        // Content-arrival detection: re-raster a frozen layer ONLY when one of its wanted thumbnails becomes
        // resident this frame (its resident-slot count changes). A steady scrub streams nothing new → both
        // counts hold → the renderer reuses both cached offscreen layers and its group closures never run, so
        // the frame pays only the fullscreen composite. (First frame / resize / new-plan re-raster is forced
        // inside the renderer via the layer cache; the closures still supply the groups when it does.)
        let srcResidentBefore = residentSlotCount(srcSlots, flatUIDs: flatUIDs)
        let tgtResidentBefore = residentSlotCount(tgtSlots, flatUIDs: flatUIDs)
        streamTextures(visibleUIDs: uids, overscanUIDs: [])
        let srcResidentAfter = residentSlotCount(srcSlots, flatUIDs: flatUIDs)
        let tgtResidentAfter = residentSlotCount(tgtSlots, flatUIDs: flatUIDs)
        evictTexturesToBudget()
        PhotoPerformanceSignposts.grid.interval("dissolve.layerPass") {
            renderer.renderLayerDissolve(
                in: view, viewportSize: viewportSize,
                redrawSource: srcResidentAfter != srcResidentBefore,
                redrawTarget: tgtResidentAfter != tgtResidentBefore,
                sourceGroups: {
                    PhotoPerformanceSignposts.grid.interval("buildRealGroups") {
                        buildRealGroups(slots: srcSlots, flatUIDs: flatUIDs, viewportSize: viewportSize, displayMode: plan.sourceDisplayMode).0
                    }
                },
                targetGroups: {
                    PhotoPerformanceSignposts.grid.interval("buildRealGroups") {
                        buildRealGroups(slots: tgtSlots, flatUIDs: flatUIDs, viewportSize: viewportSize, displayMode: plan.targetDisplayMode).0
                    }
                },
                t: Float(plan.targetOpacity))
        }
        hasPendingVisibleThumbnails = !cache.residencySaturatedThisFrame && hasRetryableMissingVisibleTexture(uids)
        publishLightDiagnostics(phase: "overviewDissolve", visibleCount: uids.count, overscanCount: 0,
                                realCount: srcResidentAfter + tgtResidentAfter,
                                cellCount: srcSlots.count + tgtSlots.count,
                                visibleRect: CGRect(origin: .zero, size: viewportSize),
                                contentSize: engine.contentSize(level: plan.targetLevel, width: layoutWidth,
                                                                columnPhase: plan.targetColumnPhase), now: now)
    }

    private func drawTransition(in view: MTKView, viewportSize: CGSize, now: CFTimeInterval) {
        let draws = gridTransition.currentDraws()
        let flatUIDs = dataSource.flatUIDs
        // stream textures for the union of source+target occupants currently drawn
        var uids: [PhotoUID] = []
        for d in draws where d.index < flatUIDs.count { uids.append(flatUIDs[d.index]) }
        streamTextures(visibleUIDs: uids, overscanUIDs: [])
        let realCount = renderTransitionDraws(in: view, draws: draws, flatUIDs: flatUIDs, viewportSize: viewportSize)
        publishLightDiagnostics(phase: "transition", visibleCount: uids.count, overscanCount: 0,
                                realCount: realCount, cellCount: draws.count,
                                visibleRect: CGRect(origin: .zero, size: viewportSize),
                                contentSize: engine.contentSize(level: level, width: layoutWidth, columnPhase: currentPhase()),
                                now: now)
    }

    /// Full-slot mix render (no global/full-screen crossfade). `GridTransitionRendererInput` already
    /// encodes the correct per-draw alpha for the renderer's premultiplied source-over blend: a mixed
    /// source↔target dissolve emits an OPAQUE source draw (alpha 1) followed by a target draw at alpha
    /// lp, so source-over composites to src·(1-lp)+tgt·lp; single-sided background dissolves stay
    /// translucent and fade against the background.
    ///
    /// ONE uniform background: like the settled path's resident tiles, transition tiles are drawn
    /// DIRECTLY on the render pass's clear colour (`MetalGridPalette.clearColor`) - NO per-slot
    /// background card. So gaps, aspectFit letterbox, and a tile fading to/from background all show the
    /// single constant grid surface (a per-slot placeholder card here gave a mismatched colour during
    /// the animation). Reuses the texture cache + TileContentFitter; geometry comes from the plan.
    @discardableResult
    private func renderTransitionDraws(in view: MTKView, draws: [GridTransitionDraw], flatUIDs: [PhotoUID],
                                       viewportSize: CGSize) -> Int {
        let cardRadius = Float(GridVisualConstants.thumbnailCornerRadius)
        let displayMode = effectiveDisplayMode
        var images: [MetalGridQuad] = []
        var imageTextures: [MTLTexture] = []
        for d in draws where d.index < flatUIDs.count {
            let cell = d.rect.offsetBy(dx: leadingObstructionInset, dy: 0)   // layout-space draw → render space (chokepoint)
            let uid = flatUIDs[d.index]
            guard cache.isResident(uid) else { continue }   // not-yet-loaded tile ⇒ show the clear surface
            cache.noteUsed(uid)
            let texture = cache.texture(for: uid)
            let fit = TileContentFitter.fit(slotRect: cell,
                                            mediaPixelSize: CGSize(width: texture.width, height: texture.height),
                                            displayMode: displayMode)
            images.append(MetalGridQuad(rect: fit.contentRect, uvMin: fit.uvMin, uvMax: fit.uvMax,
                                        radius: cellRadius(cardRadius, cell: cell),
                                        alpha: Float(max(0, min(1, d.alpha)))))
            imageTextures.append(texture)
        }
        evictTexturesToBudget()
        renderer.render(in: view, viewportSize: viewportSize, groups: [
            MetalGridRenderGroup(source: .perQuadTexture(imageTextures), quads: images),
        ])
        return images.count
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
        // Built in LAYOUT space (engine), then translated +inset to render space (the bridge draw chokepoint).
        let slots = renderTranslate(GridZoomCommitBridge.frame(transaction: tx, engine: engine, targetLevel: bridgeLevel,
                                               viewportSize: layoutViewportSize, scrollY: bridgeScrollY,
                                               overscan: overscan, progress: commitBridgeProgress, columnPhase: currentPhase()))
        let settledContentSize = engine.contentSize(level: bridgeLevel, width: layoutWidth, columnPhase: currentPhase())
        let flatUIDs = dataSource.flatUIDs
        let (visibleUIDs, overscanUIDs) = MetalGridFrameComposer.classifyVisibility(
            slots: slots, flatUIDs: flatUIDs, viewportSize: viewportSize)
        streamTextures(visibleUIDs: visibleUIDs, overscanUIDs: overscanUIDs)
        let realCount = renderRealSlots(in: view, slots: Self.viewportDrawSlots(slots, viewportSize: viewportSize),
                                        flatUIDs: flatUIDs, viewportSize: viewportSize)
        hasPendingVisibleThumbnails = !cache.residencySaturatedThisFrame && hasRetryableMissingVisibleTexture(visibleUIDs)
        publishLightDiagnostics(phase: "commitBridge", visibleCount: visibleUIDs.count,
                                overscanCount: overscanUIDs.count, realCount: realCount, cellCount: slots.count,
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
            // to the anchor under the cursor - NOT a per-frame stateless re-resolve - so the row under the
            // cursor keeps its photos (zoom-in drops edge neighbours, zoom-out adds them), never re-wrapping.
            let frame = tx.frame(continuousLevel: zoomTransactionLevel, viewportSize: layoutViewportSize, overscan: overscan)
            slots = renderTranslate(frame.visibleSlots)               // layout-space frame → render space (chokepoint)
            contentSizeForDiag = CGSize(width: layoutWidth, height: frame.pitch * CGFloat(max(1, slots.count / max(frame.columns, 1))))
            #if DEBUG
            if now - lastCommitFrameLog > 0.1 {        // ~10 Hz: trace the live focus row + anchor rect (DEBUG only;
                lastCommitFrameLog = now               // the diagnostic builds a payload string, so keep it out of release)
                let anchorRect = frame.visibleSlots.first { $0.index == tx.anchorGlobalIndex }?.rect ?? .zero
                GridZoomCommitLog.frame(progress: zoomTransactionLevel, anchorViewportRect: anchorRect,
                                        focusRow: frame.focusRow, focusRowStable: frame.focusRow.contains(tx.anchorGlobalIndex))
            }
            #endif
        } else {
            // SETTLED: render exactly at the native NSScrollView origin. During trackpad edge rubber-band,
            // AppKit intentionally reports a temporarily out-of-range clip origin; do NOT clamp it here and do
            // NOT programmatically scroll the clip view from the draw path, or we fight the native elasticity
            // and create a second snap-back. Explicit zoom/overview commits arm `rebaseActive` themselves when
            // they need a short camera correction after a content-size change.
            let phase = currentPhase()
            let rawOrigin = clip.bounds.origin
            // The Y the grid actually RENDERS at: normally the native clip origin (including elastic
            // overscroll), or an explicitly-armed rebase interpolation after a zoom/overview commit.
            let renderY: CGFloat
            if rebaseActive {
                let p = GridScrollRebase.progress(start: rebaseStart, now: now)
                renderY = GridScrollRebase.scrollY(fromY: rebaseFromY, toY: rebaseToY, progress: p)
                if p >= 1 { rebaseActive = false }                 // settled exactly at toY this frame
            } else {
                renderY = rawOrigin.y
            }
            let plan = PhotoPerformanceSignposts.grid.interval("framePlan") {
                engine.framePlan(level: level, viewportSize: layoutViewportSize,
                                 scrollOffset: CGPoint(x: rawOrigin.x, y: renderY), overscan: overscan, columnPhase: phase)
            }
            slots = renderTranslate(plan.visibleSlots.map { GridRenderSlot(index: $0.index, column: $0.column, row: $0.row, rect: $0.viewportRect) })
            contentSizeForDiag = plan.contentSize
        }

        let flatUIDs = dataSource.flatUIDs
        let (visibleUIDs, overscanUIDs) = MetalGridFrameComposer.classifyVisibility(
            slots: slots, flatUIDs: flatUIDs, viewportSize: viewportSize)
        // Fully settled (no live focus-row transaction) → allow the soft→sharp upgrade of carried-over textures.
        let pendingVisibleQualityUpgrade = streamTextures(visibleUIDs: visibleUIDs, overscanUIDs: overscanUIDs,
                                                          allowUpgrade: zoomTransaction == nil)
        let realCount = renderRealSlots(in: view, slots: Self.viewportDrawSlots(slots, viewportSize: viewportSize),
                                        flatUIDs: flatUIDs, viewportSize: viewportSize)
        // Keep ticking while a visible cell is still a placeholder OR a resident texture is mid-upgrade (a
        // budget-deferred soft→sharp grow), so both finish on an otherwise-idle grid. Residency-saturated
        // frames stay forced-idle: those placeholders can only fill on a window change, which redraws anyway.
        hasPendingVisibleThumbnails = !cache.residencySaturatedThisFrame
            && (pendingVisibleQualityUpgrade || hasRetryableMissingVisibleTexture(visibleUIDs))
        publishLightDiagnostics(phase: zoomTransaction == nil ? "settled" : "liveZoom",
                                visibleCount: visibleUIDs.count, overscanCount: overscanUIDs.count,
                                realCount: realCount, cellCount: slots.count,
                                visibleRect: CGRect(origin: clip.bounds.origin, size: viewportSize),
                                contentSize: contentSizeForDiag, now: now)
    }

    /// Real thumbnails: resident images are cover-filled INSIDE the square slot (aspect only via the UV window
    /// - never changes the slot), directly over the single uniform grid background, plus production decorations.
    /// Missing thumbnails draw nothing, so the bottom-most clear surface remains one continuous field.
    nonisolated static func viewportDrawSlots(_ slots: [GridRenderSlot], viewportSize: CGSize) -> [GridRenderSlot] {
        MetalGridFrameComposer.viewportDrawSlots(slots, viewportSize: viewportSize)
    }

    @discardableResult
    private func renderRealSlots(in view: MTKView, slots: [GridRenderSlot], flatUIDs: [PhotoUID], viewportSize: CGSize) -> Int {
        let (groups, realCount) = PhotoPerformanceSignposts.grid.interval("buildRealGroups") {
            buildRealGroups(slots: slots, flatUIDs: flatUIDs, viewportSize: viewportSize,
                            displayMode: effectiveDisplayMode)
        }
        evictTexturesToBudget()
        renderer.render(in: view, viewportSize: viewportSize, groups: groups)
        return realCount
    }

    /// Build the settled-grid render groups for a set of slots at an EXPLICIT display mode (the canonical
    /// settled appearance: rounded thumbnail cover-fit on the uniform bg + production decorations). Shared by
    /// `renderRealSlots` (settled, `effectiveDisplayMode`) and the overview layer dissolve (each layer with its
    /// OWN mode). Pure builder - no eviction, no draw. Returns (groups, resident-texture count).
    private func buildRealGroups(slots: [GridRenderSlot], flatUIDs: [PhotoUID], viewportSize: CGSize,
                                 displayMode: TileContentDisplayMode) -> (groups: [MetalGridRenderGroup], realCount: Int) {
        // Delegates to the universal `MetalGridFrameComposer` (shared with the iOS host). Production decorations
        // are injected as neutral data; the native AppKit accent colour is converted at this adapter edge - a
        // SIMD vector for the selection outline, `MetalGridGlyphColor(.controlAccentColor)` for the checkmark
        // glyph. NO per-cell card: the rounded thumbnail sits directly on the uniform background, so gaps +
        // aspectFit letterbox reveal the same surface. Pure builder - no eviction, no draw.
        let decorations = decorationsEnabled ? MetalGridDecorations<PhotoUID>(
            accent: Self.colorVector(.controlAccentColor),
            accentGlyphColor: MetalGridGlyphColor(.controlAccentColor),
            selectionMode: selectionMode,
            selected: selectedUIDs,
            favorites: favoriteUIDs,
            isVideo: { [dataSource] uid in dataSource.isVideo(uid) }
        ) : nil
        return MetalGridFrameComposer.buildGroups(
            slots: slots, flatUIDs: flatUIDs, cache: cache,
            displayMode: displayMode, cornerRadius: GridVisualConstants.thumbnailCornerRadius,
            decorations: decorations
        )
    }

    private static func colorVector(_ color: NSColor) -> SIMD4<Float> {
        let c = color.usingColorSpace(.sRGB) ?? color
        return SIMD4(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), Float(c.alphaComponent))
    }

}

// MARK: - Canonical render helpers (shared by the engine draw path)

extension MetalGridCoordinator {

    /// Clamp the card corner radius so it never exceeds half the (square) slot - keeps tiny dense cells round.
    private func cellRadius(_ base: Float, cell: CGRect) -> Float {
        min(base, Float(min(cell.width, cell.height) * 0.5))
    }

    // MARK: Texture streaming (visible-first upload + off-main warm)

    private func hasRetryableMissingVisibleTexture(_ uids: [PhotoUID]) -> Bool {
        uids.contains { !cache.isResident($0) && dataSource.canRetryThumbnail(for: $0) }
    }

    @discardableResult
    private func streamTextures(visibleUIDs: [PhotoUID], overscanUIDs: [PhotoUID], allowUpgrade: Bool = false) -> Bool {
        // The settled streaming sequence - level-aware effective-pixel cap (set BEFORE `maxSafePinnedCount`,
        // so dense levels pin more cheap textures), visible-first window + byte-budget pin clamp, `beginFrame`,
        // visible upload, soft→sharp upgrade, and warm selection - is single-sourced in `MetalGridFrameComposer`
        // so iOS and macOS stream identically. This host supplies only the platform inputs: the upload size, the
        // cold-visible pin policy, the warm PUMP (`dataSource.warm`), and the cold-start `[FirstContent]` trace.
        // While visible items are still missing, overscan stays uploadable/warmable but evictable (pinOverscan
        // false), so already-resident overscan cannot occupy the pinned byte floor and starve newly visible ones.
        let pinOverscan = visibleUIDs.allSatisfy { cache.isResident($0) || !dataSource.canRetryThumbnail(for: $0) }
        let result = MetalGridFrameComposer.stream(
            cache: cache,
            visibleIDs: visibleUIDs,
            overscanIDs: overscanUIDs,
            pinOverscan: pinOverscan,
            effectiveUploadPixels: effectiveUploadPixels(),
            allowUpgrade: allowUpgrade,
            hasImage: { [dataSource] uid in dataSource.hasImage(for: uid) },
            canRetry: { [dataSource] uid in dataSource.canRetryThumbnail(for: uid) },
            provideImage: { [dataSource] uid in dataSource.image(for: uid) },
            signposts: composeSignposts
        )
        let pendingVisibleQualityUpgrade = result.pendingVisibleQualityUpgrade
        if !result.warm.isEmpty { dataSource.warm(result.warm) }
        // Cold-start latency trace: mark the first on-screen frame that has real visible cells, then measure how
        // long until they are resident. One-shot, DEBUG-only sink; grep `[FirstContent]`.
        if !firstContentTraced, !visibleUIDs.isEmpty {
            firstContentTraced = true
            firstGridFrameAt = CACurrentMediaTime()
            let missing = visibleUIDs.reduce(into: 0) { $0 += cache.isResident($1) ? 0 : 1 }
            PhotoDiagnostics.shared.emit("FirstContent", [
                "event": "gridFrame", "visible": "\(visibleUIDs.count)", "missing": "\(missing)",
                "resident": "\(visibleUIDs.count - missing)", "level": "\(level)", "phase": "coldStart",
            ])
        }
        // First fully-populated on-screen frame (every VISIBLE cell uploaded, just now via `uploadVisible`) →
        // tell the shell to lift the launch veil. One-shot; `allSatisfy` short-circuits on the first miss.
        if !firstContentReported, !visibleUIDs.isEmpty,
           visibleUIDs.allSatisfy({ cache.isResident($0) || !dataSource.canRetryThumbnail(for: $0) }) {
            firstContentReported = true
            let elapsedMs = firstGridFrameAt > 0 ? (CACurrentMediaTime() - firstGridFrameAt) * 1000 : 0
            let resident = visibleUIDs.reduce(into: 0) { $0 += cache.isResident($1) ? 1 : 0 }
            PhotoDiagnostics.shared.emit("FirstContent", [
                "event": "ready", "visible": "\(visibleUIDs.count)", "resident": "\(resident)",
                "elapsedMs": String(format: "%.0f", elapsedMs), "level": "\(level)", "phase": "coldStart",
            ])
            onFirstContentReady?()
        }
        return pendingVisibleQualityUpgrade
    }

    private func evictTexturesToBudget() {
        PhotoPerformanceSignposts.grid.interval("evictToBudget") {
            cache.evictToBudget()
        }
    }

    private func publishLightDiagnostics(phase: String, visibleCount: Int, overscanCount: Int, realCount: Int,
                                         cellCount: Int, visibleRect: CGRect, contentSize: CGSize, now: CFTimeInterval) {
        guard now - lastHUDPushDetent > 0.1 else { return }
        lastHUDPushDetent = now
        let stats = MetalGridStats.frame(
            visibleCount: visibleCount,
            overscanCount: overscanCount,
            realCount: realCount,
            cellCount: cellCount,
            textureUploads: cache.uploadsThisFrame,
            textureUploadBytes: cache.uploadBytesThisFrame,
            deferredTextureUploads: cache.deferredUploadsThisFrame,
            textureUploadMs: cache.uploadMsThisFrame,
            evictions: cache.evictionsThisFrame,
            evictMs: cache.evictMsThisFrame,
            residentBytes: cache.residentBytes,
            residentTextureCount: cache.residentCount,
            pinnedTextureCount: cache.pinnedCount,
            textureCapacity: cache.residencyCapacity,
            pinnedTextureOverflow: cache.pinnedOverflow,
            residentByteBudget: cache.residentByteBudget,
            uploadByteBudget: cache.uploadByteBudgetPerFrame,
            byteBudgetOverflow: cache.byteBudgetOverflow,
            residencySaturated: cache.residencySaturatedThisFrame,
            drawCalls: renderer.lastDrawCalls,
            textureBinds: renderer.lastTextureBinds,
            instanceCount: renderer.lastInstanceCount,
            drawMs: renderer.lastEncodeMs,
            gpuMs: renderer.lastGpuMs
        )
        var hud = MetalGridHUD()
        hud.stats = stats
        hud.level = level
        hud.totalItems = totalItems
        hud.dataSource = dataSource.label
        onHUD?(hud)
        guard now - lastPerfDiagnosticsLog >= 0.5 else { return }
        lastPerfDiagnosticsLog = now
        PhotoDiagnostics.shared.emit("MetalGridPerf", [
            "phase": phase,
            "level": "\(level)",
            "visible": "\(stats.visibleItems)",
            "overscan": "\(stats.overscanItems)",
            "real": "\(stats.realTextureItems)",
            "placeholder": "\(stats.placeholderItems)",
            "drawCalls": "\(stats.drawCalls)",
            "textureBinds": "\(stats.textureBinds)",
            "instances": "\(stats.instanceCount)",
            "drawMs": String(format: "%.2f", stats.drawMs),
            "gpuMs": String(format: "%.2f", stats.gpuMs),
            "uploads": "\(stats.textureUploads)",
            "uploadBytes": "\(stats.textureUploadBytes)",
            "deferredUploads": "\(stats.deferredTextureUploads)",
            "uploadMs": String(format: "%.2f", stats.textureUploadMs),
            "evictions": "\(stats.evictions)",
            "evictMs": String(format: "%.2f", stats.evictMs),
            "residentTextures": "\(stats.residentTextureCount)",
            "pinnedTextures": "\(stats.pinnedTextureCount)",
            "textureCapacity": "\(stats.textureCapacity)",
            "pinnedOverflow": "\(stats.pinnedTextureOverflow)",
            "encodedSlots": "\(stats.encodedSlotItems)",
            "residentMB": String(format: "%.2f", Double(stats.memoryEstimateBytes) / 1_048_576),
            "residentBudgetMB": String(format: "%.0f", Double(stats.residentByteBudget) / 1_048_576),
            "uploadBudgetBytes": "\(stats.uploadByteBudget)",
            "byteBudgetOverflow": "\(stats.byteBudgetOverflow)",
            "residencySaturated": "\(stats.residencySaturated)",
            "effectivePixels": "\(cache.effectiveMaxTexturePixels)",
            "upgrades": "\(cache.upgradesThisFrame)",
            "directUploads": "\(cache.directUploadsThisFrame)",
            "normalizedUploads": "\(cache.normalizedUploadsThisFrame)",
        ])
    }

}
