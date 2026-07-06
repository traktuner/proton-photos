import Metal
import QuartzCore
import CoreGraphics
import simd

/// The persistent Metal renderer for the grid. Draws one quad per visible cell (rounded-corner SDF +
/// premultiplied alpha), plus solid/border/glyph quads for selection outlines and badges.
///
/// Platform adapters own view hosting and convert their drawable surface into `MetalGridDrawableTarget`.
package final class MetalGridRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let clearColor: MTLClearColor
    /// Opaque 2-texture linear-mix pipeline for the OVERVIEW LAYER DISSOLVE (offscreen compositing). nil if the
    /// composite functions failed to build ⇒ `renderLayerDissolve` falls back to the target settled render.
    private let compositePipeline: MTLRenderPipelineState?
    /// Fullscreen textured-quad pipeline (single texture, alpha blend) for the RESIZE PRESENTATION path:
    /// rasterise the gesture-start snapshot ONCE into `resizeCanvas`, then each tick draws a single
    /// transformed quad of that texture - no per-tick `buildRealGroups`, no per-cell texture binds.
    private let textureQuadPipeline: MTLRenderPipelineState?
    /// Offscreen per-layer render targets (source, target), lazily sized to the drawable. ONLY used by
    /// `renderLayerDissolve`; the normal `render(...)` path never touches them. Released on `endLayerDissolve`
    /// so a held dissolve's ~two fullscreen private textures don't linger after the gesture.
    private var layerA: MTLTexture?
    private var layerB: MTLTexture?
    /// Cached offscreen canvas for the resize/sidebar presentation (snapshot taken at gesture start).
    /// Sized once to the gesture-start viewport in points × backing scale. Released on `endResizeCanvas`
    /// so it doesn't linger between gestures.
    private var resizeCanvas: MTLTexture?
    /// Which frozen dissolve layers actually need re-rasterizing this frame (pure state machine); a steady
    /// scrub reuses both offscreen textures and only re-runs the cheap composite.
    private var dissolveCache = DissolveLayerCache()

    package private(set) var lastEncodeMs: Double = 0
    package private(set) var lastGpuMs: Double = 0
    package private(set) var lastDrawCalls = 0
    package private(set) var lastInstanceCount = 0
    package private(set) var lastTextureBinds = 0
    private var pendingGpuCommandBuffers: [MTLCommandBuffer] = []

    /// Triple-buffered vertex pool for the steady `render(...)` path: instead of allocating a fresh
    /// `MTLBuffer` per group every frame, each frame packs all groups' vertices into one growable,
    /// reused buffer (per-group byte offsets) drawn from a 3-deep ring. `frameBoundary` bounds the CPU
    /// to `maxInFlight` frames ahead of the GPU so a pooled buffer is never overwritten while a prior
    /// frame still reads it. The offscreen dissolve path keeps simple per-group allocation (transient).
    private static let maxInFlight = 3
    private let frameBoundary = DispatchSemaphore(value: maxInFlight)
    private var vertexPool: [MTLBuffer?] = Array(repeating: nil, count: maxInFlight)
    private var frameCounter = 0

    private struct Vertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
        var local: SIMD2<Float>
        var size: SIMD2<Float>
        var radius: Float
        var alpha: Float
        var color: SIMD4<Float>
        var mode: Float
        var borderWidth: Float
    }
    private struct Uniforms { var viewportSize: SIMD2<Float> }
    /// Vertex uniforms for the resize-presentation textured-quad pipeline (matches the Metal shader struct).
    private struct TextureQuadUniforms {
        var viewportSize: SIMD2<Float>
        var origin: SIMD2<Float>
        var size: SIMD2<Float>
    }

    package init?(device: MTLDevice, clearColor: MTLClearColor = MetalGridRenderPalette.clearColor) {
        self.device = device
        self.clearColor = clearColor
        guard let queue = device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            guard let vfn = library.makeFunction(name: "metalGridVertex"),
                  let ffn = library.makeFunction(name: "metalGridFragment") else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vfn
            descriptor.fragmentFunction = ffn
            descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            self.pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

            // Composite pipeline: opaque (no blending) fullscreen linear mix of two layer textures.
            if let cv = library.makeFunction(name: "metalGridCompositeVertex"),
               let cf = library.makeFunction(name: "metalGridCompositeFragment") {
                let cd = MTLRenderPipelineDescriptor()
                cd.vertexFunction = cv
                cd.fragmentFunction = cf
                cd.colorAttachments[0].pixelFormat = .bgra8Unorm
                cd.colorAttachments[0].isBlendingEnabled = false
                self.compositePipeline = try? device.makeRenderPipelineState(descriptor: cd)
            } else {
                self.compositePipeline = nil
            }

            // Texture-quad pipeline: a single textured quad (alpha-blended) for the resize/sidebar
            // presentation path - one draw call per tick instead of hundreds of per-cell binds. The
            // vertex shader transforms the unit quad by a scale+translate uniform set per tick.
            if let tqv = library.makeFunction(name: "metalGridTextureQuadVertex"),
               let tqf = library.makeFunction(name: "metalGridTextureQuadFragment") {
                let td = MTLRenderPipelineDescriptor()
                td.vertexFunction = tqv
                td.fragmentFunction = tqf
                td.colorAttachments[0].pixelFormat = .bgra8Unorm
                td.colorAttachments[0].isBlendingEnabled = false   // opaque fullscreen quad; the snapshot is already over the bg
                self.textureQuadPipeline = try? device.makeRenderPipelineState(descriptor: td)
            } else {
                self.textureQuadPipeline = nil
            }

            let sd = MTLSamplerDescriptor()
            sd.minFilter = .linear
            sd.magFilter = .linear
            sd.sAddressMode = .clampToEdge
            sd.tAddressMode = .clampToEdge
            guard let sampler = device.makeSamplerState(descriptor: sd) else { return nil }
            self.sampler = sampler
        } catch {
            return nil
        }
    }

    @MainActor
    package func render(to target: MetalGridDrawableTarget, viewportSize: CGSize, groups: [MetalGridRenderGroup]) {
        drainCompletedGpuTimings()
        let start = CFAbsoluteTimeGetCurrent()
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        let pass = target.renderPassDescriptor
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            commandBuffer.commit(); return
        }
        // Claim a pool slot only once we're committed to drawing (the guards above can early-return without
        // a matching signal). The completion handler releases it when the GPU is done with this frame.
        frameBoundary.wait()
        frameCounter &+= 1
        let slot = frameCounter % Self.maxInFlight
        commandBuffer.addCompletedHandler { [frameBoundary] _ in frameBoundary.signal() }
        configure(encoder, viewportSize: viewportSize)
        let (drawCalls, instances, textureBinds) = encode(groups: groups, into: encoder, pooledSlot: slot)
        encoder.endEncoding()
        pendingGpuCommandBuffers.append(commandBuffer)
        present(commandBuffer, to: target)
        lastEncodeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lastDrawCalls = drawCalls
        lastInstanceCount = instances
        lastTextureBinds = textureBinds
    }

    /// Set the shared per-frame state (pipeline, sampler, viewport uniforms) on an encoder. Used by the
    /// normal `render(...)` AND the offscreen layer passes, so both rasterise identically.
    private func configure(_ encoder: MTLRenderCommandEncoder, viewportSize: CGSize) {
        var uniforms = Uniforms(viewportSize: SIMD2(Float(max(viewportSize.width, 1)), Float(max(viewportSize.height, 1))))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
    }

    /// Encode all groups (back → front) onto an already-configured encoder. Returns (drawCalls, instances, binds).
    /// Pure w.r.t. the encoder - identical work whether the target is the drawable or an offscreen texture.
    ///
    /// `pooledSlot` selects how the vertex storage is sourced. A non-nil slot is the steady `render(...)` path:
    /// every group's vertices are written DIRECTLY into the reused ring buffer's `contents()` pointer at
    /// pre-computed offsets - no intermediate `[Vertex]` array and no memcpy, so a dense L5 frame no longer
    /// churns ~0.2-0.65 MB of transient allocation per invalidated frame. `nil` is the transient offscreen
    /// dissolve path: it builds a per-group array and a fresh shared buffer (it runs only on layer-dirty
    /// frames, so pooling buys nothing there). Both paths preserve group order, draw order, and the
    /// draw-call / instance / texture-bind counts exactly.
    @discardableResult
    private func encode(groups: [MetalGridRenderGroup], into encoder: MTLRenderCommandEncoder, pooledSlot: Int? = nil) -> (Int, Int, Int) {
        let stride = MemoryLayout<Vertex>.stride
        // Group metadata only (no vertices yet): source order preserved; each non-empty group reserves a
        // contiguous `quadCount * 6`-vertex run, its start offset recorded up front so the pooled and
        // per-group paths bind identical byte offsets.
        var planned: [(group: MetalGridRenderGroup, vertexOffset: Int)] = []
        planned.reserveCapacity(groups.count)
        var totalVerts = 0
        for group in groups where !group.quads.isEmpty {
            planned.append((group, totalVerts))
            totalVerts += group.quads.count * 6
        }
        guard totalVerts > 0 else { return (0, 0, 0) }

        // Steady path: grow the ring slot once, then write each quad's six vertices straight into it.
        let packed: MTLBuffer?
        if let slot = pooledSlot {
            let buffer = pooledBuffer(slot: slot, byteCount: totalVerts * stride)
            packed = buffer
            if let buffer {
                let base = buffer.contents().assumingMemoryBound(to: Vertex.self)
                for (group, vertexOffset) in planned {
                    var cursor = base.advanced(by: vertexOffset)
                    for q in group.quads {
                        writeQuad(q, into: cursor)
                        cursor = cursor.advanced(by: 6)
                    }
                }
            }
        } else {
            packed = nil   // per-group allocation below
        }

        var drawCalls = 0
        var instances = 0
        var textureBinds = 0
        for (group, vertexOffset) in planned {
            let quadCount = group.quads.count
            let buffer: MTLBuffer
            let byteOffset: Int
            if let pooled = packed {
                buffer = pooled
                byteOffset = vertexOffset * stride
            } else {
                var verts: [Vertex] = []
                verts.reserveCapacity(quadCount * 6)
                for q in group.quads { appendQuad(into: &verts, q) }
                guard let b = device.makeBuffer(bytes: verts, length: stride * verts.count, options: .storageModeShared) else { continue }
                buffer = b
                byteOffset = 0
            }
            encoder.setVertexBuffer(buffer, offset: byteOffset, index: 0)
            switch group.source {
            case .sharedTexture(let texture):
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: quadCount * 6)
                drawCalls += 1
                textureBinds += 1
                instances += quadCount
            case .perQuadTexture(let textures) where textures.count == quadCount:
                for (i, texture) in textures.enumerated() {
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: i * 6, vertexCount: 6)
                    drawCalls += 1
                    textureBinds += 1
                    instances += 1
                }
            default:
                break
            }
        }
        return (drawCalls, instances, textureBinds)
    }

    /// The ring buffer for `slot`, grown (doubling) when the frame needs more than it currently holds.
    /// Bound by the `frameBoundary` semaphore, so the slot's prior frame has finished reading before reuse.
    private func pooledBuffer(slot: Int, byteCount: Int) -> MTLBuffer? {
        if let existing = vertexPool[slot], existing.length >= byteCount { return existing }
        let capacity = max(byteCount, (vertexPool[slot]?.length ?? 0) * 2)
        let buffer = device.makeBuffer(length: capacity, options: .storageModeShared)
        vertexPool[slot] = buffer
        return buffer
    }

    // MARK: - Overview layer dissolve (offscreen, two-layer linear cross-dissolve)

    private func ensureLayerTextures(width: Int, height: Int) {
        if let a = layerA, a.width == width, a.height == height, layerB != nil { return }
        guard width > 0, height > 0 else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        layerA = device.makeTexture(descriptor: d)
        layerB = device.makeTexture(descriptor: d)
    }

    /// A new dissolve plan began (fresh begin): re-raster both layers on the next frame even if nothing has
    /// streamed in, so the new plan's geometry replaces the previous plan's frozen layers.
    @MainActor package func invalidateDissolveLayers() { dissolveCache.invalidate() }

    /// The dissolve committed/finished: drop the two offscreen textures (their GPU memory returns once the last
    /// in-flight command buffer that references them completes) and reset the layer cache.
    @MainActor package func endLayerDissolve() {
        layerA = nil
        layerB = nil
        dissolveCache.release()
    }

    // MARK: - Resize presentation (offscreen-texture cached snapshot)

    /// Ensure the offscreen resize canvas texture exists at the requested pixel size. Re-creates on a size
    /// change. Called ONCE per gesture at start (the snapshot is rasterised into it, then reused every tick).
    @MainActor package func ensureResizeCanvas(pixelWidth: Int, pixelHeight: Int) {
        if let t = resizeCanvas, t.width == pixelWidth, t.height == pixelHeight { return }
        guard pixelWidth > 0, pixelHeight > 0 else { return }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: pixelWidth, height: pixelHeight, mipmapped: false)
        d.usage = [.renderTarget, .shaderRead]
        d.storageMode = .private
        resizeCanvas = device.makeTexture(descriptor: d)
    }

    /// Rasterise the snapshot groups ONCE into `resizeCanvas` at gesture start. After this, every resize
    /// tick is a single textured-quad draw - no per-cell buildRealGroups, no per-cell texture binds, no
    /// decoration loops. The canvas persists until `endResizeCanvas`.
    @MainActor package func rasterizeResizeSnapshot(groups: () -> [MetalGridRenderGroup], viewportSize: CGSize, backingScale: CGFloat) {
        guard let cmd = commandQueue.makeCommandBuffer(), let canvas = resizeCanvas ?? {
            let pw = max(1, Int(viewportSize.width * backingScale))
            let ph = max(1, Int(viewportSize.height * backingScale))
            ensureResizeCanvas(pixelWidth: pw, pixelHeight: ph)
            return resizeCanvas
        }() else { return }
        let stats = encodeLayerPass(into: cmd, texture: canvas, groups: groups(), viewportSize: viewportSize)
        cmd.commit()
        // Don't present - this is an offscreen rasterisation. The canvas is sampled on the NEXT tick's
        // `drawResizeCanvasQuad`. We DO wait for completion so the first tick doesn't sample pre-raster content.
        cmd.waitUntilCompleted()
        _ = stats
    }

    /// Draw the cached `resizeCanvas` texture as a single fullscreen (or sub-rect) quad to the drawable.
    /// `dstOrigin`/`dstSize` are in viewport points (y-down). One draw call, one texture bind per tick.
    /// Returns `false` if the draw could not be issued (pipeline missing, canvas missing, encoder allocation
    /// failed); the caller MUST fall back to the per-cell `buildRealGroups` path on `false` so a tick never
    /// produces a blank frame.
    @discardableResult
    @MainActor package func drawResizeCanvasQuad(to target: MetalGridDrawableTarget, viewportSize: CGSize,
                                                  dstOrigin: CGPoint, dstSize: CGSize) -> Bool {
        guard let pipeline = textureQuadPipeline, let canvas = resizeCanvas,
              let cmd = commandQueue.makeCommandBuffer() else {
            return false
        }
        let pass = target.renderPassDescriptor
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { cmd.commit(); return false }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentTexture(canvas, index: 0)
        var u = TextureQuadUniforms(
            viewportSize: SIMD2(Float(max(viewportSize.width, 1)), Float(max(viewportSize.height, 1))),
            origin: SIMD2(Float(dstOrigin.x), Float(dstOrigin.y)),
            size: SIMD2(Float(max(dstSize.width, 1)), Float(max(dstSize.height, 1)))
        )
        enc.setVertexBytes(&u, length: MemoryLayout<TextureQuadUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        pendingGpuCommandBuffers.append(cmd)
        present(cmd, to: target)
        lastEncodeMs = 0   // negligible on this path
        lastDrawCalls = 1
        lastInstanceCount = 1
        lastTextureBinds = 1
        return true
    }

    /// Drop the cached resize canvas (gesture ended). Its GPU memory returns once the last in-flight
    /// command buffer that referenced it completes.
    @MainActor package func endResizeCanvas() {
        resizeCanvas = nil
    }

    /// True iff a cached resize canvas exists AND the texture-quad pipeline is usable - i.e. the host can
    /// call `drawResizeCanvasQuad` instead of falling back to `buildRealGroups` per tick. Both gates are
    /// checked here so a missing pipeline never leads the host into a silent no-draw path.
    package var hasResizeCanvas: Bool { resizeCanvas != nil && textureQuadPipeline != nil }

    private func encodeLayerPass(into cmd: MTLCommandBuffer, texture: MTLTexture,
                                 groups: [MetalGridRenderGroup], viewportSize: CGSize) -> (Int, Int, Int) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return (0, 0, 0) }
        configure(enc, viewportSize: viewportSize)
        let stats = encode(groups: groups, into: enc)
        enc.endEncoding()
        return stats
    }

    /// Render the OVERVIEW LAYER DISSOLVE: rasterise the source layer to texA and the target layer to texB
    /// (each a COMPLETE settled grid over the uniform bg), then composite to the drawable as the LINEAR mix
    /// `A·(1−t) + B·t`. Because each layer is composited independently first, there is NO `(1−t)²` source
    /// under-weighting / background bleed (the artifact a single-pass source-over dissolve would produce).
    /// `t` is the (already-eased) progress 0…1. Falls back to the target settled render if compositing is
    /// unavailable. The normal `render(...)` path is untouched.
    ///
    /// Layer caching: only the layers the caller flags (`redrawSource`/`redrawTarget` - a wanted thumbnail
    /// arrived), plus any never-rasterized-yet layer and both layers on a drawable resize, are re-rasterized.
    /// A steady scrub (only `t` moving) re-runs NEITHER offscreen pass NOR its `buildRealGroups` - the group
    /// closures are evaluated ONLY for a layer being drawn - and pays just the fullscreen composite. The two
    /// offscreen textures persist (`.private`, `.store`) between frames, so a reused layer composites its
    /// prior contents.
    @MainActor
    package func renderLayerDissolve(to target: MetalGridDrawableTarget, viewportSize: CGSize,
                                     redrawSource: Bool, redrawTarget: Bool,
                                     sourceGroups: () -> [MetalGridRenderGroup],
                                     targetGroups: () -> [MetalGridRenderGroup], t: Float) {
        drainCompletedGpuTimings()
        let start = CFAbsoluteTimeGetCurrent()
        guard let composite = compositePipeline,
              let cmd = commandQueue.makeCommandBuffer() else {
            render(to: target, viewportSize: viewportSize, groups: targetGroups())
            return
        }
        let width = Int(target.pixelSize.width), height = Int(target.pixelSize.height)
        ensureLayerTextures(width: width, height: height)
        guard let texA = layerA, let texB = layerB else {
            render(to: target, viewportSize: viewportSize, groups: targetGroups()); return   // safe fallback
        }
        // Decide (and record) which layers to draw. ensureLayerTextures reallocated on the SAME size change the
        // cache detects, so a resize consistently forces both here and fresh textures above.
        let draw = dissolveCache.plan(redrawSource: redrawSource, redrawTarget: redrawTarget, width: width, height: height)
        var sourceStats = (0, 0, 0)
        var targetStats = (0, 0, 0)
        if draw.source { sourceStats = encodeLayerPass(into: cmd, texture: texA, groups: sourceGroups(), viewportSize: viewportSize) }
        if draw.target { targetStats = encodeLayerPass(into: cmd, texture: texB, groups: targetGroups(), viewportSize: viewportSize) }
        let drawablePass = target.renderPassDescriptor
        drawablePass.colorAttachments[0].loadAction = .clear
        drawablePass.colorAttachments[0].clearColor = clearColor
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: drawablePass) else { cmd.commit(); return }
        enc.setRenderPipelineState(composite)
        enc.setFragmentTexture(texA, index: 0)
        enc.setFragmentTexture(texB, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        var tt = max(0, min(1, t))
        enc.setFragmentBytes(&tt, length: MemoryLayout<Float>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)   // fullscreen triangle
        enc.endEncoding()
        pendingGpuCommandBuffers.append(cmd)
        present(cmd, to: target)
        lastEncodeMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lastDrawCalls = sourceStats.0 + targetStats.0 + 1
        lastInstanceCount = sourceStats.1 + targetStats.1
        lastTextureBinds = sourceStats.2 + targetStats.2 + 2
    }

    @MainActor
    private func drainCompletedGpuTimings() {
        guard !pendingGpuCommandBuffers.isEmpty else { return }
        var stillPending: [MTLCommandBuffer] = []
        stillPending.reserveCapacity(pendingGpuCommandBuffers.count)
        for commandBuffer in pendingGpuCommandBuffers {
            if commandBuffer.status == .completed {
                lastGpuMs = Self.gpuDurationMs(commandBuffer)
            } else {
                stillPending.append(commandBuffer)
            }
        }
        pendingGpuCommandBuffers = stillPending
    }

    private static func gpuDurationMs(_ commandBuffer: MTLCommandBuffer) -> Double {
        let start = commandBuffer.gpuStartTime
        let end = commandBuffer.gpuEndTime
        guard start > 0, end >= start else { return 0 }
        return (end - start) * 1000
    }

    private func present(_ commandBuffer: MTLCommandBuffer, to target: MetalGridDrawableTarget) {
        if target.presentsWithTransaction {
            // LIVE-RESIZE SYNC: when the host has armed `presentsWithTransaction` (during a live window resize),
            // present the drawable INSIDE the window's current CATransaction - commit, wait until scheduled, then
            // present explicitly. This locks the Metal frame to the window border for that tick, killing the
            // "rubber-band / content trails the cursor" lag. The normal (settled / scroll / zoom) path keeps the
            // cheaper async `commandBuffer.present(drawable)` below.
            commandBuffer.commit()
            commandBuffer.waitUntilScheduled()
            target.drawable.present()
        } else {
            commandBuffer.present(target.drawable)
            commandBuffer.commit()
        }
    }

    /// The six triangle vertices for one quad (two triangles: tl,bl,tr / tr,bl,br), the single source of the
    /// renderer's vertex layout. Shared by the pooled direct-write path (`writeQuad`) and the transient
    /// per-group path (`appendQuad`) so both emit byte-identical geometry.
    private func quadVertices(_ q: MetalGridQuad) -> (Vertex, Vertex, Vertex, Vertex, Vertex, Vertex) {
        let x0 = Float(q.rect.minX), y0 = Float(q.rect.minY)
        let x1 = Float(q.rect.maxX), y1 = Float(q.rect.maxY)
        let w = Float(q.rect.width), h = Float(q.rect.height)
        let size = SIMD2(w, h)
        let m = Float(q.mode.rawValue)
        func v(_ px: Float, _ py: Float, _ ux: Float, _ uy: Float, _ lx: Float, _ ly: Float) -> Vertex {
            Vertex(position: SIMD2(px, py), uv: SIMD2(ux, uy), local: SIMD2(lx, ly), size: size,
                   radius: q.radius, alpha: q.alpha, color: q.color, mode: m, borderWidth: q.borderWidth)
        }
        let tl = v(x0, y0, q.uvMin.x, q.uvMin.y, 0, 0)
        let tr = v(x1, y0, q.uvMax.x, q.uvMin.y, w, 0)
        let bl = v(x0, y1, q.uvMin.x, q.uvMax.y, 0, h)
        let br = v(x1, y1, q.uvMax.x, q.uvMax.y, w, h)
        return (tl, bl, tr, tr, bl, br)
    }

    /// Append one quad's six vertices to a growable array - the transient offscreen dissolve path.
    private func appendQuad(into verts: inout [Vertex], _ q: MetalGridQuad) {
        let (a, b, c, d, e, f) = quadVertices(q)
        verts.append(contentsOf: [a, b, c, d, e, f])
    }

    /// Write one quad's six vertices directly into pooled ring-buffer memory (six contiguous `Vertex` slots
    /// from `ptr`). `Vertex` is trivial, so assigning into possibly-uninitialised buffer memory is safe.
    private func writeQuad(_ q: MetalGridQuad, into ptr: UnsafeMutablePointer<Vertex>) {
        let (a, b, c, d, e, f) = quadVertices(q)
        ptr[0] = a; ptr[1] = b; ptr[2] = c; ptr[3] = d; ptr[4] = e; ptr[5] = f
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
        float4 color;
        float mode;
        float borderWidth;
    };
    struct VertexOut {
        float4 position [[position]];
        float2 uv;
        float2 local;
        float2 size;
        float radius;
        float alpha;
        float4 color;
        float mode;
        float borderWidth;
    };
    struct Uniforms { float2 viewportSize; };

    vertex VertexOut metalGridVertex(
        uint vid [[vertex_id]],
        const device VertexIn *vertices [[buffer(0)]],
        constant Uniforms &u [[buffer(1)]]
    ) {
        VertexIn in = vertices[vid];
        float2 ndc = float2(
            (in.position.x / max(u.viewportSize.x, 1.0)) * 2.0 - 1.0,
            1.0 - (in.position.y / max(u.viewportSize.y, 1.0)) * 2.0
        );
        VertexOut out;
        out.position = float4(ndc, 0.0, 1.0);
        out.uv = in.uv;
        out.local = in.local;
        out.size = in.size;
        out.radius = in.radius;
        out.alpha = in.alpha;
        out.color = in.color;
        out.mode = in.mode;
        out.borderWidth = in.borderWidth;
        return out;
    }

    static inline float roundedRectSDF(float2 local, float2 size, float radius) {
        float r = min(radius, min(size.x, size.y) * 0.5);
        float2 halfSize = size * 0.5;
        float2 q = abs(local - halfSize) - (halfSize - r);
        return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
    }

    fragment float4 metalGridFragment(
        VertexOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler s [[sampler(0)]]
    ) {
        int mode = int(in.mode + 0.5);
        if (mode == 2) {
            // Rounded-rect ring: outer fill minus an inner fill inset by borderWidth. Always SDF-based —
            // at radius 0 the SDF degenerates to the plain rect ring, so no separate path is needed.
            float dist = roundedRectSDF(in.local, in.size, in.radius);
            float fillMask = 1.0 - smoothstep(-1.0, 1.0, dist);
            float inner = 1.0 - smoothstep(-1.0, 1.0, dist + in.borderWidth);
            float ring = clamp(fillMask - inner, 0.0, 1.0);
            float coverage = in.alpha * ring;
            float4 c = in.color;
            return float4(c.rgb * c.a * coverage, c.a * coverage);
        }
        // Sharp-corner fast path: radius 0 (dense square tiles, GridCornerRadiusPolicy) needs no SDF and no
        // anti-aliased edge band — full coverage, hard 90° edges, no per-fragment rounded-corner cost. All
        // quads at a dense level share radius 0, so the branch is coherent across the warp.
        float fillMask = (in.radius <= 0.0)
            ? 1.0
            : 1.0 - smoothstep(-1.0, 1.0, roundedRectSDF(in.local, in.size, in.radius));
        if (mode == 1) {
            float coverage = in.alpha * fillMask;
            float4 c = in.color;
            return float4(c.rgb * c.a * coverage, c.a * coverage);
        } else {
            float4 t = tex.sample(s, in.uv) * in.color;
            float coverage = in.alpha * fillMask;
            return float4(t.rgb * coverage, t.a * coverage);
        }
    }

    // Overview layer dissolve composite: fullscreen triangle that LINEARLY mixes two opaque layer textures
    // (each already a complete grid over the SAME bg). out = mix(A, B, t) = A·(1−t) + B·t - no background bleed.
    struct CompositeOut { float4 position [[position]]; float2 uv; };
    vertex CompositeOut metalGridCompositeVertex(uint vid [[vertex_id]]) {
        float2 pos[3] = { float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0) };
        float2 p = pos[vid];
        CompositeOut o;
        o.position = float4(p, 0.0, 1.0);
        o.uv = float2((p.x + 1.0) * 0.5, 1.0 - (p.y + 1.0) * 0.5);   // texel-centre exact at matching resolution
        return o;
    }
    fragment float4 metalGridCompositeFragment(
        CompositeOut in [[stage_in]],
        texture2d<float> texA [[texture(0)]],
        texture2d<float> texB [[texture(1)]],
        constant float &t [[buffer(0)]],
        sampler s [[sampler(0)]]
    ) {
        float4 a = texA.sample(s, in.uv);
        float4 b = texB.sample(s, in.uv);
        return float4(mix(a.rgb, b.rgb, t), 1.0);
    }

    // Resize/sidebar presentation: a single textured quad drawn fullscreen each tick. The vertex shader
    // transforms a unit-quad by a scale+translate uniform (set per tick by the host) into the offscreen
    // snapshot's source rectangle - the snapshot itself was rasterised ONCE at gesture start. The fragment
    // shader just samples the cached texture (already composited over the grid bg) with bilinear filtering
    // so the scaled tiles stay smooth instead of nearest-neighbour pixellating.
    struct TextureQuadOut { float4 position [[position]]; float2 uv; };
    struct TextureQuadUniforms { float2 viewportSize; float2 origin; float2 size; };

    vertex TextureQuadOut metalGridTextureQuadVertex(
        uint vid [[vertex_id]],
        constant TextureQuadUniforms &u [[buffer(0)]]
    ) {
        // Two triangles covering the destination rect (origin, origin+size) in viewport pixels (y-down).
        float2 p0 = u.origin;
        float2 p1 = u.origin + u.size;
        float2 pos[4] = {
            float2(p0.x, p0.y),   // tl
            float2(p1.x, p0.y),   // tr
            float2(p0.x, p1.y),   // bl
            float2(p1.x, p1.y),   // br
        };
        // Triangle strip: (tl, tr, bl, br)
        uint idx[4] = { 0, 1, 2, 3 };
        float2 p = pos[idx[vid]];
        float2 ndc = float2(
            (p.x / max(u.viewportSize.x, 1.0)) * 2.0 - 1.0,
            1.0 - (p.y / max(u.viewportSize.y, 1.0)) * 2.0
        );
        TextureQuadOut o;
        o.position = float4(ndc, 0.0, 1.0);
        // UV maps the destination rect to the full source texture (0..1 in both axes), y-flipped because
        // the snapshot texture's origin is top-left (matching the grid's viewport-space y-down) but
        // Metal textures sample bottom-left-up.
        o.uv = float2(
            (p.x - p0.x) / max(p1.x - p0.x, 1.0),
            1.0 - (p.y - p0.y) / max(p1.y - p0.y, 1.0)
        );
        return o;
    }

    fragment float4 metalGridTextureQuadFragment(
        TextureQuadOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler s [[sampler(0)]]
    ) {
        return tex.sample(s, in.uv);
    }
    """
}
