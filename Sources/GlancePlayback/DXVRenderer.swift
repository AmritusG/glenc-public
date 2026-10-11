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
/// Hap Q / HapM path (v0.17.2): HapY's BC3 scaled-YCoCg blocks (+ HapM's BC4
/// alpha) decoded in the shader the same way, then `HAPHQDecoder`'s inverse
/// in exact integers; equal to GlanceCore's CPU HAP decoder at 1:1.
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

    /// v0.18.0 — what the current DXV clip's colour is (Resolume Arena's
    /// per-clip "Alpha Type"; a DXV file does not say, DXVKit spec 8.5).
    /// Applies to DXV alpha uploads (DXT5 / legacy DXT5 through `uploadFrame`
    /// with `straightAlpha: false`, YG10 through `uploadHQFrame`):
    /// `.premultiplied` (default, Arena's) draws the texels as they are;
    /// `.straight` premultiplies them in the shader (rgb *= a) first, so
    /// both composite correctly over black and over the checkerboard. HAP is
    /// not affected (Hap5 / HapM are straight by their own path). Replaces
    /// the unused `unpremultiplyAlpha`.
    public var alphaType: AlphaType = .premultiplied

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

    // MARK: - GL objects: Hap Q / HapM path (blocks decoded in the shader)
    //
    // Hap Q (HapY) is one DXT5 texture of *scaled* YCoCg (R = Co, G = Cg,
    // B = per-block scale, A = Y); HapM adds a BC4 alpha plane. Since v0.17.2
    // both go up as integer block textures, like DXT and HQ, and one program
    // (`hapYFragmentShaderSrc`) decodes the BC3 colour and BC4 alpha blocks
    // and applies `HAPHQDecoder`'s scaled-YCoCg inverse in exact integers.
    // At 1:1 every fragment equals GlanceCore's CPU HAP decoder.
    private var hapYProgram: GLuint = 0
    /// BC3 scaled-YCoCg blocks (GL_RGBA32UI) and BC4 alpha blocks (GL_RG32UI).
    private var hapYColorTexture: GLuint = 0
    private var hapYAlphaTexture: GLuint = 0
    private var hapYULocColor: GLint = -1
    private var hapYULocAlpha: GLint = -1
    private var hapYULocHasAlpha: GLint = -1
    private var hapYULocTexSize: GLint = -1
    private var hapYULocDisplaySize: GLint = -1
    private var hapYCropLoc = CropLocations()
    private var hapYCrop = TextureCrop()
    private var hapYTexSize: (w: Int, h: Int) = (0, 0)
    private var hapYLastColorBlocks = BlockGrid()
    private var hapYLastAlphaBlocks = BlockGrid()

    /// Set by `uploadHapQFrame` / `uploadHapMFrame`, cleared by the other
    /// uploads. `render()` routes to `renderHapY()` when set.
    private var lastUploadIsHapY: Bool = false
    /// The last Hap Q / HapM upload carried an alpha plane (HapM).
    private var hapYHasAlpha: Bool = false

    /// Set true when the last DXT upload carried STRAIGHT (non-premultiplied)
    /// alpha — i.e. a HAP Hap5 (DXT5 RGBA) frame. Driven by the `straightAlpha`
    /// argument to `uploadFrame` (caller-driven), NOT inferred from the
    /// variant: DXV dxt5 is also `.dxt5`, and its convention is the clip's
    /// `alphaType` (v0.18.0), not HAP's. When true,
    /// `renderDXT()` sets the shader's `uPremultiply` so the straight texel is
    /// premultiplied (rgb*=a) post-sample, making it composite identically to
    /// premultiplied DXV dxt5/YG10 under both the `.black` (blend-off →
    /// transparent=black) and `.checkerboard` (premultiplied blend) paths.
    /// Every non-Hap5 upload (DXV dxt1/dxt5, HQ, HapQ, HapM) leaves it false,
    /// so those outputs are byte-identical to before.
    private var lastUploadIsHap5Straight: Bool = false

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
    private var hqULocPremultiply: GLint = -1
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
        hqULocPremultiply = glGetUniformLocation(hqProgram, "uPremultiply")
        hqCropLoc           = CropLocations(program: hqProgram)
        hqULocTexSize       = glGetUniformLocation(hqProgram, "uTexSize")
        hqULocDisplaySize   = glGetUniformLocation(hqProgram, "uDisplaySize")

        // HQ block textures (integer, one texel per block, nearest).
        hqTextureLuma = Self.makeBlockTexture()
        hqTextureChroma = Self.makeBlockTexture()

        // ---------- Hap Q / HapM program (blocks decoded in the shader) ----------
        hapYProgram = compileProgram(vertex: vertexShaderSrc, fragment: hapYFragmentShaderSrc)
        if hapYProgram == 0 {
            print("Glance/dxvrender: Hap Q / HapM shader program creation FAILED")
            return
        }
        hapYULocColor       = glGetUniformLocation(hapYProgram, "uBlocks")
        hapYULocAlpha       = glGetUniformLocation(hapYProgram, "uAlphaBlocks")
        hapYULocHasAlpha    = glGetUniformLocation(hapYProgram, "uHasAlpha")
        hapYULocTexSize     = glGetUniformLocation(hapYProgram, "uTexSize")
        hapYULocDisplaySize = glGetUniformLocation(hapYProgram, "uDisplaySize")
        hapYCropLoc         = CropLocations(program: hapYProgram)
        hapYColorTexture = Self.makeBlockTexture()
        hapYAlphaTexture = Self.makeBlockTexture()

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
        print("Glance/dxvrender: GL objects ready (dxtProgram=\(dxtProgram), hqProgram=\(hqProgram), hapYProgram=\(hapYProgram), bgProgram=\(bgProgram), vao=\(vao), vbo=\(vbo), dxtTex=\(dxtTexture), rgbaProgram=\(rgbaProgram), hqTex=luma\(hqTextureLuma)/chroma\(hqTextureChroma), hapYTex=color\(hapYColorTexture)/alpha\(hapYAlphaTexture))")
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
    /// dxt5 passes `false` (the default): its convention is `alphaType`.
    /// No-op for opaque DXT1 (alpha = 1).
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

        lastUploadIsHapY = false
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
        lastUploadIsHapY = false
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
        lastUploadIsHapY = false
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

    // MARK: - Public API: Hap Q / HapM path

    /// Upload a Hap Q (HapY) frame: its BC3 (DXT5) scaled-YCoCg blocks,
    /// re-padded by the caller to the 16-pixel block-column stride
    /// (`HAPDXTRepad`, 16-byte blocks), at least `ceil(height / 4)` block
    /// rows. The blocks go up unchanged as an integer texture and the shader
    /// decodes them (R = Co, G = Cg, B = per-block scale, A = Y) into RGB
    /// exactly as `HAPHQDecoder` does. `width` / `height` are display
    /// dimensions; the crop is the shared `TextureCrop` rule.
    @discardableResult
    public func uploadHapQFrame(dxt5Bytes: Data, width: Int, height: Int) -> Bool {
        uploadHapY(color: dxt5Bytes, alpha: nil, width: width, height: height)
    }

    /// Upload a HapM frame: the HapY colour blocks (as `uploadHapQFrame`) and
    /// the BC4 alpha blocks, re-padded to the same 16-pixel stride at 8 bytes
    /// per block. Straight colour, premultiplied for output (rgb * a, a).
    @discardableResult
    public func uploadHapMFrame(colorDXT5: Data, alphaBC4: Data,
                                width: Int, height: Int) -> Bool {
        uploadHapY(color: colorDXT5, alpha: alphaBC4, width: width, height: height)
    }

    private func uploadHapY(color: Data, alpha: Data?, width: Int, height: Int) -> Bool {
        ensureGLObjects()
        guard glReady, width > 0, height > 0 else { return false }
        let blocksX = (width + 15) / 16 * 4
        let rows = (height + 3) / 4
        let colorGrid = BlockGrid(blocksX: blocksX, blocksY: color.count / (blocksX * 16), blockBytes: 16)
        guard colorGrid.blocksY >= rows else {
            print("Glance/dxvrender: Hap Q colour upload too short (\(color.count) B for \(width)x\(height))")
            return false
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), hapYColorTexture)
        guard Self.uploadBlocks(color, grid: colorGrid, last: &hapYLastColorBlocks) else { return false }
        if let alpha {
            let alphaGrid = BlockGrid(blocksX: blocksX, blocksY: alpha.count / (blocksX * 8), blockBytes: 8)
            guard alphaGrid.blocksY >= rows else {
                print("Glance/dxvrender: HapM alpha upload too short (\(alpha.count) B for \(width)x\(height))")
                return false
            }
            glBindTexture(GLenum(GL_TEXTURE_2D), hapYAlphaTexture)
            guard Self.uploadBlocks(alpha, grid: alphaGrid, last: &hapYLastAlphaBlocks) else { return false }
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        lastUploadIsHapY = true
        hapYHasAlpha = alpha != nil
        lastUploadIsRGBA = false
        lastUploadIsHap5Straight = false   // Hap Q / HapM have their own shader
        lastUploadVariant = .dxt5          // keeps the public display-dim API valid
        lastUploadWidth = width
        lastUploadHeight = height
        hapYTexSize = (blocksX * 4, colorGrid.blocksY * 4)
        hapYCrop = TextureCrop(displayWidth: width, displayHeight: height,
                               textureWidth: hapYTexSize.w, textureHeight: hapYTexSize.h)
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

        if lastUploadIsHapY {
            // Hap Q is opaque (the blend is a no-op); HapM colour is STRAIGHT
            // (HAP alpha is straight) and the shader premultiplies it for output.
            renderHapY()
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
        // Hap5 (straight by format) or a DXV DXT5 clip set to Straight.
        let premultiply = lastUploadIsHap5Straight || (alphaType == .straight && lastUploadVariant == .dxt5)
        glUniform1i(dxtUPremultiplyLoc, premultiply ? 1 : 0)
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

    private func renderHapY() {
        glUseProgram(hapYProgram)
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), hapYColorTexture)
        glUniform1i(hapYULocColor, 0)
        glActiveTexture(GLenum(GL_TEXTURE1))
        // Hap Q has no alpha plane: keep a complete integer texture on the
        // unit anyway (the shader doesn't read it), never an empty one.
        glBindTexture(GLenum(GL_TEXTURE_2D), hapYHasAlpha ? hapYAlphaTexture : hapYColorTexture)
        glUniform1i(hapYULocAlpha, 1)
        glUniform1i(hapYULocHasAlpha, hapYHasAlpha ? 1 : 0)
        glUniform2f(hapYULocTexSize, Float(hapYTexSize.w), Float(hapYTexSize.h))
        glUniform2i(hapYULocDisplaySize, GLint(lastUploadWidth), GLint(lastUploadHeight))
        hapYCropLoc.set(hapYCrop)
        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
        glActiveTexture(GLenum(GL_TEXTURE0))
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
        glUniform1i(hqULocPremultiply, variant == .yg10 && alphaType == .straight ? 1 : 0)
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
    /// 1:1 each fragment is exactly its own decoded texel. Premultiplies
    /// straight colour (Hap5, or a DXV DXT5 clip whose Alpha Type is Straight).
    private let dxtFragmentShaderSrc = """
    #version 330 core
    in vec2 vTex;
    out vec4 fragColor;
    uniform usampler2D uBlocks;
    uniform int uFormat;          // 1 = BC1 (DXT1), 3 = BC3 (DXT5)
    uniform vec2 uTexSize;        // padded texture size, pixels
    uniform ivec2 uDisplaySize;
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
        // Straight colour (HAP Hap5, or DXV DXT5 with Alpha Type Straight) →
        // premultiply, so it composites like premultiplied DXV.
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
    /// Alpha (YG10) is hq_round(2 A); with Alpha Type Straight the colour is
    /// premultiplied by it (v0.18.0), else drawn as stored.
    private let hqFragmentShaderSrc = """
    #version 330 core
    in vec2 vTex;
    out vec4 fragColor;
    uniform usampler2D uLuma;     // BC4 Y (.xy) or BC5 Y (.xy) + A (.zw)
    uniform usampler2D uChroma;   // BC5 Co (.xy) + Cg (.zw)
    uniform int uHasAlpha;
    uniform int uPremultiply;     // YG10 with Alpha Type Straight
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
            if (uPremultiply == 1) {
                rgb *= alpha;
            }
        }
        fragColor = vec4(rgb, alpha);
    }
    """

    /// Hap Q / HapM fragment shader: decodes the BC3 scaled-YCoCg colour
    /// block (four-colour BC1 R = Co, G = Cg, B = scale; BC4 A = Y, all
    /// DXVKit's truncated 8-bit palettes, as `CPURender.unpackDXT5ToRGBA`)
    /// and, for HapM, the BC4 alpha block (`bc4Pal8`, as `BC4BC5Unpack`),
    /// then `HAPHQDecoder`'s inverse in exact integers (`hapYCoCg`, units
    /// of 1/255, D = B + 8):
    ///   R' = Y + 8 (R - G) / D,  G' = Y + 4 (2G - 255) / D,
    ///   B' = Y - 8 (R + G - 255) / D, each rounded half up and clamped.
    /// The four display texels around the sample point blend bilinearly
    /// (exact at 1:1, like the DXT program); HapM colour is straight; the shader premultiplies it for output.
    private let hapYFragmentShaderSrc = """
    #version 330 core
    in vec2 vTex;
    out vec4 fragColor;
    uniform usampler2D uBlocks;       // BC3 scaled YCoCg (GL_RGBA32UI)
    uniform usampler2D uAlphaBlocks;  // BC4 alpha (GL_RG32UI), HapM only
    uniform int uHasAlpha;
    uniform vec2 uTexSize;
    uniform ivec2 uDisplaySize;
    \(DXVRenderer.cropFragmentSrc)
    \(DXVRenderer.blockDecodeSrc)
    \(DXVRenderer.hapYCoCgSrc)
    vec4 texel(ivec2 p) {
        uvec4 w = texelFetch(uBlocks, p >> 2, 0);
        uint i = blockTexel(p);
        vec3 rgb = vec3(hapYCoCg(bc1Colour(w.zw, i, true), bc4Pal8(w.xy, i)));
        float a = uHasAlpha == 1 ? float(bc4Pal8(texelFetch(uAlphaBlocks, p >> 2, 0).xy, i)) : 255.0;
        return vec4(rgb, a);
    }
    void main() {
        vec2 p = samplePoint(cropUV(vTex), uTexSize);
        vec2 f = p - floor(p);
        ivec2 a = clamp(ivec2(floor(p)), ivec2(0), uDisplaySize - 1);
        ivec2 b = clamp(ivec2(floor(p)) + 1, ivec2(0), uDisplaySize - 1);
        vec4 c = mix(mix(texel(a), texel(ivec2(b.x, a.y)), f.x),
                     mix(texel(ivec2(a.x, b.y)), texel(b), f.x), f.y) / 255.0;
        if (uHasAlpha == 1) c.rgb *= c.a;
        fragColor = c;
    }
    """

    /// `HAPHQDecoder.hapYCoCgToRGB` in GLSL (same integers): scaled YCoCg
    /// (R = Co, G = Cg, B = scale, Y) to 8-bit RGB.
    private static let hapYCoCgSrc = """
    int hapRound(int v, int d) { return v <= 0 ? 0 : min(255, (2 * v + d) / (2 * d)); }
    uvec3 hapYCoCg(uvec3 c, uint yy) {
        int r = int(c.r), g = int(c.g), d = int(c.b) + 8, y = int(yy) * d;
        return uvec3(hapRound(y + 8 * (r - g), d), hapRound(y + 4 * (2 * g - 255), d),
                     hapRound(y - 8 * (r + g - 255), d));
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
