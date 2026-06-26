import Metal
import MetalKit
import CoreGraphics
import simd

/// How a quad is shaded.
enum MetalGridQuadMode: Int32 {
    case textured = 0   // sample the bound texture, tint by `color`
    case solid = 1      // fill with `color` (rounded)
    case border = 2     // stroke a rounded-rect ring of width `borderWidth` in `color`
}

/// One quad in viewport (point) coordinates, with the UV window, corner radius, and shading.
struct MetalGridQuad {
    var rect: CGRect
    var uvMin: SIMD2<Float> = SIMD2(0, 0)
    var uvMax: SIMD2<Float> = SIMD2(1, 1)
    var radius: Float
    var alpha: Float = 1
    var color: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    var mode: MetalGridQuadMode = .textured
    var borderWidth: Float = 0
}

/// A batch of quads sharing draw state. `sharedTexture` → one draw call for all quads; `perQuadTexture`
/// → one draw call per quad (each binds its own texture, for distinct thumbnails).
struct MetalGridRenderGroup {
    enum Source {
        case sharedTexture(MTLTexture)
        case perQuadTexture([MTLTexture])
    }
    var source: Source
    var quads: [MetalGridQuad]
}

/// The persistent Metal renderer for the grid. Draws one quad per visible cell (rounded-corner SDF +
/// premultiplied alpha), plus solid/border/glyph quads for selection outlines and badges.
///
/// The shader (rounded-corner signed-distance mask + premultiplied alpha + V-up sampling) and the overall
/// architecture (MTKView, one quad per cell, GPU textures, O(1) LRU cache, CGImageSource downsampling)
/// follow the Pixe reference design.
final class MetalGridRenderer {
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    /// Opaque 2-texture linear-mix pipeline for the OVERVIEW LAYER DISSOLVE (offscreen compositing). nil if the
    /// composite functions failed to build ⇒ `renderLayerDissolve` falls back to the target settled render.
    private let compositePipeline: MTLRenderPipelineState?
    /// Offscreen per-layer render targets (source, target), lazily sized to the drawable. ONLY used by
    /// `renderLayerDissolve`; the normal `render(...)` path never touches them.
    private var layerA: MTLTexture?
    private var layerB: MTLTexture?

    private(set) var lastDrawMs: Double = 0
    private(set) var lastDrawCalls = 0
    private(set) var lastInstanceCount = 0

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

    init?(device: MTLDevice) {
        self.device = device
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

    /// Draw the frame: each group is drawn in order (back → front). `sharedTexture` groups draw all their
    /// quads in one call; `perQuadTexture` groups draw one call per quad.
    @MainActor
    func render(in view: MTKView, viewportSize: CGSize, groups: [MetalGridRenderGroup]) {
        let start = CFAbsoluteTimeGetCurrent()
        guard let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MetalGridPalette.clearColor   // uniform Apple-like dark surface
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            commandBuffer.commit(); return
        }
        configure(encoder, viewportSize: viewportSize)
        let (drawCalls, instances) = encode(groups: groups, into: encoder)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastDrawMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lastDrawCalls = drawCalls
        lastInstanceCount = instances
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
    /// Pure w.r.t. the encoder — identical work whether the target is the drawable or an offscreen texture.
    @discardableResult
    private func encode(groups: [MetalGridRenderGroup], into encoder: MTLRenderCommandEncoder) -> (Int, Int) {
        var drawCalls = 0
        var instances = 0
        for group in groups where !group.quads.isEmpty {
            var verts: [Vertex] = []
            verts.reserveCapacity(group.quads.count * 6)
            for q in group.quads { appendQuad(into: &verts, q) }
            guard let buffer = device.makeBuffer(bytes: verts, length: MemoryLayout<Vertex>.stride * verts.count, options: .storageModeShared) else { continue }
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            switch group.source {
            case .sharedTexture(let texture):
                encoder.setFragmentTexture(texture, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count)
                drawCalls += 1
                instances += group.quads.count
            case .perQuadTexture(let textures) where textures.count == group.quads.count:
                for (i, texture) in textures.enumerated() {
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: i * 6, vertexCount: 6)
                    drawCalls += 1
                    instances += 1
                }
            default:
                break
            }
        }
        return (drawCalls, instances)
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

    private func encodeLayerPass(into cmd: MTLCommandBuffer, texture: MTLTexture,
                                 groups: [MetalGridRenderGroup], viewportSize: CGSize) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MetalGridPalette.clearColor   // each layer is composited over the SAME bg
        pass.colorAttachments[0].storeAction = .store
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        configure(enc, viewportSize: viewportSize)
        _ = encode(groups: groups, into: enc)
        enc.endEncoding()
    }

    /// Render the OVERVIEW LAYER DISSOLVE: rasterise the source layer to texA and the target layer to texB
    /// (each a COMPLETE settled grid over the uniform bg), then composite to the drawable as the LINEAR mix
    /// `A·(1−t) + B·t`. Because each layer is composited independently first, there is NO `(1−t)²` source
    /// under-weighting / background bleed (the artifact a single-pass source-over dissolve would produce).
    /// `t` is the (already-eased) progress 0…1. Falls back to the target settled render if compositing is
    /// unavailable. The normal `render(...)` path is untouched.
    @MainActor
    func renderLayerDissolve(in view: MTKView, viewportSize: CGSize,
                             sourceGroups: [MetalGridRenderGroup], targetGroups: [MetalGridRenderGroup], t: Float) {
        let start = CFAbsoluteTimeGetCurrent()
        guard let drawable = view.currentDrawable,
              let drawablePass = view.currentRenderPassDescriptor,
              let composite = compositePipeline,
              let cmd = commandQueue.makeCommandBuffer() else { return }
        ensureLayerTextures(width: drawable.texture.width, height: drawable.texture.height)
        guard let texA = layerA, let texB = layerB else {
            render(in: view, viewportSize: viewportSize, groups: targetGroups); return   // safe fallback
        }
        encodeLayerPass(into: cmd, texture: texA, groups: sourceGroups, viewportSize: viewportSize)
        encodeLayerPass(into: cmd, texture: texB, groups: targetGroups, viewportSize: viewportSize)
        drawablePass.colorAttachments[0].loadAction = .clear
        drawablePass.colorAttachments[0].clearColor = MetalGridPalette.clearColor
        guard let enc = cmd.makeRenderCommandEncoder(descriptor: drawablePass) else { cmd.commit(); return }
        enc.setRenderPipelineState(composite)
        enc.setFragmentTexture(texA, index: 0)
        enc.setFragmentTexture(texB, index: 1)
        enc.setFragmentSamplerState(sampler, index: 0)
        var tt = max(0, min(1, t))
        enc.setFragmentBytes(&tt, length: MemoryLayout<Float>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)   // fullscreen triangle
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
        lastDrawMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
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
    // (each already a complete grid over the SAME bg). out = mix(A, B, t) = A·(1−t) + B·t — no background bleed.
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
