// SPDX-License-Identifier: MIT
/*
 * FrameCropper.swift — Crop Release Phase F.
 *
 * Pure-BGRA pixel-region copy primitive. Given a source `PixelFrame`
 * (CVPixelBuffer-backed 32BGRA) and a source-pixel-space CGRect,
 * returns a new PixelFrame at the cropped dimensions whose bytes are
 * the rect's BGRA region of the source — row-wise memcpy, no
 * resampling, no framework calls beyond the CVPixelBuffer API.
 *
 * Ordering (CROP_PLAN.md L2)
 * ──────────────────────────
 * The pipeline runs crop BEFORE resize when both are set:
 *
 *     read → crop → resize → encode
 *
 * `EncodePipeline` calls `OutputSize.resolvedDimensions(...)` with the
 * post-crop dims so a `.original` outputSize means "encode at the
 * cropped dims," and a non-`.original` outputSize means "resize the
 * cropped frame to that target." This file is the leaf primitive;
 * ordering and resolver-threading live in `EncodePipeline`.
 *
 * Coordinate convention (CROP_PLAN.md Q2)
 * ───────────────────────────────────────
 * `rect` is in source-pixel space, top-left origin: `rect.minY = 0`
 * is the top row of source pixels. Top-left throughout — no flips,
 * no Y-axis inversion at any point in the crop path.
 *
 * Trust contract (CROP_PLAN.md L3 + §4c)
 * ──────────────────────────────────────
 * The cropper TRUSTS its caller for rect validity:
 *   - integer-valued coords (no fractional sub-pixel),
 *   - 4-pixel-aligned (minX, minY, width, height all `% 4 == 0`),
 *   - fully inside the source (`minX ≥ 0`, `maxX ≤ sourceW`, …),
 *   - positive width and height.
 *
 * Validation lives in `EncodePipeline`, which throws
 * `PipelineError.misalignedCropDimensions` /
 * `.cropRectOutOfBounds` at the loop boundary BEFORE the cropper
 * ever runs. The leaf primitive stays a leaf — same trust pattern
 * `FrameResizer` uses for its target dims.
 *
 * Buffer ownership
 * ────────────────
 * The returned PixelFrame is backed by a freshly-allocated
 * CVPixelBuffer — never a reference into the source. The caller may
 * release or mutate the source buffer after this returns without
 * affecting the cropper's output.
 *
 * Codec-agnostic
 * ──────────────
 * The cropper operates on the BGRA frame BEFORE the encoder sees it,
 * so DXV3 (DXT1/DXT5/YCG6/YG10) and HAP variants share the same crop
 * path with no per-codec branching (CROP_PLAN.md §5).
 */

import Foundation
import CoreVideo
import CoreMedia
import CoreGraphics

public enum FrameCropperError: Error, CustomStringConvertible {
    case pixelBufferAllocationFailed(CVReturn)

    public var description: String {
        switch self {
        case .pixelBufferAllocationFailed(let r):
            return "FrameCropper: CVPixelBufferCreate failed (\(r))"
        }
    }
}

public enum FrameCropper {

    /// Crop `frame` to the source-pixel-space sub-rect `rect`. The
    /// returned PixelFrame is at `(rect.width, rect.height)`, owns
    /// its own buffer (no source aliasing), and inherits the source's
    /// `presentationTime` and `alphaInfo`. `codedWidth` / `codedHeight`
    /// default to the cropped dims; padding to a 16-multiple for the
    /// downstream encoder is the encoder's own job (FrameResizer
    /// follows the same default).
    ///
    /// Throws only on CVPixelBuffer allocation failure, which under
    /// normal memory conditions does not happen — but mirroring
    /// FrameResizer's `throws` keeps the failure surface explicit
    /// rather than silently returning a zero frame.
    public static func crop(_ frame: PixelFrame, to rect: CGRect) throws -> PixelFrame {
        let dstW = Int(rect.width)
        let dstH = Int(rect.height)
        let xOff = Int(rect.minX)
        let yOff = Int(rect.minY)

        let dstBuffer = try makeBGRABuffer(width: dstW, height: dstH)

        CVPixelBufferLockBaseAddress(frame.pixelBuffer, .readOnly)
        CVPixelBufferLockBaseAddress(dstBuffer, [])
        defer {
            CVPixelBufferUnlockBaseAddress(frame.pixelBuffer, .readOnly)
            CVPixelBufferUnlockBaseAddress(dstBuffer, [])
        }

        guard let srcBase = CVPixelBufferGetBaseAddress(frame.pixelBuffer),
              let dstBase = CVPixelBufferGetBaseAddress(dstBuffer) else {
            throw FrameCropperError.pixelBufferAllocationFailed(kCVReturnAllocationFailed)
        }
        let srcRowBytes = CVPixelBufferGetBytesPerRow(frame.pixelBuffer)
        let dstRowBytes = CVPixelBufferGetBytesPerRow(dstBuffer)
        let copyBytesPerRow = dstW * 4

        // Row-by-row memcpy from `(xOff, yOff)` in source to (0, 0) in
        // dest. Either buffer may have a per-row stride larger than
        // `width * 4` (CV pads rows for alignment); only the leading
        // `copyBytesPerRow` are written per dst row, the trailing
        // padding is whatever `CVPixelBufferCreate` initialized (zero
        // for a fresh allocation) and never reaches the encoder since
        // the encoder reads `width * 4` per row.
        for y in 0..<dstH {
            let srcRow = srcBase.advanced(by: (yOff + y) * srcRowBytes + xOff * 4)
            let dstRow = dstBase.advanced(by: y * dstRowBytes)
            memcpy(dstRow, srcRow, copyBytesPerRow)
        }

        return PixelFrame(
            pixelBuffer: dstBuffer,
            presentationTime: frame.presentationTime,
            codedWidth: nil,
            codedHeight: nil,
            alphaInfo: frame.alphaInfo)
    }

    // MARK: - Helpers

    /// Mirror of `FrameResizer.makeBGRABuffer`: IOSurface-backed
    /// 32BGRA CVPixelBuffer at the requested dimensions. Same
    /// `kCVPixelBufferIOSurfacePropertiesKey` so downstream consumers
    /// (e.g. `DxvSourceReader`'s wrap path) treat cropped frames
    /// identically to resized ones.
    private static func makeBGRABuffer(width: Int, height: Int) throws -> CVPixelBuffer {
        var pb: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw FrameCropperError.pixelBufferAllocationFailed(status)
        }
        return buf
    }
}
