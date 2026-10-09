// SPDX-License-Identifier: MIT
#if os(macOS)
import Foundation
import OpenGL.GL3
import GlanceCore

/// OpenGL renderer for DXV frames (DXT1 / DXT5 / YCG6 / YG10, and the
/// legacy DXDI DXT variants). The blocks come from DXVKit (via
/// `DXVPlayer` / GlanceCore's `DXVFrameDecoder`); the GPU decodes them.
///
/// v0.17.1: the GPU decodes every DXV block in the fragment shader, exactly
/// as DXVKit's CPU decoder does (`blockDecodeSrc`): the blocks are uploaded
/// unchanged as integer textures (one texel per 4 x 4 block) and read with
/// texelFetch, so the result does not depend on the GPU's fixed-function
/// BC decoder (the M3's BC4 palette is off by up to 1.7 / 255; its BC3
/// alpha by up to 2). At 1:1 the render equals DXVKit's RGBA.
///
/// DXT path (DXT1, DXT5, legacy, HAP Hap1 / Hap5): BC1 / BC3 blocks over
/// the 16-pixel-padded width, bilinear between decoded texels when scaled.
///
/// HQ path (YCG6, YG10): DXVKit's block streams — luma BC4 Y or BC5 Y + A,
/// chroma BC5 Co + Cg — over the 16 x 16 padded coded texture, converted
/// YCoCg → RGB in Resolume Arena's convention in DXVKit's 1/70 fixed point
/// (chroma midpoint 127.5, nearest chroma, R / B folding); luma and alpha
/// bilinear when scaled.
///
/// Every program crops its padded texture to the display size by one rule
/// (`TextureCrop`): exact texel centres at 1:1, no padding when scaled.
///
/// The two paths have separate GL programs and texture sets but
/// share the VAO/VBO (same fullscreen quad geometry). render()
/// branches on lastUploadVariant to pick the right program + texture
/// bindings.
///
/// GL state contract: this renderer touches program, VAO, VBO, texture
/// binding, GL_BLEND, blend func, viewport. It restores nothing — the
/// caller (VideoLayer.draw) is responsible for setting whatever state
/// it needs after each draw call.
public final class DXVRenderer {

    public enum Variant {
        case dxt1, dxt5, ycg6, yg10

        public var isHQ: Bool {
            switch self {
            case .ycg6, .yg10: return true
            case .dxt1, .dxt5: return false
            }
        }
    }

    /// What the renderer paints behind the video frame.
    ///
    /// - `.black`: opaque-black behind. `BLEND` stays disabled. Render
    ///   path is byte-identical to pre-feature output: DXT1 and YCG6
    ///   (alpha=1 every pixel) write straight to the framebuffer; DXT5
    ///   / YG10 transparent pixels are premultiplied src=(0,0,0,0) on
    ///   top of the caller's `glClear` so they read as black.
    ///
    /// - `.checkerboard`: a 2-colour checker is rasterized first by a
    ///   minimal GL pass that fills the renderer's viewport, then
    ///   premultiplied-alpha blending (`GL_ONE`,
    ///   `GL_ONE_MINUS_SRC_ALPHA`) composites the video on top. For
    ///   opaque variants the alpha=1 fragments fully cover the checker
    ///   so the output stays bit-identical to `.black`; for DXT5 /
    ///   YG10 the transparent regions reveal the checker.
    ///
    /// Letterbox (the aspect-fit dead band outside the renderer's
    /// viewport) is unaffected — the caller's pre-render `glClear`
    /// owns that region and stays solid black.
    public enum BackgroundMode: String, CaseIterable {
        case black        = "black"
        case checkerboard = "checkerboard"
    }

    /// Phase 3a: the HQ frame struct was lifted to top-level
    /// `DXVHQFrame` (peer file `DXVHQFrame.swift`) so the player and
    /// any renderer (Mac OpenGL here, iOS Metal in Phase 3c) share a
    /// platform-agnostic data type rather than a renderer-nested one.
    /// This typealias keeps the spelling `DXVRenderer.HQFrameData`
    /// working for existing call sites (Crate-Mac's
    /// `DXVPreviewLayer`, Glance app's `PlayerModel`, CueGlance,
    /// GlEnc). No behavior change.
    public typealias HQFrameData = DXVHQFrame

    /// What the renderer's last upload was (variant, dimensions). Set
    /// during uploadFrame; consumed by render to size the viewport
    /// correctly. `lastUploadWidth`/`lastUploadHeight` are **display**
    /// dimensions — what `VideoLayer`'s aspect-fit math should use.
    /// The padded coded dimensions used for texture storage are
    /// internal to the renderer and not exposed.
    public private(set) var lastUploadVariant: Variant?
    public private(set) var lastUploadWidth: Int = 0     // display
    public private(set) var lastUploadHeight: Int = 0    // display
    public private(set) var hasUpload: Bool = false

    /// Whether to un-premultiply alpha at render time. DXV uses
    /// DXT4-style premultiplied alpha; for compositing matching
    /// Resolume we want it premultiplied. For showing alongside
    /// straight-alpha sources (Photoshop), un-premultiply.
    public var unpremultiplyAlpha: Bool = false

    /// Background mode painted behind the video frame. See `BackgroundMode`.
    /// Default `.black` — preserves byte-identical output for every variant.
    public var backgroundMode: BackgroundMode = .black

    /// Layer backing-scale factor (`pt → px`). Used by the checkerboard
    /// pass to keep cells visually `8 pt` regardless of Retina. Caller
    /// pushes its `CALayer.contentsScale` here per-draw (or once, on
    /// layout). Default `2.0` covers any Retina-class screen if the
    /// caller forgets.
    public var contentsScale: CGFloat = 2.0

    /// Checkerboard cell edge length in points. Fixed, not configurable
    /// — the design contract is "visually 8 pt on every display."
    public static let checkerboardCellPoints: CGFloat = 8.0

    // MARK: - GL objects: shared (DXT + HQ both use these)

    private var vao: GLuint = 0
    private var vbo: GLuint = 0

    /// Whether GL objects have been created. Created lazily on first
    /// draw, since we need a current GL
    /// context.
    private var glReady: Bool = false

    // MARK: - GL objects: DXT path (BC1 / BC3 blocks, decoded in the shader)

    private var dxtProgram: GLuint = 0
    /// BC1 (GL_RG32UI) or BC3 (GL_RGBA32UI) blocks, one texel per block.
    private var dxtTexture: GLuint = 0
    private var dxtUTextureLoc: GLint = -1
    private var dxtUFormatLoc: GLint = -1
    private var dxtUTexSizeLoc: GLint = -1
    private var dxtUDisplaySizeLoc: GLint = -1
    private var dxtUUnpremultiplyLoc: GLint = -1
    private var dxtUPremultiplyLoc: GLint = -1
    private var dxtCropLoc = CropLocations()

    /// Block grid + format of the DXT texture, for TexSubImage vs TexImage.
    private var dxtLastBlocks = BlockGrid()

    /// Padded size (pixels) of the last DXT upload: width to 16, height to
    /// whole block rows.
    private var dxtTexSize: (w: Int, h: Int) = (0, 0)

    /// Crop of the DXT texture (padded to 16 in width) to the display size.
    private var dxtCrop = TextureCrop()

    // MARK: - GL objects: RGBA path (CPU-decoded frames, e.g. HAP HapA)

    private var rgbaProgram: GLuint = 0
    private var rgbaTexture: GLuint = 0
    private var rgbaUTextureLoc: GLint = -1
    private var rgbaUPremultiplyLoc: GLint = -1
    private var rgbaCropLoc = CropLocations()
    private var rgbaCrop = TextureCrop()
    /// Set by `uploadRGBAFrame`, cleared by the other uploads.
    private var lastUploadIsRGBA: Bool = false

    // MARK: - GL objects: Hap Q path [Slice 2 — additive]
    //
    // Hap Q (HapY) is a SINGLE DXT5 texture of *scaled* YCoCg: the
    // encoder reinterprets the DXT5 channels as R=Co, G=Cg, B=per-block
    // scale, A=Y, with the scale packed PER-BLOCK in the DXT5 data (it
    // falls out of the texture sample — it is NOT a global uniform). So
    // like the DXV3 HQ path, Hap Q stays GPU-native: upload the DXT5 blocks
    // verbatim as a compressed DXT5 texture (reusing `uploadCompressed`),
    // then apply scaled-YCoCg → RGB in a NEW fragment shader that samples
    // that one texture. This is a separate, additive GL program — it does
    // NOT touch the DXT shader, the DXV3 YCoCg shader, or the Variant
    // enum. Selection is via `lastUploadIsHapQ`, set by `uploadHapQFrame`.
    //
    // The texture uses GL_NEAREST (not GL_LINEAR like the plain DXT
    // path): the per-block scale channel must NOT be bilinearly
    // interpolated across block boundaries (that would blend two
    // different scales → wrong colour), and point sampling is what makes
    // the GPU output match the CPU reference `HAPHQDecoder.unpackHapYToRGB`
    // per-fragment. Same precedent as the HQ chroma planes (GL_NEAREST).
    private var hapQProgram: GLuint = 0
    private var hapQTexture: GLuint = 0
    private var hapQULocTexture: GLint = -1
    private var hapQCropLoc = CropLocations()

    /// Set true by `uploadHapQFrame`, false by `uploadFrame` /
    /// `uploadHQFrame`. `render()` routes to `renderHapQ()` when true,
    /// independent of `lastUploadVariant` (which is left at `.dxt5` for
    /// the Hap Q DXT5 texture so the public dimension API stays valid).
    private var lastUploadIsHapQ: Bool = false

    private var hapQCrop = TextureCrop()
    private var hapQLastPaddedWidth: Int = 0
    private var hapQLastHeight: Int = 0
    private var hapQHasUpload: Bool = false

    // MARK: - GL objects: HapM path [Slice 3 — additive]
    //
    // HapM = HapY scaled-YCoCg DXT5 (color) + HapA BC4/RGTC1 (alpha),
    // wrapped in a 0x0D outer. This is the renderer's first TWO-texture
    // composite for a single draw: a NEW program samples the color texture
    // (scaled-YCoCg → RGB, the EXACT Slice-2 transform) AND a separate BC4
    // alpha texture (red channel → A), combining them in one fragment.
    // Output is premultiplied (rgb*a, a) so it composites identically to
    // DXT5/YG10 under the existing .black (blend off → transparent=black)
    // and .checkerboard (premultiplied blend) paths — zero blend changes.
    //
    // Both textures use GL_NEAREST: the color scale channel must not
    // interpolate across DXT5 block edges (same as Hap Q), and the BC4
    // alpha is point-sampled to match the CPU reference. Additive — does
    // NOT touch the DXT, HQ (DXV3 YCoCg), or Hap Q programs, nor the
    // Variant enum. Selection is via `lastUploadIsHapM`.
    private var hapMProgram: GLuint = 0
    private var hapMColorTexture: GLuint = 0   // DXT5 scaled-YCoCg (S3TC)
    private var hapMAlphaTexture: GLuint = 0   // BC4 / RGTC1 single-channel red
    private var hapMULocColor: GLint = -1
    private var hapMULocAlpha: GLint = -1
    private var hapMCropLoc = CropLocations()

    /// Set true by `uploadHapMFrame`, false by the other uploads.
    /// `render()` routes to `renderHapM()` when true.
    private var lastUploadIsHapM: Bool = false

    /// Set true when the last DXT upload carried STRAIGHT (non-premultiplied)
    /// alpha — i.e. a HAP Hap5 (DXT5 RGBA) frame. Driven by the `straightAlpha`
    /// argument to `uploadFrame` (caller-driven), NOT inferred from the
    /// variant: DXV dxt5 is also `.dxt5` but is premultiplied by authoring
    /// convention and MUST stay on the passthrough path. When true,
    /// `renderDXT()` sets the shader's `uPremultiply` so the straight texel is
    /// premultiplied (rgb*=a) post-sample, making it composite identically to
    /// premultiplied DXV dxt5/YG10 under both the `.black` (blend-off →
    /// transparent=black) and `.checkerboard` (premultiplied blend) paths.
    /// Every non-Hap5 upload (DXV dxt1/dxt5, HQ, HapQ, HapM) leaves it false,
    /// so those outputs are byte-identical to before. Mirrors the
    /// `lastUploadIsHapM` flag mechanism.
    private var lastUploadIsHap5Straight: Bool = false
    private var hapMCrop = TextureCrop()
    private var hapMLastPaddedWidth: Int = 0
    private var hapMLastHeight: Int = 0
    private var hapMHasUpload: Bool = false

    // MARK: - GL objects: HQ path (DXVKit block streams, compressed upload)

    private var hqProgram: GLuint = 0
    /// Luma blocks at the coded size: BC4 Y (YCG6, GL_RG32UI) or BC5 Y + A
    /// (YG10, GL_RGBA32UI), one texel per block.
    private var hqTextureLuma: GLuint = 0
    /// Chroma blocks at coded / 2: BC5 Co + Cg (GL_RGBA32UI). Sampled
    /// nearest (Resolume Arena's convention).
    private var hqTextureChroma: GLuint = 0

    private var hqULocLuma: GLint = -1
    private var hqULocChroma: GLint = -1
    private var hqULocHasAlpha: GLint = -1
    private var hqULocUnpremultiply: GLint = -1
    private var hqULocTexSize: GLint = -1
    private var hqULocDisplaySize: GLint = -1
    private var hqCropLoc = CropLocations()

    /// Crop of DXVKit's 16 x 16 padded coded texture to the display size.
    private var hqCrop = TextureCrop()

    /// Coded (16 x 16 padded) size of the last HQ upload, pixels.
    private var hqTexSize: (w: Int, h: Int) = (0, 0)

    /// Block grids of the last HQ upload, for TexSubImage vs TexImage.
    private var hqLastLumaBlocks = BlockGrid()
    private var hqLastChromaBlocks = BlockGrid()
    private var hqHasUpload: Bool = false

    // MARK: - GL objects: background pass (checkerboard)

    private var bgProgram: GLuint = 0
    private var bgULocLight: GLint = -1
    private var bgULocDark: GLint = -1
    private var bgULocCellPx: GLint = -1

    // MARK: - Constants for S3TC (not always exposed in macOS GL headers)

    private static let GL_COMPRESSED_RGB_S3TC_DXT1_EXT: GLenum = 0x83F0
    private static let GL_COMPRESSED_RGBA_S3TC_DXT5_EXT: GLenum = 0x83F3
    /// BC4 / RGTC1 — single-channel red, 8 B/block. Core since GL 3.0.
    /// Used by the HapM alpha plane [Slice 3].
    private static let GL_COMPRESSED_RED_RGTC1: GLenum = 0x8DBB

    // MARK: - Lifecycle

    public init() {}

    deinit {
        // Note: we can't safely call glDeleteX here because we don't
        // know if a GL context is current. In practice this renderer
        // lives for the app lifetime and leaking is fine.
    }

    /// Lazy create program + VAO + VBO. Called from render() once we
    /// know a GL context is current.
    private func ensureGLObjects() {
        guard !glReady else { return }

        // ---------- Shared VAO/VBO (fullscreen quad, used by both paths) ----------
        // Fullscreen quad: triangle strip, 4 vertices.
        // Each vertex: x, y (clip space), u, v (texture coords).
        // Y is flipped so the texture's row 0 lands at the TOP of the
        // viewport (HQ planes and S3TC blocks are stored top-to-bottom).
        let quad: [Float] = [
            -1, -1,   0, 1,  // bottom-left → uv (0, 1) bottom-row of tex
             1, -1,   1, 1,  // bottom-right → uv (1, 1)
            -1,  1,   0, 0,  // top-left → uv (0, 0) top-row of tex
             1,  1,   1, 0,  // top-right → uv (1, 0)
        ]
        glGenVertexArrays(1, &vao)
        glBindVertexArray(vao)
        glGenBuffers(1, &vbo)
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), vbo)
        quad.withUnsafeBufferPointer { buf in
            glBufferData(GLenum(GL_ARRAY_BUFFER),
                         quad.count * MemoryLayout<Float>.size,
                         buf.baseAddress, GLenum(GL_STATIC_DRAW))
        }
        let stride = GLsizei(4 * MemoryLayout<Float>.size)
        glEnableVertexAttribArray(0)
        glVertexAttribPointer(0, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride,
                              UnsafePointer(bitPattern: 0))
        glEnableVertexAttribArray(1)
        glVertexAttribPointer(1, 2, GLenum(GL_FLOAT), GLboolean(GL_FALSE), stride,
                              UnsafePointer(bitPattern: 2 * MemoryLayout<Float>.size))
        glBindVertexArray(0)
        glBindBuffer(GLenum(GL_ARRAY_BUFFER), 0)

        // ---------- DXT program (BC1 / BC3 decoded in the shader) ----------
        dxtProgram = compileProgram(vertex: vertexShaderSrc, fragment: dxtFragmentShaderSrc)
        if dxtProgram == 0 {
            print("Glance/dxvrender: DXT shader program creation FAILED")
            return
        }
        dxtUTextureLoc = glGetUniformLocation(dxtProgram, "uBlocks")
        dxtUFormatLoc = glGetUniformLocation(dxtProgram, "uFormat")
        dxtUTexSizeLoc = glGetUniformLocation(dxtProgram, "uTexSize")
        dxtUDisplaySizeLoc = glGetUniformLocation(dxtProgram, "uDisplaySize")
        dxtUUnpremultiplyLoc = glGetUniformLocation(dxtProgram, "uUnpremultiply")
        dxtUPremultiplyLoc = glGetUniformLocation(dxtProgram, "uPremultiply")
        dxtCropLoc = CropLocations(program: dxtProgram)
        dxtTexture = Self.makeBlockTexture()

        // ---------- RGBA program (CPU-decoded frames) ----------
        rgbaProgram = compileProgram(vertex: vertexShaderSrc, fragment: rgbaFragmentShaderSrc)
        if rgbaProgram == 0 {
            print("Glance/dxvrender: RGBA shader program creation FAILED")
            return
        }
        rgbaUTextureLoc = glGetUniformLocation(rgbaProgram, "uTexture")
        rgbaUPremultiplyLoc = glGetUniformLocation(rgbaProgram, "uPremultiply")
        rgbaCropLoc = CropLocations(program: rgbaProgram)
        glGenTextures(1, &rgbaTexture)
        glBindTexture(GLenum(GL_TEXTURE_2D), rgbaTexture)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_LINEAR)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        // ---------- HQ program ----------
        hqProgram = compileProgram(vertex: vertexShaderSrc, fragment: hqFragmentShaderSrc)
        if hqProgram == 0 {
            print("Glance/dxvrender: HQ shader program creation FAILED")
            return
        }
        hqULocLuma          = glGetUniformLocation(hqProgram, "uLuma")
        hqULocChroma        = glGetUniformLocation(hqProgram, "uChroma")
        hqULocHasAlpha      = glGetUniformLocation(hqProgram, "uHasAlpha")
        hqULocUnpremultiply = glGetUniformLocation(hqProgram, "uUnpremultiply")
        hqCropLoc           = CropLocations(program: hqProgram)
        hqULocTexSize       = glGetUniformLocation(hqProgram, "uTexSize")
        hqULocDisplaySize   = glGetUniformLocation(hqProgram, "uDisplaySize")

        // HQ block textures (integer, one texel per block, nearest).
        hqTextureLuma = Self.makeBlockTexture()
        hqTextureChroma = Self.makeBlockTexture()

        // ---------- Hap Q program [Slice 2 — additive] ----------
        // Reuses the shared vertex shader (the crop rule), new fragment
        // shader applies scaled-YCoCg → RGB to a single DXT5 sample.
        hapQProgram = compileProgram(vertex: vertexShaderSrc, fragment: hapQFragmentShaderSrc)
        if hapQProgram == 0 {
            print("Glance/dxvrender: Hap Q shader program creation FAILED")
            return
        }
        hapQULocTexture  = glGetUniformLocation(hapQProgram, "uTexture")
        hapQCropLoc      = CropLocations(program: hapQProgram)

        // Hap Q texture: a single DXT5 (S3TC) texture carrying scaled
        // YCoCg. GL_NEAREST so the per-block scale channel is point-
        // sampled (never interpolated across block edges) — see the
        // section comment above for why this differs from the DXT path.
        glGenTextures(1, &hapQTexture)
        glBindTexture(GLenum(GL_TEXTURE_2D), hapQTexture)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_NEAREST)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_NEAREST)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        // ---------- HapM program [Slice 3 — additive, two-texture] ----------
        // Reuses the shared vertex shader. New fragment shader samples the
        // color DXT5 (scaled-YCoCg → RGB) AND the BC4 alpha texture, and
        // outputs premultiplied (rgb*a, a).
        hapMProgram = compileProgram(vertex: vertexShaderSrc, fragment: hapMFragmentShaderSrc)
        if hapMProgram == 0 {
            print("Glance/dxvrender: HapM shader program creation FAILED")
            return
        }
        hapMULocColor    = glGetUniformLocation(hapMProgram, "uTextureColor")
        hapMULocAlpha    = glGetUniformLocation(hapMProgram, "uTextureAlpha")
        hapMCropLoc      = CropLocations(program: hapMProgram)

        // HapM color (DXT5 S3TC) + alpha (BC4 RGTC1) textures. Both
        // GL_NEAREST: color scale channel must not interpolate across
        // block edges; alpha point-sampled to match the CPU reference.
        var hapMTexes: [GLuint] = [0, 0]
        glGenTextures(2, &hapMTexes)
        hapMColorTexture = hapMTexes[0]
        hapMAlphaTexture = hapMTexes[1]
        for tex in hapMTexes {
            glBindTexture(GLenum(GL_TEXTURE_2D), tex)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_NEAREST)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_NEAREST)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        // ---------- Background program (checkerboard pass) ----------
        // Reuses the shared VAO/VBO. The vertex shader is minimal —
        // position-only, no uv — and the fragment shader paints a
        // viewport-aligned 2-colour checker via gl_FragCoord. Compiles
        // unconditionally; only invoked when backgroundMode == .checkerboard.
        bgProgram = compileProgram(vertex: bgVertexShaderSrc, fragment: bgFragmentShaderSrc)
        if bgProgram == 0 {
            print("Glance/dxvrender: background shader program creation FAILED")
            return
        }
        bgULocLight  = glGetUniformLocation(bgProgram, "uLight")
        bgULocDark   = glGetUniformLocation(bgProgram, "uDark")
        bgULocCellPx = glGetUniformLocation(bgProgram, "uCellPx")

        glReady = true
        print("Glance/dxvrender: GL objects ready (dxtProgram=\(dxtProgram), hqProgram=\(hqProgram), hapQProgram=\(hapQProgram), hapMProgram=\(hapMProgram), bgProgram=\(bgProgram), vao=\(vao), vbo=\(vbo), dxtTex=\(dxtTexture), rgbaProgram=\(rgbaProgram), hqTex=luma\(hqTextureLuma)/chroma\(hqTextureChroma), hapQTex=\(hapQTexture), hapMTex=color\(hapMColorTexture)/alpha\(hapMAlphaTexture))")
    }

    // MARK: - Public API: DXT path

    /// Upload a frame's BC1 (DXT1) / BC3 (DXT5) blocks. Call from a context
    /// where GL is current.
    ///
    /// `width` / `height` are **display** dimensions. `dxtBytes` holds whole
    /// 4 x 4 blocks over the 16-pixel-padded width (`(width + 15) / 16 * 16`)
    /// and at least `ceil(height / 4)` block rows — what `DXVPlayer` /
    /// GlanceCore's `DXVFrameDecoder` and `HAPDXTRepad` produce. The blocks
    /// go up unchanged and the shader decodes them; the crop to the display
    /// size is the shared `TextureCrop` rule.
    ///
    /// `straightAlpha` is caller-driven: pass `true` ONLY for HAP Hap5 (DXT5
    /// straight-alpha) frames so the shader premultiplies post-decode. DXV
    /// dxt5 is premultiplied by authoring convention and MUST pass `false`
    /// (the default). No-op for opaque DXT1 (alpha = 1).
    @discardableResult
    public func uploadFrame(dxtBytes: Data, variant: Variant,
                            width: Int, height: Int,
                            straightAlpha: Bool = false) -> Bool {
        precondition(!variant.isHQ, "uploadFrame is for DXT only; use uploadHQFrame for HQ variants")
        ensureGLObjects()
        guard glReady, width > 0, height > 0 else { return false }
        let blockBytes = variant == .dxt1 ? 8 : 16
        let blocksX = (width + 15) / 16 * 4
        let blocksY = dxtBytes.count / (blocksX * blockBytes)
        guard blocksY >= (height + 3) / 4 else {
            print("Glance/dxvrender: DXT upload too short (\(dxtBytes.count) B for \(width)x\(height) \(variant))")
            return false
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), dxtTexture)
        guard Self.uploadBlocks(dxtBytes, grid: BlockGrid(blocksX: blocksX, blocksY: blocksY, blockBytes: blockBytes),
                                last: &dxtLastBlocks) else { return false }
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        lastUploadIsHapQ = false   // [Slice 2] this is a plain DXT upload
        lastUploadIsHapM = false   // [Slice 3]
        lastUploadIsRGBA = false
        lastUploadIsHap5Straight = straightAlpha   // HAP Hap5 straight-alpha → premultiply in-shader
        lastUploadVariant = variant
        lastUploadWidth = width                    // public: display
        lastUploadHeight = height
        dxtTexSize = (blocksX * 4, blocksY * 4)    // internal: padded
        dxtCrop = TextureCrop(displayWidth: width, displayHeight: height,
                              textureWidth: dxtTexSize.w, textureHeight: dxtTexSize.h)
        hasUpload = true
        return true
    }

    // MARK: - Public API: RGBA path (CPU-decoded frames, e.g. HAP HapA)

    /// Upload a CPU-decoded RGBA8 frame (display size, tightly packed rows)
    /// and draw it with the DXT program. `straightAlpha` = true premultiplies
    /// in the shader (e.g. HapA: white + straight alpha), so it composites
    /// like every other path under both background modes.
    @discardableResult
    public func uploadRGBAFrame(_ rgba: [UInt8], width: Int, height: Int, straightAlpha: Bool) -> Bool {
        ensureGLObjects()
        guard glReady, width > 0, height > 0, rgba.count >= width * height * 4 else { return false }
        glBindTexture(GLenum(GL_TEXTURE_2D), rgbaTexture)
        glPixelStorei(GLenum(GL_UNPACK_ALIGNMENT), 1)
        rgba.withUnsafeBufferPointer { buf in
            glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA, GLsizei(width), GLsizei(height), 0,
                         GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), buf.baseAddress)
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        lastUploadIsHapQ = false
        lastUploadIsHapM = false
        lastUploadIsRGBA = true
        lastUploadIsHap5Straight = straightAlpha
        lastUploadVariant = .dxt5          // any non-HQ variant keeps the public display-dim API valid
        lastUploadWidth = width
        lastUploadHeight = height
        rgbaCrop = TextureCrop(displayWidth: width, displayHeight: height, textureWidth: width, textureHeight: height)
        hasUpload = true
        return true
    }

    // MARK: - Public API: HQ path

    /// Upload an HQ frame's DXVKit block streams: luma = BC4 Y (YCG6) or
    /// BC5 Y + A (YG10) at the coded size, chroma = BC5 Co + Cg at coded / 2.
    /// The blocks go up unchanged; the shader decodes them and turns YCoCg
    /// into RGB in Resolume Arena's convention exactly as DXVKit does. Both
    /// cover the 16 x 16 padded coded texture and are cropped to the display
    /// size by the shared `TextureCrop` rule. Call with a current GL context.
    ///
    /// Frames built from 8-bit planes (`DXVHQFrame.init(y:co:cg:a:...)`)
    /// carry no block streams and are refused (returns false).
    @discardableResult
    public func uploadHQFrame(_ frame: HQFrameData, variant: Variant) -> Bool {
        precondition(variant.isHQ, "uploadHQFrame is for HQ variants only; use uploadFrame for DXT")
        ensureGLObjects()
        guard glReady else { return false }
        guard let luma = frame.lumaBlocks, let chroma = frame.chromaBlocks else {
            print("Glance/dxvrender: HQ frame has no block streams (plane-only DXVHQFrame) — not drawable")
            return false
        }
        let hasAlpha = variant == .yg10
        let lumaGrid = BlockGrid(blocksX: frame.codedWidth / 4, blocksY: frame.codedHeight / 4, blockBytes: hasAlpha ? 16 : 8)
        let chromaGrid = BlockGrid(blocksX: frame.chromaWidth / 4, blocksY: frame.chromaHeight / 4, blockBytes: 16)
        guard frame.hasAlpha == hasAlpha, luma.count == lumaGrid.byteCount, chroma.count == chromaGrid.byteCount else {
            print("Glance/dxvrender: HQ block streams inconsistent (\(variant), coded \(frame.codedWidth)x\(frame.codedHeight), luma \(luma.count)/\(lumaGrid.byteCount), chroma \(chroma.count)/\(chromaGrid.byteCount))")
            return false
        }
        lastUploadIsHapQ = false   // [Slice 2] this is a DXV3 HQ upload
        lastUploadIsHapM = false   // [Slice 3]
        lastUploadIsRGBA = false
        lastUploadIsHap5Straight = false   // HQ is its own premult-aware path

        glBindTexture(GLenum(GL_TEXTURE_2D), hqTextureLuma)
        guard Self.uploadBlocks(luma, grid: lumaGrid, last: &hqLastLumaBlocks) else { return false }
        glBindTexture(GLenum(GL_TEXTURE_2D), hqTextureChroma)
        guard Self.uploadBlocks(chroma, grid: chromaGrid, last: &hqLastChromaBlocks) else { return false }
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        hqHasUpload = true

        // Public-facing dimensions are DISPLAY — VideoLayer's aspect-fit
        // math reads these and must never see padding.
        lastUploadVariant = variant
        lastUploadWidth = frame.width
        lastUploadHeight = frame.height
        hqTexSize = (frame.codedWidth, frame.codedHeight)
        hqCrop = TextureCrop(displayWidth: frame.width, displayHeight: frame.height,
                             textureWidth: frame.codedWidth, textureHeight: frame.codedHeight)
        hasUpload = true
        return true
    }

    // MARK: - Public API: Hap Q path [Slice 2 — additive]

    /// Upload a Hap Q (HapY) frame's DXT5 scaled-YCoCg blocks as a
    /// compressed DXT5 texture, then flag the renderer to use the Hap Q
    /// shader at draw time. Call from a context where GL is current.
    ///
    /// `dxt5Bytes` is the raw DXT5 block payload (after the HAP section
    /// header + Snappy/chunked reassembly), re-padded by the caller to
    /// the renderer's 16-pixel block-row stride — exactly the same
    /// `HAPDXTRepad` layout the Slice-1 Hap5 path uses. `width`/`height`
    /// are display dimensions; the renderer pads width to 16-pixel block
    /// alignment for storage and crops it back via per-frame UV scaling
    /// at draw time (same contract as `uploadFrame`).
    ///
    /// The DXT5 blocks are uploaded verbatim (reusing `uploadCompressed`,
    /// internal format `GL_COMPRESSED_RGBA_S3TC_DXT5_EXT`) — the GPU
    /// decompresses to RGBA at sample time, and the Hap Q fragment shader
    /// reinterprets R=Co, G=Cg, B=per-block scale, A=Y. The scale falls
    /// out of the texture sample per-fragment; it is NOT a global uniform.
    @discardableResult
    public func uploadHapQFrame(dxt5Bytes: Data, width: Int, height: Int) -> Bool {
        ensureGLObjects()
        guard glReady else { return false }

        let paddedW = (width + 15) / 16 * 16
        let needsRealloc = !hapQHasUpload
            || hapQLastPaddedWidth != paddedW
            || hapQLastHeight != height

        glBindTexture(GLenum(GL_TEXTURE_2D), hapQTexture)
        guard uploadCompressed(dxtBytes: dxt5Bytes, variant: .dxt5,
                               width: paddedW, height: height,
                               realloc: needsRealloc) else {
            // S3TC unavailable or a malformed payload. Hap Q has no GPU
            // fallback — the caller decides what to do. Surface
            // the failure rather than render garbage.
            print("Glance/dxvrender: Hap Q DXT5 upload failed")
            return false
        }

        hapQLastPaddedWidth = paddedW
        hapQLastHeight = height
        hapQHasUpload = true

        hapQCrop = TextureCrop(displayWidth: width, displayHeight: height,
                               textureWidth: paddedW, textureHeight: height)

        // Route render() to the Hap Q program. lastUploadVariant is left
        // at .dxt5 so the public display-dimension API stays consistent;
        // the isHapQ flag overrides the render path.
        lastUploadIsHapQ = true
        lastUploadIsHapM = false   // [Slice 3]
        lastUploadIsRGBA = false
        lastUploadIsHap5Straight = false   // Hap Q has its own (opaque) shader path
        lastUploadVariant = .dxt5
        lastUploadWidth = width
        lastUploadHeight = height
        hasUpload = true
        return true
    }

    // MARK: - Public API: HapM path [Slice 3 — additive]

    /// Upload a HapM frame's two planes — scaled-YCoCg color (DXT5) and
    /// BC4/RGTC1 alpha — as two compressed textures, then flag the
    /// renderer to use the HapM two-texture composite shader at draw time.
    /// Call from a context where GL is current.
    ///
    /// `colorDXT5` is the raw HapY DXT5 block payload, re-padded by the
    /// caller to the renderer's 16-pixel block-row stride (blockBytes:16).
    /// `alphaBC4` is the raw HapA BC4 block payload, re-padded to the SAME
    /// 16-pixel width stride but at **blockBytes:8** (BC4 = 8 B/block, vs
    /// DXT5's 16 — the silent-corruption trap). Both planes share the same
    /// display dimensions; width is padded to 16-px block alignment for
    /// storage and cropped back via per-frame UV scaling at draw time.
    @discardableResult
    public func uploadHapMFrame(colorDXT5: Data, alphaBC4: Data,
                                width: Int, height: Int) -> Bool {
        ensureGLObjects()
        guard glReady else { return false }

        let paddedW = (width + 15) / 16 * 16
        let needsRealloc = !hapMHasUpload
            || hapMLastPaddedWidth != paddedW
            || hapMLastHeight != height

        // Color plane → DXT5 (S3TC) into hapMColorTexture.
        glBindTexture(GLenum(GL_TEXTURE_2D), hapMColorTexture)
        guard uploadCompressed(dxtBytes: colorDXT5, variant: .dxt5,
                               width: paddedW, height: height,
                               realloc: needsRealloc) else {
            print("Glance/dxvrender: HapM color (DXT5) upload failed")
            return false
        }

        // Alpha plane → BC4 / RGTC1 into hapMAlphaTexture.
        glBindTexture(GLenum(GL_TEXTURE_2D), hapMAlphaTexture)
        guard uploadCompressedFormat(dxtBytes: alphaBC4,
                                     internalFormat: Self.GL_COMPRESSED_RED_RGTC1,
                                     width: paddedW, height: height,
                                     realloc: needsRealloc) else {
            print("Glance/dxvrender: HapM alpha (BC4) upload failed")
            return false
        }

        hapMLastPaddedWidth = paddedW
        hapMLastHeight = height
        hapMHasUpload = true
        hapMCrop = TextureCrop(displayWidth: width, displayHeight: height,
                               textureWidth: paddedW, textureHeight: height)

        lastUploadIsHapM = true
        lastUploadIsHapQ = false
        lastUploadIsRGBA = false
        lastUploadIsHap5Straight = false   // HapM premultiplies in its own (renderHapM) shader
        lastUploadVariant = .dxt5   // keeps the public display-dim API valid
        lastUploadWidth = width
        lastUploadHeight = height
        hasUpload = true
        return true
    }

    // MARK: - Public API: render

    /// Render the most-recently-uploaded frame into the currently-bound
    /// framebuffer. Caller is responsible for the FBO binding,
    /// glViewport, and any pre-clear.
    public func render() {
        guard glReady, hasUpload, let variant = lastUploadVariant else { return }

        glBindVertexArray(vao)

        switch backgroundMode {
        case .black:
            // Byte-identical to pre-feature behaviour: no checker pass,
            // blend disabled, video drawn straight onto whatever the
            // caller cleared the viewport to.
            glDisable(GLenum(GL_BLEND))
        case .checkerboard:
            // 1. Paint checker into the renderer's viewport.
            // 2. Enable premultiplied-alpha blending so transparent
            //    pixels of DXT5 / YG10 reveal the checker. Opaque
            //    variants (DXT1 / YCG6) ship alpha=1 every fragment
            //    so the blend is a no-op for them — output stays
            //    byte-identical to .black mode for those variants.
            renderCheckerboard()
            glEnable(GLenum(GL_BLEND))
            glBlendFunc(GLenum(GL_ONE), GLenum(GL_ONE_MINUS_SRC_ALPHA))
        }

        if lastUploadIsHapM {
            // [Slice 3] HapM: two-texture composite (color DXT5 + BC4
            // alpha). Output is premultiplied (rgb*a, a), so under
            // .checkerboard the premultiplied blend reveals the checker in
            // transparent regions, and under .black (blend off) transparent
            // writes black — identical compositing to DXT5/YG10.
            renderHapM()
        } else if lastUploadIsHapQ {
            // [Slice 2] Hap Q: one DXT5 texture + scaled-YCoCg shader.
            // HapY is opaque (alpha=1 every fragment), so under
            // .checkerboard the premultiplied blend is a no-op and the
            // output stays byte-identical to .black — same as DXT1/YCG6.
            renderHapQ()
        } else if lastUploadIsRGBA {
            renderRGBA()
        } else if variant.isHQ {
            renderHQ(variant: variant)
        } else {
            renderDXT()
        }

        // Restore the renderer's exit-state contract: BLEND off.
        glDisable(GLenum(GL_BLEND))
        glBindVertexArray(0)
    }

    private func renderCheckerboard() {
        glUseProgram(bgProgram)
        let cellPx = Float(Self.checkerboardCellPoints * max(1.0, contentsScale))
        glUniform3f(bgULocLight, 0.85, 0.85, 0.85)
        glUniform3f(bgULocDark,  0.65, 0.65, 0.65)
        glUniform1f(bgULocCellPx, cellPx)
        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
    }

    private func renderDXT() {
        glUseProgram(dxtProgram)
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), dxtTexture)
        glUniform1i(dxtUTextureLoc, 0)
        glUniform1i(dxtUFormatLoc, lastUploadVariant == .dxt1 ? 1 : 3)
        glUniform2f(dxtUTexSizeLoc, Float(dxtTexSize.w), Float(dxtTexSize.h))
        glUniform2i(dxtUDisplaySizeLoc, GLint(lastUploadWidth), GLint(lastUploadHeight))
        glUniform1i(dxtUUnpremultiplyLoc, unpremultiplyAlpha ? 1 : 0)
        glUniform1i(dxtUPremultiplyLoc, lastUploadIsHap5Straight ? 1 : 0)
        dxtCropLoc.set(dxtCrop)
        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
    }

    private func renderRGBA() {
        glUseProgram(rgbaProgram)
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), rgbaTexture)
        glUniform1i(rgbaUTextureLoc, 0)
        glUniform1i(rgbaUPremultiplyLoc, lastUploadIsHap5Straight ? 1 : 0)
        rgbaCropLoc.set(rgbaCrop)
        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
    }

    private func renderHapM() {
        glUseProgram(hapMProgram)
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), hapMColorTexture)
        glUniform1i(hapMULocColor, 0)
        glActiveTexture(GLenum(GL_TEXTURE1))
        glBindTexture(GLenum(GL_TEXTURE_2D), hapMAlphaTexture)
        glUniform1i(hapMULocAlpha, 1)
        hapMCropLoc.set(hapMCrop)
        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
    }

    private func renderHapQ() {
        glUseProgram(hapQProgram)
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), hapQTexture)
        glUniform1i(hapQULocTexture, 0)
        hapQCropLoc.set(hapQCrop)
        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
    }

    private func renderHQ(variant: Variant) {
        glUseProgram(hqProgram)

        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), hqTextureLuma)
        glUniform1i(hqULocLuma, 0)

        glActiveTexture(GLenum(GL_TEXTURE1))
        glBindTexture(GLenum(GL_TEXTURE_2D), hqTextureChroma)
        glUniform1i(hqULocChroma, 1)

        glUniform1i(hqULocHasAlpha, variant == .yg10 ? 1 : 0)
        glUniform1i(hqULocUnpremultiply, unpremultiplyAlpha ? 1 : 0)
        glUniform2f(hqULocTexSize, Float(hqTexSize.w), Float(hqTexSize.h))
        glUniform2i(hqULocDisplaySize, GLint(lastUploadWidth), GLint(lastUploadHeight))
        hqCropLoc.set(hqCrop)

        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
        glActiveTexture(GLenum(GL_TEXTURE0))
    }

    // MARK: - Private upload helpers (block textures)

    /// An integer texture holding raw BC blocks, one texel per 4 x 4 block
    /// (8-byte blocks: GL_RG32UI, 16-byte blocks: GL_RGBA32UI). Integer
    /// textures are not filterable: nearest, read with texelFetch.
    private static func makeBlockTexture() -> GLuint {
        var tex: GLuint = 0
        glGenTextures(1, &tex)
        glBindTexture(GLenum(GL_TEXTURE_2D), tex)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), GL_NEAREST)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), GL_NEAREST)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
        glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)
        return tex
    }

    /// Uploads `bytes` (whole blocks, row-major) into the bound block
    /// texture: TexImage when the grid changed, TexSubImage otherwise.
    private static func uploadBlocks(_ bytes: Data, grid: BlockGrid, last: inout BlockGrid) -> Bool {
        guard grid.blocksX > 0, grid.blocksY > 0, bytes.count >= grid.byteCount else { return false }
        let wide = grid.blockBytes == 16
        let internalFormat = wide ? GL_RGBA32UI : GL_RG32UI
        let format = GLenum(wide ? GL_RGBA_INTEGER : GL_RG_INTEGER)
        while glGetError() != GLenum(GL_NO_ERROR) {}
        glPixelStorei(GLenum(GL_UNPACK_ALIGNMENT), 4)
        bytes.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            if grid != last {
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, internalFormat, GLsizei(grid.blocksX), GLsizei(grid.blocksY), 0,
                             format, GLenum(GL_UNSIGNED_INT), base)
            } else {
                glTexSubImage2D(GLenum(GL_TEXTURE_2D), 0, 0, 0, GLsizei(grid.blocksX), GLsizei(grid.blocksY),
                                format, GLenum(GL_UNSIGNED_INT), base)
            }
        }
        let err = glGetError()
        if err != GLenum(GL_NO_ERROR) {
            print(String(format: "Glance/dxvrender: block upload failed (GL error 0x%X)", err))
            last = BlockGrid()
            return false
        }
        last = grid
        return true
    }

    // MARK: - Private upload helpers (compressed, Hap Q / HapM)

    /// Compressed S3TC upload (Hap Q / HapM colour). Returns true if the
    /// upload succeeded with no GL error.
    private func uploadCompressed(dxtBytes: Data, variant: Variant,
                                  width: Int, height: Int,
                                  realloc: Bool) -> Bool {
        let internalFormat: GLenum
        switch variant {
        case .dxt1: internalFormat = Self.GL_COMPRESSED_RGB_S3TC_DXT1_EXT
        case .dxt5: internalFormat = Self.GL_COMPRESSED_RGBA_S3TC_DXT5_EXT
        default:    return false
        }
        // Drain any pre-existing error so we don't blame the previous
        // operation on this upload.
        while glGetError() != GLenum(GL_NO_ERROR) {}

        dxtBytes.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            if realloc {
                glCompressedTexImage2D(
                    GLenum(GL_TEXTURE_2D), 0, internalFormat,
                    GLsizei(width), GLsizei(height), 0,
                    GLsizei(dxtBytes.count), base)
            } else {
                glCompressedTexSubImage2D(
                    GLenum(GL_TEXTURE_2D), 0, 0, 0,
                    GLsizei(width), GLsizei(height), internalFormat,
                    GLsizei(dxtBytes.count), base)
            }
        }
        let err = glGetError()
        if err != GLenum(GL_NO_ERROR) {
            print(String(format: "Glance/dxvrender: compressed upload failed (GL error 0x%X)", err))
            return false
        }
        return true
    }

    /// [Slice 3] Format-explicit compressed upload. Same shape as
    /// `uploadCompressed` (which switches on Variant for the S3TC formats)
    /// but takes the GL internal format directly, so the HapM alpha plane
    /// can upload BC4 / `GL_COMPRESSED_RED_RGTC1` without adding a Variant
    /// case. The existing `uploadCompressed` is left byte-identical.
    /// Operates on the currently-bound texture (caller binds).
    private func uploadCompressedFormat(dxtBytes: Data, internalFormat: GLenum,
                                        width: Int, height: Int,
                                        realloc: Bool) -> Bool {
        while glGetError() != GLenum(GL_NO_ERROR) {}
        dxtBytes.withUnsafeBytes { buf in
            guard let base = buf.baseAddress else { return }
            if realloc {
                glCompressedTexImage2D(
                    GLenum(GL_TEXTURE_2D), 0, internalFormat,
                    GLsizei(width), GLsizei(height), 0,
                    GLsizei(dxtBytes.count), base)
            } else {
                glCompressedTexSubImage2D(
                    GLenum(GL_TEXTURE_2D), 0, 0, 0,
                    GLsizei(width), GLsizei(height), internalFormat,
                    GLsizei(dxtBytes.count), base)
            }
        }
        let err = glGetError()
        if err != GLenum(GL_NO_ERROR) {
            print(String(format: "Glance/dxvrender: format-compressed upload failed (GL error 0x%X)", err))
            return false
        }
        return true
    }

    // MARK: - Shader sources

    /// Vertex shader shared by every textured program (DXT, HQ, Hap Q,
    /// HapM, RGBA): the quad's UV runs over the display region of the
    /// (possibly padded) texture — `uUvScale` = display / texture size on
    /// both axes. Half of the crop rule; `cropFragmentSrc` is the other half.
    private let vertexShaderSrc = """
    #version 330 core
    layout(location = 0) in vec2 aPos;
    layout(location = 1) in vec2 aTex;
    uniform vec2 uUvScale;
    out vec2 vTex;
    void main() {
        vTex = aTex * uUvScale;
        gl_Position = vec4(aPos, 0.0, 1.0);
    }
    """

    /// Fragment half of the crop rule, spliced into every textured fragment
    /// shader: the sample point is clamped to the centres of the display
    /// texels (`uUvClamp` = min.xy, max.zw). At 1:1 it is a no-op — every
    /// fragment already sits on its own texel centre, so nothing is
    /// resampled; scaled, linear filtering can never reach the padding.
    private static let cropFragmentSrc = """
    uniform vec4 uUvClamp;
    vec2 cropUV(vec2 t) { return clamp(t, uUvClamp.xy, uUvClamp.zw); }
    """

    /// DXVKit's BC block decode, in the shader (GLSL 3.30, integer ops).
    /// Blocks are raw little-endian words from an integer texture (8-byte
    /// block: .xy, 16-byte block: .xyzw); texel i = row * 4 + column inside
    /// the block. Palettes are DXVKit's (src/pixels.c): BC1 thirds / halves
    /// truncated, 5:6:5 endpoints widened by bit replication; BC4 sevenths /
    /// fifths truncated to 8 bits (`bc4Pal8`, the DXT5 alpha) or exact in
    /// 1/35 units (`bc4Pal35`, the HQ planes).
    private static let blockDecodeSrc = """
    uvec3 expand565(uint c) {
        uint r = c >> 11, g = (c >> 5) & 63u, b = c & 31u;
        return uvec3((r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2));
    }
    uvec3 bc1Colour(uvec2 b, uint i, bool fourColour) {
        uint c0 = b.x & 0xFFFFu, c1 = b.x >> 16;
        uvec3 p0 = expand565(c0), p1 = expand565(c1);
        uint idx = (b.y >> (2u * i)) & 3u;
        if (idx == 0u) return p0;
        if (idx == 1u) return p1;
        if (fourColour || c0 > c1) return idx == 2u ? (2u * p0 + p1) / 3u : (p0 + 2u * p1) / 3u;
        return idx == 2u ? (p0 + p1) / 2u : uvec3(0u);
    }
    uint bc4Index(uvec2 b, uint i) {
        uint pos = 16u + 3u * i;
        if (pos >= 32u) return (b.y >> (pos - 32u)) & 7u;
        if (pos <= 29u) return (b.x >> pos) & 7u;
        return ((b.x >> pos) | (b.y << (32u - pos))) & 7u;
    }
    uint bc4Pal35(uvec2 b, uint i) {
        uint a0 = b.x & 255u, a1 = (b.x >> 8) & 255u, idx = bc4Index(b, i);
        if (idx == 0u) return a0 * 35u;
        if (idx == 1u) return a1 * 35u;
        uint k = idx - 1u;
        if (a0 > a1) return ((7u - k) * a0 + k * a1) * 5u;
        if (idx <= 5u) return ((5u - k) * a0 + k * a1) * 7u;
        return idx == 6u ? 0u : 255u * 35u;
    }
    uint bc4Pal8(uvec2 b, uint i) {
        uint a0 = b.x & 255u, a1 = (b.x >> 8) & 255u, idx = bc4Index(b, i);
        if (idx == 0u) return a0;
        if (idx == 1u) return a1;
        uint k = idx - 1u;
        if (a0 > a1) return ((7u - k) * a0 + k * a1) / 7u;
        if (idx <= 5u) return ((5u - k) * a0 + k * a1) / 5u;
        return idx == 6u ? 0u : 255u;
    }
    uint blockTexel(ivec2 p) { return uint((p.y & 3) * 4 + (p.x & 3)); }
    // Bilinear sample position in texels (texel centres at whole numbers),
    // snapped to 1/256 texel like the hardware's 8-bit filter weights: at
    // 1:1 it lands exactly on a whole texel (weight 0, no float drift).
    vec2 samplePoint(vec2 uv, vec2 texSize) { return floor((uv * texSize - 0.5) * 256.0 + 0.5) / 256.0; }
    """

    /// DXT fragment shader (BC1 / BC3, plus legacy and HAP Hap1 / Hap5):
    /// decodes the four display texels around the sample point from the
    /// raw blocks and blends them bilinearly (GL_LINEAR's formula), so at
    /// 1:1 each fragment is exactly its own decoded texel. Optionally
    /// un-premultiplies, or premultiplies straight-alpha Hap5.
    private let dxtFragmentShaderSrc = """
    #version 330 core
    in vec2 vTex;
    out vec4 fragColor;
    uniform usampler2D uBlocks;
    uniform int uFormat;          // 1 = BC1 (DXT1), 3 = BC3 (DXT5)
    uniform vec2 uTexSize;        // padded texture size, pixels
    uniform ivec2 uDisplaySize;
    uniform int uUnpremultiply;
    uniform int uPremultiply;
    \(DXVRenderer.cropFragmentSrc)
    \(DXVRenderer.blockDecodeSrc)
    vec4 texel(ivec2 p) {
        uvec4 w = texelFetch(uBlocks, p >> 2, 0);
        uint i = blockTexel(p);
        if (uFormat == 1) return vec4(vec3(bc1Colour(w.xy, i, false)), 255.0);
        return vec4(vec3(bc1Colour(w.zw, i, true)), float(bc4Pal8(w.xy, i)));
    }
    void main() {
        vec2 p = samplePoint(cropUV(vTex), uTexSize);
        vec2 f = p - floor(p);
        ivec2 a = clamp(ivec2(floor(p)), ivec2(0), uDisplaySize - 1);
        ivec2 b = clamp(ivec2(floor(p)) + 1, ivec2(0), uDisplaySize - 1);
        vec4 c = mix(mix(texel(a), texel(ivec2(b.x, a.y)), f.x),
                     mix(texel(ivec2(a.x, b.y)), texel(b), f.x), f.y) / 255.0;
        if (uUnpremultiply == 1 && c.a > 0.0) {
            c.rgb /= c.a;
        }
        // Straight-alpha (HAP Hap5) → premultiply so it composites identically
        // to premultiplied DXV dxt5/YG10. Gated by uPremultiply (caller-driven
        // via uploadFrame's straightAlpha); off for every DXV upload.
        if (uPremultiply == 1) {
            c.rgb *= c.a;
        }
        fragColor = c;
    }
    """

    /// RGBA fragment shader (CPU-decoded frames, e.g. HAP HapA): samples
    /// the display-size RGBA texture; premultiplies straight alpha.
    private let rgbaFragmentShaderSrc = """
    #version 330 core
    in vec2 vTex;
    out vec4 fragColor;
    uniform sampler2D uTexture;
    uniform int uPremultiply;
    \(DXVRenderer.cropFragmentSrc)
    void main() {
        vec4 c = texture(uTexture, cropUV(vTex));
        if (uPremultiply == 1) {
            c.rgb *= c.a;
        }
        fragColor = c;
    }
    """

    /// HQ fragment shader (YCG6 / YG10): DXVKit's HQ decode (src/pixels.c,
    /// `rows_hq` / `hq_rgb`) in the shader, in its 1/70 fixed point. Y and A
    /// come from the luma blocks (exact BC4 palette, 1/35 units, bilinear
    /// between the four display texels around the sample point when scaled,
    /// exact at 1:1); Co / Cg from the chroma block of the nearest pixel
    /// (pixel / 2, Arena's nearest chroma). Then Resolume Arena's convention:
    ///   co = 2 Co - 127.5, cg = 2 Cg - 127.5   (units 1/70: midpoint 8925)
    ///   R = Y - cg + co, G = Y + cg, B = Y - cg - co
    ///   fold: R < 0 -> B += R, R = 0; B < 0 -> R += B, B = 0;
    ///         R > max -> B += R - max, R = max; B > max -> R += B - max, B = max
    ///   round half up to 8 bits and clamp (`hq_round`).
    /// Alpha (YG10) is hq_round(2 A) and passes through (straight).
    private let hqFragmentShaderSrc = """
    #version 330 core
    in vec2 vTex;
    out vec4 fragColor;
    uniform usampler2D uLuma;     // BC4 Y (.xy) or BC5 Y (.xy) + A (.zw)
    uniform usampler2D uChroma;   // BC5 Co (.xy) + Cg (.zw)
    uniform int uHasAlpha;
    uniform int uUnpremultiply;
    uniform vec2 uTexSize;        // coded size, pixels
    uniform ivec2 uDisplaySize;
    \(DXVRenderer.cropFragmentSrc)
    \(DXVRenderer.blockDecodeSrc)
    const int ONE = 70, MAXV = 255 * 70, MID = 255 * 70 / 2;
    vec2 lumaTexel(ivec2 p) {   // (Y, A) in 1/35 units
        uvec4 w = texelFetch(uLuma, p >> 2, 0);
        uint i = blockTexel(p);
        return vec2(float(bc4Pal35(w.xy, i)), uHasAlpha == 1 ? float(bc4Pal35(w.zw, i)) : 255.0 * 35.0);
    }
    int hqRound(int v) { return v <= 0 ? 0 : v >= MAXV ? 255 : (v + ONE / 2) / ONE; }

    void main() {
        vec2 uv = cropUV(vTex);
        vec2 p = samplePoint(uv, uTexSize);
        vec2 f = p - floor(p);
        ivec2 a = clamp(ivec2(floor(p)), ivec2(0), uDisplaySize - 1);
        ivec2 b = clamp(ivec2(floor(p)) + 1, ivec2(0), uDisplaySize - 1);
        vec2 l = mix(mix(lumaTexel(a), lumaTexel(ivec2(b.x, a.y)), f.x),
                     mix(lumaTexel(ivec2(a.x, b.y)), lumaTexel(b), f.x), f.y);
        ivec2 q = clamp(ivec2(floor(uv * uTexSize)), ivec2(0), uDisplaySize - 1) >> 1;
        uvec4 cw = texelFetch(uChroma, q >> 2, 0);
        uint ci = blockTexel(q);
        int y  = int(floor(2.0 * l.x + 0.5));
        int co = 2 * int(bc4Pal35(cw.xy, ci)) - MID;
        int cg = 2 * int(bc4Pal35(cw.zw, ci)) - MID;
        int t = y - cg, r = t + co, g = y + cg, bl = t - co;
        if (r < 0)     { bl += r; r = 0; }
        if (bl < 0)    { r += bl; bl = 0; }
        if (r > MAXV)  { bl += r - MAXV; r = MAXV; }
        if (bl > MAXV) { r += bl - MAXV; bl = MAXV; }
        vec3 rgb = vec3(float(hqRound(r)), float(hqRound(g)), float(hqRound(bl))) / 255.0;

        float alpha = 1.0;
        if (uHasAlpha == 1) {
            alpha = float(hqRound(int(floor(2.0 * l.y + 0.5)))) / 255.0;
            if (uUnpremultiply == 1 && alpha > 0.0) {
                rgb /= alpha;
            }
        }
        fragColor = vec4(rgb, alpha);
    }
    """

    /// Hap Q fragment shader [Slice 2 — additive]. Samples ONE DXT5
    /// (S3TC) texture carrying scaled YCoCg and applies the inverse
    /// transform, ported DIRECTLY from `HAPHQDecoder.unpackHapYToRGB`.
    ///
    /// Channel reinterpretation of the DXT5 sample (Castaño & van
    /// Waveren, *Real-Time YCoCg-DXT Compression*, 2007 — the canonical
    /// HapQ encoding):
    ///   R (c.r) = Co + 0.5        (BC1 colour, 5-bit)
    ///   G (c.g) = Cg + 0.5        (BC1 colour, 6-bit)
    ///   B (c.b) = scale-encoding  (BC1 colour — CONSTANT per 4×4 block)
    ///   A (c.a) = Y               (BC4 alpha, full resolution)
    ///
    /// Inverse (matches the CPU reference byte-for-byte):
    ///   s  = 1 / ((255/8) * B + 1)        // per-fragment, from the sample
    ///   Co = (R - 0.5) * s
    ///   Cg = (G - 0.5) * s
    ///   R' = Y + Co - Cg
    ///   G' = Y + Cg
    ///   B' = Y - Co - Cg
    ///
    /// The scale `s` is recovered from the per-fragment B sample — it is
    /// NOT a global uniform. Because B is constant within a 4×4 block and
    /// the texture is GL_NEAREST point-sampled, every fragment recovers
    /// its block's exact scale, with no interpolation across block edges.
    ///
    /// Output is clamped to [0,1] then written; the framebuffer's
    /// float→unorm8 rounding mirrors the CPU's `round(clamp(v*255,0,255))`,
    /// so the GPU result matches `unpackHapYToRGB` within float-rounding
    /// (the only residual divergence vs the CPU path is the GPU's own
    /// S3TC block decode, the same ±1 565-endpoint class as every DXT
    /// variant). HapY has no alpha → opaque.
    private let hapQFragmentShaderSrc = """
    #version 330 core
    in vec2 vTex;
    out vec4 fragColor;
    uniform sampler2D uTexture;
    \(DXVRenderer.cropFragmentSrc)
    void main() {
        vec4 c = texture(uTexture, cropUV(vTex));
        // c.rgb = scaled-YCoCg colour (BC1), c.a = Y (BC4).
        float s  = 1.0 / ((255.0 / 8.0) * c.b + 1.0);
        float co = (c.r - 0.5) * s;
        float cg = (c.g - 0.5) * s;
        float y  = c.a;
        vec3 rgb = vec3(y + co - cg,   // R'
                        y + cg,        // G'
                        y - co - cg);  // B'
        fragColor = vec4(clamp(rgb, 0.0, 1.0), 1.0);
    }
    """

    /// HapM fragment shader [Slice 3 — additive, TWO textures]. Samples
    /// the color DXT5 (scaled-YCoCg, the EXACT Slice-2 Hap Q transform —
    /// identical math, verified clean by the isolation gate) AND a separate
    /// BC4/RGTC1 alpha texture (single-channel red), then composites them
    /// in one fragment.
    ///
    /// Output is PREMULTIPLIED `vec4(rgb*a, a)` so it composites identically
    /// to DXV3 DXT5/YG10 under both background modes: under `.black` (blend
    /// off) transparent fragments write `rgb*0 = 0` → black; under
    /// `.checkerboard` the premultiplied-alpha blend `(GL_ONE,
    /// GL_ONE_MINUS_SRC_ALPHA)` reveals the checker in transparent regions.
    /// No blend-state changes vs the existing pipeline.
    private let hapMFragmentShaderSrc = """
    #version 330 core
    in vec2 vTex;
    out vec4 fragColor;
    uniform sampler2D uTextureColor;   // DXT5 scaled-YCoCg (HapY)
    uniform sampler2D uTextureAlpha;   // BC4 / RGTC1 red = alpha (HapA)
    \(DXVRenderer.cropFragmentSrc)
    void main() {
        vec2 uv = cropUV(vTex);
        vec4 c = texture(uTextureColor, uv);
        // Same scaled-YCoCg → RGB as the Hap Q shader.
        float s  = 1.0 / ((255.0 / 8.0) * c.b + 1.0);
        float co = (c.r - 0.5) * s;
        float cg = (c.g - 0.5) * s;
        float y  = c.a;
        vec3 rgb = clamp(vec3(y + co - cg, y + cg, y - co - cg), 0.0, 1.0);
        // BC4 alpha plane: the decoded value is in the red channel.
        float a = texture(uTextureAlpha, uv).r;
        // Premultiplied output (matches DXT5/YG10 compositing).
        fragColor = vec4(rgb * a, a);
    }
    """

    /// Background-pass vertex shader. Position-only, no UV, no
    /// crop uniforms — keeps the program independent of the
    /// stride-fix uniforms the DXT / HQ programs need.
    private let bgVertexShaderSrc = """
    #version 330 core
    layout(location = 0) in vec2 aPos;
    void main() {
        gl_Position = vec4(aPos, 0.0, 1.0);
    }
    """

    /// Background-pass fragment shader. Paints a 2-colour checker
    /// keyed off `gl_FragCoord` (pixel-space), so cell size is exact
    /// regardless of the viewport's aspect or how it's mapped to clip
    /// space. `uCellPx` is the cell edge length in framebuffer pixels;
    /// the renderer computes it from `checkerboardCellPoints *
    /// contentsScale` so visually it stays 8 pt on every display.
    ///
    /// Colours are ported verbatim from Crate's `ThumbnailExtractor`
    /// composite: light gray 0.85, dark gray 0.65.
    private let bgFragmentShaderSrc = """
    #version 330 core
    out vec4 fragColor;
    uniform vec3 uLight;
    uniform vec3 uDark;
    uniform float uCellPx;
    void main() {
        vec2 cell = floor(gl_FragCoord.xy / uCellPx);
        float k = mod(cell.x + cell.y, 2.0);
        vec3 c = mix(uDark, uLight, k);
        fragColor = vec4(c, 1.0);
    }
    """

    private func compileProgram(vertex: String, fragment: String) -> GLuint {
        let vs = compileShader(source: vertex, type: GLenum(GL_VERTEX_SHADER))
        let fs = compileShader(source: fragment, type: GLenum(GL_FRAGMENT_SHADER))
        guard vs != 0, fs != 0 else { return 0 }
        let prog = glCreateProgram()
        glAttachShader(prog, vs)
        glAttachShader(prog, fs)
        glLinkProgram(prog)
        var linked: GLint = 0
        glGetProgramiv(prog, GLenum(GL_LINK_STATUS), &linked)
        if linked == GL_FALSE {
            var logLen: GLint = 0
            glGetProgramiv(prog, GLenum(GL_INFO_LOG_LENGTH), &logLen)
            if logLen > 0 {
                var log = [GLchar](repeating: 0, count: Int(logLen))
                glGetProgramInfoLog(prog, logLen, nil, &log)
                print("Glance/dxvrender: link error: \(String(cString: log))")
            }
            glDeleteProgram(prog)
            glDeleteShader(vs); glDeleteShader(fs)
            return 0
        }
        glDetachShader(prog, vs)
        glDetachShader(prog, fs)
        glDeleteShader(vs)
        glDeleteShader(fs)
        return prog
    }

    private func compileShader(source: String, type: GLenum) -> GLuint {
        let shader = glCreateShader(type)
        source.withCString { cstr in
            var ptr: UnsafePointer<GLchar>? = cstr
            glShaderSource(shader, 1, &ptr, nil)
        }
        glCompileShader(shader)
        var compiled: GLint = 0
        glGetShaderiv(shader, GLenum(GL_COMPILE_STATUS), &compiled)
        if compiled == GL_FALSE {
            var logLen: GLint = 0
            glGetShaderiv(shader, GLenum(GL_INFO_LOG_LENGTH), &logLen)
            if logLen > 0 {
                var log = [GLchar](repeating: 0, count: Int(logLen))
                glGetShaderInfoLog(shader, logLen, nil, &log)
                let typeName = (type == GLenum(GL_VERTEX_SHADER)) ? "vertex" : "fragment"
                print("Glance/dxvrender: \(typeName) shader compile error: \(String(cString: log))")
            }
            glDeleteShader(shader)
            return 0
        }
        return shader
    }
}
/// A texture of raw BC blocks: grid size and bytes per block.
struct BlockGrid: Equatable {
    var blocksX = 0
    var blocksY = 0
    var blockBytes = 0
    var byteCount: Int { blocksX * blocksY * blockBytes }
}

/// The one crop rule for every texture the renderer draws (DXT, HQ BC4/BC5,
/// Hap Q, HapM, RGBA): `scale` maps the quad's 0...1 UV onto the display
/// region of a texture that may be padded (to 16 in width, and for HQ in
/// height too); `clamp` keeps the sample point inside the display texels'
/// centres. At 1:1 each fragment samples exactly its own texel centre, on
/// both axes, with no shrink or resample.
struct TextureCrop {
    var scale: (Float, Float) = (1, 1)
    var clamp: (Float, Float, Float, Float) = (0, 0, 1, 1)

    init() {}

    init(displayWidth: Int, displayHeight: Int, textureWidth: Int, textureHeight: Int) {
        let tw = Float(max(1, textureWidth)), th = Float(max(1, textureHeight))
        let dw = Float(max(1, min(displayWidth, textureWidth)))
        let dh = Float(max(1, min(displayHeight, textureHeight)))
        scale = (dw / tw, dh / th)
        clamp = (0.5 / tw, 0.5 / th, (dw - 0.5) / tw, (dh - 0.5) / th)
    }
}

/// Uniform locations of the crop rule in one program.
struct CropLocations {
    var scale: GLint = -1
    var clamp: GLint = -1

    init() {}

    init(program: GLuint) {
        scale = glGetUniformLocation(program, "uUvScale")
        clamp = glGetUniformLocation(program, "uUvClamp")
    }

    /// Sets the crop on the program currently in use.
    func set(_ c: TextureCrop) {
        glUniform2f(scale, c.scale.0, c.scale.1)
        glUniform4f(clamp, c.clamp.0, c.clamp.1, c.clamp.2, c.clamp.3)
    }
}
#endif
