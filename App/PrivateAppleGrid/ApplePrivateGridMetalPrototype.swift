import AppKit
import CoreGraphics
import Metal
import MetalKit
import QuartzCore
import SwiftUI
import simd

/// Isolated MTKView-backed prototype for the private Apple-style grid.
///
/// This file is intentionally not wired into the current test window or project file.
/// It gives the app a concrete Metal surface shape to evaluate before replacing the
/// existing AppKit/NSImage drawing path.
struct ApplePrivateGridMetalSpriteID: Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    var rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }

    var description: String { rawValue }
}

struct ApplePrivateGridMetalTextureKey: Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    var rawValue: String

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    init(stringLiteral value: StringLiteralType) {
        rawValue = value
    }

    var description: String { rawValue }
}

struct ApplePrivateGridMetalColor: Equatable {
    var red: Float
    var green: Float
    var blue: Float
    var alpha: Float

    static let white = ApplePrivateGridMetalColor(red: 1, green: 1, blue: 1, alpha: 1)
    static let loading = ApplePrivateGridMetalColor(red: 0.065, green: 0.065, blue: 0.070, alpha: 1)

    var vector: SIMD4<Float> {
        SIMD4(red, green, blue, alpha)
    }
}

struct ApplePrivateGridMetalSprite: Equatable {
    enum ContentMode: Equatable {
        case aspectFill
        case aspectFit
        case stretch
    }

    var id: ApplePrivateGridMetalSpriteID
    var frame: CGRect
    var textureKey: ApplePrivateGridMetalTextureKey?
    var opacity: Float
    var cornerRadius: CGFloat
    var tint: ApplePrivateGridMetalColor
    var contentMode: ContentMode
    var zIndex: Int
    var debugLabel: String?

    init(
        id: ApplePrivateGridMetalSpriteID,
        frame: CGRect,
        textureKey: ApplePrivateGridMetalTextureKey? = nil,
        opacity: Float = 1,
        cornerRadius: CGFloat = 0,
        tint: ApplePrivateGridMetalColor = .white,
        contentMode: ContentMode = .aspectFill,
        zIndex: Int = 0,
        debugLabel: String? = nil
    ) {
        self.id = id
        self.frame = frame
        self.textureKey = textureKey
        self.opacity = opacity
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.contentMode = contentMode
        self.zIndex = zIndex
        self.debugLabel = debugLabel
    }
}

struct ApplePrivateGridMetalFrame: Equatable {
    var sprites: [ApplePrivateGridMetalSprite]
    var contentSize: CGSize
    var viewport: CGRect
    var backingScale: CGFloat
    var pinchLevel: CGFloat
    var isPinching: Bool

    init(
        sprites: [ApplePrivateGridMetalSprite] = [],
        contentSize: CGSize = .zero,
        viewport: CGRect = .zero,
        backingScale: CGFloat = 1,
        pinchLevel: CGFloat = 0,
        isPinching: Bool = false
    ) {
        self.sprites = sprites.sortedForMetalGrid()
        self.contentSize = contentSize
        self.viewport = viewport
        self.backingScale = backingScale
        self.pinchLevel = pinchLevel
        self.isPinching = isPinching
    }

    static let empty = ApplePrivateGridMetalFrame()
}

struct ApplePrivateGridMetalRenderStats: Equatable {
    var hasDevice: Bool
    var drawableSize: CGSize
    var spriteCount: Int
    var visibleSpriteCount: Int
    var cachedTextureCount: Int
    var frameMillis: Double
}

enum ApplePrivateGridMetalError: LocalizedError {
    case missingDevice

    var errorDescription: String? {
        switch self {
        case .missingDevice:
            "Metal is not available for ApplePrivateGridMetalView."
        }
    }
}

struct ApplePrivateGridMetalRepresentable: NSViewRepresentable {
    var frame: ApplePrivateGridMetalFrame
    var textures: [ApplePrivateGridMetalTextureKey: MTLTexture] = [:]
    var onStats: ((ApplePrivateGridMetalRenderStats) -> Void)?

    func makeNSView(context: Context) -> ApplePrivateGridMetalView {
        let view = ApplePrivateGridMetalView()
        view.onStats = onStats
        view.setVisibleFrame(frame)
        view.setTextures(textures)
        return view
    }

    func updateNSView(_ view: ApplePrivateGridMetalView, context: Context) {
        view.onStats = onStats
        view.setVisibleFrame(frame)
        view.setTextures(textures)
    }
}

final class ApplePrivateGridMetalView: MTKView {
    var onStats: ((ApplePrivateGridMetalRenderStats) -> Void)? {
        get { renderer.onStats }
        set { renderer.onStats = newValue }
    }

    private let renderer: ApplePrivateGridMetalRenderer
    private var textureLoader: MTKTextureLoader?

    override init(frame frameRect: CGRect = .zero, device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        let renderer = ApplePrivateGridMetalRenderer(device: device)
        self.renderer = renderer
        super.init(frame: frameRect, device: device)
        configureMetalView(device: device)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        let device = MTLCreateSystemDefaultDevice()
        renderer = ApplePrivateGridMetalRenderer(device: device)
        super.init(coder: coder)
        self.device = device
        configureMetalView(device: device)
    }

    override var isFlipped: Bool { true }

    func setVisibleItems(
        _ sprites: [ApplePrivateGridMetalSprite],
        contentSize: CGSize,
        viewport: CGRect,
        backingScale: CGFloat? = nil,
        pinchLevel: CGFloat = 0,
        isPinching: Bool = false
    ) {
        let frame = ApplePrivateGridMetalFrame(
            sprites: sprites,
            contentSize: contentSize,
            viewport: viewport,
            backingScale: backingScale ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1,
            pinchLevel: pinchLevel,
            isPinching: isPinching
        )
        setVisibleFrame(frame)
    }

    func setVisibleFrame(_ frame: ApplePrivateGridMetalFrame) {
        renderer.setFrame(frame)
        draw()
    }

    func setViewport(_ viewport: CGRect, backingScale: CGFloat? = nil) {
        renderer.updateViewport(
            viewport,
            backingScale: backingScale ?? window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        )
        draw()
    }

    func setTexture(_ texture: MTLTexture?, for key: ApplePrivateGridMetalTextureKey) {
        renderer.setTexture(texture, for: key)
    }

    func setTextures(_ textures: [ApplePrivateGridMetalTextureKey: MTLTexture]) {
        renderer.setTextures(textures)
    }

    func removeUnusedTextures(keeping keys: Set<ApplePrivateGridMetalTextureKey>) {
        renderer.removeUnusedTextures(keeping: keys)
    }

    func removeAllTextures() {
        renderer.removeAllTextures()
    }

    func loadTexture(from cgImage: CGImage, for key: ApplePrivateGridMetalTextureKey) throws {
        guard let textureLoader else { throw ApplePrivateGridMetalError.missingDevice }
        let texture = try textureLoader.newTexture(
            cgImage: cgImage,
            options: [
                .SRGB: false,
                .textureUsage: NSNumber(value: MTLTextureUsage.shaderRead.rawValue)
            ]
        )
        setTexture(texture, for: key)
    }

    private func configureMetalView(device: MTLDevice?) {
        wantsLayer = true
        clearColor = MTLClearColorMake(0, 0, 0, 1)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        preferredFramesPerSecond = 120
        enableSetNeedsDisplay = false
        isPaused = false
        presentsWithTransaction = false
        delegate = renderer

        renderer.attach(to: self)
        if let device {
            textureLoader = MTKTextureLoader(device: device)
        }
    }
}

private final class ApplePrivateGridMetalRenderer: NSObject, MTKViewDelegate {
    var onStats: ((ApplePrivateGridMetalRenderStats) -> Void)?

    private weak var view: MTKView?
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let lock = NSLock()
    private var frame = ApplePrivateGridMetalFrame.empty
    private var textures: [ApplePrivateGridMetalTextureKey: MTLTexture] = [:]
    private var samplerState: MTLSamplerState?
    private var pipelineState: MTLRenderPipelineState?
    private var vertexBuffer: MTLBuffer?
    private var uniformBuffer: MTLBuffer?
    private var lastDrawableSize: CGSize = .zero

    init(device: MTLDevice?) {
        self.device = device
        commandQueue = device?.makeCommandQueue()
        super.init()
        samplerState = Self.makeSampler(device: device)
    }

    func attach(to view: MTKView) {
        self.view = view
        lastDrawableSize = view.drawableSize
    }

    func setFrame(_ frame: ApplePrivateGridMetalFrame) {
        lock.withLock {
            self.frame = frame
        }
    }

    func updateViewport(_ viewport: CGRect, backingScale: CGFloat) {
        lock.withLock {
            frame.viewport = viewport
            frame.backingScale = backingScale
        }
    }

    func setTexture(_ texture: MTLTexture?, for key: ApplePrivateGridMetalTextureKey) {
        lock.withLock {
            textures[key] = texture
        }
    }

    func setTextures(_ textures: [ApplePrivateGridMetalTextureKey: MTLTexture]) {
        lock.withLock {
            self.textures = textures
        }
    }

    func removeUnusedTextures(keeping keys: Set<ApplePrivateGridMetalTextureKey>) {
        lock.withLock {
            textures = textures.filter { keys.contains($0.key) }
        }
    }

    func removeAllTextures() {
        lock.withLock {
            textures.removeAll()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        lastDrawableSize = size
    }

    func draw(in view: MTKView) {
        let start = CACurrentMediaTime()
        guard
            let commandQueue,
            let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable
        else {
            emitStats(drawableSize: view.drawableSize, visibleSpriteCount: 0, frameMillis: 0)
            return
        }

        let snapshot = lock.withLock {
            (frame, textures)
        }
        let visibleSprites = visibleSprites(in: snapshot.0)
        rebuildPipelineIfNeeded(pixelFormat: view.colorPixelFormat)
        updateBuffersIfNeeded(for: visibleSprites, viewport: snapshot.0.viewport, drawableSize: view.drawableSize)

        let commandBuffer = commandQueue.makeCommandBuffer()
        commandBuffer?.label = "ApplePrivateGridMetalPrototype Command Buffer"

        let encoder = commandBuffer?.makeRenderCommandEncoder(descriptor: descriptor)
        encoder?.label = "ApplePrivateGridMetalPrototype Clear and Sprite Pass"
        encodeSprites(visibleSprites, textures: snapshot.1, encoder: encoder, viewport: snapshot.0.viewport)
        encoder?.endEncoding()

        commandBuffer?.present(drawable)
        commandBuffer?.commit()

        let frameMillis = (CACurrentMediaTime() - start) * 1000
        emitStats(
            drawableSize: view.drawableSize,
            visibleSpriteCount: visibleSprites.count,
            frameMillis: frameMillis
        )
    }

    private func visibleSprites(in frame: ApplePrivateGridMetalFrame) -> [ApplePrivateGridMetalSprite] {
        let viewport = frame.viewport.isNull || frame.viewport.isEmpty
            ? CGRect(origin: .zero, size: frame.contentSize)
            : frame.viewport
        let expandedViewport = viewport.insetBy(dx: -viewport.width * 0.15, dy: -viewport.height * 0.35)
        return frame.sprites.filter { sprite in
            sprite.opacity > 0 && sprite.frame.intersects(expandedViewport)
        }
    }

    private func rebuildPipelineIfNeeded(pixelFormat: MTLPixelFormat) {
        guard pipelineState == nil, device != nil else { return }
        _ = pixelFormat

        // Hook point for the later real sprite shader:
        // - load a tiny vertex/fragment function pair from the app's Metal library,
        // - configure alpha blending for photo edges,
        // - keep rounded-corner masking in the fragment stage or via SDF uniforms.
    }

    private func updateBuffersIfNeeded(
        for sprites: [ApplePrivateGridMetalSprite],
        viewport: CGRect,
        drawableSize: CGSize
    ) {
        guard let device else { return }
        let requiredVertexBytes = max(1, sprites.count * 6 * MemoryLayout<ApplePrivateGridMetalVertex>.stride)
        if vertexBuffer == nil || (vertexBuffer?.length ?? 0) < requiredVertexBytes {
            vertexBuffer = device.makeBuffer(length: requiredVertexBytes, options: [.storageModeShared])
            vertexBuffer?.label = "ApplePrivateGridMetalPrototype Sprite Vertices"
        }

        if uniformBuffer == nil || (uniformBuffer?.length ?? 0) < MemoryLayout<ApplePrivateGridMetalUniforms>.stride {
            uniformBuffer = device.makeBuffer(length: MemoryLayout<ApplePrivateGridMetalUniforms>.stride, options: [.storageModeShared])
            uniformBuffer?.label = "ApplePrivateGridMetalPrototype Uniforms"
        }

        let uniforms = ApplePrivateGridMetalUniforms(
            viewportOrigin: SIMD2(Float(viewport.minX), Float(viewport.minY)),
            viewportSize: SIMD2(Float(max(viewport.width, 1)), Float(max(viewport.height, 1))),
            drawableSize: SIMD2(Float(max(drawableSize.width, 1)), Float(max(drawableSize.height, 1))),
            spriteCount: UInt32(sprites.count)
        )
        uniformBuffer?.contents().copyMemory(from: [uniforms], byteCount: MemoryLayout<ApplePrivateGridMetalUniforms>.stride)
    }

    private func encodeSprites(
        _ sprites: [ApplePrivateGridMetalSprite],
        textures: [ApplePrivateGridMetalTextureKey: MTLTexture],
        encoder: MTLRenderCommandEncoder?,
        viewport: CGRect
    ) {
        guard let encoder else { return }
        _ = sprites
        _ = textures
        _ = viewport
        _ = samplerState
        _ = pipelineState
        _ = vertexBuffer
        _ = uniformBuffer

        // Deliberately a no-op for this prototype revision. The command encoder,
        // buffers, sampler, texture cache, culling, and stats path are live; the
        // next step is adding the shader library and issuing draw calls here.
        encoder.pushDebugGroup("ApplePrivateGridMetalPrototype sprites pending shader pipeline")
        encoder.popDebugGroup()
    }

    private func emitStats(drawableSize: CGSize, visibleSpriteCount: Int, frameMillis: Double) {
        let snapshot = lock.withLock {
            ApplePrivateGridMetalRenderStats(
                hasDevice: device != nil,
                drawableSize: drawableSize,
                spriteCount: frame.sprites.count,
                visibleSpriteCount: visibleSpriteCount,
                cachedTextureCount: textures.count,
                frameMillis: frameMillis
            )
        }

        if Thread.isMainThread {
            onStats?(snapshot)
        } else {
            DispatchQueue.main.async { [onStats] in
                onStats?(snapshot)
            }
        }
    }

    private static func makeSampler(device: MTLDevice?) -> MTLSamplerState? {
        guard let device else { return nil }
        let descriptor = MTLSamplerDescriptor()
        descriptor.label = "ApplePrivateGridMetalPrototype Linear Sampler"
        descriptor.minFilter = .linear
        descriptor.magFilter = .linear
        descriptor.mipFilter = .notMipmapped
        descriptor.sAddressMode = .clampToEdge
        descriptor.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: descriptor)
    }
}

private struct ApplePrivateGridMetalVertex {
    var position: SIMD2<Float>
    var textureCoordinate: SIMD2<Float>
    var tint: SIMD4<Float>
    var cornerRadius: Float
    var opacity: Float
}

private struct ApplePrivateGridMetalUniforms {
    var viewportOrigin: SIMD2<Float>
    var viewportSize: SIMD2<Float>
    var drawableSize: SIMD2<Float>
    var spriteCount: UInt32
}

private extension Array where Element == ApplePrivateGridMetalSprite {
    func sortedForMetalGrid() -> [ApplePrivateGridMetalSprite] {
        sorted { lhs, rhs in
            if lhs.zIndex == rhs.zIndex {
                return lhs.id.rawValue < rhs.id.rawValue
            }
            return lhs.zIndex < rhs.zIndex
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
