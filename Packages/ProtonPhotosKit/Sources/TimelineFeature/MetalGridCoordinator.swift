import AppKit
import MetalKit
import CoreGraphics
import simd
import PhotosCore

/// Bridges scroll position + layout + texture cache + renderer for the Metal grid lab. It is the
/// `MTKView` delegate: every frame it reads the clip view's scroll origin, queries the visible item
/// rects from `MetalGridLayout`, uploads a bounded number of newly-available thumbnails, draws the
/// viewport, and emits diagnostics. Only items intersecting the (overscan-expanded) visible rect are
/// ever touched — never all 20k.
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
            if level != oldValue { cachedDetent = nil; onContentSizeChange?(contentSize()) }
        }
    }

    // MARK: - Zoom mode (Option A: detent-only foundation)

    /// FALSE on purpose. A continuous fractional pinch would re-resolve the grid every frame — changing
    /// `columnCount` and rewrapping every flat index, which shuffles the items at every screen position
    /// (the "jumps to unrelated index regions" failure). Until live pinch is rebuilt as an engine-owned
    /// `GridZoomTransaction` (Option B), the production grid is DETENT-ONLY: it renders only settled
    /// integer-level `GridFramePlan`s, and the pinch maps to discrete, anchor-preserving level steps (the
    /// `PinchStepDetector` path in the host) — stable static/discrete geometry over a broken live pinch.
    let usesDetentZoom = false
    let detentModel = GridZoomDetentModel.apple

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
    /// The production grid is engine-only. (Stored, not a literal, so the retained legacy draw paths below
    /// stay compiled-but-unreachable without a dead-code warning, pending their deletion.)
    private let useCanonicalEngine = true

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

    /// The persistent view anchor (item + the viewport point it was last zoomed toward). Drives the settled
    /// grid's COLUMN PHASE so, after a live-zoom commit (or a +/- step), the focus item keeps its cursor
    /// column — the settled grid matches where the live transaction left things (seamless commit, no rephase
    /// jump). Single continuous run only; nil = the default bottom-right wrap.
    private var viewAnchor: (globalIndex: Int, viewportPoint: CGPoint, localFraction: CGPoint)?

    /// The column phase for the settled grid. DISABLED (always nil → the default BOTTOM-RIGHT wrap, newest in
    /// the corner). A cursor-aligned phase would keep the focus item's column on a live-zoom commit (seamless),
    /// but it is INCOMPATIBLE with bottom-right anchoring — it moves the partial row to the bottom-right
    /// (black there) and breaks "newest bottom-right". The real release jump is fixed in the host's scroll
    /// lock, so the phase is not needed; making the commit's residual horizontal rephase smooth is a future
    /// settle-animation step, not a phase. (`viewAnchor` + the engine's `columnPhase` support stay for that.)
    private func currentPhase(level lv: Int, width: CGFloat) -> Int? {
        _ = (viewAnchor, lv, width)
        return nil
    }
    private func currentPhase() -> Int? {
        currentPhase(level: level, width: metalView?.bounds.width ?? clipView?.bounds.width ?? 0)
    }

    /// Per-section item aspect ratios (w/h) for the justified levels, fed from the `AspectRegistry`.
    private var sectionAspects: [[CGFloat]] = []
    private var aspectVersion = 0
    private var cachedDetent: (level: Int, width: CGFloat, version: Int, layout: GridDetentLayout)?
    // Per-gesture memo of detent layouts by level (justified composition is O(N) — never rebuild per frame).
    private var memoWidth: CGFloat = 0
    private var memoVersion = -1
    private var memoLayouts: [Int: GridDetentLayout] = [:]
    /// Active pinch/button zoom transition (nil = settled on a single detent).
    private(set) var zoomSession: ZoomSession?
    /// True only while the post-release SETTLE animation runs.
    var isZoomSettling = false
    /// The detent the release-settle is heading to (the snap target) — the base grid cross-dissolves into it.
    var settleTargetLevel: Int?
    /// Release-settle crossfade progress 0→1 (base → snap target). Driven by the settle animation so the
    /// re-align ramps smoothly from 0 instead of popping in at the release position. 0 during the live drag.
    var settleCrossfade: CGFloat = 0

    // ── Geometric-scale zoom (gummiband) + release re-align ─────────────────────────────────────────────
    /// The detent currently shown. Held for the gesture; reset to the committed level on commit.
    private var displayedLevel = 0
    /// The release re-align overlay fade rendered last frame (0→1) — the settle continues from it.
    private var lastZoomFade: Float = 0

    /// One in-flight zoom gesture. Scroll is frozen at `scrollOriginY`; the anchor item is held under
    /// `anchorScreen` (viewport coords) while the two detent surfaces scale + crossfade around it.
    struct ZoomSession: Equatable {
        var baseLevel: Int
        var levelPosition: CGFloat
        var anchorScreen: CGPoint
        var anchorContentBase: CGPoint
        var anchorFlatIndex: Int?
        /// The cursor's UNIT position within the anchor item's cell (0…1). Keeping the same relative spot of
        /// the same photo under the cursor in every layout is what makes the anchor feel rock-solid (and
        /// avoids a pop at progress 0, where source == the settled grid).
        var anchorRelInCell: CGPoint
        var anchorYFraction: CGFloat
        var scrollOriginY: CGFloat
    }

    /// Build (uncached) the detent layout for an arbitrary level.
    func detentLayout(level lv: Int, width: CGFloat) -> GridDetentLayout {
        GridDetentLayout(detent: detentModel.detent(lv), width: width,
                         sectionCounts: dataSource.sectionCounts, sectionAspects: sectionAspects)
    }

    /// Memoized detent layout by level (cleared on width / aspect / dataset change). Used during the
    /// transition so a justified surface's O(N) composition is built once per gesture, never per frame.
    func detentLayoutMemo(level lv: Int, width: CGFloat) -> GridDetentLayout {
        if memoWidth != width || memoVersion != aspectVersion { memoLayouts.removeAll(keepingCapacity: true); memoWidth = width; memoVersion = aspectVersion }
        if let l = memoLayouts[lv] { return l }
        let l = detentLayout(level: lv, width: width)
        memoLayouts[lv] = l
        return l
    }

    /// The cached detent layout for the committed level/width/aspect-version (rebuilt only on change).
    func currentDetentLayout(width: CGFloat) -> GridDetentLayout {
        if let c = cachedDetent, c.level == level, c.width == width, c.version == aspectVersion { return c.layout }
        let l = detentLayout(level: level, width: width)
        cachedDetent = (level, width, aspectVersion, l)
        return l
    }

    /// Push per-section aspect ratios (from the AspectRegistry). Recomposes the justified levels.
    func setSectionAspects(_ aspects: [[CGFloat]]) {
        guard usesDetentZoom, aspects != sectionAspects else { return }
        sectionAspects = aspects
        aspectVersion &+= 1
        cachedDetent = nil
        onContentSizeChange?(contentSize())
        requestRedraw()
    }

    /// Pushed (throttled) so the SwiftUI HUD can mirror live stats.
    var onHUD: ((MetalGridHUD) -> Void)?
    /// Called when the content size changes (level / width) so the host can resize the document view.
    var onContentSizeChange: ((CGSize) -> Void)?

    // Diagnostics state
    private var frameTimestamps: [CFTimeInterval] = []
    private var lastOriginY: CGFloat = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var velocity: CGFloat = 0
    private var lastHUDPush: CFTimeInterval = 0
    private var lastHUDPushDetent: CFTimeInterval = 0
    private var lastLog: CFTimeInterval = 0
    private var totalUploads = 0

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
        viewAnchor = nil                          // a stale anchor index could point past the new data
        cachedDetent = nil
        memoLayouts.removeAll(keepingCapacity: true)
        memoVersion = -1
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
        zoomTransaction = engine.beginZoomTransaction(cursorContentPoint: cursorContentPoint,
                                                      viewportPoint: viewportPoint, level: level, width: width,
                                                      columnPhase: currentPhase(level: level, width: width))
        zoomTransactionLevel = CGFloat(level)
        requestRedraw()
    }

    /// Update the live continuous level position (fractional = mid-pinch).
    func updateLiveZoom(continuousLevel x: CGFloat) {
        guard zoomTransaction != nil else { return }
        zoomTransactionLevel = min(max(x, 0), CGFloat(engine.levelCount - 1))
        requestRedraw()
    }

    /// The settled scroll Y that keeps the live anchor under the cursor at `finalLevel`, AND latches the view
    /// anchor so the settled grid adopts the live transaction's column phase (seamless commit — no rephase
    /// jump). The host scrolls there after committing. nil if no transaction.
    func liveZoomCommitScrollOffsetY(finalLevel: Int) -> CGFloat? {
        guard let tx = zoomTransaction else { return nil }
        let width = metalView?.bounds.width ?? clipView?.bounds.width ?? 1
        viewAnchor = (tx.anchorGlobalIndex, tx.anchorViewportPoint, tx.anchorLocalFraction)
        let phase = currentPhase(level: finalLevel, width: width)
        return engine.anchoredScrollOffset(flatIndex: tx.anchorGlobalIndex, localFraction: tx.anchorLocalFraction,
                                           viewportPoint: tx.anchorViewportPoint, level: finalLevel, width: width, columnPhase: phase).y
    }

    /// Commit the live zoom to a settled detent and clear the transaction (didSet recomputes content size).
    func commitLiveZoom(finalLevel: Int) {
        zoomTransaction = nil
        level = engine.clampLevel(finalLevel)
        requestRedraw()
    }

    func cancelLiveZoom() { zoomTransaction = nil; requestRedraw() }

    /// A discrete +/- (or programmatic) level change that keeps the item under `anchorContentPoint` at the
    /// same viewport point AND latches the view anchor / column phase (so +/- is seamless with the phased
    /// grid too). Returns the scroll Y to apply; nil if no item resolvable.
    func settleScrollOffsetY(toLevel newLevel: Int, anchorContentPoint: CGPoint, viewportPoint: CGPoint) -> CGFloat? {
        let width = metalView?.bounds.width ?? clipView?.bounds.width ?? 1
        guard let a = engine.anchorItem(nearContentPoint: anchorContentPoint, level: level, width: width,
                                        columnPhase: currentPhase(level: level, width: width)) else {
            level = engine.clampLevel(newLevel); return nil
        }
        viewAnchor = (a.flatIndex, viewportPoint, a.localFraction)
        level = engine.clampLevel(newLevel)
        let phase = currentPhase(level: level, width: width)
        return engine.anchoredScrollOffset(flatIndex: a.flatIndex, localFraction: a.localFraction,
                                           viewportPoint: viewportPoint, level: level, width: width, columnPhase: phase).y
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

    /// Layout at the current width/level. Width comes from the metal view (== document/clip width).
    func currentLayout(width: CGFloat) -> MetalGridLayout {
        MetalGridLayout.forLevel(level, sectionCounts: dataSource.sectionCounts, width: width)
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

        // CANONICAL PATH: input → engine → GridFramePlan → renderer draws exactly that plan. The legacy
        // detent/two-surface (`drawDetent`) and square (`MetalGridLayout`, below) paths are retained but
        // unreachable until the engine is signed off, then deleted.
        if useCanonicalEngine {
            drawEngineFrame(in: view, clip: clip, viewportSize: viewportSize, now: now)
            return
        }

        if usesDetentZoom {
            drawDetent(in: view, clip: clip, viewportSize: viewportSize, now: now)
            return
        }

        // ---- Layout pass ----
        let layoutStart = CFAbsoluteTimeGetCurrent()
        let visibleOrigin = clip.bounds.origin
        let visibleRect = CGRect(origin: visibleOrigin, size: viewportSize)
        let layout = currentLayout(width: viewportSize.width)
        let overscan = budget.overscanFraction * viewportSize.height
        let overscanRect = MetalGridGeometry.overscanRect(visibleRect: visibleRect, overscan: overscan, contentHeight: layout.contentHeight)
        let cells = layout.visibleCells(in: overscanRect)
        let cpuLayoutMs = (CFAbsoluteTimeGetCurrent() - layoutStart) * 1000

        // Split into visible (pinned) and overscan, preserving priority order (visible first).
        var visibleUIDs: [PhotoUID] = []
        var overscanUIDs: [PhotoUID] = []
        let flatUIDs = dataSource.flatUIDs
        for c in cells where c.flatIndex < flatUIDs.count {
            if c.rect.intersects(visibleRect) { visibleUIDs.append(flatUIDs[c.flatIndex]) }
            else { overscanUIDs.append(flatUIDs[c.flatIndex]) }
        }
        cache.beginFrame(pinned: Set(visibleUIDs))
        let priorityOrder = visibleUIDs + overscanUIDs

        // ---- Upload pass (bounded, visible-first) ----
        var wanted: [PhotoUID] = []
        for uid in priorityOrder where !cache.isResident(uid) && dataSource.hasImage(for: uid) { wanted.append(uid) }
        cache.uploadVisible(wanted: wanted) { [dataSource] uid in dataSource.image(for: uid) }
        totalUploads += cache.uploadsThisFrame

        // ---- Warm pass (still-missing → prime RAM off-main) ----
        var warm: [PhotoUID] = []
        for uid in priorityOrder where !cache.isResident(uid) && !cache.isInFlight(uid) && !dataSource.hasImage(for: uid) { warm.append(uid) }
        if !warm.isEmpty { dataSource.warm(warm) }

        // ---- Instance build pass ----
        let instanceStart = CFAbsoluteTimeGetCurrent()
        var backgrounds: [MetalGridQuad] = []
        var images: [MetalGridQuad] = []
        var imageTextures: [MTLTexture] = []
        // Decoration quads (production only — all empty in the lab, where `decorationsEnabled` is false).
        var outlineQuads: [MetalGridQuad] = []
        var favoriteQuads: [MetalGridQuad] = []
        var checkFilledQuads: [MetalGridQuad] = []
        var checkEmptyQuads: [MetalGridQuad] = []
        var videoQuads: [MetalGridQuad] = []
        backgrounds.reserveCapacity(cells.count)
        let cardRadius = Float(GridVisualConstants.thumbnailCornerRadius)
        let accent = Self.colorVector(.controlAccentColor)
        var realCount = 0
        for c in cells where c.flatIndex < flatUIDs.count {
            let uid = flatUIDs[c.flatIndex]
            let cellViewport = MetalGridGeometry.viewportRect(contentRect: c.rect, visibleOrigin: visibleOrigin)
            backgrounds.append(MetalGridQuad(rect: cellViewport, radius: cardRadius))
            var displayedRect = cellViewport
            if cache.isResident(uid) {
                cache.noteUsed(uid)
                let texture = cache.texture(for: uid)
                let geo = imageGeometry(cellViewport: cellViewport, texture: texture, cropMode: layout.cropMode)
                displayedRect = geo.rect
                images.append(MetalGridQuad(rect: geo.rect, uvMin: geo.uvMin, uvMax: geo.uvMax, radius: cardRadius))
                imageTextures.append(texture)
                realCount += 1
            }
            if decorationsEnabled {
                appendDecorations(uid: uid, cell: cellViewport, displayed: displayedRect, cardRadius: cardRadius, accent: accent,
                                  outline: &outlineQuads, favorite: &favoriteQuads,
                                  checkFilled: &checkFilledQuads, checkEmpty: &checkEmptyQuads, video: &videoQuads)
            }
        }
        let cpuInstanceMs = (CFAbsoluteTimeGetCurrent() - instanceStart) * 1000

        cache.evictToBudget()

        // ---- Draw (back → front: cards, thumbnails, then decorations) ----
        var groups: [MetalGridRenderGroup] = [
            MetalGridRenderGroup(source: .sharedTexture(cache.placeholderTexture), quads: backgrounds),
            MetalGridRenderGroup(source: .perQuadTexture(imageTextures), quads: images),
        ]
        if !outlineQuads.isEmpty {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(cache.placeholderTexture), quads: outlineQuads))
        }
        if !videoQuads.isEmpty, let t = cache.glyphTexture(symbol: "video.fill", color: .white) {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(t), quads: videoQuads))
        }
        if !favoriteQuads.isEmpty, let t = cache.glyphTexture(symbol: "heart.fill", color: .white) {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(t), quads: favoriteQuads))
        }
        if !checkEmptyQuads.isEmpty, let t = cache.glyphTexture(symbol: "circle", color: .white) {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(t), quads: checkEmptyQuads))
        }
        if !checkFilledQuads.isEmpty, let t = cache.glyphTexture(symbol: "checkmark.circle.fill", color: .controlAccentColor) {
            groups.append(MetalGridRenderGroup(source: .sharedTexture(t), quads: checkFilledQuads))
        }
        renderer.render(in: view, viewportSize: viewportSize, groups: groups)

        // Still-streaming if any VISIBLE cell lacks a real texture (drives the host's redraw ticker).
        hasPendingVisibleThumbnails = visibleUIDs.contains { !cache.isResident($0) }

        // ---- Diagnostics ----
        updateMotion(originY: visibleOrigin.y, now: now)
        let placeholderCount = cells.count - realCount
        let overscanCount = max(0, cells.count - visibleUIDs.count)
        var stats = MetalGridStats()
        stats.visibleItems = visibleUIDs.count
        stats.overscanItems = overscanCount
        stats.realTextureItems = realCount
        stats.placeholderItems = placeholderCount
        stats.textureUploads = cache.uploadsThisFrame
        stats.textureUploadBytes = cache.uploadBytesThisFrame
        stats.cacheHits = realCount
        stats.cacheMisses = placeholderCount
        stats.evictions = cache.evictionsThisFrame
        stats.drawCalls = renderer.lastDrawCalls
        stats.instanceCount = renderer.lastInstanceCount
        stats.cpuLayoutMs = cpuLayoutMs
        stats.cpuInstanceMs = cpuInstanceMs
        stats.textureUploadMs = cache.uploadMsThisFrame
        stats.gpuDrawMs = renderer.lastDrawMs
        stats.fpsEstimate = fpsEstimate()
        stats.memoryEstimateBytes = cache.memoryEstimateBytes

        var scroll = MetalGridScrollStats()
        scroll.visibleRect = visibleRect
        scroll.contentSize = layout.contentSize
        scroll.scrollVelocity = velocity
        scroll.overscanAhead = overscan
        scroll.overscanBehind = overscan

        publishDiagnostics(stats: stats, scroll: scroll, cache: cache.cacheStats, now: now)
    }

    // MARK: - Canonical engine render: GridFramePlan → Metal quads (no edge-fill, no second surface)

    /// THE production render. Resolves a `GridFramePlan` from the engine and draws exactly its square
    /// slots. Settled → free scroll origin. Live pinch → the engine computes the anchored scroll offset and
    /// the width-filling apparent grid itself, so left/right always carry real slots (never a black strip).
    private func drawEngineFrame(in view: MTKView, clip: NSClipView, viewportSize: CGSize, now: CFTimeInterval) {
        let overscan = budget.overscanFraction * viewportSize.height
        let slots: [GridSlot]
        let contentSizeForDiag: CGSize
        if let tx = zoomTransaction {
            // LIVE zoom: an engine-owned transaction with a STABLE focus row. The grid is laid out relative
            // to the anchor under the cursor — NOT a per-frame stateless re-resolve — so the row under the
            // cursor keeps its photos (zoom-in drops edge neighbours, zoom-out adds them), never re-wrapping.
            let frame = tx.frame(continuousLevel: zoomTransactionLevel, viewportSize: viewportSize, overscan: overscan)
            slots = frame.visibleSlots
            contentSizeForDiag = CGSize(width: viewportSize.width, height: frame.pitch * CGFloat(max(1, slots.count / max(frame.columns, 1))))
        } else {
            // SETTLED: clamp the camera to the content extent (the window is a camera over the wall; it can't
            // leave the wall — pull it back if a zoom-out shrank the content below the scroll position). The
            // column phase keeps the focus item's column where the last live zoom / +- left it (seamless).
            let phase = currentPhase(level: level, width: viewportSize.width)
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
            slots = plan.visibleSlots
            contentSizeForDiag = plan.contentSize
        }

        if debugSyntheticGrid {
            renderSyntheticSlots(in: view, slots: slots, viewportSize: viewportSize)
            hasPendingVisibleThumbnails = false
            updateMotion(originY: clip.bounds.origin.y, now: now)
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
            if s.viewportRect.intersects(pureViewport) { visibleUIDs.append(flatUIDs[s.index]) }
            else { overscanUIDs.append(flatUIDs[s.index]) }
        }
        streamTextures(visibleUIDs: visibleUIDs, overscanUIDs: overscanUIDs)
        let realCount = renderRealSlots(in: view, slots: slots, flatUIDs: flatUIDs, viewportSize: viewportSize)
        hasPendingVisibleThumbnails = visibleUIDs.contains { !cache.isResident($0) }
        updateMotion(originY: clip.bounds.origin.y, now: now)
        publishLightDiagnostics(visibleCount: visibleUIDs.count, realCount: realCount, cellCount: slots.count,
                                visibleRect: CGRect(origin: clip.bounds.origin, size: viewportSize),
                                contentSize: contentSizeForDiag, now: now)
    }

    /// Real thumbnails: a square outer card + the image cover-filled INSIDE the square slot (aspect only via
    /// the UV window — never changes the slot), plus production decorations. Returns the real-texture count.
    @discardableResult
    private func renderRealSlots(in view: MTKView, slots: [GridSlot], flatUIDs: [PhotoUID], viewportSize: CGSize) -> Int {
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
        for s in slots where s.index < flatUIDs.count {
            let uid = flatUIDs[s.index]
            let cell = s.viewportRect                       // ALWAYS square (engine guarantee)
            let r = cellRadius(cardRadius, cell: cell)
            backgrounds.append(MetalGridQuad(rect: cell, radius: r))
            if cache.isResident(uid) {
                cache.noteUsed(uid)
                let texture = cache.texture(for: uid)
                // Compose: slotRect (engine) + content fit (TileContentFitter) + texture (cache). The
                // fitter is the ONLY thing that sees media aspect; the slot is square regardless.
                let fit = TileContentFitter.fit(slotRect: cell,
                                                mediaPixelSize: CGSize(width: texture.width, height: texture.height),
                                                mode: .aspectFill)
                images.append(MetalGridQuad(rect: fit.contentRect, uvMin: fit.uvMin, uvMax: fit.uvMax, radius: r))
                imageTextures.append(texture)
                realCount += 1
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
    private func renderSyntheticSlots(in view: MTKView, slots: [GridSlot], viewportSize: CGSize) {
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

    // MARK: - Image quad geometry (crop / aspect)

    /// The displayed-image rect (viewport coords) + the UV window for a thumbnail in a cell.
    private func imageGeometry(cellViewport: CGRect, texture: MTLTexture, cropMode: GridCropMode) -> (rect: CGRect, uvMin: SIMD2<Float>, uvMax: SIMD2<Float>) {
        let texW = CGFloat(max(texture.width, 1)), texH = CGFloat(max(texture.height, 1))
        switch cropMode {
        case .squareFill:
            // Center-crop the texture to a square that fills the whole (square) cell.
            var insetX: Float = 0, insetY: Float = 0
            if texW > texH { insetX = Float((1 - texH / texW) / 2) } else if texH > texW { insetY = Float((1 - texW / texH) / 2) }
            return (cellViewport, SIMD2(insetX, insetY), SIMD2(1 - insetX, 1 - insetY))
        case .aspectFit:
            // Letterbox the whole image inside the cell (bars are the placeholder card behind it).
            let ar = texW / texH
            var w = cellViewport.width, h = cellViewport.height
            if ar >= 1 { h = w / ar } else { w = h * ar }
            let rect = CGRect(x: cellViewport.midX - w / 2, y: cellViewport.midY - h / 2, width: w, height: h)
            return (rect, SIMD2(0, 0), SIMD2(1, 1))
        }
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

    // MARK: - Motion / fps / logging

    private func updateMotion(originY: CGFloat, now: CFTimeInterval) {
        if lastFrameTime > 0 {
            let dt = now - lastFrameTime
            if dt > 0 { velocity = (originY - lastOriginY) / CGFloat(dt) }
            // On-demand rendering is bursty (active during scroll/streaming, idle otherwise). After an
            // idle gap, restart the fps window so the estimate reflects the CURRENT active cadence rather
            // than being dragged down by the idle period.
            if dt > 0.25 { frameTimestamps.removeAll(keepingCapacity: true); velocity = 0 }
        }
        lastOriginY = originY
        lastFrameTime = now
        frameTimestamps.append(now)
        if frameTimestamps.count > 60 { frameTimestamps.removeFirst(frameTimestamps.count - 60) }
    }

    private func fpsEstimate() -> Double {
        guard frameTimestamps.count >= 2, let first = frameTimestamps.first, let last = frameTimestamps.last, last > first else { return 0 }
        return Double(frameTimestamps.count - 1) / (last - first)
    }

    private func publishDiagnostics(stats: MetalGridStats, scroll: MetalGridScrollStats, cache cacheStats: MetalGridCacheStats, now: CFTimeInterval) {
        if now - lastHUDPush > 0.1 {   // ~10 Hz HUD
            lastHUDPush = now
            var hud = MetalGridHUD()
            hud.stats = stats
            hud.scroll = scroll
            hud.cache = cacheStats
            hud.level = level
            hud.totalItems = totalItems
            hud.dataSource = dataSource.label
            onHUD?(hud)
        }
        if now - lastLog > 1.0 {       // ~1 Hz log
            lastLog = now
            PhotoDiagnostics.shared.emit("MetalGrid", ["stats": stats.summary])
            PhotoDiagnostics.shared.emit("MetalGridScroll", ["scroll": scroll.summary])
            PhotoDiagnostics.shared.emit("MetalGridCache", ["cache": cacheStats.summary])
        }
    }
}

// MARK: - Apple-matched detent zoom: render + transition compositing
//
// Single source of truth for the new grid look (justified aspect rows / square overview) and the
// two-surface pinch transition (see GridZoom/*.swift + docs/grid-zoom-apple-model.md). All cells are
// cover-filled — NO letterbox bars, ever. When a `zoomSession` is live the SOURCE and TARGET detent
// layouts are both anchored at one screen point, geometrically scaled to a shared apparent size, and the
// target is crossfaded over the source per the transition family (focus-protected near vs. global whoosh).
extension MetalGridCoordinator {

    func drawDetent(in view: MTKView, clip: NSClipView, viewportSize: CGSize, now: CFTimeInterval) {
        if zoomSession != nil {
            drawZoomTransition(in: view, viewportSize: viewportSize, now: now)
        } else {
            drawSettledDetent(in: view, clip: clip, viewportSize: viewportSize, now: now)
        }
    }

    // MARK: Settled (no active gesture) — the normal justified/square grid

    private func drawSettledDetent(in view: MTKView, clip: NSClipView, viewportSize: CGSize, now: CFTimeInterval) {
        let visibleOrigin = clip.bounds.origin
        let visibleRect = CGRect(origin: visibleOrigin, size: viewportSize)
        let layout = currentDetentLayout(width: viewportSize.width)
        let overscan = budget.overscanFraction * viewportSize.height
        let overscanRect = MetalGridGeometry.overscanRect(visibleRect: visibleRect, overscan: overscan, contentHeight: layout.contentSize.height)
        let cells = layout.visibleCells(in: overscanRect)

        var visibleUIDs: [PhotoUID] = []
        var overscanUIDs: [PhotoUID] = []
        let flatUIDs = dataSource.flatUIDs
        for c in cells where c.flatIndex < flatUIDs.count {
            if c.rect.intersects(visibleRect) { visibleUIDs.append(flatUIDs[c.flatIndex]) }
            else { overscanUIDs.append(flatUIDs[c.flatIndex]) }
        }
        streamTextures(visibleUIDs: visibleUIDs, overscanUIDs: overscanUIDs)

        let detent = detentModel.detent(level)
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
        backgrounds.reserveCapacity(cells.count)
        var realCount = 0
        for c in cells where c.flatIndex < flatUIDs.count {
            let uid = flatUIDs[c.flatIndex]
            let cellViewport = MetalGridGeometry.viewportRect(contentRect: c.rect, visibleOrigin: visibleOrigin)
            let r = cellRadius(cardRadius, cell: cellViewport)
            backgrounds.append(MetalGridQuad(rect: cellViewport, radius: r))
            if cache.isResident(uid) {
                cache.noteUsed(uid)
                let texture = cache.texture(for: uid)
                let geo = coverFillGeometry(cell: cellViewport, texture: texture, family: detent.family)
                images.append(MetalGridQuad(rect: geo.rect, uvMin: geo.uvMin, uvMax: geo.uvMax, radius: r))
                imageTextures.append(texture)
                realCount += 1
            }
            if decorationsEnabled {
                appendDecorations(uid: uid, cell: cellViewport, displayed: cellViewport, cardRadius: r, accent: accent,
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

        hasPendingVisibleThumbnails = visibleUIDs.contains { !cache.isResident($0) }
        publishLightDiagnostics(visibleCount: visibleUIDs.count, realCount: realCount, cellCount: cells.count,
                                visibleRect: visibleRect, contentSize: layout.contentSize, now: now)
    }

    // MARK: Active transition — SINGLE-GRID geometric scale (the "rubber-band" applied to the whole zoom)
    //
    // The user loved the rubber-band: ONE grid, scaled around the cursor, no second overlaid grid. So that is
    // now the WHOLE pinch. During the drag we render exactly one detent (the gesture's base), scaled to the
    // apparent cell size around the cursor — no crossfade (→ no ghost/double-exposure), the same detent's
    // textures stay loaded (→ no blackouts), no per-frame re-justify (→ nothing jumps). The width over/
    // underflows as it scales (clean, like zooming an image). The REFLOW to the new column count happens
    // ONCE, on release: a brief cross-dissolve from the scaled base grid to the snapped detent (whose
    // textures we pre-warm during the drag) — Apple's "smooth zoom, then re-align".

    /// Apparent cell size for a continuous level position, including the soft rubber-band past the ends.
    /// Within the ladder it interpolates the two bracketing detents; past detent 0 (over-zoom IN) it grows
    /// with diminishing return (the gummiband that snaps back on release); the densest end is clamped (no
    /// over-shrink, so an over-zoom OUT never drops below fill).
    private func apparentSize(at x: CGFloat) -> CGFloat {
        let maxIndex = detentModel.count - 1
        if x <= 0 { return detentModel.detent(0).size * (1 - x * 0.6) }
        if x >= CGFloat(maxIndex) { return detentModel.detent(maxIndex).size }
        let lo = Int(x)
        return GridZoomEasing.lerp(detentModel.detent(lo).size, detentModel.detent(lo + 1).size, x - CGFloat(lo))
    }

    private func drawZoomTransition(in view: MTKView, viewportSize: CGSize, now: CFTimeInterval) {
        guard let session = zoomSession else { return }
        let x = session.levelPosition
        let apparent = apparentSize(at: x)
        let flatUIDs = dataSource.flatUIDs
        let baseRadius = Float(GridVisualConstants.thumbnailCornerRadius)
        let dispLevel = detentModel.clampIndex(displayedLevel)

        // ── Geometric scale of the displayed grid (gummiband) + release re-align ──────────────────────────
        // Each thumbnail grows (pinch-in) / shrinks (pinch-out), geometrically scaled to `apparent` around the
        // cursor; rubber-band past the largest detent via `apparentSize`. Zoom-OUT contracts the grid -> black
        // L/R strips while dragging (known/accepted in this clean state). The re-pack ("neu ausrichten")
        // happens only on RELEASE: the snapped detent fades in on top (`settleCrossfade`).
        var overlayLevel: Int?
        var fade: Float = 0
        if isZoomSettling, let target = settleTargetLevel, target != dispLevel {
            overlayLevel = target
            fade = Float(min(max(settleCrossfade, 0), 1))
        }
        lastZoomFade = overlayLevel != nil ? fade : 0

        let baseInfo = scaledGrid(level: dispLevel, apparent: apparent, viewportSize: viewportSize, session: session)
        let overlayInfo = overlayLevel.map { scaledGrid(level: $0, apparent: apparent, viewportSize: viewportSize, session: session) }

        var visibleUIDs: [PhotoUID] = []
        for c in baseInfo.cells where c.flatIndex < flatUIDs.count { visibleUIDs.append(flatUIDs[c.flatIndex]) }
        if let o = overlayInfo { for c in o.cells where c.flatIndex < flatUIDs.count { visibleUIDs.append(flatUIDs[c.flatIndex]) } }
        streamTextures(visibleUIDs: visibleUIDs, overscanUIDs: [])

        var groups: [MetalGridRenderGroup] = []
        var bbg: [MetalGridQuad] = [], bimg: [MetalGridQuad] = [], btex: [MTLTexture] = []
        buildSurfaceQuads(cells: baseInfo.cells, transform: baseInfo.transform, family: baseInfo.family, alpha: { _ in 1 },
                          flatUIDs: flatUIDs, baseRadius: baseRadius, backgrounds: &bbg, images: &bimg, textures: &btex)
        groups.append(MetalGridRenderGroup(source: .sharedTexture(cache.placeholderTexture), quads: bbg))
        groups.append(MetalGridRenderGroup(source: .perQuadTexture(btex), quads: bimg))
        if let o = overlayInfo {
            var obg: [MetalGridQuad] = [], oimg: [MetalGridQuad] = [], otex: [MTLTexture] = []
            buildSurfaceQuads(cells: o.cells, transform: o.transform, family: o.family, alpha: { _ in fade },
                              flatUIDs: flatUIDs, baseRadius: baseRadius, backgrounds: &obg, images: &oimg, textures: &otex)
            groups.append(MetalGridRenderGroup(source: .perQuadTexture(otex), quads: oimg))
        }
        cache.evictToBudget()
        renderer.render(in: view, viewportSize: viewportSize, groups: groups)
        hasPendingVisibleThumbnails = visibleUIDs.contains { !cache.isResident($0) }
        if now - lastLog > 0.25 {
            lastLog = now
            GridZoomDebug.transition(mode: overlayLevel != nil ? "reAlign" : "scale", progress: CGFloat(fade),
                                     replacementCount: baseInfo.cells.count, focusProtected: false)
        }
    }


    private func scaledGrid(level: Int, apparent: CGFloat, viewportSize: CGSize, session: ZoomSession)
        -> (cells: [GridDetentCell], transform: GridZoomSurfaceTransform, family: GridLayoutFamily) {
        let detent = detentModel.detent(level)
        let layout = detentLayoutMemo(level: level, width: viewportSize.width)
        let scale = apparent / max(detent.size, 0.001)
        let transform = GridZoomSurfaceTransform(anchorScreen: session.anchorScreen,
                                                 anchorContent: anchorContent(in: layout, session: session), scale: scale)
        let query = CGRect(origin: .zero, size: viewportSize).insetBy(dx: -apparent, dy: -apparent)
        return (layout.visibleCells(in: transform.contentRect(forViewport: query)), transform, detent.family)
    }

    private func buildSurfaceQuads(
        cells: [GridDetentCell], transform: GridZoomSurfaceTransform, family: GridLayoutFamily,
        alpha: (CGRect) -> Float, flatUIDs: [PhotoUID], baseRadius: Float,
        backgrounds: inout [MetalGridQuad], images: inout [MetalGridQuad], textures: inout [MTLTexture]
    ) {
        for c in cells where c.flatIndex < flatUIDs.count {
            let screen = transform.screenRect(c.rect)
            let a = alpha(screen)
            guard a > 0.004 else { continue }
            let r = cellRadius(baseRadius, cell: screen)
            backgrounds.append(MetalGridQuad(rect: screen, radius: r, alpha: a))
            let uid = flatUIDs[c.flatIndex]
            if cache.isResident(uid) {
                cache.noteUsed(uid)
                let texture = cache.texture(for: uid)
                let geo = coverFillGeometry(cell: screen, texture: texture, family: family)
                images.append(MetalGridQuad(rect: geo.rect, uvMin: geo.uvMin, uvMax: geo.uvMax, radius: r, alpha: a))
                textures.append(texture)
            }
        }
    }

    /// The anchor location in a layout's content space: the anchor item's cell center if present, else the
    /// same vertical fraction of content (keeps the scroll position over a gap).
    private func anchorContent(in layout: GridDetentLayout, session: ZoomSession) -> CGPoint {
        if let item = session.anchorFlatIndex, let f = layout.frame(flatIndex: item) {
            // The SAME relative spot of the SAME photo — keeps the cursor pinned exactly (no start pop).
            return CGPoint(x: f.minX + session.anchorRelInCell.x * f.width,
                           y: f.minY + session.anchorRelInCell.y * f.height)
        }
        // No item under the cursor (a gap) → keep the same x and the same vertical fraction of content.
        return CGPoint(x: session.anchorContentBase.x, y: session.anchorYFraction * layout.contentSize.height)
    }

    // MARK: Cover-fill geometry (no letterbox bars)

    /// Center-crop the texture to COVER the cell (any aspect). For justified cells (cell aspect ≈ photo
    /// aspect) this is a near-zero crop; for square cells it crops to the square. Never letterboxes.
    private func coverFillGeometry(cell: CGRect, texture: MTLTexture, family: GridLayoutFamily) -> (rect: CGRect, uvMin: SIMD2<Float>, uvMax: SIMD2<Float>) {
        let texW = CGFloat(max(texture.width, 1)), texH = CGFloat(max(texture.height, 1))
        let texAR = texW / texH
        let cellAR = cell.width / max(cell.height, 1)
        var insetX: Float = 0, insetY: Float = 0
        if texAR > cellAR { insetX = Float((1 - cellAR / texAR) / 2) }
        else { insetY = Float((1 - texAR / cellAR) / 2) }
        return (cell, SIMD2(insetX, insetY), SIMD2(1 - insetX, 1 - insetY))
    }

    private func cellRadius(_ base: Float, cell: CGRect) -> Float {
        min(base, Float(min(cell.width, cell.height) * 0.5))
    }

    // MARK: Texture streaming (shared by both detent paths)

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

    // MARK: - Zoom session API (driven by MetalGridScrollHost)

    /// Begin a gesture anchored at a CONTENT point under the cursor (scroll frozen at the current origin).
    func beginZoomTransition(anchorContentPoint: CGPoint) {
        let originY = clipView?.bounds.origin.y ?? 0
        let width = metalView?.bounds.width ?? clipView?.bounds.width ?? 1
        let anchorScreen = CGPoint(x: anchorContentPoint.x, y: anchorContentPoint.y - originY)
        // Capture a LOGICAL anchor: the engine resolves the ITEM under (or nearest to) the cursor + the
        // local fraction within its slot. The anchor identity is the item (section/global index), never a
        // raw y — so the engine rebases the scroll offset from THIS item's new slot rect at every apparent
        // metric, instead of reusing a scroll offset that's invalid once slotSide/gap/columns/sections change.
        let resolvedAnchor = engine.anchorItem(nearContentPoint: anchorContentPoint, level: level, width: width)
        let item = resolvedAnchor?.flatIndex
        let rel = resolvedAnchor?.localFraction ?? CGPoint(x: 0.5, y: 0.5)
        let frac = anchorContentPoint.y / max(engine.contentSize(level: level, width: width).height, 1)
        zoomSession = ZoomSession(
            baseLevel: level, levelPosition: CGFloat(level),
            anchorScreen: anchorScreen, anchorContentBase: anchorContentPoint,
            anchorFlatIndex: item, anchorRelInCell: rel, anchorYFraction: frac, scrollOriginY: originY
        )
        displayedLevel = level            // grid starts on the committed detent
        lastZoomFade = 0
        GridZoomDebug.anchor(uid: item.flatMap { uid(atFlatIndex: $0) }.map { "\($0.nodeID)" } ?? "—",
                             screen: anchorScreen, status: item == nil ? "GAP" : "PASS")
        // Pre-warm the DENSER neighbour's visible thumbnails so the zoom-out fill backdrop isn't a wall of
        // grey placeholders the moment the user starts pinching out.
        prewarmNeighbor(of: level, width: width)
        requestRedraw()
    }

    /// Decode (off-main) the thumbnails the denser neighbour detent would reveal, so a zoom-out has them ready.
    private func prewarmNeighbor(of baseLevel: Int, width: CGFloat) {
        let denser = engine.clampLevel(baseLevel + 1)
        guard denser != baseLevel, let view = metalView, let clip = clipView else { return }
        let plan = engine.framePlan(level: denser, viewportSize: view.bounds.size,
                                    scrollOffset: clip.bounds.origin, overscan: view.bounds.height * 0.5)
        let uids = plan.visibleSlots.compactMap { uid(atFlatIndex: $0.index) }
        let missing = uids.filter { !cache.isResident($0) && !dataSource.hasImage(for: $0) }
        if !missing.isEmpty { dataSource.warm(missing) }
    }

    /// Update the continuous level position during the gesture (allows a little over-travel past the ends
    /// for the rubber-band; the release snap clamps back to a real detent).
    func updateZoomTransition(levelPosition: CGFloat) {
        guard zoomSession != nil else { return }
        zoomSession?.levelPosition = min(max(levelPosition, -0.5), CGFloat(detentModel.count - 1) + 0.5)
        requestRedraw()
    }

    /// The detent the gesture should settle on (velocity in levels/sec; + = zooming out). Snaps to the detent
    /// whose cell size is nearest the apparent size shown during the drag, with a flick biasing one detent
    /// further in the motion direction.
    func snapLevel(velocity: CGFloat) -> Int {
        guard let session = zoomSession else { return level }
        // Snap to the detent whose engine slot size is nearest the apparent size shown during the drag —
        // same size space as the rendered grid, so the release lands without a jump.
        let apparent = engine.apparentSlotSide(at: session.levelPosition)
        let flick = detentModel.tuning.flickVelocity
        var best = 0, bestDelta = CGFloat.greatestFiniteMagnitude
        for i in 0 ..< engine.levelCount {
            let d = abs(engine.metrics(level: i).slotSide - apparent)
            if d < bestDelta { bestDelta = d; best = i }
        }
        if velocity > flick { best = max(best, engine.clampLevel(displayedLevel + 1)) }       // zoom-out flick
        else if velocity < -flick { best = min(best, engine.clampLevel(displayedLevel - 1)) } // zoom-in flick
        return engine.clampLevel(best)
    }

    var activeLevelPosition: CGFloat? { zoomSession?.levelPosition }
    var activeAnchorFlatIndex: Int? { zoomSession?.anchorFlatIndex }
    /// The re-align overlay fade showing last frame — so the release-settle CONTINUES it (no reset/flicker).
    var lastZoomFadeValue: Float { lastZoomFade }

    /// The scroll origin Y that keeps the anchor under its gesture screen point at `finalLevel`. Call BEFORE
    /// `commitZoomTransition` (it reads the live session). nil if no session.
    func scrollOriginAfterCommit(finalLevel: Int) -> CGFloat? {
        guard let session = zoomSession else { return nil }
        let width = metalView?.bounds.width ?? clipView?.bounds.width ?? 1
        return engine.anchoredScrollOffsetY(flatIndex: session.anchorFlatIndex, relInCellY: session.anchorRelInCell.y,
                                            contentFractionY: session.anchorYFraction, viewportPointY: session.anchorScreen.y,
                                            level: finalLevel, width: width)
    }

    /// Finish: commit `finalLevel` as the settled detent and clear the gesture (the host re-anchors scroll).
    func commitZoomTransition(finalLevel: Int) {
        let originMatch = zoomSession.map { abs($0.levelPosition - CGFloat(finalLevel)) < 0.001 } ?? false
        GridZoomDebug.settle(velocity: 0, finalDetent: finalLevel, originMatch: originMatch)
        zoomSession = nil
        displayedLevel = detentModel.clampIndex(finalLevel)
        lastZoomFade = 0
        level = detentModel.clampIndex(finalLevel)   // didSet recomputes content size
        requestRedraw()
    }

    func cancelZoomTransition() {
        zoomSession = nil
        lastZoomFade = 0
        requestRedraw()
    }
}
