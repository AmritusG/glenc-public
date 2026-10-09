// SPDX-License-Identifier: MIT
import Foundation
import Metal

/// RGBA passthrough Metal renderer with the locked-spec checkerboard painted
/// behind it — a single `.rgba8Unorm` texture and a fullscreen passthrough
/// quad.
///
/// Stage C: HOISTED VERBATIM from Crate's app-local copy (iCrate
/// `HAPPlayerHost.swift`) into GlancePlayback, so a shared
/// `GlancePlaybackWarmer.prewarm()` can pre-compile its 2 pipelines, and so
/// the iOS HAP host can adopt it from the library at a later stage. Crate's
/// copy is unchanged this arc; this is an additive sibling. The body is the
/// Crate class verbatim — only the imports, the type/member visibility
/// (public per Stage C), and this header doc differ.
///
/// Geometry + checker math mirror `MetalDXVRenderer` (same v=0-at-top quad,
/// same `position.xy`-keyed 8 pt checker) so HAP and DXV read identically on
/// screen. The deltas from the DXV renderer: one uncompressed RGBA texture
/// instead of BC/plane textures, a trivial sample-and-return fragment, and
/// STRAIGHT-alpha blend factors.
///
/// Construction COMPILES ONLY — nothing is uploaded, decoded, or drawn — so
/// `prewarm()` can construct-and-discard it to prime Metal's process-wide
/// pipeline cache.
public final class RGBAQuadRenderer {

    public enum RendererError: Error, CustomStringConvertible {
        case commandQueueUnavailable
        case libraryCreationFailed(String)
        case pipelineCreationFailed(String)
        public var description: String {
            switch self {
            case .commandQueueUnavailable: return "MTLDevice.makeCommandQueue returned nil"
            case .libraryCreationFailed(let s): return "Metal library creation failed: \(s)"
            case .pipelineCreationFailed(let s): return "Metal pipeline creation failed: \(s)"
            }
        }
    }

    /// Layer backing-scale (pt → px), so the checker cells stay a fixed
    /// 8 pt regardless of Retina. Push the MTKView's contentScaleFactor.
    public var contentsScale: CGFloat = 2.0

    public private(set) var lastUploadWidth: Int = 0
    public private(set) var lastUploadHeight: Int = 0
    public private(set) var hasUpload: Bool = false

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let texPipeline: MTLRenderPipelineState     // straight-alpha blended frame
    private let bgPipeline: MTLRenderPipelineState      // opaque checker
    private let sampler: MTLSamplerState

    private var texture: MTLTexture?

    /// Checker cell size in points (locked toolchain spec).
    private static let checkerboardCellPoints: CGFloat = 8.0

    public init(device: MTLDevice, colorPixelFormat: MTLPixelFormat) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw RendererError.commandQueueUnavailable
        }
        self.commandQueue = queue

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw RendererError.libraryCreationFailed("\(error)")
        }

        // Frame pass — passthrough fragment, straight-alpha source-over.
        let texDesc = MTLRenderPipelineDescriptor()
        texDesc.vertexFunction = library.makeFunction(name: "hap_vertex")
        texDesc.fragmentFunction = library.makeFunction(name: "hap_fragment")
        if let att = texDesc.colorAttachments[0] {
            att.pixelFormat = colorPixelFormat
            att.isBlendingEnabled = true
            att.rgbBlendOperation = .add
            att.alphaBlendOperation = .add
            // STRAIGHT alpha (HAPThumbnail tags CGImageAlphaInfo.last) —
            // NOT the DXV premultiplied `one / oneMinusSourceAlpha`.
            att.sourceRGBBlendFactor = .sourceAlpha
            att.sourceAlphaBlendFactor = .sourceAlpha
            att.destinationRGBBlendFactor = .oneMinusSourceAlpha
            att.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        // Background pass — opaque checker, no blend.
        let bgDesc = MTLRenderPipelineDescriptor()
        bgDesc.vertexFunction = library.makeFunction(name: "hap_vertex_bg")
        bgDesc.fragmentFunction = library.makeFunction(name: "hap_fragment_bg")
        bgDesc.colorAttachments[0]?.pixelFormat = colorPixelFormat

        do {
            self.texPipeline = try device.makeRenderPipelineState(descriptor: texDesc)
            self.bgPipeline = try device.makeRenderPipelineState(descriptor: bgDesc)
        } catch {
            throw RendererError.pipelineCreationFailed("\(error)")
        }

        let sampDesc = MTLSamplerDescriptor()
        sampDesc.minFilter = .linear
        sampDesc.magFilter = .linear
        sampDesc.sAddressMode = .clampToEdge
        sampDesc.tAddressMode = .clampToEdge
        guard let s = device.makeSamplerState(descriptor: sampDesc) else {
            throw RendererError.pipelineCreationFailed("sampler state nil")
        }
        self.sampler = s
    }

    public func makeCommandBuffer() -> MTLCommandBuffer? {
        commandQueue.makeCommandBuffer()
    }

    /// Upload one straight-alpha RGBA frame. Reuses the texture when the
    /// dimensions are unchanged (the common per-clip case); reallocates
    /// only on a size change.
    public func uploadRGBA(_ rgba: [UInt8], width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        let bytesPerRow = width * 4
        guard rgba.count >= bytesPerRow * height else {
            print("RGBAQuadRenderer: short RGBA buffer \(rgba.count) < \(bytesPerRow * height) for \(width)x\(height)")
            return
        }

        if texture == nil || texture?.width != width || texture?.height != height {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm,   // linear, raw RGBA byte order — no sRGB round-trip
                width: width,
                height: height,
                mipmapped: false
            )
            desc.usage = .shaderRead
            desc.storageMode = .shared
            texture = device.makeTexture(descriptor: desc)
        }
        guard let texture else { return }

        let region = MTLRegionMake2D(0, 0, width, height)
        rgba.withUnsafeBytes { raw in
            texture.replace(
                region: region,
                mipmapLevel: 0,
                withBytes: raw.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        lastUploadWidth = width
        lastUploadHeight = height
        hasUpload = true
    }

    /// Paint the checker into the aspect-fit viewport, then blend the
    /// frame over it. Letterbox outside the viewport stays the MTKView's
    /// black clear — same contract as `MetalDXVRenderer.render`.
    public func render(into encoder: MTLRenderCommandEncoder, viewport: MTLViewport) {
        guard hasUpload, let texture else { return }
        encoder.setViewport(viewport)

        // Background checker (opaque) first.
        encoder.setRenderPipelineState(bgPipeline)
        var bg = BGUniforms(
            light: SIMD3<Float>(0.85, 0.85, 0.85),
            dark:  SIMD3<Float>(0.65, 0.65, 0.65),
            cellPx: Float(Self.checkerboardCellPoints * max(1.0, contentsScale))
        )
        encoder.setFragmentBytes(&bg, length: MemoryLayout<BGUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

        // Frame on top, straight-alpha source-over.
        encoder.setRenderPipelineState(texPipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // Mirrored to MSL via stride — same layout as MetalDXVRenderer.BGUniforms.
    private struct BGUniforms {
        var light: SIMD3<Float>
        var dark: SIMD3<Float>
        var cellPx: Float
    }

    /// MSL: a fullscreen quad (vertex_id-generated, no vertex buffer),
    /// v=0 at the top so RGBA row 0 lands at the top of the viewport
    /// (HAP RGBA is top-row-first, same convention as the DXV BC quad).
    /// The frame fragment is a straight sample-and-return — the
    /// straight-alpha source-over happens in the pipeline blend state,
    /// not the shader. The checker is the `position.xy`-keyed two-colour
    /// pattern, identical to `MetalDXVRenderer.dxv_fragment_bg`.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut {
        float4 position [[position]];
        float2 uv;
    };

    struct BGVOut {
        float4 position [[position]];
    };

    struct BGUniforms {
        float3 light;
        float3 dark;
        float cellPx;
    };

    constant float2 kQuadPos[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0),
    };
    constant float2 kQuadUV[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0),
    };

    vertex VOut hap_vertex(uint vid [[vertex_id]]) {
        VOut out;
        out.position = float4(kQuadPos[vid], 0.0, 1.0);
        out.uv = kQuadUV[vid];
        return out;
    }

    fragment float4 hap_fragment(
        VOut in [[stage_in]],
        texture2d<float> tex [[texture(0)]],
        sampler s [[sampler(0)]]
    ) {
        return tex.sample(s, in.uv);
    }

    vertex BGVOut hap_vertex_bg(uint vid [[vertex_id]]) {
        BGVOut out;
        out.position = float4(kQuadPos[vid], 0.0, 1.0);
        return out;
    }

    fragment float4 hap_fragment_bg(
        BGVOut in [[stage_in]],
        constant BGUniforms& u [[buffer(0)]]
    ) {
        float2 cell = floor(in.position.xy / u.cellPx);
        float k = fmod(cell.x + cell.y, 2.0);
        float3 c = mix(u.dark, u.light, k);
        return float4(c, 1.0);
    }
    """
}
