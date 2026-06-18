import AppKit
import CoreGraphics
import Metal
import MetalKit
import simd

/// What a frozen overlay page represents. Crucially the roles have a fixed DRAW ORDER (back → front).
/// Every page is made of PER-PHOTO sprites — there is no opaque plate/rectangle/wall in the visible
/// transition (pass #10). Source draws OVER the target world, so the focused photo stays on top.
///  • `targetWorld` — UNDER source: the global target detent rendered as individual photo nodes for the
///                       regions a shrinking source no longer covers. NOT a wall: the protected focus row
///                       is excluded and each node is suppressed where a source photo covers it (per-photo
///                       depth occlusion, NOT a rectangular mask). Drawn at the target scale.
///  • `sourcePlate`    — UNUSED legacy role (no opaque plate is ever drawn). Kept only for drawOrder.
///  • `source`         — page 0, the thumbnail sprites captured at pinch begin.
///  • `sourceCoverage` — append-only source photos (same transform as source).
///  • `topologyGhost`  — OVER source: brief topology-transition replacement only (disabled by default;
///                       the settle `targetPreview` handles topology reveal).
///  • `targetPreview`  — OVER source during the settle cross-fade; the target grid (per-photo nodes) at
///                       the commit origin, focus row dissolved LAST, so the real grid reveal is boring.
enum FrozenPageRole {
    case targetWorld      // UNDER source — per-photo target detent nodes (focus row excluded, source-
                          //                occluded per photo). NOT a wall, NOT a rectangle.
    case sourcePlate      // UNUSED (no opaque plate is drawn); retained only for a stable drawOrder
    case source           // frozen source thumbnail surface (page 0)
    case sourceCoverage   // appended source pages (same transform as source)
    case topologyGhost    // OVER source — brief topology-transition replacement only (disabled by default)
    case targetPreview    // OVER source during settle/commit crossfade
    case worldSlots       // pass #12 — the per-slot replacement compositor: a SINGLE flat page of
                          //            screen-space slot quads (occupant + target crossfading in place),
                          //            drawn at IDENTITY. When active it is the ONLY thing drawn.
    /// Source thumbnail pages dedupe against the shown-key set; plates and target pages own their keyspace.
    var isSourceRole: Bool { self == .source || self == .sourceCoverage }
    /// Draw order (low → high = back → front): backdrop, plate, source, coverage, ghost, preview, slots.
    var drawOrder: Int {
        switch self {
        case .targetWorld: return 0
        case .sourcePlate: return 1
        case .source: return 2
        case .sourceCoverage: return 3
        case .topologyGhost: return 4
        case .targetPreview: return 5
        case .worldSlots: return 6
        }
    }
}

/// Per-frame render accounting so blackouts/disappearing sprites are never silent — surfaced to the
/// coordinator's `[GridZoom]` log during a pinch.
struct GridSpriteRenderStats {
    var descriptorCount = 0
    var slotCount = 0
    var pageCount = 0
    var textureCount = 0
    var atlasCount = 0
    var atlasItemCount = 0
    var atlasPlacementCount = 0
    var renderedSpriteCount = 0
    var droppedMissingUVCount = 0
    var gpuTextureMiss = 0
    var atlasMissingUV = 0
    var nilImageDescriptorCount = 0
    var placeholderDescriptorCount = 0
    var placeholderTextureUsed = 0
    var droppedMissingImageCount = 0
    var atlasDimension = 0
    var atlasBuildCount = 0
    var textureUploadCount = 0
    var vertexBuildCount = 0
    var perFrameAllocationBytes = 0
    var cpuPrepareMs: Double = 0
    var mainThreadMs: Double = 0
    var atlasBuildMs: Double = 0
    var textureUploadMs: Double = 0
    var vertexBuildMs: Double = 0
    var metalDrawMs: Double = 0

    var summary: String {
        "descriptors=\(descriptorCount) slots=\(slotCount) pages=\(pageCount) textures=\(textureCount) atlases=\(atlasCount) atlasItems=\(atlasItemCount) placements=\(atlasPlacementCount) rendered=\(renderedSpriteCount) droppedMissingUV=\(droppedMissingUVCount) gpuTextureMiss=\(gpuTextureMiss) atlasMissingUV=\(atlasMissingUV) nilImage=\(nilImageDescriptorCount) placeholders=\(placeholderDescriptorCount) placeholderTextureUsed=\(placeholderTextureUsed) droppedMissingImage=\(droppedMissingImageCount) atlasDim=\(atlasDimension) atlasBuilds=\(atlasBuildCount) textureUploads=\(textureUploadCount) vertexBuilds=\(vertexBuildCount) allocBytes=\(perFrameAllocationBytes) cpuMs=\(String(format: "%.2f", cpuPrepareMs)) mainMs=\(String(format: "%.2f", mainThreadMs)) atlasMs=\(String(format: "%.2f", atlasBuildMs)) uploadMs=\(String(format: "%.2f", textureUploadMs)) vertexMs=\(String(format: "%.2f", vertexBuildMs)) metalMs=\(String(format: "%.2f", metalDrawMs))"
    }
}

struct GridTransitionSpriteDescriptor {
    let key: String
    let image: CGImage?
    let imageSize: CGSize
    let fromFrame: CGRect
    let toFrame: CGRect
    let fromAlpha: Float
    let toAlpha: Float
    let phaseStart: Float
    let phaseEnd: Float
    let priority: CGFloat
    /// When true, the sprite center-crops its image to fill a square cell (its frame), instead of
    /// letterboxing — used by `squareFill` levels. The atlas keeps the full thumbnail; the renderer
    /// insets the UVs to the centered square, so no image is re-decoded.
    let fillSquare: Bool
    let usedPlaceholderFallback: Bool

    init(
        key: String,
        image: CGImage?,
        imageSize: CGSize,
        fromFrame: CGRect,
        toFrame: CGRect,
        fromAlpha: Float,
        toAlpha: Float,
        priority: CGFloat,
        phaseStart: CGFloat = 0,
        phaseEnd: CGFloat = 1,
        fillSquare: Bool = false
    ) {
        let fallback = image == nil
        self.key = key
        self.image = image ?? GridThumbnailFallback.placeholderImage
        self.imageSize = image == nil ? GridThumbnailFallback.placeholderSize : imageSize
        self.fromFrame = fromFrame
        self.toFrame = toFrame
        self.fromAlpha = fromAlpha
        self.toAlpha = toAlpha
        self.phaseStart = Float(max(0, min(1, phaseStart)))
        self.phaseEnd = Float(max(0, min(1, phaseEnd)))
        self.priority = priority
        self.fillSquare = fallback ? false : fillSquare
        self.usedPlaceholderFallback = fallback
    }
}

/// Metal-backed sprite canvas used only during grid zoom transitions.
///
/// The overlay draws only the viewport working set, packed into a temporary atlas, so per-frame cost
/// depends on visible sprites rather than the total library size. While a grid zoom is active, the
/// coordinator keeps the live collection view hidden so this overlay owns visual continuity.
final class GridSpriteTransitionView: NSView, MTKViewDelegate {
    private let metalView: MTKView
    private let renderer: GridSpriteRenderer?

    var isReady: Bool { renderer != nil }

    /// Last-frame render accounting (for diagnostics).
    var stats: GridSpriteRenderStats { renderer?.stats ?? GridSpriteRenderStats() }

    /// Renders the colored-corner test image through the exact atlas/UV/quad path and reads the result
    /// back off-screen. Returns "PASS …" only if top-left is RED (upright). Used once at the first pinch.
    func runOrientationSelfTest() -> String { renderer?.orientationSelfTest() ?? "orientation: no renderer" }

    override init(frame frameRect: NSRect) {
        let device = MTLCreateSystemDefaultDevice()
        self.metalView = TransparentMTKView(frame: .zero, device: device)
        self.renderer = device.flatMap(GridSpriteRenderer.init(device:))
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.isOpaque = false

        metalView.translatesAutoresizingMaskIntoConstraints = false
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.enableSetNeedsDisplay = true
        metalView.isPaused = true
        metalView.preferredFramesPerSecond = 120
        metalView.delegate = self
        metalView.layer?.isOpaque = false
        metalView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(metalView)

        NSLayoutConstraint.activate([
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(
        sprites: [GridTransitionSpriteDescriptor],
        progress: CGFloat,
        rebuildAtlas: Bool = true
    ) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        renderer?.configure(
            sprites: sprites,
            viewportSize: bounds.size,
            backingScale: scale,
            rebuildAtlas: rebuildAtlas
        )
        setProgress(progress)
    }

    func setProgress(_ progress: CGFloat) {
        renderer?.setProgress(Float(max(0, min(1, progress))))
        metalView.draw()
    }

    func containsAtlasKey(_ key: String) -> Bool {
        renderer?.containsAtlasKey(key) ?? false
    }

    func animate(to target: CGFloat, duration: TimeInterval, completion: @escaping () -> Void) {
        guard let renderer else {
            completion()
            return
        }
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        renderer.animate(
            to: Float(max(0, min(1, target))),
            duration: duration,
            completion: { [weak self] in
                self?.metalView.isPaused = true
                self?.metalView.enableSetNeedsDisplay = true
                completion()
            }
        )
    }

    // MARK: - Frozen-source mode

    var lastDrawMs: Double { renderer?.lastDrawMs ?? 0 }

    func configureFrozenSource(sprites: [GridTransitionSpriteDescriptor], anchor: CGPoint, rebuildAtlas: Bool) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        renderer?.configureFrozenSource(sprites: sprites, anchor: anchor, viewportSize: bounds.size, backingScale: scale, rebuildAtlas: rebuildAtlas)
        metalView.draw()
    }

    func setSourceScale(_ scale: CGFloat) {
        renderer?.setSourceScale(Float(scale))
        metalView.draw()
    }

    /// Per-cell SOURCE-alpha update (pass #11 compositor): rebuild ONLY the frozen source vertex buffer
    /// from `sprites` (each carrying its own `fromAlpha`), reusing the atlas. Lets individual source
    /// photos fade out outside the focus band so the source is never a globally-opaque rectangle.
    func updateFrozenSourceNodes(_ sprites: [GridTransitionSpriteDescriptor]) {
        renderer?.updateFrozenSourceNodes(sprites)
        metalView.draw()
    }

    /// Number of append-only pages currently layered around page 0 (source plate, coverage, backdrop).
    var frozenPageCount: Int { renderer?.frozenPageCount ?? 0 }

    /// Append a `role` page: source plate/source/coverage scale with the surface; target fill/preview
    /// have role-specific transforms. `pageAlpha` is the initial whole-page opacity. Returns render accounting.
    @discardableResult
    func appendFrozenSourcePage(sprites: [GridTransitionSpriteDescriptor], role: FrozenPageRole, pageAlpha: Float, sourceRect: CGRect, settleWindow: SIMD2<Float>? = nil) -> (rendered: Int, skippedNil: Int, skippedDup: Int, pageCount: Int) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let result = renderer?.appendFrozenPage(sprites: sprites, backingScale: scale, role: role, pageAlpha: pageAlpha, sourceRect: sourceRect, settleWindow: settleWindow)
            ?? (0, 0, 0, 0)
        metalView.draw()
        return result
    }

    /// Remove pages of the given roles and redraw.
    func clearPages(roles: Set<FrozenPageRole>) {
        renderer?.clearPages(roles: roles)
        metalView.draw()
    }

    /// Live scale (around the anchor) for `.targetWorld` pages, so the outer/edge photos breathe with
    /// the pinch instead of looking pasted on. Cheap — just a uniform + redraw.
    func setTargetFillScale(_ scale: CGFloat) {
        renderer?.setTargetFillScale(Float(scale))
        metalView.draw()
    }

    /// Atomically swap the live `.targetWorld` page (double-buffered: keeps the previous page if the new
    /// one would be empty/worse-covered). One redraw, so no empty-hole frame between clear and append.
    @discardableResult
    func replaceTargetFillPage(sprites: [GridTransitionSpriteDescriptor], pageAlpha: Float, sourceRect: CGRect) -> (rendered: Int, visibleNeeded: Int, missingImage: Int, keptPrevious: Bool, coverageRatio: Double, blackTileCount: Int, pageCount: Int) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let result = renderer?.replacePages(sprites: sprites, backingScale: scale, role: .targetWorld, pageAlpha: pageAlpha, sourceRect: sourceRect)
            ?? (0, sprites.count, 0, false, 0, 0, 0)
        metalView.draw()
        return result
    }

    /// Pass #12: atomically swap the single flat `.worldSlots` page (screen-space slot quads, drawn at
    /// identity). When present it is the ONLY thing drawn — page 0 + the source/target pages are suppressed.
    @discardableResult
    func replaceWorldSlots(sprites: [GridTransitionSpriteDescriptor], sourceRect: CGRect) -> (rendered: Int, visibleNeeded: Int, missingImage: Int, keptPrevious: Bool, coverageRatio: Double, blackTileCount: Int, pageCount: Int) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let result = renderer?.replacePages(sprites: sprites, backingScale: scale, role: .worldSlots, pageAlpha: 1, sourceRect: sourceRect)
            ?? (0, sprites.count, 0, false, 0, 0, 0)
        metalView.draw()
        return result
    }

    /// Drop the `.worldSlots` page (e.g. when a zoom-out detent disappears → back to the source surface).
    func clearWorldSlots() {
        renderer?.clearPages(roles: [.worldSlots])
        metalView.draw()
    }

    func animateSettleCrossfade(toScale: CGFloat, duration: TimeInterval, latePreview: Bool = false, completion: @escaping () -> Void) {
        guard let renderer else { completion(); return }
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        renderer.animateSettleCrossfade(toScale: Float(toScale), duration: duration, latePreview: latePreview) { [weak self] in
            self?.metalView.isPaused = true
            self?.metalView.enableSetNeedsDisplay = true
            completion()
        }
    }

    func animateSourceScale(to target: CGFloat, duration: TimeInterval, completion: @escaping () -> Void) {
        guard let renderer else { completion(); return }
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = false
        renderer.animateSourceScale(to: Float(target), duration: duration) { [weak self] in
            self?.metalView.isPaused = true
            self?.metalView.enableSetNeedsDisplay = true
            completion()
        }
    }

    @MainActor func draw(in view: MTKView) {
        renderer?.draw(in: view)
    }

    @MainActor func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        renderer?.viewportSize = bounds.size
    }
}

private final class TransparentMTKView: MTKView {
    override var isOpaque: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }
}

private final class GridSpriteRenderer {
    private struct AtlasSprite {
        let fromFrame: CGRect
        let toFrame: CGRect
        let fromAlpha: Float
        let toAlpha: Float
        let phaseStart: Float
        let phaseEnd: Float
        let uvMin: SIMD2<Float>
        let uvMax: SIMD2<Float>
    }

    private struct AtlasBuildItem {
        let descriptor: GridTransitionSpriteDescriptor
        let pixelSize: CGSize
    }

    private struct AtlasPlacement {
        let item: AtlasBuildItem
        let rect: CGRect
    }

    private struct Vertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
        var local: SIMD2<Float>
        var size: SIMD2<Float>
        var radius: Float
        var alpha: Float
    }

    private struct VertexUniforms {
        var viewportSize: SIMD2<Float>
        var anchor: SIMD2<Float>   // viewport-space zoom centre (frozen-source mode)
        var scale: Float           // live source scale (frozen-source mode); 1 in legacy mode
        var pageAlpha: Float       // whole-page opacity multiplier (settle cross-fade)
    }

    private struct RunningAnimation {
        let from: Float
        let to: Float
        let start: CFTimeInterval
        let duration: CFTimeInterval
        let completion: () -> Void
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private var atlasTexture: MTLTexture?
    private var atlasUVByKey: [String: (min: SIMD2<Float>, max: SIMD2<Float>)] = [:]
    private var sprites: [AtlasSprite] = []
    private var vertices: [Vertex] = []
    private var progress: Float = 0
    private var animation: RunningAnimation?
    private(set) var stats = GridSpriteRenderStats()
    private var lastAtlasDimension = 0
    private var atlasBuildCount = 0
    private var textureUploadCount = 0
    private var vertexBuildCount = 0
    private var lastAtlasBuildMs: Double = 0
    private var lastTextureUploadMs: Double = 0
    private var lastVertexBuildMs: Double = 0
    var viewportSize: CGSize = .zero

    // Frozen-source mode: base geometry built ONCE at pinch begin; every `.changed` tick just updates
    // `sourceScale` (a uniform) and redraws — no descriptor/vertex/buffer reconstruction.
    private var frozenMode = false
    private var frozenVertices: [Vertex] = []
    private var frozenVertexBuffer: MTLBuffer?
    private var frozenAnchor = SIMD2<Float>(0, 0)
    private var sourceScale: Float = 1
    private var targetWorldScale: Float = 1   // live scale (around the anchor) for the `.targetWorld` backdrop
    // Reusable backdrop atlas: rebuilt only when the cell set (keys) changes; the live alpha/scale
    // updates rebuild ONLY the vertex buffer, not this atlas.
    private var worldAtlas: (texture: MTLTexture, uvByKey: [String: (min: SIMD2<Float>, max: SIMD2<Float>)], keys: Set<String>)?
    private struct ScaleAnimation { let from: Float; let to: Float; let start: CFTimeInterval; let duration: CFTimeInterval; let completion: () -> Void }
    private var scaleAnimation: ScaleAnimation?
    // Settle cross-fade: animate source scale → final AND source pages' alpha down / targetPreview up,
    // in one pass, so the reveal lands on an already-matching overlay (no per-frame atlas rebuild).
    private struct SettleAnimation { let fromScale: Float; let toScale: Float; let start: CFTimeInterval; let duration: CFTimeInterval; let latePreview: Bool; let completion: () -> Void }
    private var settleAnimation: SettleAnimation?
    private(set) var lastDrawMs: Double = 0

    /// Append-only plate/coverage/ghost pages around page 0. Each carries its OWN atlas texture and
    /// vertex buffer (so page 0 is never rebuilt) but shares the live `sourceScale`/`frozenAnchor`
    /// uniform — except `scaleExempt` (ghost) pages, which draw at identity so their target-frame
    /// geometry stays put while the source surface scales underneath.
    private struct FrozenPage {
        let texture: MTLTexture
        let vertexBuffer: MTLBuffer
        let vertexCount: Int
        let sourceRect: CGRect
        let keys: Set<String>
        let role: FrozenPageRole
        var pageAlpha: Float
        /// Settle dissolve window (smoothstep edges) for `.targetPreview` pages. Lets the focus-band
        /// preview dissolve in LATER than the far-band preview. nil → the default late window.
        var settleWindow: SIMD2<Float>? = nil
    }
    private var frozenPages: [FrozenPage] = []
    private var frozenSeenKeys: Set<String> = []   // page-0 + appended source keys, for dedupe
    private var page0Alpha: Float = 1              // page-0 (source) alpha, faded out during settle
    var frozenPageCount: Int { frozenPages.count }
    private func totalFrozenSpriteCount() -> Int {
        frozenVertices.count / 6 + frozenPages.reduce(0) { $0 + $1.vertexCount / 6 }
    }

    private func stampCounters(into stats: inout GridSpriteRenderStats) {
        stats.atlasBuildCount = atlasBuildCount
        stats.textureUploadCount = textureUploadCount
        stats.vertexBuildCount = vertexBuildCount
        stats.atlasBuildMs = lastAtlasBuildMs
        stats.textureUploadMs = lastTextureUploadMs
        stats.vertexBuildMs = lastVertexBuildMs
        stats.metalDrawMs = lastDrawMs
        stats.pageCount = frozenPages.count + ((atlasTexture != nil && frozenVertexBuffer != nil) ? 1 : 0)
        stats.textureCount = frozenPages.count + (atlasTexture == nil ? 0 : 1) + (worldAtlas == nil ? 0 : 1)
        stats.atlasCount = stats.textureCount
        stats.gpuTextureMiss = stats.droppedMissingUVCount
        stats.atlasMissingUV = stats.droppedMissingUVCount
        stats.placeholderTextureUsed = stats.placeholderDescriptorCount > 0 ? 1 : 0
        stats.mainThreadMs = stats.cpuPrepareMs + stats.metalDrawMs
    }

    init?(device: MTLDevice) {
        self.device = device
        guard let commandQueue = device.makeCommandQueue() else { return nil }
        self.commandQueue = commandQueue

        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vertex = library.makeFunction(name: "gridSpriteVertex"),
                  let fragment = library.makeFunction(name: "gridSpriteFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            samplerDescriptor.mipFilter = .notMipmapped
            samplerDescriptor.sAddressMode = .clampToEdge
            samplerDescriptor.tAddressMode = .clampToEdge
            guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else { return nil }
            self.sampler = sampler
        } catch {
            return nil
        }
    }

    func configure(
        sprites descriptors: [GridTransitionSpriteDescriptor],
        viewportSize: CGSize,
        backingScale: CGFloat,
        rebuildAtlas: Bool
    ) {
        let prepareStart = CACurrentMediaTime()
        self.viewportSize = viewportSize
        self.animation = nil
        self.frozenMode = false

        var newStats = GridSpriteRenderStats()
        newStats.descriptorCount = descriptors.count
        newStats.slotCount = descriptors.count
        newStats.nilImageDescriptorCount = descriptors.reduce(0) { $0 + ($1.image == nil ? 1 : 0) }
        newStats.placeholderDescriptorCount = descriptors.reduce(0) { $0 + ($1.usedPlaceholderFallback ? 1 : 0) }

        // Rebuild the atlas only when forced, when missing, or when the descriptor key set is NOT a
        // subset of the current atlas. For the frozen source-only surface this means we build ONCE at
        // `.began` and reuse it for every `.changed` tick (no per-frame texture upload → no flicker).
        let keysCovered = !descriptors.isEmpty && descriptors.allSatisfy { atlasUVByKey[$0.key] != nil }
        let needsRebuild = rebuildAtlas || atlasTexture == nil || !keysCovered
        if needsRebuild {
            let items = descriptors
                .sorted { $0.priority < $1.priority }
                .prefix(1800)
                .map { descriptor in
                    AtlasBuildItem(
                        descriptor: descriptor,
                        pixelSize: Self.atlasPixelSize(for: descriptor, backingScale: backingScale)
                    )
                }
            newStats.atlasItemCount = items.count
            if let atlas = buildAtlas(for: Array(items)) {
                atlasTexture = atlas.texture
                atlasUVByKey = atlas.uvByKey
                newStats.atlasPlacementCount = atlas.placementCount
                newStats.atlasDimension = atlas.dimension
                lastAtlasDimension = atlas.dimension
            } else {
                atlasTexture = nil
                atlasUVByKey = [:]
                sprites = []
                newStats.cpuPrepareMs = (CACurrentMediaTime() - prepareStart) * 1000
                stampCounters(into: &newStats)
                stats = newStats
                return
            }
        } else {
            newStats.atlasItemCount = atlasUVByKey.count
            newStats.atlasPlacementCount = atlasUVByKey.count
            newStats.atlasDimension = lastAtlasDimension
        }

        newStats.droppedMissingUVCount = descriptors.reduce(0) { $0 + (atlasUVByKey[$1.key] == nil ? 1 : 0) }

        sprites = descriptors.compactMap { descriptor in
            guard let uv = atlasUVByKey[descriptor.key] else { return nil }
            return AtlasSprite(
                fromFrame: descriptor.fromFrame,
                toFrame: descriptor.toFrame,
                fromAlpha: descriptor.fromAlpha,
                toAlpha: descriptor.toAlpha,
                phaseStart: descriptor.phaseStart,
                phaseEnd: descriptor.phaseEnd,
                uvMin: uv.min,
                uvMax: uv.max
            )
        }
        vertices.reserveCapacity(max(vertices.capacity, sprites.count * 6))
        newStats.renderedSpriteCount = sprites.count
        newStats.perFrameAllocationBytes = sprites.count * MemoryLayout<AtlasSprite>.stride
        newStats.cpuPrepareMs = (CACurrentMediaTime() - prepareStart) * 1000
        stampCounters(into: &newStats)
        stats = newStats
    }

    func setProgress(_ progress: Float) {
        self.animation = nil
        self.progress = progress
    }

    func containsAtlasKey(_ key: String) -> Bool {
        atlasUVByKey[key] != nil
    }

    func animate(to target: Float, duration: TimeInterval, completion: @escaping () -> Void) {
        animation = RunningAnimation(
            from: progress,
            to: target,
            start: CACurrentMediaTime(),
            duration: max(duration, 0.001),
            completion: completion
        )
    }

    // MARK: - Frozen-source mode (static geometry + one live scale uniform)

    /// Build the frozen source surface ONCE: the atlas (subset-guarded) and a persistent base-geometry
    /// vertex buffer. `.changed` then only updates `sourceScale` and redraws.
    func configureFrozenSource(
        sprites descriptors: [GridTransitionSpriteDescriptor],
        anchor: CGPoint,
        viewportSize: CGSize,
        backingScale: CGFloat,
        rebuildAtlas: Bool
    ) {
        let prepareStart = CACurrentMediaTime()
        self.viewportSize = viewportSize
        self.animation = nil
        self.scaleAnimation = nil
        self.settleAnimation = nil
        self.frozenMode = true
        self.frozenAnchor = SIMD2(Float(anchor.x), Float(anchor.y))
        self.sourceScale = 1
        self.targetWorldScale = 1
        self.page0Alpha = 1
        self.worldAtlas = nil
        self.frozenPages.removeAll(keepingCapacity: true)   // page 0 is being (re)built → drop append pages
        self.frozenSeenKeys.removeAll(keepingCapacity: true)

        var newStats = GridSpriteRenderStats()
        newStats.descriptorCount = descriptors.count
        newStats.slotCount = descriptors.count
        newStats.nilImageDescriptorCount = descriptors.reduce(0) { $0 + ($1.image == nil ? 1 : 0) }
        newStats.placeholderDescriptorCount = descriptors.reduce(0) { $0 + ($1.usedPlaceholderFallback ? 1 : 0) }

        let keysCovered = !descriptors.isEmpty && descriptors.allSatisfy { atlasUVByKey[$0.key] != nil }
        let needsRebuild = rebuildAtlas || atlasTexture == nil || !keysCovered
        if needsRebuild {
            let items = descriptors
                .sorted { $0.priority < $1.priority }
                .prefix(1800)
                .map { AtlasBuildItem(descriptor: $0, pixelSize: Self.atlasPixelSize(for: $0, backingScale: backingScale)) }
            newStats.atlasItemCount = items.count
            if let atlas = buildAtlas(for: Array(items)) {
                atlasTexture = atlas.texture
                atlasUVByKey = atlas.uvByKey
                newStats.atlasPlacementCount = atlas.placementCount
                newStats.atlasDimension = atlas.dimension
                lastAtlasDimension = atlas.dimension
            } else {
                atlasTexture = nil; atlasUVByKey = [:]; frozenVertices = []; frozenVertexBuffer = nil
                newStats.cpuPrepareMs = (CACurrentMediaTime() - prepareStart) * 1000
                stampCounters(into: &newStats)
                stats = newStats
                return
            }
        } else {
            newStats.atlasItemCount = atlasUVByKey.count
            newStats.atlasPlacementCount = atlasUVByKey.count
            newStats.atlasDimension = lastAtlasDimension
        }

        newStats.droppedMissingUVCount = descriptors.reduce(0) { $0 + (atlasUVByKey[$1.key] == nil ? 1 : 0) }

        frozenVertices.removeAll(keepingCapacity: true)
        for descriptor in descriptors {
            guard descriptor.image != nil, let uv = atlasUVByKey[descriptor.key] else { continue }   // nil image → never a black tile
            let frame = descriptor.fromFrame
            guard frame.width > 0.5, frame.height > 0.5 else { continue }
            let crop = descriptor.fillSquare ? Self.squareCroppedUV(uvMin: uv.min, uvMax: uv.max, imageSize: descriptor.imageSize) : (min: uv.min, max: uv.max)
            appendQuad(into: &frozenVertices, frame: frame, uvMin: crop.min, uvMax: crop.max, radius: Float(GridVisualConstants.thumbnailCornerRadius), alpha: descriptor.fromAlpha)
            frozenSeenKeys.insert(descriptor.key)
        }
        frozenVertexBuffer = frozenVertices.isEmpty
            ? nil
            : device.makeBuffer(bytes: frozenVertices, length: MemoryLayout<Vertex>.stride * frozenVertices.count, options: .storageModeShared)
        newStats.renderedSpriteCount = frozenVertices.count / 6
        newStats.perFrameAllocationBytes = frozenVertices.count * MemoryLayout<Vertex>.stride
        newStats.cpuPrepareMs = (CACurrentMediaTime() - prepareStart) * 1000
        stampCounters(into: &newStats)
        stats = newStats
    }

    /// Pass #11 per-cell compositor: rebuild ONLY the frozen source vertex buffer from `descriptors`
    /// (each carrying its own per-cell `fromAlpha`), reusing the existing atlas — no atlas rebuild, no
    /// change to `sourceScale` / append pages / animations. Cells whose key is not in the atlas (or whose
    /// alpha ≈ 0) are dropped. This is what fades individual source photos out outside the focus band.
    func updateFrozenSourceNodes(_ descriptors: [GridTransitionSpriteDescriptor]) {
        let prepareStart = CACurrentMediaTime()
        guard frozenMode, atlasTexture != nil else { return }
        frozenVertices.removeAll(keepingCapacity: true)
        for d in descriptors {
            guard d.image != nil, let uv = atlasUVByKey[d.key] else { continue }
            let frame = d.fromFrame
            guard frame.width > 0.5, frame.height > 0.5, d.fromAlpha > 0.003 else { continue }
            let crop = d.fillSquare ? Self.squareCroppedUV(uvMin: uv.min, uvMax: uv.max, imageSize: d.imageSize) : (min: uv.min, max: uv.max)
            appendQuad(into: &frozenVertices, frame: frame, uvMin: crop.min, uvMax: crop.max, radius: Float(GridVisualConstants.thumbnailCornerRadius), alpha: d.fromAlpha)
        }
        frozenVertexBuffer = frozenVertices.isEmpty
            ? nil
            : device.makeBuffer(bytes: frozenVertices, length: MemoryLayout<Vertex>.stride * frozenVertices.count, options: .storageModeShared)
        vertexBuildCount += 1
        lastVertexBuildMs = (CACurrentMediaTime() - prepareStart) * 1000
        stats.descriptorCount = descriptors.count
        stats.slotCount = descriptors.count
        stats.renderedSpriteCount = frozenVertices.count / 6 + frozenPages.reduce(0) { $0 + $1.vertexCount / 6 }
        stats.perFrameAllocationBytes = frozenVertices.count * MemoryLayout<Vertex>.stride
        stats.cpuPrepareMs = lastVertexBuildMs
        stampCounters(into: &stats)
    }

    /// Append a `role` page on top of page 0 WITHOUT rebuilding it. Builds the page its own atlas +
    /// vertex buffer. Source/coverage pages dedupe against keys already shown so the same photo is never
    /// drawn twice; target (scale-exempt) pages use a separate keyspace and are never deduped.
    /// `pageAlpha` is the initial whole-page opacity (target preview starts at 0, animated up at settle).
    /// Returns render accounting for the `[GridZoom] pageAppend` log.
    func appendFrozenPage(
        sprites descriptors: [GridTransitionSpriteDescriptor],
        backingScale: CGFloat,
        role: FrozenPageRole,
        pageAlpha: Float,
        sourceRect: CGRect,
        settleWindow: SIMD2<Float>? = nil
    ) -> (rendered: Int, skippedNil: Int, skippedDup: Int, pageCount: Int) {
        let prepareStart = CACurrentMediaTime()
        guard frozenMode else { return (0, 0, 0, frozenPages.count) }
        let dedup = role.isSourceRole
        var skippedNil = 0, skippedDup = 0
        let fresh = descriptors.filter { d in
            if d.image == nil { skippedNil += 1; return false }
            if dedup, frozenSeenKeys.contains(d.key) { skippedDup += 1; return false }
            return true
        }
        guard !fresh.isEmpty else { return (0, skippedNil, skippedDup, frozenPages.count) }

        let items = fresh
            .sorted { $0.priority < $1.priority }
            .prefix(600)
            .map { AtlasBuildItem(descriptor: $0, pixelSize: Self.atlasPixelSize(for: $0, backingScale: backingScale)) }
        guard let atlas = buildAtlas(for: Array(items)) else { return (0, skippedNil, skippedDup, frozenPages.count) }

        let (verts, keys) = buildPageVertices(from: fresh, uvByKey: atlas.uvByKey)
        guard !verts.isEmpty,
              let buffer = device.makeBuffer(bytes: verts, length: MemoryLayout<Vertex>.stride * verts.count, options: .storageModeShared) else {
            return (0, skippedNil, skippedDup, frozenPages.count)
        }
        if dedup { frozenSeenKeys.formUnion(keys) }
        frozenPages.append(FrozenPage(texture: atlas.texture, vertexBuffer: buffer, vertexCount: verts.count, sourceRect: sourceRect, keys: keys, role: role, pageAlpha: pageAlpha, settleWindow: settleWindow))
        stats.renderedSpriteCount = totalFrozenSpriteCount()
        stats.descriptorCount = descriptors.count
        stats.slotCount = descriptors.count
        stats.perFrameAllocationBytes = verts.count * MemoryLayout<Vertex>.stride
        stats.cpuPrepareMs = (CACurrentMediaTime() - prepareStart) * 1000
        stampCounters(into: &stats)
        return (verts.count / 6, skippedNil, skippedDup, frozenPages.count)
    }

    /// Atomically replace all pages of `role` with a freshly-built one. Builds the new page FIRST; only
    /// swaps if it rendered some sprites AND not fewer than the page it replaces — so a transient decode
    /// gap never shows an empty hole (keep the previous, better-covered page instead). Used for the live
    /// `.targetWorld` surface, which rebuilds as the pinch moves. `blackTileCount` is always 0 (nil images
    /// are skipped, never drawn).
    func replacePages(
        sprites descriptors: [GridTransitionSpriteDescriptor],
        backingScale: CGFloat,
        role: FrozenPageRole,
        pageAlpha: Float,
        sourceRect: CGRect
    ) -> (rendered: Int, visibleNeeded: Int, missingImage: Int, keptPrevious: Bool, coverageRatio: Double, blackTileCount: Int, pageCount: Int) {
        let prepareStart = CACurrentMediaTime()
        let prevRendered = frozenPages.filter { $0.role == role }.reduce(0) { $0 + $1.vertexCount / 6 }
        guard frozenMode else { return (0, descriptors.count, 0, false, 0, 0, frozenPages.count) }
        // The caller supplies a fallback image for every cell (never nil) so there are no holes; count
        // any nil defensively.
        var missingImage = 0
        let usable = descriptors.filter { d in if d.image == nil { missingImage += 1; return false }; return true }

        // Reuse the backdrop atlas when the cell set is unchanged → cheap VERTEX-only rebuild for the
        // live alpha/scale. Rebuild it only when new keys appear (scroll/level change, or a
        // placeholder→real upgrade, which changes the key from "…:ph" to the real key).
        let keys = Set(usable.map(\.key))
        let reuse = worldAtlas.map { keys.isSubset(of: $0.keys) } ?? false
        var texture: MTLTexture?
        var uvByKey: [String: (min: SIMD2<Float>, max: SIMD2<Float>)]?
        if reuse, let atlas = worldAtlas {
            texture = atlas.texture; uvByKey = atlas.uvByKey
        } else {
            let items = usable.sorted { $0.priority < $1.priority }.prefix(900)
                .map { AtlasBuildItem(descriptor: $0, pixelSize: Self.atlasPixelSize(for: $0, backingScale: backingScale)) }
            if let atlas = items.isEmpty ? nil : buildAtlas(for: Array(items)) {
                worldAtlas = (atlas.texture, atlas.uvByKey, Set(atlas.uvByKey.keys))
                texture = atlas.texture; uvByKey = atlas.uvByKey
            }
        }
        let built = uvByKey.map { buildPageVertices(from: usable, uvByKey: $0) }
        let newRendered = (built?.verts.count ?? 0) / 6
        let keptPrevious = newRendered == 0          // with fallback images this only happens if the atlas failed
        if !keptPrevious, let texture, let built,
           let buffer = device.makeBuffer(bytes: built.verts, length: MemoryLayout<Vertex>.stride * built.verts.count, options: .storageModeShared) {
            frozenPages.removeAll { $0.role == role }
            frozenPages.append(FrozenPage(texture: texture, vertexBuffer: buffer, vertexCount: built.verts.count, sourceRect: sourceRect, keys: built.keys, role: role, pageAlpha: pageAlpha))
            vertexBuildCount += 1
            lastVertexBuildMs = (CACurrentMediaTime() - prepareStart) * 1000
        }
        stats.descriptorCount = descriptors.count
        stats.slotCount = descriptors.count
        stats.placeholderDescriptorCount = descriptors.reduce(0) { $0 + ($1.usedPlaceholderFallback ? 1 : 0) }
        stats.droppedMissingUVCount = max(0, descriptors.count - newRendered)
        stats.perFrameAllocationBytes = (built?.verts.count ?? 0) * MemoryLayout<Vertex>.stride
        stats.cpuPrepareMs = (CACurrentMediaTime() - prepareStart) * 1000
        stats.renderedSpriteCount = totalFrozenSpriteCount()
        stampCounters(into: &stats)
        let shown = keptPrevious ? prevRendered : newRendered
        let coverage = descriptors.isEmpty ? 1 : Double(shown) / Double(descriptors.count)
        return (newRendered, descriptors.count, missingImage, keptPrevious, coverage, 0, frozenPages.count)
    }

    /// Shared quad build: skip nil images (never a black tile), center-crop `fillSquare` sprites, apply
    /// the shared corner radius. Returns the vertex list + the keys that made it in.
    private func buildPageVertices(from descriptors: [GridTransitionSpriteDescriptor], uvByKey: [String: (min: SIMD2<Float>, max: SIMD2<Float>)]) -> (verts: [Vertex], keys: Set<String>) {
        var verts: [Vertex] = []
        var keys: Set<String> = []
        for descriptor in descriptors {
            guard descriptor.image != nil, let uv = uvByKey[descriptor.key] else { continue }
            let frame = descriptor.fromFrame
            guard frame.width > 0.5, frame.height > 0.5 else { continue }
            let crop = descriptor.fillSquare ? Self.squareCroppedUV(uvMin: uv.min, uvMax: uv.max, imageSize: descriptor.imageSize) : (min: uv.min, max: uv.max)
            appendQuad(into: &verts, frame: frame, uvMin: crop.min, uvMax: crop.max, radius: Float(GridVisualConstants.thumbnailCornerRadius), alpha: descriptor.fromAlpha)
            keys.insert(descriptor.key)
        }
        return (verts, keys)
    }

    func setTargetFillScale(_ scale: Float) { targetWorldScale = scale }

    /// Drop pages whose role is in `roles` (e.g. at settle). Prefer `replacePages` for live `.targetWorld`
    /// rebuilds so there's never an empty frame between clear and append.
    func clearPages(roles: Set<FrozenPageRole>) {
        frozenPages.removeAll { roles.contains($0.role) }
        stats.renderedSpriteCount = totalFrozenSpriteCount()
        stampCounters(into: &stats)
    }

    func setSourceScale(_ scale: Float) {
        scaleAnimation = nil
        settleAnimation = nil
        sourceScale = scale
    }

    func animateSourceScale(to target: Float, duration: TimeInterval, completion: @escaping () -> Void) {
        settleAnimation = nil
        scaleAnimation = ScaleAnimation(from: sourceScale, to: target, start: CACurrentMediaTime(), duration: max(duration, 0.001), completion: completion)
    }

    /// Settle cross-fade: source scale → `toScale` while source pages fade out and any `.targetPreview`
    /// page fades in. Drives `page0Alpha` and per-page `pageAlpha` from a single eased progress.
    func animateSettleCrossfade(toScale: Float, duration: TimeInterval, latePreview: Bool = false, completion: @escaping () -> Void) {
        scaleAnimation = nil
        settleAnimation = SettleAnimation(fromScale: sourceScale, toScale: toScale, start: CACurrentMediaTime(), duration: max(duration, 0.001), latePreview: latePreview, completion: completion)
    }

    @MainActor func draw(in view: MTKView) {
        let drawStart = CACurrentMediaTime()
        updateAnimationIfNeeded()
        guard let drawable = view.currentDrawable,
              let passDescriptor = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if frozenMode {
            encodeFrozen(into: commandBuffer, pass: passDescriptor)
        } else {
            encodeLegacy(into: commandBuffer, pass: passDescriptor)
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastDrawMs = (CACurrentMediaTime() - drawStart) * 1000
        stampCounters(into: &stats)
    }

    /// Frozen-source mode: reuse the persistent base-geometry buffer(s) and just push the scale/anchor
    /// uniform. No per-frame CPU vertex work or buffer allocation. Page 0 plus any appended coverage
    /// pages scale with `sourceScale`; ghost pages (`scaleExempt`) draw at identity over the top.
    @MainActor private func encodeFrozen(into commandBuffer: MTLCommandBuffer, pass passDescriptor: MTLRenderPassDescriptor) {
        struct DrawPage { let order: Int; let texture: MTLTexture; let buffer: MTLBuffer; let count: Int; let anchor: SIMD2<Float>; let scale: Float; let alpha: Float }
        // Per-role transform: source/coverage scale with the live `sourceScale`. The target-world nodes
        // scale with their OWN `targetWorldScale` (= apparent / targetLevelSize), so they sit at the target
        // detent instead of shrinking with the old source layout. The preview is the final grid at the
        // commit origin, drawn at identity.
        func transform(for role: FrozenPageRole) -> (anchor: SIMD2<Float>, scale: Float) {
            switch role {
            case .sourcePlate, .source, .sourceCoverage: return (frozenAnchor, sourceScale)
            case .targetWorld, .topologyGhost: return (frozenAnchor, targetWorldScale)
            case .targetPreview, .worldSlots: return (SIMD2(0, 0), 1)   // slot rects are already screen-space
            }
        }
        var pages: [DrawPage] = []
        // Pass #12 SLOT MODE: the `.worldSlots` page IS the whole world (screen-space slot quads). When it
        // is present, draw ONLY it — page 0 and the source/target pages are suppressed so there is no
        // independent source rectangle or target wall underneath.
        let slotModeActive = frozenPages.contains { $0.role == .worldSlots && $0.pageAlpha > 0.003 }
        if !slotModeActive, let atlasTexture, let buffer = frozenVertexBuffer, !frozenVertices.isEmpty, page0Alpha > 0.003 {
            let t = transform(for: .source)
            pages.append(DrawPage(order: FrozenPageRole.source.drawOrder, texture: atlasTexture, buffer: buffer, count: frozenVertices.count, anchor: t.anchor, scale: t.scale, alpha: page0Alpha))
        }
        for page in frozenPages where page.pageAlpha > 0.003 {
            if slotModeActive && page.role != .worldSlots { continue }
            let t = transform(for: page.role)
            pages.append(DrawPage(order: page.role.drawOrder, texture: page.texture, buffer: page.vertexBuffer, count: page.vertexCount, anchor: t.anchor, scale: t.scale, alpha: page.pageAlpha))
        }
        // Deterministic back → front: targetWorld nodes UNDER source, then source thumbnails, coverage,
        // any topology ghost, and finally the settle preview. Source occludes the target world by depth.
        pages.sort { $0.order < $1.order }
        guard !pages.isEmpty, let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)?.endEncoding()
            return
        }
        let viewport = SIMD2(Float(max(viewportSize.width, 1)), Float(max(viewportSize.height, 1)))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        for page in pages {
            var uniforms = VertexUniforms(viewportSize: viewport, anchor: page.anchor, scale: page.scale, pageAlpha: page.alpha)
            encoder.setVertexBuffer(page.buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<VertexUniforms>.stride, index: 1)
            encoder.setFragmentTexture(page.texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: page.count)
        }
        encoder.endEncoding()
    }

    /// Legacy descriptor/progress mode (used only when target ghosts are re-enabled). Rebuilds vertices
    /// per frame and uses an identity transform (anchor 0, scale 1).
    @MainActor private func encodeLegacy(into commandBuffer: MTLCommandBuffer, pass passDescriptor: MTLRenderPassDescriptor) {
        if let atlasTexture, !sprites.isEmpty {
            buildVertices()
            if !vertices.isEmpty,
               let vertexBuffer = device.makeBuffer(
                bytes: vertices,
                length: MemoryLayout<Vertex>.stride * vertices.count,
                options: .storageModeShared
               ),
               let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
                var uniforms = VertexUniforms(viewportSize: SIMD2(Float(max(viewportSize.width, 1)), Float(max(viewportSize.height, 1))), anchor: SIMD2(0, 0), scale: 1, pageAlpha: 1)
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<VertexUniforms>.stride, index: 1)
                encoder.setFragmentTexture(atlasTexture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
                encoder.endEncoding()
            } else if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
                encoder.endEncoding()
            }
        } else if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) {
            encoder.endEncoding()
        }
    }

    @MainActor private func updateAnimationIfNeeded() {
        if let animation {
            let elapsed = CACurrentMediaTime() - animation.start
            let raw = Float(min(max(elapsed / animation.duration, 0), 1))
            let eased = 1 - pow(1 - raw, 3)
            progress = animation.from + (animation.to - animation.from) * eased
            if raw >= 1 {
                self.animation = nil
                DispatchQueue.main.async { animation.completion() }
            }
        }
        if let scaleAnimation {
            let elapsed = CACurrentMediaTime() - scaleAnimation.start
            let raw = Float(min(max(elapsed / scaleAnimation.duration, 0), 1))
            let eased = 1 - pow(1 - raw, 3)
            sourceScale = scaleAnimation.from + (scaleAnimation.to - scaleAnimation.from) * eased
            if raw >= 1 {
                self.scaleAnimation = nil
                DispatchQueue.main.async { scaleAnimation.completion() }
            }
        }
        if let settleAnimation {
            let elapsed = CACurrentMediaTime() - settleAnimation.start
            let raw = Float(min(max(elapsed / settleAnimation.duration, 0), 1))
            let eased = 1 - pow(1 - raw, 3)
            sourceScale = settleAnimation.fromScale + (settleAnimation.toScale - settleAnimation.fromScale) * eased
            // Source surface fades out; the target-preview page fades in. With `latePreview`, the preview
            // only dissolves in over the LAST window (smoothstep 0.72→1), so it is not a full wall from
            // the first frame — the focus stays source-dominant until late.
            func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
                let t = min(max((x - e0) / max(e1 - e0, 0.0001), 0), 1); return t * t * (3 - 2 * t)
            }
            let previewAlpha = settleAnimation.latePreview ? smoothstep(0.72, 1.0, eased) : eased
            let sourceAlpha = settleAnimation.latePreview ? (1 - smoothstep(0.72, 1.0, eased)) : (1 - eased)
            page0Alpha = sourceAlpha
            for index in frozenPages.indices {
                switch frozenPages[index].role {
                case .sourcePlate, .source, .sourceCoverage, .targetWorld, .topologyGhost: frozenPages[index].pageAlpha = sourceAlpha
                case .worldSlots: break   // pass #12: slot page alpha is driven per-tick by replaceWorldSlots, not this crossfade
                case .targetPreview:
                    // A per-page settle window lets the focus-band preview dissolve in LATER than the
                    // far-band preview (focus is replaced last); nil → the default late window.
                    if let w = frozenPages[index].settleWindow {
                        frozenPages[index].pageAlpha = smoothstep(w.x, w.y, eased)
                    } else {
                        frozenPages[index].pageAlpha = previewAlpha
                    }
                }
            }
            if raw >= 1 {
                self.settleAnimation = nil
                DispatchQueue.main.async { settleAnimation.completion() }
            }
        }
    }

    private func buildVertices() {
        let start = CACurrentMediaTime()
        vertices.removeAll(keepingCapacity: true)
        let visibleRect = CGRect(origin: .zero, size: viewportSize).insetBy(dx: -2, dy: -2)
        for sprite in sprites {
            let localProgress = phasedProgress(global: progress, start: sprite.phaseStart, end: sprite.phaseEnd)
            let frame = interpolate(sprite.fromFrame, sprite.toFrame, progress: CGFloat(localProgress))
            guard frame.width > 0.5, frame.height > 0.5, frame.intersects(visibleRect) else { continue }
            let alpha = sprite.fromAlpha + (sprite.toAlpha - sprite.fromAlpha) * localProgress
            guard alpha > 0.01 else { continue }
            let radius = Float(min(10, max(2, frame.height * 0.06)))
            appendQuad(into: &vertices, frame: frame, uvMin: sprite.uvMin, uvMax: sprite.uvMax, radius: radius, alpha: alpha)
        }
        stats.renderedSpriteCount = vertices.count / 6
        vertexBuildCount += 1
        lastVertexBuildMs = (CACurrentMediaTime() - start) * 1000
        stampCounters(into: &stats)
    }

    private func phasedProgress(global progress: Float, start: Float, end: Float) -> Float {
        let lo = min(start, end)
        let hi = max(start, end)
        let raw = (progress - lo) / max(hi - lo, 0.001)
        let t = max(0, min(1, raw))
        return t * t * (3 - 2 * t)
    }

    private func appendQuad(into vertices: inout [Vertex], frame: CGRect, uvMin: SIMD2<Float>, uvMax: SIMD2<Float>, radius: Float, alpha: Float) {
        let x0 = Float(frame.minX), y0 = Float(frame.minY)
        let x1 = Float(frame.maxX), y1 = Float(frame.maxY)
        let w = Float(frame.width), h = Float(frame.height)
        let size = SIMD2(w, h)
        let topLeft = Vertex(position: SIMD2(x0, y0), uv: SIMD2(uvMin.x, uvMin.y), local: SIMD2(0, 0), size: size, radius: radius, alpha: alpha)
        let topRight = Vertex(position: SIMD2(x1, y0), uv: SIMD2(uvMax.x, uvMin.y), local: SIMD2(w, 0), size: size, radius: radius, alpha: alpha)
        let bottomLeft = Vertex(position: SIMD2(x0, y1), uv: SIMD2(uvMin.x, uvMax.y), local: SIMD2(0, h), size: size, radius: radius, alpha: alpha)
        let bottomRight = Vertex(position: SIMD2(x1, y1), uv: SIMD2(uvMax.x, uvMax.y), local: SIMD2(w, h), size: size, radius: radius, alpha: alpha)
        vertices.append(contentsOf: [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight])
    }

    private func interpolate(_ from: CGRect, _ to: CGRect, progress: CGFloat) -> CGRect {
        CGRect(
            x: from.minX + (to.minX - from.minX) * progress,
            y: from.minY + (to.minY - from.minY) * progress,
            width: from.width + (to.width - from.width) * progress,
            height: from.height + (to.height - from.height) * progress
        )
    }

    private func buildAtlas(
        for rawItems: [AtlasBuildItem]
    ) -> (texture: MTLTexture, uvByKey: [String: (min: SIMD2<Float>, max: SIMD2<Float>)], placementCount: Int, dimension: Int)? {
        let atlasStart = CACurrentMediaTime()
        // Dedup by key: duplicate keys (e.g. the shared neutral placeholder used for many missing cells)
        // need only ONE atlas placement — all sprites with that key sample the same region.
        var seenKeys = Set<String>()
        let items = rawItems.filter { seenKeys.insert($0.descriptor.key).inserted }
        guard !items.isEmpty else { return nil }
        let totalArea = items.reduce(CGFloat(0)) { $0 + $1.pixelSize.width * $1.pixelSize.height }
        let largestSide = items.reduce(CGFloat(64)) { max($0, $1.pixelSize.width, $1.pixelSize.height) }
        var dimension = Self.roundedTextureDimension(Int(max(largestSide, sqrt(totalArea * 1.25))))
        dimension = min(max(dimension, 1024), 6144)

        var placements: [AtlasPlacement] = []
        while true {
            placements = Self.pack(items: items, dimension: dimension)
            if placements.count == items.count || dimension >= 6144 { break }
            dimension = min(6144, dimension + 1024)
        }
        guard !placements.isEmpty else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = dimension * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * dimension)
        guard let context = CGContext(
            data: &pixels,
            width: dimension,
            height: dimension,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        // EXACTLY ONE vertical flip (proven by `orientationSelfTest`): draw into the default bottom-left
        // CGContext (NO context flip), then flip V in the UVs below. Metal reads texture row 0 as the
        // TOP while CG's row 0 is the BOTTOM, so the single `1 - y/dim` UV flip lands the image upright.
        // (Having BOTH a context flip and the UV flip — the previous code — double-flipped → rotated /
        // black sprites.)
        //
        // Missing images are left TRANSPARENT (not filled) — a nil image must never become a black tile.
        // Callers also skip nil-image descriptors before vertex build, so these regions are never drawn.
        var output: [String: (min: SIMD2<Float>, max: SIMD2<Float>)] = [:]
        output.reserveCapacity(placements.count)
        for placement in placements {
            let rect = placement.rect
            if let image = placement.item.descriptor.image {
                context.draw(image, in: rect)
            }
            let uvMin = SIMD2(
                Float(rect.minX / CGFloat(dimension)),
                Float(1 - rect.maxY / CGFloat(dimension))
            )
            let uvMax = SIMD2(
                Float(rect.maxX / CGFloat(dimension)),
                Float(1 - rect.minY / CGFloat(dimension))
            )
            output[placement.item.descriptor.key] = (uvMin, uvMax)
        }

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: dimension,
            height: dimension,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else { return nil }
        let uploadStart = CACurrentMediaTime()
        texture.replace(
            region: MTLRegionMake2D(0, 0, dimension, dimension),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: bytesPerRow
        )
        lastTextureUploadMs = (CACurrentMediaTime() - uploadStart) * 1000
        lastAtlasBuildMs = (CACurrentMediaTime() - atlasStart) * 1000
        atlasBuildCount += 1
        textureUploadCount += 1
        return (texture, output, placements.count, dimension)
    }

    // MARK: - Orientation self-test

    /// A 64×64 image whose data row 0 (visual top) is RED on the left, GREEN on the right; bottom row is
    /// BLUE on the left, YELLOW on the right. Distinct corners make any flip/rotation obvious.
    private static func makeOrientationTestImage(side: Int = 64) -> CGImage? {
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        for row in 0 ..< side {
            for col in 0 ..< side {
                let i = (row * side + col) * 4
                let top = row < side / 2, left = col < side / 2
                let (r, g, b): (UInt8, UInt8, UInt8) = top
                    ? (left ? (255, 0, 0) : (0, 255, 0))
                    : (left ? (0, 0, 255) : (255, 255, 0))
                pixels[i] = r; pixels[i + 1] = g; pixels[i + 2] = b; pixels[i + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// Renders the test image through the REAL atlas/UV/quad/shader path into an off-screen target and
    /// reads back the four corners. "PASS" only if top-left is RED (image is upright). Does not disturb
    /// the live atlas (`buildAtlas` returns its own texture).
    func orientationSelfTest() -> String {
        guard let image = Self.makeOrientationTestImage() else { return "orientation: test image failed" }
        let side = 64
        let descriptor = GridTransitionSpriteDescriptor(
            key: "__orientation_probe__", image: image, imageSize: CGSize(width: side, height: side),
            fromFrame: CGRect(x: 0, y: 0, width: side, height: side),
            toFrame: CGRect(x: 0, y: 0, width: side, height: side),
            fromAlpha: 1, toAlpha: 1, priority: 0
        )
        let item = AtlasBuildItem(descriptor: descriptor, pixelSize: CGSize(width: side, height: side))
        guard let atlas = buildAtlas(for: [item]), let uv = atlas.uvByKey[descriptor.key] else {
            return "orientation: atlas build failed"
        }
        let w = Float(side), h = Float(side), size = SIMD2<Float>(w, h)
        func vertex(_ px: Float, _ py: Float, _ ux: Float, _ uy: Float, _ lx: Float, _ ly: Float) -> Vertex {
            Vertex(position: SIMD2(px, py), uv: SIMD2(ux, uy), local: SIMD2(lx, ly), size: size, radius: 0, alpha: 1)
        }
        var verts = [
            vertex(0, 0, uv.min.x, uv.min.y, 0, 0), vertex(0, h, uv.min.x, uv.max.y, 0, h), vertex(w, 0, uv.max.x, uv.min.y, w, 0),
            vertex(w, 0, uv.max.x, uv.min.y, w, 0), vertex(0, h, uv.min.x, uv.max.y, 0, h), vertex(w, h, uv.max.x, uv.max.y, w, h),
        ]
        let outDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: side, height: side, mipmapped: false)
        outDesc.usage = [.renderTarget]
        outDesc.storageMode = .managed
        guard let outTexture = device.makeTexture(descriptor: outDesc) else { return "orientation: no target" }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = outTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass),
              let vertexBuffer = device.makeBuffer(bytes: &verts, length: MemoryLayout<Vertex>.stride * verts.count, options: .storageModeShared) else {
            return "orientation: encode failed"
        }
        var uniforms = VertexUniforms(viewportSize: SIMD2(w, h), anchor: SIMD2(0, 0), scale: 1, pageAlpha: 1)
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<VertexUniforms>.stride, index: 1)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
        encoder.endEncoding()
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return "orientation: no blit" }
        blit.synchronize(resource: outTexture)
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        var out = [UInt8](repeating: 0, count: side * side * 4)
        outTexture.getBytes(&out, bytesPerRow: side * 4, from: MTLRegionMake2D(0, 0, side, side), mipmapLevel: 0)
        func cornerName(_ x: Int, _ y: Int) -> String {
            let i = (y * side + x) * 4
            let b = out[i], g = out[i + 1], r = out[i + 2]   // bgra
            if r > 180, g < 80, b < 80 { return "RED" }
            if g > 180, r < 80, b < 80 { return "GREEN" }
            if b > 180, r < 80, g < 80 { return "BLUE" }
            if r > 180, g > 180, b < 80 { return "YELLOW" }
            return "(\(r),\(g),\(b))"
        }
        let tl = cornerName(3, 3), tr = cornerName(side - 4, 3), bl = cornerName(3, side - 4), br = cornerName(side - 4, side - 4)
        let pass2 = tl == "RED" && tr == "GREEN" && bl == "BLUE" && br == "YELLOW"
        return "\(pass2 ? "PASS" : "FAIL") TL=\(tl) TR=\(tr) BL=\(bl) BR=\(br)"
    }

    /// Inset UVs to the centered square of the image, for `squareFill` (aspectFill) cells. Symmetric
    /// inset, so it's orientation-agnostic w.r.t. the atlas's flipped V. Keeps the full thumbnail in the
    /// atlas (no re-decode); just samples the center square.
    private static func squareCroppedUV(uvMin: SIMD2<Float>, uvMax: SIMD2<Float>, imageSize: CGSize) -> (min: SIMD2<Float>, max: SIMD2<Float>) {
        let inset = GridZoomMath.squareFillCropInset(imageSize: imageSize)   // shared, unit-tested
        let uw = uvMax.x - uvMin.x, vh = uvMax.y - uvMin.y
        return (SIMD2(uvMin.x + uw * Float(inset.x), uvMin.y + vh * Float(inset.y)),
                SIMD2(uvMax.x - uw * Float(inset.x), uvMax.y - vh * Float(inset.y)))
    }

    private static func atlasPixelSize(for descriptor: GridTransitionSpriteDescriptor, backingScale: CGFloat) -> CGSize {
        let maxPointSize = max(descriptor.fromFrame.width, descriptor.fromFrame.height, descriptor.toFrame.width, descriptor.toFrame.height)
        let target = min(max(ceil(maxPointSize * backingScale), 24), 256)
        let aspect = descriptor.imageSize.width / max(descriptor.imageSize.height, 1)
        if aspect >= 1 {
            return CGSize(width: target, height: max(4, ceil(target / aspect)))
        } else {
            return CGSize(width: max(4, ceil(target * aspect)), height: target)
        }
    }

    private static func pack(items: [AtlasBuildItem], dimension: Int) -> [AtlasPlacement] {
        var placements: [AtlasPlacement] = []
        var x = 0
        var y = 0
        var rowHeight = 0
        for item in items {
            let width = Int(ceil(item.pixelSize.width))
            let height = Int(ceil(item.pixelSize.height))
            guard width <= dimension, height <= dimension else { continue }
            if x + width > dimension {
                x = 0
                y += rowHeight + 2
                rowHeight = 0
            }
            guard y + height <= dimension else { continue }
            placements.append(AtlasPlacement(
                item: item,
                rect: CGRect(x: x, y: y, width: width, height: height)
            ))
            x += width + 2
            rowHeight = max(rowHeight, height)
        }
        return placements
    }

    private static func roundedTextureDimension(_ value: Int) -> Int {
        let quantum = 256
        return max(quantum, ((value + quantum - 1) / quantum) * quantum)
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexIn {
        float2 position;
        float2 uv;
        float2 local;
        float2 size;
        float radius;
        float alpha;
    };

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float2 local;
        float2 size;
        float radius;
        float alpha;
    };

    struct VertexUniforms {
        float2 viewportSize;
        float2 anchor;
        float scale;
        float pageAlpha;
    };

    vertex VertexOut gridSpriteVertex(
        uint vertexID [[vertex_id]],
        const device VertexIn *vertices [[buffer(0)]],
        constant VertexUniforms &uniforms [[buffer(1)]]
    ) {
        VertexIn input = vertices[vertexID];
        // Frozen-source mode scales the base geometry around the anchor on the GPU (one uniform per
        // frame, no CPU vertex rebuild). Legacy mode passes anchor=(0,0) scale=1 → identity.
        float2 scaled = uniforms.anchor + (input.position - uniforms.anchor) * uniforms.scale;
        float2 ndc = float2(
            (scaled.x / max(uniforms.viewportSize.x, 1.0)) * 2.0 - 1.0,
            1.0 - (scaled.y / max(uniforms.viewportSize.y, 1.0)) * 2.0
        );
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = input.uv;
        out.local = input.local;
        out.size = input.size;
        out.radius = input.radius;
        out.alpha = input.alpha * uniforms.pageAlpha;
        return out;
    }

    fragment float4 gridSpriteFragment(
        VertexOut input [[stage_in]],
        texture2d<float> atlas [[texture(0)]],
        sampler atlasSampler [[sampler(0)]]
    ) {
        float4 color = atlas.sample(atlasSampler, input.uv);
        float radius = min(input.radius, min(input.size.x, input.size.y) * 0.5);
        float2 halfSize = input.size * 0.5;
        float2 q = abs(input.local - halfSize) - (halfSize - radius);
        float distance = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
        float mask = 1.0 - smoothstep(-1.0, 1.0, distance);
        float coverage = input.alpha * mask;
        color.rgb *= coverage;
        color.a *= coverage;
        return color;
    }
    """
}
