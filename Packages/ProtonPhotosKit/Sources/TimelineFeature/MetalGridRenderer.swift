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
        var uniforms = Uniforms(viewportSize: SIMD2(Float(max(viewportSize.width, 1)), Float(max(viewportSize.height, 1))))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)

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

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastDrawMs = (CFAbsoluteTimeGetCurrent() - start) * 1000
        lastDrawCalls = drawCalls
        lastInstanceCount = instances
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
    """
}
