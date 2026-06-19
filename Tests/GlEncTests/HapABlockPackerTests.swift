/*
 * HapABlockPackerTests — v0.9.2 Phase B.
 *
 * Validates the HapA BC4 alpha block packer:
 *   - Alpha-plane extraction from BGRA
 *   - BC4 output stream sizing (8 bytes/block, coded at 4-pixel
 *     alignment per Q3)
 *   - 4-pixel-native padding (vs v0.9.1's 16-pixel HapY/Hap5/Hap1)
 *   - Alpha round-trip via an inline BC4 decoder (mirrors GlanceCore's
 *     `BC4BC5Unpack.unpackBC4Plane` — that helper is public on Glance
 *     main but internal at the v0.5.0 pin GlEnc uses, so we inline a
 *     small reference decoder here, same pattern v0.9.1 used for the
 *     HAP section parser)
 *   - Each AlphaNormalization mode wired correctly (forceOpaque /
 *     straightThrough / unpremultiply)
 */

import XCTest
import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
@testable import GlEncCore

@MainActor
final class HapABlockPackerTests: XCTestCase {

    // MARK: - Synthesis helpers

    /// Build a BGRA CVPixelBuffer with per-pixel alpha given by
    /// `alphaFn(x, y)`. RGB is constant mid-grey so the alpha is the
    /// only signal.
    private func framePerPixelAlpha(
        width: Int, height: Int,
        alphaInfo: CGImageAlphaInfo = .last,
        alphaFn: (Int, Int) -> UInt8
    ) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "HapAPackerTest", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            let row = base.advanced(by: y * bpr)
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                p[0] = 0x80; p[1] = 0x80; p[2] = 0x80
                p[3] = alphaFn(x, y)
            }
        }
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero,
                          alphaInfo: alphaInfo)
    }

    /// Build a BGRA frame with constant alpha per row half (top opaque,
    /// bottom transparent — the BC4 alpha-preservation pattern).
    private func halfAlphaFrame(width: Int, height: Int) throws -> PixelFrame {
        return try framePerPixelAlpha(width: width, height: height) { _, y in
            y < height / 2 ? 0xFF : 0x00
        }
    }

    // MARK: - Output size

    func testBC4BlockStreamSize_AtMultipleOf4() throws {
        let packer = HapABlockPacker()
        packer.prepare(width: 64, height: 64)
        let frame = try halfAlphaFrame(width: 64, height: 64)
        let blocks = try packer.packBlocks(frame: frame)
        // 64/4 × 64/4 = 256 blocks × 8 B = 2048 B.
        XCTAssertEqual(blocks.count, 2048)
    }

    func testBC4BlockStreamSize_AtNonMultipleOf4_PadsTo4() throws {
        let packer = HapABlockPacker()
        // 254×254 → padded coded 256×256 (next 4-multiple).
        packer.prepare(width: 254, height: 254)
        let frame = try framePerPixelAlpha(width: 254, height: 254) { x, _ in UInt8(x & 0xFF) }
        let blocks = try packer.packBlocks(frame: frame)
        // (256/4)² = 4096 blocks × 8 = 32768 B.
        XCTAssertEqual(blocks.count, 32768)
    }

    // MARK: - Padding alignment (Q3: 4-pixel, NOT 16-pixel)

    /// 1080 = 270 × 4 → already 4-aligned → coded should be 1080.
    /// This is the key difference from v0.9.1's HapY/Hap5/Hap1 which
    /// over-pad 1080 to 1088. C.5 will tighten them; HapA is born
    /// correct here.
    func test1080pHeight_NotOverPaddedTo1088() throws {
        let packer = HapABlockPacker()
        packer.prepare(width: 1920, height: 1080)
        let frame = try halfAlphaFrame(width: 1920, height: 1080)
        let blocks = try packer.packBlocks(frame: frame)
        // 1920×1080 at 4-pixel alignment: (1920/4) × (1080/4) = 480 × 270
        // = 129,600 blocks × 8 = 1,036,800 B.
        // If wrongly padded to 1920×1088 (16-pixel): 480 × 272 = 130,560
        // blocks × 8 = 1,044,480 B (+0.74% overhead).
        XCTAssertEqual(blocks.count, 1_036_800,
                       "1080 must stay at 4-aligned coded height, not be widened to 1088")
    }

    // MARK: - Round-trip via GlanceCore BC4 decoder

    /// Encode a half-alpha frame (top α=255 / bottom α=0), decode the
    /// BC4 blocks back, assert the alpha pattern survives. BC4 is
    /// single-channel 8-bit with high fidelity; a uniform top half +
    /// uniform bottom half round-trips effectively losslessly (each
    /// 4×4 tile is uniform → BC4 emits a single endpoint per tile).
    func testHalfAlphaRoundTripViaBC4() throws {
        let w = 64
        let h = 64
        let packer = HapABlockPacker()
        packer.prepare(width: w, height: h)
        let frame = try halfAlphaFrame(width: w, height: h)
        let blocks = try packer.packBlocks(frame: frame)

        let alphaOut = unpackBC4Plane(blocks: blocks, width: w, height: h)

        // Top half should be α≈255; bottom should be α≈0. Tolerate
        // BC4 endpoint quantization — uniform tiles should be
        // very close (typically exact).
        for y in 0..<h {
            for x in 0..<w {
                let v = Int(alphaOut[y * w + x])
                if y < h / 2 {
                    XCTAssertGreaterThanOrEqual(v, 240,
                        "top-half pixel (\(x),\(y)) α=\(v) below expected 240")
                } else {
                    XCTAssertLessThanOrEqual(v, 15,
                        "bottom-half pixel (\(x),\(y)) α=\(v) above expected 15")
                }
            }
        }
    }

    /// Gradient PSNR — 64×64 vertical alpha gradient → BC4 → decode →
    /// PSNR vs source. BC4 on a smooth gradient typically clears 40 dB
    /// (8-bit endpoints + 3-bit indices on uniform 4-pixel tile
    /// vertical gradient).
    func testAlphaGradientPSNR() throws {
        let w = 64
        let h = 64
        let packer = HapABlockPacker()
        packer.prepare(width: w, height: h)
        let frame = try framePerPixelAlpha(width: w, height: h) { _, y in
            UInt8((y * 4) & 0xFF)
        }
        let blocks = try packer.packBlocks(frame: frame)
        let alphaOut = unpackBC4Plane(blocks: blocks, width: w, height: h)

        var sumSq: Double = 0
        for y in 0..<h {
            for x in 0..<w {
                let src = Int(UInt8((y * 4) & 0xFF))
                let dec = Int(alphaOut[y * w + x])
                let d = src - dec
                sumSq += Double(d * d)
            }
        }
        let mse = sumSq / Double(w * h)
        let psnr = mse <= 0 ? .infinity : 10.0 * log10(255.0 * 255.0 / mse)
        XCTAssertGreaterThan(psnr, 40.0,
                             "BC4 alpha-gradient round-trip PSNR \(psnr) < 40 dB")
    }

    // MARK: - Normalization modes wired through

    /// Premultiplied source — alpha bytes pass through (un-premultiply
    /// only affects RGB, not α). Verify the packer doesn't crash and
    /// produces the same alpha as straight-through for the same α
    /// bytes.
    func testPremultipliedSource_AlphaBytesPreserved() throws {
        let w = 16, h = 16
        let packerPre = HapABlockPacker()
        packerPre.prepare(width: w, height: h)
        let framePre = try framePerPixelAlpha(width: w, height: h,
                                              alphaInfo: .premultipliedLast) { _, _ in 0x80 }
        let blocksPre = try packerPre.packBlocks(frame: framePre)

        let packerStraight = HapABlockPacker()
        packerStraight.prepare(width: w, height: h)
        let frameStraight = try framePerPixelAlpha(width: w, height: h,
                                                   alphaInfo: .last) { _, _ in 0x80 }
        let blocksStraight = try packerStraight.packBlocks(frame: frameStraight)

        XCTAssertEqual(blocksPre, blocksStraight,
                       "premultiplied vs straight α=128 should produce same BC4 alpha output")
    }

    /// Opaque source (alphaInfo = .none / .noneSkipLast) → forceOpaque
    /// normalization → all α=255 → all-FF BC4 stream (one endpoint
    /// per block at 255).
    func testOpaqueSource_ForcesAlpha255() throws {
        let w = 16, h = 16
        let packer = HapABlockPacker()
        packer.prepare(width: w, height: h)
        let frame = try framePerPixelAlpha(width: w, height: h,
                                           alphaInfo: .noneSkipLast) { _, _ in 0x00 }
        // Note: source α=0 BUT alphaInfo says "no alpha" → forceOpaque
        // overrides to 255.
        let blocks = try packer.packBlocks(frame: frame)

        // Decode and verify all 255.
        let alphaOut = unpackBC4Plane(blocks: blocks, width: w, height: h)
        for v in alphaOut {
            XCTAssertEqual(v, 255,
                           "opaque source must produce α=255 throughout")
        }
    }

    // MARK: - Error paths

    func testNotPreparedThrows() throws {
        let packer = HapABlockPacker()
        let frame = try halfAlphaFrame(width: 16, height: 16)
        XCTAssertThrowsError(try packer.packBlocks(frame: frame)) { e in
            guard case HapABlockPacker.HapAError.notPrepared = e else {
                XCTFail("expected .notPrepared, got \(e)")
                return
            }
        }
    }

    func testUnexpectedFrameDimensionsThrows() throws {
        let packer = HapABlockPacker()
        packer.prepare(width: 16, height: 16)
        let frame = try halfAlphaFrame(width: 32, height: 32)
        XCTAssertThrowsError(try packer.packBlocks(frame: frame)) { e in
            guard case HapABlockPacker.HapAError.unexpectedFrameDimensions = e else {
                XCTFail("expected .unexpectedFrameDimensions, got \(e)")
                return
            }
        }
    }

    // MARK: - Inline BC4 decoder
    //
    // Mirrors GlanceCore.BC4BC5Unpack.unpackBC4Plane byte-for-byte —
    // that helper is public on Glance main but internal at v0.5.0
    // (the pin GlEnc holds). Inlining here keeps the test self-
    // contained without bumping the pin. Same pattern v0.9.1 used
    // for the HAP section header parser.
    //
    // BC4 decode: each 8-byte block stores
    //   bytes 0..1 — a0, a1 endpoint bytes (uint8)
    //   bytes 2..7 — 16 × 3-bit indices, LSB-first (48 bits packed)
    // Two palette modes per the BC4 spec:
    //   a0 > a1  (8-mode): palette[i] = round(a0*(7-i) + a1*i) / 7 for i=0..7
    //   a0 ≤ a1  (6-mode): palette[i] for i=0..5 interpolates a0..a1 in 5 steps;
    //                      palette[6] = 0, palette[7] = 255
    private func unpackBC4Plane(blocks: Data, width: Int, height: Int) -> [UInt8] {
        precondition(width % 4 == 0 && height % 4 == 0,
                     "BC4 unpack requires 4-multiple dims")
        let wBlocks = width / 4
        let hBlocks = height / 4
        var out = [UInt8](repeating: 0, count: width * height)
        for by in 0..<hBlocks {
            for bx in 0..<wBlocks {
                let blockOff = (by * wBlocks + bx) * 8
                let a0 = blocks[blockOff]
                let a1 = blocks[blockOff + 1]
                let palette = bc4Palette(a0: a0, a1: a1)
                // Pack indices bytes 2..7 into a 48-bit value.
                var indices: UInt64 = 0
                for k in 0..<6 {
                    indices |= UInt64(blocks[blockOff + 2 + k]) << (k * 8)
                }
                for py in 0..<4 {
                    for px in 0..<4 {
                        let bitOff = (py * 4 + px) * 3
                        let idx = Int((indices >> bitOff) & 0x07)
                        let pixelX = bx * 4 + px
                        let pixelY = by * 4 + py
                        out[pixelY * width + pixelX] = palette[idx]
                    }
                }
            }
        }
        return out
    }

    private func bc4Palette(a0: UInt8, a1: UInt8) -> [UInt8] {
        var pal = [UInt8](repeating: 0, count: 8)
        pal[0] = a0
        pal[1] = a1
        let a0i = Int(a0)
        let a1i = Int(a1)
        if a0 > a1 {
            // 8-mode: 6 interpolated values.
            for i in 2...7 {
                let num = a0i * (8 - i) + a1i * (i - 1)
                pal[i] = UInt8((num + 3) / 7)  // round to nearest
            }
        } else {
            // 6-mode: 4 interpolated values + {0, 255} at slots 6, 7.
            for i in 2...5 {
                let num = a0i * (6 - i) + a1i * (i - 1)
                pal[i] = UInt8((num + 2) / 5)
            }
            pal[6] = 0
            pal[7] = 255
        }
        return pal
    }
}
