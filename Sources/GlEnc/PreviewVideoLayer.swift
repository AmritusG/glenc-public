// SPDX-License-Identifier: MIT
import Cocoa
import OpenGL.GL3
import GlancePlayback

/// CAOpenGLLayer that hosts a Glance `DXVRenderer`. Phase 8B-c.
///
/// Subset of Glance.app's `Sources/Glance/VideoLayer.swift` with the
/// mpv branch removed — GlEnc only ever previews DXV3 content, so the
/// layer has a single mode (DXV) and no mpv plumbing.
///
/// Pattern:
///   - `dxvRenderer` is installed by the hosting NSView. The renderer
///     defers GL object creation to its first `render()` call, so we
///     can install it before any GL context is current.
///   - `uploadHook` is set by the hosting view when a new frame is
///     ready (DXVPlayer's `onFrameDecoded` / `onHQFrameDecoded` →
///     PreviewPlayerModel's outbound closures → hosting view sets the
///     hook + calls `setNeedsDisplay`).
///   - On the next vsync, `draw(inCGLContext:...)` fires with a
///     current GL context: it runs the upload hook (single-shot,
///     cleared after invocation), sets an aspect-fit viewport, and
///     calls `renderer.render()`.
final class PreviewVideoLayer: CAOpenGLLayer {

    var dxvRenderer: DXVRenderer?

    /// Single-shot upload closure. Cleared after each draw so the
    /// next frame must re-arm. Hosting view re-arms via
    /// `setNeedsDisplay()` on each `onDXTFrame` / `onHQFrame` callback.
    var uploadHook: (() -> Void)?

    override init() {
        super.init()
        // asynchronous=false: we draw on demand (per frame decode).
        // async=true would loop canDraw at vsync regardless, burning
        // cycles to ask "is there a new frame yet?".
        isAsynchronous = false
        isOpaque = true
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError("not implemented") }

    /// Request an OpenGL 3.2 Core profile. CAOpenGLLayer defaults to
    /// a legacy 2.x context which doesn't accept `#version 330` shaders.
    /// `DXVRenderer` uses Core 3.2+ shaders, so this is required.
    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        let profileCore32 = UInt32(kCGLOGLPVersion_3_2_Core.rawValue)
        let attribs: [CGLPixelFormatAttribute] = [
            kCGLPFADisplayMask, CGLPixelFormatAttribute(mask),
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(profileCore32),
            kCGLPFAColorSize, CGLPixelFormatAttribute(24),
            kCGLPFAAlphaSize, CGLPixelFormatAttribute(8),
            kCGLPFADoubleBuffer,
            kCGLPFAAccelerated,
            CGLPixelFormatAttribute(0),
        ]
        var pf: CGLPixelFormatObj? = nil
        var npix: GLint = 0
        let err = attribs.withUnsafeBufferPointer { buf in
            CGLChoosePixelFormat(buf.baseAddress!, &pf, &npix)
        }
        if err != kCGLNoError || pf == nil {
            print("[GlEnc/preview-layer] CGLChoosePixelFormat failed (\(err)); falling back to default")
            return super.copyCGLPixelFormat(forDisplayMask: mask)
        }
        return pf!
    }

    // MARK: - CAOpenGLLayer

    override func canDraw(inCGLContext ctx: CGLContextObj,
                          pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval,
                          displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        // Draw if an upload is pending (new frame arriving) OR the
        // renderer already has a frame on-texture (repaint on resize /
        // layer invalidation).
        return uploadHook != nil || (dxvRenderer?.hasUpload ?? false)
    }

    override func draw(inCGLContext ctx: CGLContextObj,
                       pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval,
                       displayTime ts: UnsafePointer<CVTimeStamp>?) {
        let scale = contentsScale > 0 ? contentsScale : 2.0
        let pxW = GLsizei(bounds.width * scale)
        let pxH = GLsizei(bounds.height * scale)
        guard pxW > 0, pxH > 0 else {
            super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
            return
        }

        // Clear to black so letterbox/pillarbox regions paint black.
        glViewport(0, 0, pxW, pxH)
        glClearColor(0, 0, 0, 1)
        glClear(GLbitfield(GL_COLOR_BUFFER_BIT))

        // Single-shot upload (DXVRenderer needs a current GL context
        // for the actual texture upload).
        if let hook = uploadHook {
            uploadHook = nil
            hook()
        }

        guard let renderer = dxvRenderer else {
            super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
            return
        }

        // Aspect-fit viewport. Same math Glance.app's VideoLayer uses.
        // `lastUploadWidth` / `lastUploadHeight` are DISPLAY dims per
        // the DXVRenderer v0.5.0 contract; pad-aware math lives inside
        // the renderer.
        if renderer.hasUpload {
            let texW = GLfloat(renderer.lastUploadWidth)
            let texH = GLfloat(renderer.lastUploadHeight)
            let layW = GLfloat(pxW)
            let layH = GLfloat(pxH)
            let texAspect = texW / texH
            let layAspect = layW / layH
            var vpW: GLsizei
            var vpH: GLsizei
            var vpX: GLsizei = 0
            var vpY: GLsizei = 0
            if layAspect > texAspect {
                // Layer wider than texture → pillarbox.
                vpH = pxH
                vpW = GLsizei(layH * texAspect)
                vpX = (pxW - vpW) / 2
            } else {
                vpW = pxW
                vpH = GLsizei(layW / texAspect)
                vpY = (pxH - vpH) / 2
            }
            glViewport(vpX, vpY, vpW, vpH)
        }

        renderer.render()
        super.draw(inCGLContext: ctx, pixelFormat: pf, forLayerTime: t, displayTime: ts)
    }
}
