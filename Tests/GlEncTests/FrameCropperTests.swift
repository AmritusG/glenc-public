/*
 * FrameCropperTests — Crop Release Phase F.
 *
 * Byte-exact property tests for the FrameCropper primitive. Crop is a
 * pure row-wise memcpy, so every assertion here is exact equality —
 * no tolerance. Coverage:
 *
 *   - Identity crop (full frame) — output bytes == source bytes.
 *   - Top-left sub-rect — exercises the basic row arithmetic with
 *     zero `xOff` / `yOff`.
 *   - Offset sub-rect — non-zero `xOff` AND `yOff`, exercises both
 *     the column- and row-offset arithmetic.
 *   - 1080p centered 720p crop — realistic dim per the v0.9.1 H.3
 *     standing rule ("the bug that bites is the 1080p one").
 *   - 4-pixel-minimum crop — smallest legal crop, top-left corner.
 *   - Near-boundary crop — bottom-right 4×4, catches off-by-one in
 *     `(yOff + y) * srcRowBytes + xOff * 4`.
 *   - Source-buffer-not-aliased guarantee — after the cropper
 *     returns, mutating the source must not affect the cropped
 *     output.
 *
 * All synthetic source pixels follow a known formula so the test can
 * assert specific byte values rather than just "non-empty." The
 * FrameResizerTests' makeFrame / readPixel / bytes helpers are
 * mirrored exactly — same shape so a reader who knows one knows the
 * other.
 *
 * Validation (4-pixel alignment, in-bounds) is `EncodePipeline`'s
 * job — the cropper trusts its caller. Those error paths are
 * exercised by integration tests against the pipeline, not here.
 */

import XCTest
import Foundation
import CoreVideo
import CoreMedia
import CoreGraphics
@testable import GlEncCore

final class FrameCropperTests: XCTestCase {

    // MARK: - Synthesis (mirror of FrameResizerTests' helpers)

    /// Build a BGRA PixelFrame at `(width, height)` filled by
    /// `pixelFn(x, y) -> (B, G, R, A)`.
    private func makeFrame(
        width: Int, height: Int,
        alphaInfo: CGImageAlphaInfo = .last,
        pixelFn: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)
    ) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "FrameCropperTest", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            let row = base.advanced(by: y * bpr)
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                let (b, g, r, a) = pixelFn(x, y)
                p[0] = b; p[1] = g; p[2] = r; p[3] = a
            }
        }
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero,
                          alphaInfo: alphaInfo)
    }

    private func readPixel(_ f: PixelFrame, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        CVPixelBufferLockBaseAddress(f.pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(f.pixelBuffer, .readOnly) }
        let base = CVPixelBufferGetBaseAddress(f.pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(f.pixelBuffer)
        let p = base.advanced(by: y * bpr + x * 4)
        return (p[0], p[1], p[2], p[3])
    }

    /// Mutate the source frame's byte at `(x, y)` channel `ch` to
    /// `value`. Used by the no-aliasing test to prove the cropped
    /// output owns its own bytes.
    private func setPixelByte(_ f: PixelFrame, x: Int, y: Int, ch: Int, value: UInt8) {
        CVPixelBufferLockBaseAddress(f.pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(f.pixelBuffer, []) }
        let base = CVPixelBufferGetBaseAddress(f.pixelBuffer)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(f.pixelBuffer)
        base.advanced(by: y * bpr + x * 4 + ch).pointee = value
    }

    /// The canonical synthetic pattern: pixel (x, y) has bytes
    /// (B=x & 0xFF, G=y & 0xFF, R=(x+y) & 0xFF, A=0xFF). Lets each
    /// test predict the byte at every (x, y) without storing the
    /// source.
    private func gradientPixel(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        (UInt8(x & 0xFF), UInt8(y & 0xFF), UInt8((x + y) & 0xFF), 0xFF)
    }

    // MARK: - 1. Identity crop (full frame)

    func testIdentityCrop_FullFrame_BytesMatch() throws {
        let src = try makeFrame(width: 64, height: 64, pixelFn: gradientPixel)
        let out = try FrameCropper.crop(src,
            to: CGRect(x: 0, y: 0, width: 64, height: 64))
        XCTAssertEqual(out.width, 64)
        XCTAssertEqual(out.height, 64)
        // Every pixel must match the gradient.
        for y in 0..<64 {
            for x in 0..<64 {
                let (b, g, r, a) = readPixel(out, x: x, y: y)
                let (eb, eg, er, ea) = gradientPixel(x, y)
                XCTAssertEqual(b, eb, "B at (\(x),\(y))")
                XCTAssertEqual(g, eg, "G at (\(x),\(y))")
                XCTAssertEqual(r, er, "R at (\(x),\(y))")
                XCTAssertEqual(a, ea, "A at (\(x),\(y))")
            }
        }
    }

    // MARK: - 2. Top-left sub-rect (xOff == yOff == 0)

    func testTopLeftSubRect_32x32_From_64x64() throws {
        let src = try makeFrame(width: 64, height: 64, pixelFn: gradientPixel)
        let out = try FrameCropper.crop(src,
            to: CGRect(x: 0, y: 0, width: 32, height: 32))
        XCTAssertEqual(out.width, 32)
        XCTAssertEqual(out.height, 32)
        for y in 0..<32 {
            for x in 0..<32 {
                XCTAssertEqual(
                    readPixel(out, x: x, y: y).0, gradientPixel(x, y).0,
                    "B at (\(x),\(y)) must match source(\(x),\(y))")
            }
        }
    }

    // MARK: - 3. Offset sub-rect (xOff > 0, yOff > 0)

    /// Crop rect (16, 16, 32, 32). The output pixel at (0, 0) must
    /// equal the source pixel at (16, 16). Exercises BOTH the column
    /// offset (`xOff * 4`) and the row offset (`(yOff + y) * srcRowBytes`).
    func testOffsetSubRect_16_16_32x32() throws {
        let src = try makeFrame(width: 64, height: 64, pixelFn: gradientPixel)
        let out = try FrameCropper.crop(src,
            to: CGRect(x: 16, y: 16, width: 32, height: 32))
        XCTAssertEqual(out.width, 32)
        XCTAssertEqual(out.height, 32)
        for y in 0..<32 {
            for x in 0..<32 {
                let (b, g, r, a) = readPixel(out, x: x, y: y)
                let (eb, eg, er, ea) = gradientPixel(x + 16, y + 16)
                XCTAssertEqual(b, eb, "B at (\(x),\(y)) must equal source(\(x+16),\(y+16))")
                XCTAssertEqual(g, eg, "G at (\(x),\(y)) must equal source(\(x+16),\(y+16))")
                XCTAssertEqual(r, er, "R at (\(x),\(y)) must equal source(\(x+16),\(y+16))")
                XCTAssertEqual(a, ea, "A at (\(x),\(y)) must equal source(\(x+16),\(y+16))")
            }
        }
    }

    // MARK: - 4. Realistic dim: 1080p source, centered 720p crop

    /// The v0.9.1 H.3 standing rule: realistic dims from day one. A
    /// centered 1280×720 crop of a 1920×1080 source — the "centered
    /// 720p of 1080p" the integration test will exercise end-to-end.
    /// Sampled (not exhaustive) because comparing 2 MP of pixels per
    /// run extends the suite for no extra signal.
    func testRealisticCrop_1080p_Centered720p() throws {
        let src = try makeFrame(width: 1920, height: 1080, pixelFn: gradientPixel)
        let out = try FrameCropper.crop(src,
            to: CGRect(x: 320, y: 180, width: 1280, height: 720))
        XCTAssertEqual(out.width, 1280)
        XCTAssertEqual(out.height, 720)
        // Sample the four corners and the center of the output rect.
        let samples: [(Int, Int)] = [
            (0, 0), (1279, 0), (0, 719), (1279, 719), (640, 360),
        ]
        for (x, y) in samples {
            let (b, g, r, a) = readPixel(out, x: x, y: y)
            let (eb, eg, er, ea) = gradientPixel(x + 320, y + 180)
            XCTAssertEqual(b, eb, "B at (\(x),\(y))")
            XCTAssertEqual(g, eg, "G at (\(x),\(y))")
            XCTAssertEqual(r, er, "R at (\(x),\(y))")
            XCTAssertEqual(a, ea, "A at (\(x),\(y))")
        }
    }

    // MARK: - 5. 4-pixel minimum crop

    func testMinimumCrop_4x4_AtOrigin() throws {
        let src = try makeFrame(width: 64, height: 64, pixelFn: gradientPixel)
        let out = try FrameCropper.crop(src,
            to: CGRect(x: 0, y: 0, width: 4, height: 4))
        XCTAssertEqual(out.width, 4)
        XCTAssertEqual(out.height, 4)
        for y in 0..<4 {
            for x in 0..<4 {
                let (b, g, _, _) = readPixel(out, x: x, y: y)
                XCTAssertEqual(b, UInt8(x & 0xFF))
                XCTAssertEqual(g, UInt8(y & 0xFF))
            }
        }
    }

    // MARK: - 6. Near-boundary crop (bottom-right 4×4)

    /// Crop rect (60, 60, 4, 4) — the bottom-right 4×4 of a 64×64
    /// source. Catches off-by-one in the row/column offset arithmetic
    /// where `(yOff + y) * srcRowBytes + xOff * 4` is exercised at its
    /// maximum legal indices.
    func testNearBoundaryCrop_BottomRight4x4() throws {
        let src = try makeFrame(width: 64, height: 64, pixelFn: gradientPixel)
        let out = try FrameCropper.crop(src,
            to: CGRect(x: 60, y: 60, width: 4, height: 4))
        XCTAssertEqual(out.width, 4)
        XCTAssertEqual(out.height, 4)
        for y in 0..<4 {
            for x in 0..<4 {
                let (b, g, r, _) = readPixel(out, x: x, y: y)
                let (eb, eg, er, _) = gradientPixel(x + 60, y + 60)
                XCTAssertEqual(b, eb)
                XCTAssertEqual(g, eg)
                XCTAssertEqual(r, er)
            }
        }
    }

    // MARK: - 7. Source buffer is not aliased

    /// After cropping, mutate the source buffer's pixels covering the
    /// cropped region. The cropped output must NOT reflect the
    /// mutation — proves `FrameCropper` allocates and copies, never
    /// returns a view into the source. (CVPixelBuffer is a class /
    /// retained object, so this catches the "I held a reference"
    /// failure mode as well as "I returned the same buffer.")
    func testSourceBufferNotAliased() throws {
        let src = try makeFrame(width: 64, height: 64, pixelFn: gradientPixel)
        let out = try FrameCropper.crop(src,
            to: CGRect(x: 16, y: 16, width: 16, height: 16))
        // Mutate every pixel of the source that the crop covered to a
        // distinctive sentinel (B=0xAA, G=0xBB, R=0xCC, A=0xDD).
        for y in 16..<32 {
            for x in 16..<32 {
                setPixelByte(src, x: x, y: y, ch: 0, value: 0xAA)
                setPixelByte(src, x: x, y: y, ch: 1, value: 0xBB)
                setPixelByte(src, x: x, y: y, ch: 2, value: 0xCC)
                setPixelByte(src, x: x, y: y, ch: 3, value: 0xDD)
            }
        }
        // The cropped output must still read as the pre-mutation
        // gradient — its buffer is independent of the source.
        for y in 0..<16 {
            for x in 0..<16 {
                let (b, g, r, a) = readPixel(out, x: x, y: y)
                let (eb, eg, er, ea) = gradientPixel(x + 16, y + 16)
                XCTAssertEqual(b, eb, "B at (\(x),\(y))")
                XCTAssertEqual(g, eg, "G at (\(x),\(y))")
                XCTAssertEqual(r, er, "R at (\(x),\(y))")
                XCTAssertEqual(a, ea, "A at (\(x),\(y))")
                XCTAssertNotEqual(b, 0xAA, "cropped output is aliased to source")
            }
        }
    }
}
