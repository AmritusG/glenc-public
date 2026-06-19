// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation
import OpenGL.GL3
import GlanceCore

/// OpenGL renderer for DXV3 frames (DXT1 / DXT5 / YCG6 / YG10).
///
/// DXT path (DXT1, DXT5): uploads the raw DXT-compressed bytes via
/// glCompressedTexImage2D, letting the GPU decompress at sample time.
/// Falls back to software RGBA unpack via DXVValidator if S3TC is
/// unsupported. Validated byte-exact against FFmpeg in Phase 2.
///
/// HQ path (YCG6, YG10) [Phase 4d.2, fix in 4d.4]: uploads three or
/// four R8 single-channel textures (Y, Co, Cg, optional A) and
/// converts YCoCg → RGB(A) in a fragment shader (non-reversible
/// variant, matching what Resolume's encoder uses — see shader
/// comment for the 4d.4 finding). The HQ decoder (DXVHQDecoder)
/// produces these planes from the encoded packet, validated
/// byte-exact against FFmpeg in Phase 4d.1.
///
/// The two paths have separate GL programs and texture sets but
/// share the VAO/VBO (same fullscreen quad geometry). render()
/// branches on lastUploadVariant to pick the right program + texture
/// bindings.
///
/// GL state contract: this renderer touches program, VAO, VBO, texture
/// binding, GL_BLEND, blend func, viewport. It restores nothing — the
/// caller (VideoLayer.draw) is responsible for setting whatever state
/// it needs after each draw call. mpv has the same contract; we
/// mirror it for symmetry.
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

    /// Bundle of HQ frame planes. Y and (for YG10) A at full resolution;
    /// Co and Cg at half resolution (4:2:0 chroma subsampling).
    ///
    /// **Dimension contract (v0.5.0):**
    /// - `width` / `height`: **display** dimensions. What aspect-fit and
    ///   any other "what the user sees" math should use.
    /// - `codedWidth` / `codedHeight`: 16-pixel-aligned **padded**
    ///   dimensions. What plane allocation and texture allocation use.
    ///   Resolume's HQ encoder pads to 16-px block alignment internally;
    ///   the decoder returns planes at coded dimensions; the renderer
    ///   uploads textures at coded dimensions and crops to display
    ///   dimensions via per-frame UV scaling. Plane data sizes match
    ///   `codedWidth × codedHeight` (Y, A) and `chromaWidth × chromaHeight`
    ///   (Co, Cg).
    /// - `chromaWidth` / `chromaHeight`: padded chroma plane dimensions —
    ///   always `codedWidth/2 × codedHeight/2` for the 4:2:0 layout DXV3
    ///   uses.
    ///
    /// For 16-pixel-aligned widths (1920, 1280, 720, etc.) `codedWidth ==
    /// width` and the renderer's UV scaling is a no-op.
    public struct HQFrameData {
        public let y: [UInt8]
        public let co: [UInt8]
        public let cg: [UInt8]
        public let a: [UInt8]?     // nil for YCG6, present for YG10
        public let width: Int          // display
        public let height: Int         // display
        public let codedWidth: Int     // padded (16-aligned)
        public let codedHeight: Int    // padded
        public let chromaWidth: Int    // = codedWidth / 2
        public let chromaHeight: Int   // = codedHeight / 2

        public init(
            y: [UInt8], co: [UInt8], cg: [UInt8], a: [UInt8]?,
            width: Int, height: Int,
            codedWidth: Int, codedHeight: Int,
            chromaWidth: Int, chromaHeight: Int
        ) {
            self.y = y
            self.co = co
            self.cg = cg
            self.a = a
            self.width = width
            self.height = height
            self.codedWidth = codedWidth
            self.codedHeight = codedHeight
            self.chromaWidth = chromaWidth
            self.chromaHeight = chromaHeight
        }
    }

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

    /// True after we've discovered S3TC isn't supported and switched
    /// to the software unpack path. Once true, stays true.
    public private(set) var softwareFallback: Bool = false

    // MARK: - GL objects: shared (DXT + HQ both use these)

    private var vao: GLuint = 0
    private var vbo: GLuint = 0

    /// Whether GL objects have been created. Created lazily on first
    /// draw, like MPVRenderer's pattern, since we need a current GL
    /// context.
    private var glReady: Bool = false

    // MARK: - GL objects: DXT path

    private var dxtProgram: GLuint = 0
    private var dxtTexture: GLuint = 0
    private var dxtUTextureLoc: GLint = -1
    private var dxtUUnpremultiplyLoc: GLint = -1
    private var dxtUUvScaleXLoc: GLint = -1

    /// Padded (coded) width of the last DXT upload — drives the realloc
    /// decision in uploadFrame's internal path. `lastUploadWidth` stays
    /// at display width for the public API. v0.5.0 stride fix.
    private var dxtLastPaddedWidth: Int = 0

    /// Per-upload UV-scale factor for the DXT program. Fragment samples
    /// u in `[0..uvScaleX]` so only the display portion of the padded
    /// texture is rasterized.
    ///
    /// For non-16-aligned widths, biased by half a pixel inward:
    /// `(displayWidth - 0.5) / paddedWidth`. This places the rightmost
    /// fragment's sample half a texel inside the display region, dodging
    /// the GL_LINEAR right-edge blend with the padding column — without
    /// the bias, a sub-pixel sliver of the padding pixel leaked through
    /// as a visible artifact (1-px blue rim on 908×2276 portrait clips).
    ///
    /// For 16-pixel-aligned widths, hard-coded to 1.0 (no padding column
    /// exists, no bias needed) so the rendered result is bit-identical
    /// to pre-v0.5.0.
    private var dxtUvScaleX: Float = 1.0

    // MARK: - GL objects: HQ path [Phase 4d.2]

    private var hqProgram: GLuint = 0
    private var hqTextureY: GLuint = 0
    private var hqTextureCo: GLuint = 0
    private var hqTextureCg: GLuint = 0
    private var hqTextureA: GLuint = 0

    private var hqULocY: GLint = -1
    private var hqULocCo: GLint = -1
    private var hqULocCg: GLint = -1
    private var hqULocA: GLint = -1
    private var hqULocHasAlpha: GLint = -1
    private var hqULocUnpremultiply: GLint = -1
    private var hqULocUvScaleX: GLint = -1

    /// Per-upload UV-scale factor for the HQ program. Same role as
    /// `dxtUvScaleX` — biased by half a pixel inward for non-aligned
    /// widths, hard 1.0 when aligned. Applied uniformly to all four HQ
    /// texture samples (Y, Co, Cg, A) which share the same
    /// display:coded ratio because chroma is coded-width/2 wide and
    /// display-width/2 wide. v0.5.0 stride fix.
    private var hqUvScaleX: Float = 1.0

    /// Cached dimensions of last HQ upload, so we can detect
    /// resize/realloc cases for SubImage vs Image2D.
    private var hqLastUploadWidth: Int = 0
    private var hqLastUploadHeight: Int = 0
    private var hqLastUploadChromaW: Int = 0
    private var hqLastUploadChromaH: Int = 0
    /// Alpha texture dimensions tracked SEPARATELY because YCG6
    /// frames upload only a 1×1 dummy alpha while YG10 frames
    /// upload full-resolution alpha — so a YCG6→YG10 transition
    /// can leave Y/Co/Cg dimensions unchanged but require an alpha
    /// realloc. Without this tracking, the YG10 alpha upload uses
    /// glTexSubImage2D against a 1×1 storage and produces a stream
    /// of GL_INVALID_VALUE errors.
    private var hqLastAlphaW: Int = 0
    private var hqLastAlphaH: Int = 0
    private var hqHasUpload: Bool = false

    // MARK: - Constants for S3TC (not always exposed in macOS GL headers)

    private static let GL_COMPRESSED_RGB_S3TC_DXT1_EXT: GLenum = 0x83F0
    private static let GL_COMPRESSED_RGBA_S3TC_DXT5_EXT: GLenum = 0x83F3

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

        // ---------- DXT program ----------
        dxtProgram = compileProgram(vertex: vertexShaderSrc, fragment: dxtFragmentShaderSrc)
        if dxtProgram == 0 {
            print("Glance/dxvrender: DXT shader program creation FAILED")
            return
        }
        dxtUTextureLoc = glGetUniformLocation(dxtProgram, "uTexture")
        dxtUUnpremultiplyLoc = glGetUniformLocation(dxtProgram, "uUnpremultiply")
        dxtUUvScaleXLoc = glGetUniformLocation(dxtProgram, "uUvScaleX")

        // DXT texture: a single 2D texture for the compressed/RGBA upload.
        glGenTextures(1, &dxtTexture)
        glBindTexture(GLenum(GL_TEXTURE_2D), dxtTexture)
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
        hqULocY            = glGetUniformLocation(hqProgram, "uTextureY")
        hqULocCo           = glGetUniformLocation(hqProgram, "uTextureCo")
        hqULocCg           = glGetUniformLocation(hqProgram, "uTextureCg")
        hqULocA            = glGetUniformLocation(hqProgram, "uTextureA")
        hqULocHasAlpha     = glGetUniformLocation(hqProgram, "uHasAlpha")
        hqULocUnpremultiply = glGetUniformLocation(hqProgram, "uUnpremultiply")
        hqULocUvScaleX     = glGetUniformLocation(hqProgram, "uUvScaleX")

        // HQ textures: 4 single-channel R8 textures.
        //
        // Filter choice (v0.5.0):
        //   - Y / A use GL_LINEAR: visible smoothing benefit when the
        //     viewport doesn't 1:1 the texture (always, under aspect-fit).
        //     Luma carries the perceptually-dominant detail; alpha edges
        //     look better interpolated.
        //   - Co / Cg use GL_NEAREST: chroma planes are at half-res and
        //     16-pixel-aligned-padded (chromaPaddedW = paddedW / 2).
        //     Even with the pixel-center-biased uvScaleX, GL_LINEAR
        //     across the right-edge half-pixel produces a visible color
        //     cast bled in from the padding column — at 908×2276 portrait
        //     this shows as a 1-pixel blue rim. GL_NEAREST samples the
        //     last display chroma texel cleanly and eliminates the bleed.
        //     The perceptual loss of chroma bilinear is small (chroma is
        //     already half-res and the human eye is much less sensitive
        //     to high-frequency chroma than luma — same reason 4:2:0
        //     subsampling is acceptable in the first place).
        var hqTexes: [GLuint] = [0, 0, 0, 0]
        glGenTextures(4, &hqTexes)
        hqTextureY  = hqTexes[0]
        hqTextureCo = hqTexes[1]
        hqTextureCg = hqTexes[2]
        hqTextureA  = hqTexes[3]
        for tex in hqTexes {
            glBindTexture(GLenum(GL_TEXTURE_2D), tex)
            let filter: GLint = (tex == hqTextureCo || tex == hqTextureCg) ? GL_NEAREST : GL_LINEAR
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MIN_FILTER), filter)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_MAG_FILTER), filter)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_S), GL_CLAMP_TO_EDGE)
            glTexParameteri(GLenum(GL_TEXTURE_2D), GLenum(GL_TEXTURE_WRAP_T), GL_CLAMP_TO_EDGE)
        }
        glBindTexture(GLenum(GL_TEXTURE_2D), 0)

        glReady = true
        print("Glance/dxvrender: GL objects ready (dxtProgram=\(dxtProgram), hqProgram=\(hqProgram), vao=\(vao), vbo=\(vbo), dxtTex=\(dxtTexture), hqTex=Y\(hqTextureY)/Co\(hqTextureCo)/Cg\(hqTextureCg)/A\(hqTextureA))")
    }

    // MARK: - Public API: DXT path

    /// Upload a frame's compressed (or RGBA-fallback) bytes to the
    /// texture. Call from a context where GL is current. Caller has
    /// already ensured the texture target is bindable.
    ///
    /// `width` / `height` are **display** dimensions — the renderer
    /// internally pads to 16-pixel block alignment for the texture
    /// upload and crops back to display dimensions via per-frame UV
    /// scaling at draw time. `dxtBytes` must be sized for the padded
    /// layout: `paddedWidth * height / 2` (DXT1) / `paddedWidth *
    /// height` (DXT5) where `paddedWidth = (width + 15) / 16 * 16`.
    /// `DXVPlayer.decodeDXTFrame` produces padded bytes automatically.
    /// For 16-pixel-aligned widths the padded layout equals the
    /// display layout (no-op).
    @discardableResult
    public func uploadFrame(dxtBytes: Data, variant: Variant,
                            width: Int, height: Int) -> Bool {
        let paddedW = (width + 15) / 16 * 16
        return uploadFrameInternal(
            dxtBytes: dxtBytes, variant: variant,
            paddedWidth: paddedW, displayWidth: width, height: height)
    }

    private func uploadFrameInternal(
        dxtBytes: Data, variant: Variant,
        paddedWidth: Int, displayWidth: Int, height: Int
    ) -> Bool {
        precondition(!variant.isHQ, "uploadFrame is for DXT only; use uploadHQFrame for HQ variants")
        ensureGLObjects()
        guard glReady else { return false }

        let needsRealloc = !hasUpload
            || lastUploadVariant != variant
            || dxtLastPaddedWidth != paddedWidth
            || lastUploadHeight != height

        glBindTexture(GLenum(GL_TEXTURE_2D), dxtTexture)

        // First-use S3TC probe: try the compressed path; if it errors,
        // mark softwareFallback and fall through.
        if !softwareFallback {
            let ok = uploadCompressed(
                dxtBytes: dxtBytes, variant: variant,
                width: paddedWidth, height: height,
                realloc: needsRealloc)
            if ok {
                lastUploadVariant = variant
                lastUploadWidth = displayWidth          // public: display
                lastUploadHeight = height
                dxtLastPaddedWidth = paddedWidth        // internal: padded
                dxtUvScaleX = (paddedWidth == displayWidth)
                    ? 1.0
                    : (Float(displayWidth) - 0.5) / Float(paddedWidth)
                hasUpload = true
                return true
            }
            // Compressed path failed — switch to software for this and
            // all future uploads. needsRealloc must be true now since
            // we're about to upload a totally different format.
            softwareFallback = true
            print("Glance/dxvrender: S3TC unsupported, switching to software unpack + RGBA upload")
        }

        // SW fallback path. Uses GlanceCore.CPURender (the canonical,
        // padding-aware DXT→RGBA decoder shared with the QuickLook /
        // thumbnail paths). Replaced DXVValidator's older unpack
        // helpers when DXVRenderer moved out of the executable target
        // in v0.5.0 — DXVValidator stays in the Glance executable for
        // its PNG-diff diagnostic flow and can't be reached from
        // GlancePlayback.
        //
        // CPURender.unpackDXT*ToRGBA decodes at padded width internally
        // and crops to display width, so the returned buffer is exactly
        // `displayWidth × height × 4` bytes. Upload at display
        // dimensions; uvScale stays 1.0 for the SW path because the
        // crop already happened on CPU.
        let rgba: [UInt8]
        switch variant {
        case .dxt1:
            rgba = CPURender.unpackDXT1ToRGBA(dxt1: dxtBytes, width: displayWidth, height: height)
        case .dxt5:
            rgba = CPURender.unpackDXT5ToRGBA(dxt5: dxtBytes, width: displayWidth, height: height)
        default:
            return false  // unreachable due to precondition above
        }
        let realloc = needsRealloc || lastUploadVariant != variant
        rgba.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            if realloc {
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_RGBA,
                             GLsizei(displayWidth), GLsizei(height), 0,
                             GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE),
                             base)
            } else {
                glTexSubImage2D(GLenum(GL_TEXTURE_2D), 0, 0, 0,
                                GLsizei(displayWidth), GLsizei(height),
                                GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE),
                                base)
            }
        }
        lastUploadVariant = variant
        lastUploadWidth = displayWidth
        lastUploadHeight = height
        dxtLastPaddedWidth = displayWidth   // SW path already cropped; texture is display-sized
        dxtUvScaleX = 1.0
        hasUpload = true
        return true
    }

    // MARK: - Public API: HQ path [Phase 4d.2]

    /// Upload an HQ frame's planes (Y, Co, Cg, optional A) as separate
    /// single-channel R8 textures. Call from a context where GL is
    /// current.
    ///
    /// `variant` must be .ycg6 or .yg10. For YCG6, frame.a is ignored
    /// (the shader writes alpha=1.0). For YG10, frame.a is required.
    ///
    /// Frame planes are uploaded at **coded** (padded) dimensions —
    /// see `HQFrameData` for the dimension contract. Texture storage
    /// uses coded dims; aspect-fit math uses display dims (exposed via
    /// `lastUploadWidth` / `lastUploadHeight`); right-edge padding
    /// columns are cropped at draw time via per-program UV scaling.
    ///
    /// On the first call (or on dimension change) we use glTexImage2D
    /// (allocates + uploads). On subsequent calls with same dimensions
    /// we use glTexSubImage2D (upload-only).
    @discardableResult
    public func uploadHQFrame(_ frame: HQFrameData, variant: Variant) -> Bool {
        precondition(variant.isHQ, "uploadHQFrame is for HQ variants only; use uploadFrame for DXT")
        ensureGLObjects()
        guard glReady else { return false }

        // Sanity: Y plane size matches coded dimensions, Co/Cg match
        // (coded) chroma dimensions, A (if present) matches Y.
        guard frame.y.count == frame.codedWidth * frame.codedHeight,
              frame.co.count == frame.chromaWidth * frame.chromaHeight,
              frame.cg.count == frame.chromaWidth * frame.chromaHeight else {
            print("Glance/dxvrender: HQ plane sizes inconsistent (y=\(frame.y.count) coded=\(frame.codedWidth)x\(frame.codedHeight) chroma=\(frame.chromaWidth)x\(frame.chromaHeight) co=\(frame.co.count) cg=\(frame.cg.count))")
            return false
        }
        if variant == .yg10 {
            guard let alpha = frame.a, alpha.count == frame.codedWidth * frame.codedHeight else {
                print("Glance/dxvrender: YG10 missing or wrong-size alpha plane")
                return false
            }
        }

        let needsRealloc = !hqHasUpload
            || hqLastUploadWidth != frame.codedWidth
            || hqLastUploadHeight != frame.codedHeight
            || hqLastUploadChromaW != frame.chromaWidth
            || hqLastUploadChromaH != frame.chromaHeight

        // Drain any pre-existing GL error before our uploads.
        while glGetError() != GLenum(GL_NO_ERROR) {}

        // Upload Y plane at coded dimensions.
        uploadR8Plane(texture: hqTextureY, data: frame.y,
                      width: frame.codedWidth, height: frame.codedHeight,
                      realloc: needsRealloc)
        // Upload Co plane at coded chroma dimensions.
        uploadR8Plane(texture: hqTextureCo, data: frame.co,
                      width: frame.chromaWidth, height: frame.chromaHeight,
                      realloc: needsRealloc)
        // Upload Cg plane at coded chroma dimensions.
        uploadR8Plane(texture: hqTextureCg, data: frame.cg,
                      width: frame.chromaWidth, height: frame.chromaHeight,
                      realloc: needsRealloc)
        // Upload A plane (or a 1-pixel dummy for YCG6, just so the
        // sampler always has valid storage). Track alpha dimensions
        // independently of Y/Co/Cg so a YCG6→YG10 (or vice versa)
        // transition correctly forces alpha realloc — Y/Co/Cg dims
        // can be unchanged across the transition.
        if let alpha = frame.a {
            // YG10: full-resolution alpha plane at coded dimensions.
            let alphaNeedsRealloc = hqLastAlphaW != frame.codedWidth
                                 || hqLastAlphaH != frame.codedHeight
            uploadR8Plane(texture: hqTextureA, data: alpha,
                          width: frame.codedWidth, height: frame.codedHeight,
                          realloc: alphaNeedsRealloc)
            hqLastAlphaW = frame.codedWidth
            hqLastAlphaH = frame.codedHeight
        } else if hqLastAlphaW != 1 || hqLastAlphaH != 1 {
            // YCG6: install a 1×1 opaque dummy if the alpha texture
            // isn't already at that size. Shader's uHasAlpha=0 will
            // gate the sample, but storage must be valid.
            let dummy: [UInt8] = [255]
            dummy.withUnsafeBufferPointer { buf in
                glBindTexture(GLenum(GL_TEXTURE_2D), hqTextureA)
                glPixelStorei(GLenum(GL_UNPACK_ALIGNMENT), 1)
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_R8,
                             1, 1, 0,
                             GLenum(GL_RED), GLenum(GL_UNSIGNED_BYTE),
                             buf.baseAddress)
            }
            hqLastAlphaW = 1
            hqLastAlphaH = 1
        }

        let err = glGetError()
        if err != GLenum(GL_NO_ERROR) {
            print(String(format: "Glance/dxvrender: HQ texture upload failed (GL error 0x%X)", err))
            return false
        }

        hqLastUploadWidth = frame.codedWidth      // internal: coded
        hqLastUploadHeight = frame.codedHeight
        hqLastUploadChromaW = frame.chromaWidth
        hqLastUploadChromaH = frame.chromaHeight
        hqHasUpload = true

        // Update shared "last upload" tracking so render() knows which
        // path to take and the layer can size the viewport correctly.
        // The public-facing dimensions are DISPLAY — VideoLayer's
        // aspect-fit math reads these and must never see padding.
        lastUploadVariant = variant
        lastUploadWidth = frame.width             // public: display
        lastUploadHeight = frame.height
        hqUvScaleX = (frame.codedWidth == frame.width)
            ? 1.0
            : (Float(frame.width) - 0.5) / Float(frame.codedWidth)
        hasUpload = true

        return true
    }

    /// Upload one R8 plane to the given texture. Sets unpack alignment
    /// to 1 since plane widths aren't necessarily multiples of 4.
    private func uploadR8Plane(texture: GLuint, data: [UInt8],
                               width: Int, height: Int,
                               realloc: Bool) {
        glBindTexture(GLenum(GL_TEXTURE_2D), texture)
        glPixelStorei(GLenum(GL_UNPACK_ALIGNMENT), 1)
        data.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            if realloc {
                glTexImage2D(GLenum(GL_TEXTURE_2D), 0, GL_R8,
                             GLsizei(width), GLsizei(height), 0,
                             GLenum(GL_RED), GLenum(GL_UNSIGNED_BYTE),
                             base)
            } else {
                glTexSubImage2D(GLenum(GL_TEXTURE_2D), 0, 0, 0,
                                GLsizei(width), GLsizei(height),
                                GLenum(GL_RED), GLenum(GL_UNSIGNED_BYTE),
                                base)
            }
        }
    }

    // MARK: - Public API: render

    /// Render the most-recently-uploaded frame into the currently-bound
    /// framebuffer. Caller is responsible for the FBO binding,
    /// glViewport, and any pre-clear. mpv uses the same contract.
    public func render() {
        guard glReady, hasUpload, let variant = lastUploadVariant else { return }

        glDisable(GLenum(GL_BLEND))
        glBindVertexArray(vao)

        if variant.isHQ {
            renderHQ(variant: variant)
        } else {
            renderDXT()
        }

        glBindVertexArray(0)
    }

    private func renderDXT() {
        glUseProgram(dxtProgram)
        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), dxtTexture)
        glUniform1i(dxtUTextureLoc, 0)
        glUniform1i(dxtUUnpremultiplyLoc, unpremultiplyAlpha ? 1 : 0)
        glUniform1f(dxtUUvScaleXLoc, dxtUvScaleX)

        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
    }

    private func renderHQ(variant: Variant) {
        glUseProgram(hqProgram)

        glActiveTexture(GLenum(GL_TEXTURE0))
        glBindTexture(GLenum(GL_TEXTURE_2D), hqTextureY)
        glUniform1i(hqULocY, 0)

        glActiveTexture(GLenum(GL_TEXTURE1))
        glBindTexture(GLenum(GL_TEXTURE_2D), hqTextureCo)
        glUniform1i(hqULocCo, 1)

        glActiveTexture(GLenum(GL_TEXTURE2))
        glBindTexture(GLenum(GL_TEXTURE_2D), hqTextureCg)
        glUniform1i(hqULocCg, 2)

        glActiveTexture(GLenum(GL_TEXTURE3))
        glBindTexture(GLenum(GL_TEXTURE_2D), hqTextureA)
        glUniform1i(hqULocA, 3)

        glUniform1i(hqULocHasAlpha, variant == .yg10 ? 1 : 0)
        glUniform1i(hqULocUnpremultiply, unpremultiplyAlpha ? 1 : 0)
        glUniform1f(hqULocUvScaleX, hqUvScaleX)

        glDrawArrays(GLenum(GL_TRIANGLE_STRIP), 0, 4)
    }

    // MARK: - Private upload helpers (DXT)

    /// Try the compressed-texture path. Returns true if upload
    /// succeeded with no GL error, false otherwise (caller falls back
    /// to RGBA).
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

    // MARK: - Shader sources

    /// Vertex shader shared by DXT and HQ programs. The `uUvScaleX`
    /// uniform crops the rendered slice of the texture along U to the
    /// display portion of the padded texture (v0.5.0 stride fix). For
    /// 16-pixel-aligned widths this is 1.0 and the rendering is
    /// identical to pre-v0.5.0.
    private let vertexShaderSrc = """
    #version 330 core
    layout(location = 0) in vec2 aPos;
    layout(location = 1) in vec2 aTex;
    uniform float uUvScaleX;
    out vec2 vTex;
    void main() {
        vTex = vec2(aTex.x * uUvScaleX, aTex.y);
        gl_Position = vec4(aPos, 0.0, 1.0);
    }
    """

    /// DXT fragment shader. Samples the bound 2D texture; optionally
    /// un-premultiplies alpha (for matching straight-alpha sources).
    private let dxtFragmentShaderSrc = """
    #version 330 core
    in vec2 vTex;
    out vec4 fragColor;
    uniform sampler2D uTexture;
    uniform int uUnpremultiply;
    void main() {
        vec4 c = texture(uTexture, vTex);
        if (uUnpremultiply == 1 && c.a > 0.0) {
            c.rgb /= c.a;
        }
        fragColor = c;
    }
    """

    /// HQ fragment shader. Samples three (or four) R8 single-channel
    /// textures (Y, Co, Cg, A) and converts YCoCg → RGB(A) using
    /// the non-reversible YCoCg inverse, matching what Resolume's
    /// HQ encoder uses.
    ///
    /// YCoCg reverse transform (non-reversible variant):
    ///   co = co_byte - 128
    ///   cg = cg_byte - 128
    ///   t  = y_byte - cg
    ///   R  = t + co
    ///   G  = y_byte + cg
    ///   B  = t - co
    ///
    /// Phase 4d.4 finding: the YCoCg-R variant (with `>>1` halvings on
    /// chroma) produces visibly desaturated output. Resolume's encoder
    /// uses the non-reversible form. Verified via the color-bisect
    /// harness in tools/color-bisect/ — naive YCoCg matched a
    /// Resolume-rendered reference at 99.82% within ±4 per channel.
    /// Mean error ≤ 1.4 per channel; residual is from chroma
    /// upsampling differences (we use bilinear via GL_LINEAR; Resolume
    /// likely the same).
    ///
    /// Texture samples are float 0..1; we multiply by 255 and round to
    /// int to recover the exact byte values, then do all math in int.
    private let hqFragmentShaderSrc = """
    #version 330 core
    in vec2 vTex;
    out vec4 fragColor;
    uniform sampler2D uTextureY;
    uniform sampler2D uTextureCo;
    uniform sampler2D uTextureCg;
    uniform sampler2D uTextureA;
    uniform int uHasAlpha;
    uniform int uUnpremultiply;

    void main() {
        // Sample R channel of each plane and convert to int 0..255.
        // Co and Cg textures are at half resolution; the GL sampler
        // (set to GL_LINEAR) does bilinear chroma upsampling for free.
        int yI  = int(round(texture(uTextureY,  vTex).r * 255.0));
        int coI = int(round(texture(uTextureCo, vTex).r * 255.0));
        int cgI = int(round(texture(uTextureCg, vTex).r * 255.0));

        // Non-reversible YCoCg reverse transform. Co and Cg are
        // biased by 128. Note: this is NOT the YCoCg-R variant
        // (which would be y - (cg>>1) + cg, etc.). The byte-validation
        // harness color-bisect proved Resolume's encoder uses the
        // non-reversible YCoCg form: chroma comes through at full
        // magnitude, no >>1 halvings. Using the YCoCg-R inverse
        // produces ~halved chroma and visibly desaturated output
        // (Phase 4d.4 finding, 2026-05-06).
        int co = coI - 128;
        int cg = cgI - 128;
        int t = yI - cg;
        int r = t + co;
        int g = yI + cg;
        int b = t - co;

        // Clamp into 0..255 then normalize to 0..1.
        r = clamp(r, 0, 255);
        g = clamp(g, 0, 255);
        b = clamp(b, 0, 255);

        vec3 rgb = vec3(r, g, b) / 255.0;

        float alpha = 1.0;
        if (uHasAlpha == 1) {
            alpha = texture(uTextureA, vTex).r;
            if (uUnpremultiply == 1 && alpha > 0.0) {
                rgb /= alpha;
            }
        }

        fragColor = vec4(rgb, alpha);
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
