// SPDX-License-Identifier: MIT
/*
 * FrameResizer.swift — Resize Release Phase D (v0.9.4-pending).
 *
 * Pure scaling helper. Given a source `PixelFrame` (BGRA via
 * CVPixelBuffer), a target (width, height), and a `ResizeQuality`,
 * returns a new `PixelFrame` at the target dimensions. NO pipeline
 * wiring (Phase E), NO UI (Phase F) — standalone helper.
 *
 * Quality resolution
 * ──────────────────
 *   .auto  → ResizeQuality.resolved(forSource:output:) per Phase B's
 *            Q1+Q2 contract: downscale → .lanczos, upscale → .bilinear,
 *            equal-dims → .bilinear (and the equal-dims fast-path
 *            below short-circuits before any vImage call).
 *   .nearest, .bilinear, .lanczos → used directly.
 *
 * vImage mapping
 * ──────────────
 *   .nearest  → manual nearest-neighbour sample loop. Apple's vImage
 *               doesn't expose a direct nearest-scale API for the
 *               `_ARGB8888` family; the canonical
 *               `srcX = x * srcW / targetW` integer formula is the
 *               right shape for the .nearest contract (hard-edge
 *               preservation for pixel-art content per the Phase B
 *               doc-comment).
 *   .bilinear → `vImageScale_ARGB8888` with `kvImageNoFlags`. Apple
 *               documents the default as a bilinear-class kernel.
 *   .lanczos  → `vImageScale_ARGB8888` with `kvImageHighQualityResampling`.
 *               Apple documents this flag as switching to a Lanczos
 *               resampling filter (developer.apple.com:
 *               "uses a Lanczos resampling filter to produce the
 *               output image"). Confirmed Lanczos-class via the
 *               solid-color preservation test.
 *
 * `_ARGB8888` is byte-order-agnostic: vImage scales each channel
 * independently and doesn't care which channel is at which byte
 * offset. BGRA works identically to ARGB through this API.
 *
 * Equal-dims fast path
 * ────────────────────
 * If `targetWidth == frame.width && targetHeight == frame.height`,
 * returns the input frame unchanged (no allocation, no scale call).
 * This is the .auto "equal → neutral" case made concrete, and also
 * a free optimization for explicit-filter callers.
 *
 * Alignment
 * ─────────
 * FrameResizer does NOT enforce 4-pixel alignment on the target.
 * It's a general scaler; alignment is the caller's contract (Phase F's
 * Custom… sheet rounds; the preset list is 4-pixel-legal by
 * construction). FrameResizer accepts any positive (w, h).
 */

import Foundation
import Accelerate
import CoreVideo
import CoreMedia

public enum FrameResizerError: Error, CustomStringConvertible {
    case invalidTargetDimensions(width: Int, height: Int)
    case pixelBufferAllocationFailed(CVReturn)
    case vImageError(vImage_Error)

    public var description: String {
        switch self {
        case .invalidTargetDimensions(let w, let h):
            return "FrameResizer: target dimensions must be positive — got (\(w)×\(h))"
        case .pixelBufferAllocationFailed(let r):
            return "FrameResizer: CVPixelBufferCreate failed (\(r))"
        case .vImageError(let e):
            return "FrameResizer: vImage error \(e)"
        }
    }
}

public enum FrameResizer {

    /// Resize `frame` to `(targetWidth, targetHeight)` using
    /// `quality` and `aspectMode` (Phase G).
    ///
    /// `.distortToFill` (the default for this helper) is the original
    /// Phase E behavior — straight non-uniform scale to target.
    /// `.letterbox` fits the source aspect inside the target rect and
    /// fills the remainder with opaque black; when source aspect ==
    /// target aspect both modes are equivalent and take the no-bar
    /// fast path.
    ///
    /// The user-facing default lives at the UI/AppSettings layer
    /// (`.letterbox` per CROP_RESIZE_PLAN.md Q3) — this function's
    /// default is the simplest behavior, so pre-Phase-G callers that
    /// pass only (width, height, quality) keep their straight-resize
    /// contract intact.
    ///
    /// Equal-dimensions returns `frame` unchanged regardless of
    /// aspect mode (no resize needed → no bars needed).
    public static func resize(
        _ frame: PixelFrame,
        toWidth targetW: Int,
        toHeight targetH: Int,
        quality: ResizeQuality,
        aspectMode: AspectMode = .distortToFill
    ) throws -> PixelFrame {
        // Pre-Phase-G call sites passed only quality + width/height.
        // For .distortToFill or matched aspect the path collapses to
        // the original Phase E behavior; only the mismatched-aspect
        // + .letterbox branch composites into a black canvas.
        if aspectMode == .letterbox {
            let rect = letterboxRect(
                sourceWidth: frame.width, sourceHeight: frame.height,
                targetWidth: targetW, targetHeight: targetH)
            if !rect.fillsCanvas(canvasWidth: targetW, canvasHeight: targetH) {
                return try letterboxResize(frame,
                                            targetW: targetW, targetH: targetH,
                                            inner: rect, quality: quality)
            }
            // Matched aspect → fall through to the plain resize path.
        }
        return try plainResize(frame,
                                toWidth: targetW, toHeight: targetH,
                                quality: quality)
    }

    /// Phase E's original resize entry point — straight scale, no
    /// aspect handling. Kept as the internal worker called by both
    /// `.distortToFill` and the matched-aspect `.letterbox` fast path.
    private static func plainResize(
        _ frame: PixelFrame,
        toWidth targetW: Int,
        toHeight targetH: Int,
        quality: ResizeQuality
    ) throws -> PixelFrame {
        guard targetW > 0, targetH > 0 else {
            throw FrameResizerError.invalidTargetDimensions(width: targetW, height: targetH)
        }

        let srcW = frame.width
        let srcH = frame.height

        // Equal-dims fast path. Returns the input frame unchanged.
        // The .auto "equal → neutral" case made concrete; also a free
        // optimization for callers that hand back the same dims.
        if targetW == srcW && targetH == srcH {
            return frame
        }

        // Resolve .auto to a concrete filter via the Phase B helper.
        // For non-auto cases this returns self.
        let resolved = quality.resolved(
            forSourceWidth: srcW, sourceHeight: srcH,
            outputWidth: targetW, outputHeight: targetH)

        // Allocate destination CVPixelBuffer at target dims. Always
        // 32BGRA to match the input layout.
        let dstBuffer = try makeBGRABuffer(width: targetW, height: targetH)

        // Lock source for read, dest for write, for the scale pass.
        CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(dstBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(dstBuffer, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(frame.pixelBuffer),
              let dstBase = CVPixelBufferGetBaseAddress(dstBuffer) else {
            throw FrameResizerError.pixelBufferAllocationFailed(kCVReturnAllocationFailed)
        }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(frame.pixelBuffer)
        let dstRowBytes = CVPixelBufferGetBytesPerRow(dstBuffer)

        switch resolved {
        case .auto:
            // Unreachable — `resolved(...)` removes .auto from the
            // type system by mapping it to .lanczos / .bilinear above.
            fatalError("FrameResizer: ResizeQuality.auto survived resolved() — bug")
        case .nearest:
            nearestScale(srcBase: srcBase, srcW: srcW, srcH: srcH, srcRowBytes: srcRowBytes,
                         dstBase: dstBase, dstW: targetW, dstH: targetH, dstRowBytes: dstRowBytes)
        case .bilinear:
            try vImageScale(srcBase: srcBase, srcW: srcW, srcH: srcH, srcRowBytes: srcRowBytes,
                            dstBase: dstBase, dstW: targetW, dstH: targetH, dstRowBytes: dstRowBytes,
                            flags: vImage_Flags(kvImageNoFlags))
        case .lanczos:
            try vImageScale(srcBase: srcBase, srcW: srcW, srcH: srcH, srcRowBytes: srcRowBytes,
                            dstBase: dstBase, dstW: targetW, dstH: targetH, dstRowBytes: dstRowBytes,
                            flags: vImage_Flags(kvImageHighQualityResampling))
        }

        // Wrap the destination buffer in a new PixelFrame. Coded dims
        // default to width/height (the caller — Phase E pipeline —
        // decides what to do with coded alignment downstream; the
        // resizer just produces a buffer at the requested size).
        return PixelFrame(
            pixelBuffer: dstBuffer,
            presentationTime: frame.presentationTime,
            codedWidth: nil,
            codedHeight: nil,
            alphaInfo: frame.alphaInfo)
    }

    // MARK: - Letterbox compositing (Phase G)

    /// Build the letterboxed output frame: resize source into the
    /// inner rect (a temp buffer of those dims), then composite that
    /// inner image centered onto a target-size canvas pre-filled with
    /// opaque black.
    ///
    /// The black canvas uses (B=0, G=0, R=0, A=255) — opaque so the
    /// bars are visually black regardless of the consumer codec's
    /// alpha handling.
    private static func letterboxResize(
        _ frame: PixelFrame,
        targetW: Int, targetH: Int,
        inner: LetterboxRect,
        quality: ResizeQuality
    ) throws -> PixelFrame {
        // First produce a PixelFrame at the inner rect's dimensions
        // via the plain resize worker. Reuses the same vImage path
        // the matched-aspect case takes — no special-case scaling.
        let innerFrame = try plainResize(
            frame, toWidth: inner.width, toHeight: inner.height,
            quality: quality)

        // Allocate the target-size canvas and fill it with opaque
        // black. We have to lock + write before the inner-rect memcpy.
        let canvas = try makeBGRABuffer(width: targetW, height: targetH)
        CVPixelBufferLockBaseAddress(canvas, [])
        defer { CVPixelBufferUnlockBaseAddress(canvas, []) }
        guard let canvasBase = CVPixelBufferGetBaseAddress(canvas) else {
            throw FrameResizerError.pixelBufferAllocationFailed(kCVReturnAllocationFailed)
        }
        let canvasRowBytes = CVPixelBufferGetBytesPerRow(canvas)
        fillOpaqueBlack(base: canvasBase,
                         width: targetW, height: targetH,
                         rowBytes: canvasRowBytes)

        // Memcpy each row of the inner frame into the offset position
        // in the canvas. Rows are independent — no need to handle row-
        // straddling or partial blocks.
        CVPixelBufferLockBaseAddress(innerFrame.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(innerFrame.pixelBuffer, .readOnly) }
        guard let innerBase = CVPixelBufferGetBaseAddress(innerFrame.pixelBuffer) else {
            throw FrameResizerError.pixelBufferAllocationFailed(kCVReturnAllocationFailed)
        }
        let innerRowBytes = CVPixelBufferGetBytesPerRow(innerFrame.pixelBuffer)
        let innerSrc = innerBase.assumingMemoryBound(to: UInt8.self)
        let canvasDst = canvasBase.assumingMemoryBound(to: UInt8.self)
        let copyRowBytes = inner.width * 4  // BGRA = 4 bytes/pixel
        let xByteOffset = inner.insetX * 4
        for y in 0..<inner.height {
            let srcRow = innerSrc.advanced(by: y * innerRowBytes)
            let dstRow = canvasDst.advanced(by: (inner.insetY + y) * canvasRowBytes + xByteOffset)
            memcpy(dstRow, srcRow, copyRowBytes)
        }

        return PixelFrame(
            pixelBuffer: canvas,
            presentationTime: frame.presentationTime,
            codedWidth: nil,
            codedHeight: nil,
            alphaInfo: frame.alphaInfo)
    }

    /// Fill a tightly-packed BGRA buffer with opaque black: every
    /// pixel becomes (B=0, G=0, R=0, A=255). This is the bar color
    /// for letterbox compositing.
    private static func fillOpaqueBlack(
        base: UnsafeMutableRawPointer,
        width: Int, height: Int, rowBytes: Int
    ) {
        let p = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            let row = p.advanced(by: y * rowBytes)
            // Each pixel is 4 bytes B,G,R,A. memset 0 then patch A.
            memset(row, 0, width * 4)
            // Alpha is byte index 3 within each pixel (BGRA).
            for x in 0..<width {
                row[x * 4 + 3] = 0xFF
            }
        }
    }

    // MARK: - Pixel-buffer allocation

    private static func makeBGRABuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        // IOSurface-backed for compatibility with downstream consumers
        // (matches the convention in SourceFrameReader's DxvSourceReader).
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw FrameResizerError.pixelBufferAllocationFailed(status)
        }
        return buf
    }

    // MARK: - vImage bilinear / Lanczos

    private static func vImageScale(
        srcBase: UnsafeMutableRawPointer, srcW: Int, srcH: Int, srcRowBytes: Int,
        dstBase: UnsafeMutableRawPointer, dstW: Int, dstH: Int, dstRowBytes: Int,
        flags: vImage_Flags
    ) throws {
        var srcBuf = vImage_Buffer(
            data: srcBase,
            height: vImagePixelCount(srcH),
            width: vImagePixelCount(srcW),
            rowBytes: srcRowBytes)
        var dstBuf = vImage_Buffer(
            data: dstBase,
            height: vImagePixelCount(dstH),
            width: vImagePixelCount(dstW),
            rowBytes: dstRowBytes)
        // `_ARGB8888` operates on any 4-channel-8-bit buffer — channel
        // order is irrelevant since scaling is per-channel. BGRA works
        // identically. `nil` tempBuffer lets vImage allocate its own
        // scratch space per call; for the standalone helper this is
        // fine. The Phase E pipeline-side resizer reuses tempBuffer
        // across frames; that's a separate optimization.
        let result = vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, flags)
        guard result == kvImageNoError else {
            throw FrameResizerError.vImageError(result)
        }
    }

    // MARK: - Nearest-neighbour (manual)

    /// Nearest-neighbour scale via the canonical
    /// `srcX = outX * srcW / dstW` integer formula. Preserves hard
    /// edges (pixel-art) — the contract `.nearest` is meant to
    /// fulfill. Per-output-pixel cost is one memory access; no
    /// arithmetic on the channel data.
    private static func nearestScale(
        srcBase: UnsafeMutableRawPointer, srcW: Int, srcH: Int, srcRowBytes: Int,
        dstBase: UnsafeMutableRawPointer, dstW: Int, dstH: Int, dstRowBytes: Int
    ) {
        let src = srcBase.assumingMemoryBound(to: UInt8.self)
        let dst = dstBase.assumingMemoryBound(to: UInt8.self)
        // Each pixel is 4 bytes (BGRA).
        for y in 0..<dstH {
            let srcY = (y * srcH) / dstH
            let srcRow = src.advanced(by: srcY * srcRowBytes)
            let dstRow = dst.advanced(by: y * dstRowBytes)
            for x in 0..<dstW {
                let srcX = (x * srcW) / dstW
                let s = srcRow.advanced(by: srcX * 4)
                let d = dstRow.advanced(by: x * 4)
                // Per-pixel 4-byte copy. memcpy would be a function
                // call; manual unroll keeps the inner loop tight.
                d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3]
            }
        }
    }
}
