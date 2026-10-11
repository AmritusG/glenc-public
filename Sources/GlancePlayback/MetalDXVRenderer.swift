// SPDX-License-Identifier: MIT
#if os(iOS)
import Foundation
import Metal
import CoreGraphics
import QuartzCore  // CACurrentMediaTime for Phase 3d perf-diag timing
import GlanceCore

/// Metal renderer for DXV frames (DXT1, DXT5, legacy DXT, YCG6, YG10) —
/// the iOS counterpart of the Mac `DXVRenderer`, with the same decode:
/// v0.17.1 uploads the DXVKit blocks unchanged as integer textures (one
/// texel per 4 x 4 block: `.rg32Uint` for 8-byte blocks, `.rgba32Uint`
/// for 16-byte ones) and decodes them in the fragment shader exactly as
/// DXVKit's CPU decoder does, so the result at 1:1 equals DXVKit's RGBA
/// and does not depend on the GPU's BC decoder (or on BC texture support).
/// Scaled, DXT and HQ luma / alpha blend bilinearly (8-bit weights), HQ
/// chroma is nearest (Resolume Arena's convention). Every texture is
/// cropped to the display size by the same rule as the Mac renderer
/// (`uvScale` in the vertex stage, `uvClamp` to the display texel centres
/// in the fragment stage).
///
/// **Render-target pixel format contract.** The renderer's pipeline
/// state is built against the `colorPixelFormat` passed to `init`.
/// Pass it the `MTKView.colorPixelFormat` you'll be drawing into —
/// changing it later requires a new renderer instance. Default for
/// `MTKView` on iOS is `.bgra8Unorm` (linear), which matches the Mac
/// renderer's tone. Hard requirement: stay linear (no `_srgb` target).
///
/// **Premultiplied alpha + checkerboard.** DXV uses DXT4-style
/// premultiplied alpha. The visual spec for the checkerboard
/// background is locked across the Glance toolchain (8 pt cells,
/// light gray 0.85, dark gray 0.65, premultiplied src=`one` /
/// dst=`oneMinusSourceAlpha`). Same colours and cell-size policy as
/// `DXVRenderer` lines 626–633 + 845–857. The `_srgb` variants are
/// off; the gamma-correct blend that produces is NOT what we want.
public final class MetalDXVRenderer {

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

    /// What the renderer paints behind the video frame. Mirrors
    /// `DXVRenderer.BackgroundMode` semantically (locked Glance-
    /// toolchain visual spec). `.black` disables blend; `.checkerboard`
    /// paints the locked 8 pt / 0.85 / 0.65 pattern and enables
    /// premultiplied-alpha blending so DXT5 transparent pixels reveal
    /// it.
    public enum BackgroundMode { case black, checkerboard }

    /// Layer backing-scale (`pt → px`). Used by the checkerboard pass
    /// to keep cells visually 8 pt regardless of Retina. Push the
    /// MTKView's `contentScaleFactor` (or `traitCollection.displayScale`)
    /// here. Default 2.0 covers any Retina-class iPad if the caller
    /// forgets.
    public var contentsScale: CGFloat = 2.0

    /// v0.18.0 — mirrors `DXVRenderer.alphaType`: what the current DXV
    /// clip's colour is (Resolume Arena's per-clip "Alpha Type"; a DXV file
    /// does not say). `.premultiplied` (default) draws DXT5 / YG10 texels as
    /// they are; `.straight` premultiplies them in the shader first.
    public var alphaType: AlphaType = .premultiplied

    public var backgroundMode: BackgroundMode = .black

    /// Phase 3d perf-diag: when true, the renderer prints one line per
    /// upload (variant + dims + ms) and one line per `MTLTexture`
    /// allocation (label + dims + format). Off by default — caller flips
    /// it on for device performance runs. Effectively free when off
    /// (a single `if enableDiagnostics` branch per call site).
    public var enableDiagnostics: Bool = false

    /// Visual spec, locked Glance-toolchain. Don't make configurable.
    public static let checkerboardCellPoints: CGFloat = 8.0

    public private(set) var lastUploadVariant: DXVVariant?
    public private(set) var lastUploadWidth: Int = 0   // display
    public private(set) var lastUploadHeight: Int = 0
    public private(set) var hasUpload: Bool = false

    // MARK: - Internal Metal state

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let colorPixelFormat: MTLPixelFormat

    /// Pipeline used to draw the DXT-sampled fullscreen quad with
    /// premultiplied-alpha blending (matches `DXVRenderer.renderDXT`
    /// + the post-checker `glBlendFunc(ONE, ONE_MINUS_SRC_ALPHA)`).
    private var dxtBlendPipeline: MTLRenderPipelineState!

    /// Pipeline used to draw the DXT-sampled fullscreen quad with
    /// blend OFF (matches `.black` background mode where Mac calls
    /// `glDisable(GL_BLEND)` before the DXT draw). Same shaders;
    /// different `colorAttachments[0]` blend config.
    private var dxtOpaquePipeline: MTLRenderPipelineState!

    /// Pipeline for the checkerboard background pass.
    private var bgPipeline: MTLRenderPipelineState!

    /// HQ-path pipelines (Phase 3d). Two for the same blend/opaque
    /// switch the DXT path uses — same shaders, different
    /// `colorAttachments[0]` blend config.
    private var hqBlendPipeline: MTLRenderPipelineState!
    private var hqOpaquePipeline: MTLRenderPipelineState!


    /// BC1 (`.rg32Uint`) or BC3 (`.rgba32Uint`) blocks, one texel per
    /// block. Reallocated on a grid or format change.
    private var dxtTexture: MTLTexture?

    /// Padded size (pixels) of the last DXT upload and its display crop.
    private var dxtTexSize: (w: Int, h: Int) = (0, 0)
    private var dxtCrop = Crop()

    // MARK: - Internal Metal state — HQ path

    /// DXVKit block streams, one texel per block: luma BC4 Y (YCG6,
    /// `.rg32Uint`) or BC5 Y + A (YG10, `.rgba32Uint`) at the coded size;
    /// chroma BC5 Co + Cg (`.rgba32Uint`) at coded / 2.
    private var hqTextureLuma: MTLTexture?
    private var hqTextureChroma: MTLTexture?

    private var hqHasUpload: Bool = false

    /// Coded (16 x 16 padded) size of the last HQ upload and its crop.
    private var hqTexSize: (w: Int, h: Int) = (0, 0)
    private var hqCrop = Crop()

    // MARK: - Init

    public init(device: MTLDevice, colorPixelFormat: MTLPixelFormat = .bgra8Unorm) throws {
        self.device = device
        self.colorPixelFormat = colorPixelFormat
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

        try buildPipelines(library: library)
    }

    private func buildPipelines(library: MTLLibrary) throws {
        let dxtVS = library.makeFunction(name: "dxv_vertex")
        let dxtFS = library.makeFunction(name: "dxv_fragment_dxt")
        let hqFS = library.makeFunction(name: "dxv_fragment_hq")
        let bgVS = library.makeFunction(name: "dxv_vertex_bg")
        let bgFS = library.makeFunction(name: "dxv_fragment_bg")

        // DXT blend pipeline (premultiplied alpha; used in checkerboard mode)
        let blendDesc = MTLRenderPipelineDescriptor()
        blendDesc.label = "DXV.DXT.blend"
        blendDesc.vertexFunction = dxtVS
        blendDesc.fragmentFunction = dxtFS
        blendDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        blendDesc.colorAttachments[0].isBlendingEnabled = true
        blendDesc.colorAttachments[0].rgbBlendOperation = .add
        blendDesc.colorAttachments[0].alphaBlendOperation = .add
        blendDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        blendDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        blendDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        blendDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            dxtBlendPipeline = try device.makeRenderPipelineState(descriptor: blendDesc)
        } catch {
            throw RendererError.pipelineCreationFailed("DXT blend: \(error)")
        }

        // DXT opaque pipeline (blend off; used in .black mode)
        let opaqueDesc = MTLRenderPipelineDescriptor()
        opaqueDesc.label = "DXV.DXT.opaque"
        opaqueDesc.vertexFunction = dxtVS
        opaqueDesc.fragmentFunction = dxtFS
        opaqueDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        opaqueDesc.colorAttachments[0].isBlendingEnabled = false
        do {
            dxtOpaquePipeline = try device.makeRenderPipelineState(descriptor: opaqueDesc)
        } catch {
            throw RendererError.pipelineCreationFailed("DXT opaque: \(error)")
        }

        // Background pipeline (checkerboard; opaque)
        let bgDesc = MTLRenderPipelineDescriptor()
        bgDesc.label = "DXV.background"
        bgDesc.vertexFunction = bgVS
        bgDesc.fragmentFunction = bgFS
        bgDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        bgDesc.colorAttachments[0].isBlendingEnabled = false
        do {
            bgPipeline = try device.makeRenderPipelineState(descriptor: bgDesc)
        } catch {
            throw RendererError.pipelineCreationFailed("background: \(error)")
        }

        // HQ blend pipeline (premultiplied alpha; checkerboard mode)
        let hqBlendDesc = MTLRenderPipelineDescriptor()
        hqBlendDesc.label = "DXV.HQ.blend"
        hqBlendDesc.vertexFunction = dxtVS  // shared vertex — the crop rule
        hqBlendDesc.fragmentFunction = hqFS
        hqBlendDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        hqBlendDesc.colorAttachments[0].isBlendingEnabled = true
        hqBlendDesc.colorAttachments[0].rgbBlendOperation = .add
        hqBlendDesc.colorAttachments[0].alphaBlendOperation = .add
        hqBlendDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        hqBlendDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        hqBlendDesc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        hqBlendDesc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            hqBlendPipeline = try device.makeRenderPipelineState(descriptor: hqBlendDesc)
        } catch {
            throw RendererError.pipelineCreationFailed("HQ blend: \(error)")
        }

        // HQ opaque pipeline (blend off; .black mode)
        let hqOpaqueDesc = MTLRenderPipelineDescriptor()
        hqOpaqueDesc.label = "DXV.HQ.opaque"
        hqOpaqueDesc.vertexFunction = dxtVS
        hqOpaqueDesc.fragmentFunction = hqFS
        hqOpaqueDesc.colorAttachments[0].pixelFormat = colorPixelFormat
        hqOpaqueDesc.colorAttachments[0].isBlendingEnabled = false
        do {
            hqOpaquePipeline = try device.makeRenderPipelineState(descriptor: hqOpaqueDesc)
        } catch {
            throw RendererError.pipelineCreationFailed("HQ opaque: \(error)")
        }
    }

    // MARK: - Upload — DXT path

    /// DXT1 / DXT5 upload. Mirrors `DXVRenderer.uploadFrame`: display
    /// `width` / `height`; `dxtBytes` holds whole blocks over the
    /// 16-pixel-padded width and at least `ceil(height / 4)` block rows
    /// (what `DXVPlayer` produces). The blocks go up unchanged; the shader
    /// decodes them.
    @discardableResult
    public func uploadFrame(
        dxtBytes: Data,
        variant: DXVVariant,
        width: Int,
        height: Int
    ) -> Bool {
        precondition(variant == .dxt1 || variant == .dxt5, "uploadFrame is DXT only; use uploadHQFrame for HQ")
        let diagStart = enableDiagnostics ? CACurrentMediaTime() : 0
        guard width > 0, height > 0 else { return false }
        let blockBytes = variant == .dxt1 ? 8 : 16
        let blocksX = (width + 15) / 16 * 4
        let blocksY = dxtBytes.count / (blocksX * blockBytes)
        guard blocksY >= (height + 3) / 4 else {
            print("MetalDXVRenderer: DXT upload too short (\(dxtBytes.count) B for \(width)x\(height))")
            return false
        }
        guard let tex = uploadBlocks(into: dxtTexture, data: dxtBytes, blockBytes: blockBytes,
                                     blocksX: blocksX, blocksY: blocksY) else { return false }
        dxtTexture = tex
        dxtTexSize = (blocksX * 4, blocksY * 4)
        dxtCrop = Crop(displayWidth: width, displayHeight: height, textureWidth: dxtTexSize.w, textureHeight: dxtTexSize.h)
        lastUploadVariant = variant
        lastUploadWidth = width
        lastUploadHeight = height
        hasUpload = true
        if enableDiagnostics {
            let ms = (CACurrentMediaTime() - diagStart) * 1000.0
            print(String(format: "MetalDXVRenderer/perf: upload DXT variant=%@ w=%d h=%d ms=%.3f bytes=%d",
                         variant == .dxt1 ? "dxt1" : "dxt5", width, height, ms, dxtBytes.count))
        }
        return true
    }

    /// HQ upload — YCG6 / YG10 DXVKit block streams (mirror of the Mac
    /// `DXVRenderer.uploadHQFrame`): luma = BC4 Y (YCG6) or BC5 Y + A (YG10)
    /// at the coded size, chroma = BC5 Co + Cg at coded / 2, uploaded
    /// unchanged and decoded in the shader; cropped to the display size.
    /// Plane-only frames (no block streams) are refused.
    @discardableResult
    public func uploadHQFrame(_ frame: DXVHQFrame, variant: DXVVariant) -> Bool {
        precondition(variant == .ycg6 || variant == .yg10,
                     "uploadHQFrame is HQ only; use uploadFrame for DXT")
        let diagStart = enableDiagnostics ? CACurrentMediaTime() : 0
        guard let luma = frame.lumaBlocks, let chroma = frame.chromaBlocks else {
            print("MetalDXVRenderer: HQ frame has no block streams (plane-only DXVHQFrame) — not drawable")
            return false
        }
        let hasAlpha = variant == .yg10
        let lumaBlockBytes = hasAlpha ? 16 : 8
        guard frame.hasAlpha == hasAlpha,
              luma.count == (frame.codedWidth / 4) * (frame.codedHeight / 4) * lumaBlockBytes,
              chroma.count == (frame.chromaWidth / 4) * (frame.chromaHeight / 4) * 16 else {
            print("MetalDXVRenderer: HQ block streams inconsistent (\(variant) coded=\(frame.codedWidth)x\(frame.codedHeight) luma=\(luma.count) chroma=\(chroma.count))")
            return false
        }
        guard let l = uploadBlocks(into: hqTextureLuma, data: luma, blockBytes: lumaBlockBytes,
                                   blocksX: frame.codedWidth / 4, blocksY: frame.codedHeight / 4),
              let c = uploadBlocks(into: hqTextureChroma, data: chroma, blockBytes: 16,
                                   blocksX: frame.chromaWidth / 4, blocksY: frame.chromaHeight / 4) else { return false }
        hqTextureLuma = l
        hqTextureChroma = c
        hqHasUpload = true

        // Shared "last upload" state — public display dims so the
        // caller's aspect-fit reads display, not padded.
        lastUploadVariant = variant
        lastUploadWidth = frame.width
        lastUploadHeight = frame.height
        hqTexSize = (frame.codedWidth, frame.codedHeight)
        hqCrop = Crop(displayWidth: frame.width, displayHeight: frame.height,
                      textureWidth: frame.codedWidth, textureHeight: frame.codedHeight)
        hasUpload = true
        if enableDiagnostics {
            let ms = (CACurrentMediaTime() - diagStart) * 1000.0
            print(String(format: "MetalDXVRenderer/perf: upload HQ variant=%@ display=%dx%d coded=%dx%d ms=%.3f bytes=%d",
                         hasAlpha ? "yg10" : "ycg6", frame.width, frame.height,
                         frame.codedWidth, frame.codedHeight, ms, luma.count + chroma.count))
        }
        return true
    }

    /// Allocate (on a grid / format change) or update one block texture:
    /// raw blocks, one texel per block (8-byte blocks `.rg32Uint`, 16-byte
    /// blocks `.rgba32Uint`). Returns the texture, or nil if allocation failed.
    private func uploadBlocks(into existing: MTLTexture?, data: Data, blockBytes: Int,
                              blocksX: Int, blocksY: Int) -> MTLTexture? {
        guard blocksX > 0, blocksY > 0, data.count >= blocksX * blocksY * blockBytes else { return nil }
        let format: MTLPixelFormat = blockBytes == 16 ? .rgba32Uint : .rg32Uint
        var target = existing
        if target == nil || target!.pixelFormat != format || target!.width != blocksX || target!.height != blocksY {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: blocksX,
                                                                height: blocksY, mipmapped: false)
            desc.usage = .shaderRead
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else {
                if enableDiagnostics { print("MetalDXVRenderer/perf: ALLOC FAILED \(format) \(blocksX)x\(blocksY) blocks") }
                return nil
            }
            if enableDiagnostics { print("MetalDXVRenderer/perf: alloc \(format) \(blocksX)x\(blocksY) blocks") }
            target = tex
        }
        data.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            target!.replace(region: MTLRegionMake2D(0, 0, blocksX, blocksY), mipmapLevel: 0,
                            withBytes: base, bytesPerRow: blocksX * blockBytes)
        }
        return target
    }

    // MARK: - Render

    /// Render the most-recently-uploaded frame into the encoder's
    /// drawable. `viewport` is the iPad-app-side aspect-fit rect in
    /// the drawable's pixel coords — letterbox happens outside that
    /// rect (caller handles the clear). Same contract as
    /// `DXVRenderer.render()` lines 588–624: video pixels touch only
    /// the renderer's viewport; surrounding letterbox is the caller's.
    public func render(into encoder: MTLRenderCommandEncoder, viewport: MTLViewport) {
        guard hasUpload, let variant = lastUploadVariant else { return }
        let isHQ = (variant == .ycg6 || variant == .yg10)
        if isHQ {
            guard hqHasUpload, let luma = hqTextureLuma, let chroma = hqTextureChroma else { return }
            encodeHQ(into: encoder, viewport: viewport, variant: variant, luma: luma, chroma: chroma)
        } else {
            guard let texture = dxtTexture else { return }
            encodeDXT(into: encoder, viewport: viewport, texture: texture)
        }
    }

    private func encodeDXT(
        into encoder: MTLRenderCommandEncoder,
        viewport: MTLViewport,
        texture: MTLTexture
    ) {
        encoder.setViewport(viewport)

        // Background pass first (only in checkerboard mode), then DXT
        // pass on top with premultiplied-alpha blending — same order
        // and same semantics as Mac DXVRenderer.render().
        switch backgroundMode {
        case .black:
            encoder.setRenderPipelineState(dxtOpaquePipeline)
        case .checkerboard:
            encodeBackground(into: encoder)
            encoder.setRenderPipelineState(dxtBlendPipeline)
        }

        var vertexUniforms = VertexUniforms(uvScale: dxtCrop.scale)
        encoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<VertexUniforms>.stride, index: 0)

        var dxtFragUniforms = DXTFragUniforms(
            uvClamp: dxtCrop.clamp,
            texSize: SIMD2<Float>(Float(dxtTexSize.w), Float(dxtTexSize.h)),
            displaySize: SIMD2<Int32>(Int32(lastUploadWidth), Int32(lastUploadHeight)),
            format: lastUploadVariant == .dxt1 ? 1 : 3,
            premultiply: alphaType == .straight && lastUploadVariant == .dxt5 ? 1 : 0)
        encoder.setFragmentBytes(&dxtFragUniforms, length: MemoryLayout<DXTFragUniforms>.stride, index: 0)

        encoder.setFragmentTexture(texture, index: 0)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func encodeHQ(
        into encoder: MTLRenderCommandEncoder,
        viewport: MTLViewport,
        variant: DXVVariant,
        luma: MTLTexture,
        chroma: MTLTexture
    ) {
        encoder.setViewport(viewport)

        switch backgroundMode {
        case .black:
            encoder.setRenderPipelineState(hqOpaquePipeline)
        case .checkerboard:
            encodeBackground(into: encoder)
            encoder.setRenderPipelineState(hqBlendPipeline)
        }

        var vertexUniforms = VertexUniforms(uvScale: hqCrop.scale)
        encoder.setVertexBytes(&vertexUniforms, length: MemoryLayout<VertexUniforms>.stride, index: 0)

        var hqFragUniforms = HQFragUniforms(
            uvClamp: hqCrop.clamp,
            texSize: SIMD2<Float>(Float(hqTexSize.w), Float(hqTexSize.h)),
            displaySize: SIMD2<Int32>(Int32(lastUploadWidth), Int32(lastUploadHeight)),
            hasAlpha: variant == .yg10 ? 1 : 0,
            premultiply: alphaType == .straight && variant == .yg10 ? 1 : 0
        )
        encoder.setFragmentBytes(&hqFragUniforms, length: MemoryLayout<HQFragUniforms>.stride, index: 0)

        // Texture bindings: luma blocks (Y [+ A]) = 0, chroma blocks (Co + Cg) = 1.
        encoder.setFragmentTexture(luma, index: 0)
        encoder.setFragmentTexture(chroma, index: 1)

        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    private func encodeBackground(into encoder: MTLRenderCommandEncoder) {
        encoder.setRenderPipelineState(bgPipeline)
        var bgUniforms = BGUniforms(
            light: SIMD3<Float>(0.85, 0.85, 0.85),
            dark:  SIMD3<Float>(0.65, 0.65, 0.65),
            cellPx: Float(Self.checkerboardCellPoints * max(1.0, contentsScale))
        )
        encoder.setFragmentBytes(&bgUniforms, length: MemoryLayout<BGUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - Uniform structs (mirrored to MSL via stride)

    /// The crop rule (same as the Mac renderer's `TextureCrop`): `scale` =
    /// display / texture size on both axes for the vertex stage; `clamp`
    /// (min.xy, max.zw) keeps the sample point on the display texels' centres.
    private struct Crop {
        var scale = SIMD2<Float>(1, 1)
        var clamp = SIMD4<Float>(0, 0, 1, 1)
        init() {}
        init(displayWidth: Int, displayHeight: Int, textureWidth: Int, textureHeight: Int) {
            let tw = Float(max(1, textureWidth)), th = Float(max(1, textureHeight))
            let dw = Float(max(1, min(displayWidth, textureWidth))), dh = Float(max(1, min(displayHeight, textureHeight)))
            scale = SIMD2(dw / tw, dh / th)
            clamp = SIMD4(0.5 / tw, 0.5 / th, (dw - 0.5) / tw, (dh - 0.5) / th)
        }
    }
    private struct VertexUniforms {
        var uvScale: SIMD2<Float>
    }
    private struct DXTFragUniforms {
        var uvClamp: SIMD4<Float>
        var texSize: SIMD2<Float>
        var displaySize: SIMD2<Int32>
        var format: Int32         // 1 = BC1 (DXT1), 3 = BC3 (DXT5)
        var premultiply: Int32    // 0/1 — kept Int32 to match MSL `int`
    }
    private struct HQFragUniforms {
        var uvClamp: SIMD4<Float>
        var texSize: SIMD2<Float>
        var displaySize: SIMD2<Int32>
        var hasAlpha: Int32       // 0 for YCG6 (shader writes alpha=1), 1 for YG10
        var premultiply: Int32    // 0/1
    }
    private struct BGUniforms {
        var light: SIMD3<Float>
        var dark: SIMD3<Float>
        var cellPx: Float
    }

    // MARK: - MSL shader source

    /// MSL shaders for the DXT and HQ paths + the checkerboard background.
    /// Geometry: fullscreen quad as a triangle strip, generated in the
    /// vertex shader from `vertex_id` (no vertex buffer needed). UVs
    /// are flipped on Y so texture row 0 lands at the top of the
    /// viewport (blocks are stored top-to-bottom, same as Mac's
    /// `DXVRenderer` quad). `uvScale` + `uvClamp` are the crop rule,
    /// matching Mac's `vertexShaderSrc` / `cropFragmentSrc`.
    ///
    /// Checkerboard math is the same `gl_FragCoord`-keyed two-colour
    /// pattern as `DXVRenderer.bgFragmentShaderSrc`. MSL's
    /// `position.xy` plays the role of `gl_FragCoord.xy`.
    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct DXTVertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct VertexUniforms {
        float2 uvScale;
    };

    struct DXTFragUniforms {
        float4 uvClamp;
        float2 texSize;
        int2 displaySize;
        int format;
        int premultiply;
    };

    struct HQFragUniforms {
        float4 uvClamp;
        float2 texSize;
        int2 displaySize;
        int hasAlpha;
        int premultiply;
    };

    struct BGUniforms {
        float3 light;
        float3 dark;
        float cellPx;
    };

    // Fullscreen quad triangle-strip: 4 vertices indexed by vertex_id.
    // Position in clip space, uv in [0,1] with y flipped so v=0 is the
    // top row of the texture (matches Mac DXVRenderer's quad).
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

    vertex DXTVertexOut dxv_vertex(
        uint vid [[vertex_id]],
        constant VertexUniforms& u [[buffer(0)]]
    ) {
        DXTVertexOut out;
        out.position = float4(kQuadPos[vid], 0.0, 1.0);
        out.uv = kQuadUV[vid] * u.uvScale;
        return out;
    }

    // DXVKit's BC block decode (src/pixels.c), same as the Mac GLSL
    // `blockDecodeSrc`: raw little-endian block words, texel i = row * 4 +
    // column; BC1 thirds / halves truncated, BC4 truncated to 8 bits (DXT5
    // alpha) or exact in 1/35 units (HQ planes).
    static uint3 expand565(uint c) {
        uint r = c >> 11, g = (c >> 5) & 63u, b = c & 31u;
        return uint3((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2));
    }
    static uint3 bc1Colour(uint2 b, uint i, bool fourColour) {
        uint c0 = b.x & 0xFFFFu, c1 = b.x >> 16;
        uint3 p0 = expand565(c0), p1 = expand565(c1);
        uint idx = (b.y >> (2u * i)) & 3u;
        if (idx == 0u) return p0;
        if (idx == 1u) return p1;
        if (fourColour || c0 > c1) return idx == 2u ? (2u * p0 + p1) / 3u : (p0 + 2u * p1) / 3u;
        return idx == 2u ? (p0 + p1) / 2u : uint3(0u);
    }
    static uint bc4Index(uint2 b, uint i) {
        uint pos = 16u + 3u * i;
        if (pos >= 32u) return (b.y >> (pos - 32u)) & 7u;
        if (pos <= 29u) return (b.x >> pos) & 7u;
        return ((b.x >> pos) | (b.y << (32u - pos))) & 7u;
    }
    static uint bc4Pal35(uint2 b, uint i) {
        uint a0 = b.x & 255u, a1 = (b.x >> 8) & 255u, idx = bc4Index(b, i);
        if (idx == 0u) return a0 * 35u;
        if (idx == 1u) return a1 * 35u;
        uint k = idx - 1u;
        if (a0 > a1) return ((7u - k) * a0 + k * a1) * 5u;
        if (idx <= 5u) return ((5u - k) * a0 + k * a1) * 7u;
        return idx == 6u ? 0u : 255u * 35u;
    }
    static uint bc4Pal8(uint2 b, uint i) {
        uint a0 = b.x & 255u, a1 = (b.x >> 8) & 255u, idx = bc4Index(b, i);
        if (idx == 0u) return a0;
        if (idx == 1u) return a1;
        uint k = idx - 1u;
        if (a0 > a1) return ((7u - k) * a0 + k * a1) / 7u;
        if (idx <= 5u) return ((5u - k) * a0 + k * a1) / 5u;
        return idx == 6u ? 0u : 255u;
    }
    static uint blockTexel(int2 p) { return uint((p.y & 3) * 4 + (p.x & 3)); }
    // Bilinear sample position in texels, snapped to 1/256 texel (8-bit
    // weights): whole texels at 1:1. `uv` is already clamped (crop rule).
    static float2 samplePoint(float2 uv, float2 texSize) { return floor((uv * texSize - 0.5) * 256.0 + 0.5) / 256.0; }

    static float4 dxtTexel(texture2d<uint, access::read> tex, int2 p, int format) {
        uint4 w = tex.read(uint2(p >> 2));
        uint i = blockTexel(p);
        if (format == 1) return float4(float3(bc1Colour(w.xy, i, false)), 255.0);
        return float4(float3(bc1Colour(w.zw, i, true)), float(bc4Pal8(w.xy, i)));
    }

    // DXT fragment (BC1 / BC3): the four display texels around the sample
    // point, decoded and blended bilinearly; exact at 1:1.
    fragment float4 dxv_fragment_dxt(
        DXTVertexOut in [[stage_in]],
        texture2d<uint, access::read> tex [[texture(0)]],
        constant DXTFragUniforms& u [[buffer(0)]]
    ) {
        float2 p = samplePoint(clamp(in.uv, u.uvClamp.xy, u.uvClamp.zw), u.texSize);
        float2 f = p - floor(p);
        int2 lo = int2(0), hi = u.displaySize - 1;
        int2 a = clamp(int2(floor(p)), lo, hi), b = clamp(int2(floor(p)) + 1, lo, hi);
        float4 c = mix(mix(dxtTexel(tex, a, u.format), dxtTexel(tex, int2(b.x, a.y), u.format), f.x),
                       mix(dxtTexel(tex, int2(a.x, b.y), u.format), dxtTexel(tex, b, u.format), f.x), f.y) / 255.0;
        if (u.premultiply == 1) {   // DXT5 with Alpha Type Straight
            c.rgb = c.rgb * c.a;
        }
        return c;
    }

    // HQ fragment — DXVKit's HQ decode (rows_hq / hq_rgb) in its 1/70 fixed
    // point, as the Mac GLSL shader: Y / A exact BC4 (1/35), bilinear when
    // scaled; Co / Cg from the nearest pixel / 2; Resolume Arena's
    // conversion (midpoint 127.5, R / B folding, round half up). Alpha
    // passes through.
    constant int HQ_ONE = 70, HQ_MAX = 255 * 70, HQ_MID = 255 * 70 / 2;
    static float2 lumaTexel(texture2d<uint, access::read> tex, int2 p, int hasAlpha) {
        uint4 w = tex.read(uint2(p >> 2));
        uint i = blockTexel(p);
        return float2(float(bc4Pal35(w.xy, i)), hasAlpha == 1 ? float(bc4Pal35(w.zw, i)) : 255.0 * 35.0);
    }
    static int hqRound(int v) { return v <= 0 ? 0 : v >= HQ_MAX ? 255 : (v + HQ_ONE / 2) / HQ_ONE; }

    fragment float4 dxv_fragment_hq(
        DXTVertexOut in [[stage_in]],
        texture2d<uint, access::read> texLuma   [[texture(0)]],
        texture2d<uint, access::read> texChroma [[texture(1)]],
        constant HQFragUniforms& u [[buffer(0)]]
    ) {
        float2 uv = clamp(in.uv, u.uvClamp.xy, u.uvClamp.zw);
        float2 p = samplePoint(uv, u.texSize);
        float2 f = p - floor(p);
        int2 lo = int2(0), hi = u.displaySize - 1;
        int2 a = clamp(int2(floor(p)), lo, hi), b = clamp(int2(floor(p)) + 1, lo, hi);
        float2 l = mix(mix(lumaTexel(texLuma, a, u.hasAlpha), lumaTexel(texLuma, int2(b.x, a.y), u.hasAlpha), f.x),
                       mix(lumaTexel(texLuma, int2(a.x, b.y), u.hasAlpha), lumaTexel(texLuma, b, u.hasAlpha), f.x), f.y);
        int2 q = clamp(int2(floor(uv * u.texSize)), lo, hi) >> 1;
        uint4 cw = texChroma.read(uint2(q >> 2));
        uint ci = blockTexel(q);
        int y  = int(floor(2.0 * l.x + 0.5));
        int co = 2 * int(bc4Pal35(cw.xy, ci)) - HQ_MID;
        int cg = 2 * int(bc4Pal35(cw.zw, ci)) - HQ_MID;
        int t = y - cg, r = t + co, g = y + cg, bl = t - co;
        if (r < 0)       { bl += r; r = 0; }
        if (bl < 0)      { r += bl; bl = 0; }
        if (r > HQ_MAX)  { bl += r - HQ_MAX; r = HQ_MAX; }
        if (bl > HQ_MAX) { r += bl - HQ_MAX; bl = HQ_MAX; }
        float3 rgb = float3(float(hqRound(r)), float(hqRound(g)), float(hqRound(bl))) / 255.0;

        float alpha = 1.0;
        if (u.hasAlpha == 1) {
            alpha = float(hqRound(int(floor(2.0 * l.y + 0.5)))) / 255.0;
            if (u.premultiply == 1) {   // YG10 with Alpha Type Straight
                rgb = rgb * alpha;
            }
        }
        return float4(rgb, alpha);
    }

    // Background pass: same fullscreen quad, no uv attribute needed
    // (the fragment is position-driven, like Mac's bgFragmentShaderSrc).
    struct BGVertexOut {
        float4 position [[position]];
    };

    vertex BGVertexOut dxv_vertex_bg(uint vid [[vertex_id]]) {
        BGVertexOut out;
        out.position = float4(kQuadPos[vid], 0.0, 1.0);
        return out;
    }

    fragment float4 dxv_fragment_bg(
        BGVertexOut in [[stage_in]],
        constant BGUniforms& u [[buffer(0)]]
    ) {
        float2 cell = floor(in.position.xy / u.cellPx);
        float k = fmod(cell.x + cell.y, 2.0);
        float3 c = mix(u.dark, u.light, k);
        return float4(c, 1.0);
    }
    """
}
#endif
