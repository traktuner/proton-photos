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
    /// Offscreen per-layer render targets (source, target), lazily sized to the drawable. ONLY used by
    /// `renderLayerDissolve`; the normal `render(...)` path never touches them. Released on `endLayerDissolve`
    /// so a held dissolve's ~two fullscreen private textures don't linger after the gesture.
    private var layerA: MTLTexture?
    private var layerB: MTLTexture?
    /// Which frozen dissolve layers actually need re-rasterizing this frame (pure state machine); a steady
    /// scrub reuses both offscreen textures and only re-runs the cheap composite.
    private var dissolveCache = DissolveLayerCache()

    package private(set) var lastDrawMs: Double = 0
    package private(set) var lastDrawCalls = 0
    package private(set) var lastInstanceCount = 0
    package private(set) var lastTextureBinds = 0

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
        present(commandBuffer, to: target)
        lastDrawMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
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

    /// Encode all groups (back → front) onto an already-configured encoder. Returns (drawCalls, instances).
    /// Pure w.r.t. the encoder - identical work whether the target is the drawable or an offscreen texture.
    ///
    /// `pooledSlot` selects how the vertex storage is sourced: a non-nil slot packs every group's vertices
    /// into one reused ring buffer (the steady `render(...)` path - no per-frame allocation); `nil` allocates
    /// a fresh shared buffer per group (the transient offscreen dissolve path, where pooling buys nothing).
    @discardableResult
    private func encode(groups: [MetalGridRenderGroup], into encoder: MTLRenderCommandEncoder, pooledSlot: Int? = nil) -> (Int, Int, Int) {
        let stride = MemoryLayout<Vertex>.stride
        // Build each non-empty group's vertices up front, recording its byte offset into the packed buffer.
        var built: [(verts: [Vertex], source: MetalGridRenderGroup.Source, quadCount: Int, offset: Int)] = []
        built.reserveCapacity(groups.count)
        var totalVerts = 0
        for group in groups where !group.quads.isEmpty {
            var verts: [Vertex] = []
            verts.reserveCapacity(group.quads.count * 6)
            for q in group.quads { appendQuad(into: &verts, q) }
            built.append((verts, group.source, group.quads.count, totalVerts * stride))
            totalVerts += verts.count
        }
        guard totalVerts > 0 else { return (0, 0, 0) }

        // Resolve the vertex buffer + each group's offset into it.
        let packed: MTLBuffer?
        if let slot = pooledSlot {
            packed = pooledBuffer(slot: slot, byteCount: totalVerts * stride)
            if let buffer = packed {
                let base = buffer.contents()
                for g in built {
                    g.verts.withUnsafeBytes { raw in
                        if let src = raw.baseAddress { memcpy(base.advanced(by: g.offset), src, raw.count) }
                    }
                }
            }
        } else {
            packed = nil   // per-group allocation below
        }

        var drawCalls = 0
        var instances = 0
        var textureBinds = 0
        for g in built {
            let buffer: MTLBuffer
            let offset: Int
            if let pooled = packed {
                buffer = pooled
                offset = g.offset
            } else {
                guard let b = device.makeBuffer(bytes: g.verts, length: stride * g.verts.count, options: .storageModeShared) else { continue }
                buffer = b
                offset = 0
            }
            encoder.setVertexBuffer(buffer, offset: offset, index: 0)
            switch g.source {
            case .sharedTexture(let texture):
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: g.verts.count)
                drawCalls += 1
                textureBinds += 1
                instances += g.quadCount
            case .perQuadTexture(let textures) where textures.count == g.quadCount:
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
        present(cmd, to: target)
        lastDrawMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lastDrawCalls = sourceStats.0 + targetStats.0 + 1
        lastInstanceCount = sourceStats.1 + targetStats.1
        lastTextureBinds = sourceStats.2 + targetStats.2 + 2
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

    private func appendQuad(into verts: inout [Vertex], _ q: MetalGridQuad) {
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
        verts.append(contentsOf: [tl, bl, tr, tr, bl, br])
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
        float dist = roundedRectSDF(in.local, in.size, in.radius);
        float fillMask = 1.0 - smoothstep(-1.0, 1.0, dist);
        int mode = int(in.mode + 0.5);
        if (mode == 2) {
            // Rounded-rect ring: outer fill minus an inner fill inset by borderWidth.
            float inner = 1.0 - smoothstep(-1.0, 1.0, dist + in.borderWidth);
            float ring = clamp(fillMask - inner, 0.0, 1.0);
            float coverage = in.alpha * ring;
            float4 c = in.color;
            return float4(c.rgb * c.a * coverage, c.a * coverage);
        } else if (mode == 1) {
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
    """
}
