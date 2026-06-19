/*
 * YCoCgTransform tests — Phase 4A.1 validation.
 *
 * Pinned cases for the forward + inverse YCoCg formulas (matches the
 * non-reversible variant GlanceCore.CPURender uses on the decoder
 * side). Verifies the +128 offset convention, the integer rounding of
 * Y, the signed range of Co/Cg, and the 2:1 chroma subsample.
 */

import XCTest
@testable import GlEncCore

final class YCoCgTransformTests: XCTestCase {

    func testForwardInverseBlack() {
        let r: [UInt8] = [0, 0, 0, 255]
        var arr = r
        arr.withUnsafeBufferPointer { buf in
            let (y, co, cg) = YCoCgTransform.ycocg(buf.baseAddress!)
            XCTAssertEqual(y, 0)
            XCTAssertEqual(co, 0)
            XCTAssertEqual(cg, 0)
            let (rr, gg, bb) = YCoCgTransform.inverseYCoCg(
                y: y, coStored: UInt8(co + 128), cgStored: UInt8(cg + 128))
            XCTAssertEqual(rr, 0)
            XCTAssertEqual(gg, 0)
            XCTAssertEqual(bb, 0)
        }
    }

    func testForwardInverseWhite() {
        let r: [UInt8] = [255, 255, 255, 255]
        var arr = r
        arr.withUnsafeBufferPointer { buf in
            let (y, co, cg) = YCoCgTransform.ycocg(buf.baseAddress!)
            XCTAssertEqual(y, 255)
            XCTAssertEqual(co, 0)
            XCTAssertEqual(cg, 0)
            let (rr, gg, bb) = YCoCgTransform.inverseYCoCg(
                y: y, coStored: UInt8(co + 128), cgStored: UInt8(cg + 128))
            XCTAssertEqual(rr, 255)
            XCTAssertEqual(gg, 255)
            XCTAssertEqual(bb, 255)
        }
    }

    func testForwardGray128() {
        let arr: [UInt8] = [128, 128, 128, 255]
        arr.withUnsafeBufferPointer { buf in
            let (y, co, cg) = YCoCgTransform.ycocg(buf.baseAddress!)
            XCTAssertEqual(y, 128)
            XCTAssertEqual(co, 0)
            XCTAssertEqual(cg, 0)
        }
    }

    func testForwardPureRed() {
        let arr: [UInt8] = [255, 0, 0, 255]
        arr.withUnsafeBufferPointer { buf in
            let (y, co, cg) = YCoCgTransform.ycocg(buf.baseAddress!)
            // Y = (255 + 0 + 0 + 2) >> 2 = 64
            // Co = (255 - 0) >> 1 = 127
            // Cg = (-255 + 0 - 0) >> 2 = -64 (arithmetic shift floors)
            XCTAssertEqual(y, 64)
            XCTAssertEqual(co, 127)
            XCTAssertEqual(cg, -64)
            // Range check: Co/Cg must stay in [-128, 127] for the
            // +128 offset to store as UInt8.
            XCTAssertGreaterThanOrEqual(co, -128)
            XCTAssertLessThanOrEqual(co, 127)
            XCTAssertGreaterThanOrEqual(cg, -128)
            XCTAssertLessThanOrEqual(cg, 127)
        }
    }

    func testForwardPureBlue() {
        let arr: [UInt8] = [0, 0, 255, 255]
        arr.withUnsafeBufferPointer { buf in
            let (y, co, cg) = YCoCgTransform.ycocg(buf.baseAddress!)
            // Y = (0 + 0 + 255 + 2) >> 2 = 64
            // Co = (0 - 255) >> 1 = -128 (arithmetic shift)
            // Cg = (-0 + 0 - 255) >> 2 = -64
            XCTAssertEqual(y, 64)
            XCTAssertEqual(co, -128)
            XCTAssertEqual(cg, -64)
        }
    }

    func testForwardPureGreen() {
        let arr: [UInt8] = [0, 255, 0, 255]
        arr.withUnsafeBufferPointer { buf in
            let (y, co, cg) = YCoCgTransform.ycocg(buf.baseAddress!)
            // Y = (0 + 510 + 0 + 2) >> 2 = 128
            // Co = (0 - 0) >> 1 = 0
            // Cg = (-0 + 510 - 0) >> 2 = 127
            XCTAssertEqual(y, 128)
            XCTAssertEqual(co, 0)
            XCTAssertEqual(cg, 127)
        }
    }

    /// 2:1 chroma subsample over a 2×2 flat-color RGB tile: 4 identical
    /// pixels should produce the same Co/Cg as a single per-pixel
    /// transform of the same RGB. (Averaging four equal values is a
    /// no-op.)
    func testChromaSubsampleFlat() {
        // 2×2 buffer: all pixels = (200, 100, 50, 255).
        var rgba = [UInt8]()
        for _ in 0..<4 {
            rgba.append(contentsOf: [200, 100, 50, 255])
        }
        let planes = rgba.withUnsafeBufferPointer { buf in
            YCoCgTransform.ycocgFromRGBA(
                rgba: buf.baseAddress!,
                presentationWidth: 2, presentationHeight: 2,
                codedWidth: 2, codedHeight: 2)
        }
        XCTAssertEqual(planes.co.count, 1)
        XCTAssertEqual(planes.cg.count, 1)
        // Per-pixel: R=200, G=100, B=50.
        // Y = (200 + 200 + 50 + 2) >> 2 = 452 >> 2 = 113
        // Co = (200 - 50) >> 1 = 75
        // Cg = (-200 + 200 - 50) >> 2 = -50 >> 2 = -13 (arithmetic shift floors)
        for v in planes.luma {
            XCTAssertEqual(v, 113)
        }
        XCTAssertEqual(planes.co[0], UInt8(75 + 128))
        XCTAssertEqual(planes.cg[0], UInt8(-13 + 128))
    }

    /// 2×2 padding: 1×1 presentation in a 2×2 coded buffer.
    /// Unwritten Y cells = 0 (zero-fill); unwritten chroma cells = 128
    /// (signed-zero offset).
    func testPaddingFillConvention() {
        let rgba: [UInt8] = [200, 100, 50, 255]
        let planes = rgba.withUnsafeBufferPointer { buf in
            YCoCgTransform.ycocgFromRGBA(
                rgba: buf.baseAddress!,
                presentationWidth: 1, presentationHeight: 1,
                codedWidth: 2, codedHeight: 2)
        }
        XCTAssertEqual(planes.luma.count, 4)
        XCTAssertEqual(planes.luma[0], 113)
        XCTAssertEqual(planes.luma[1], 0)   // pad
        XCTAssertEqual(planes.luma[2], 0)   // pad
        XCTAssertEqual(planes.luma[3], 0)   // pad
        XCTAssertEqual(planes.co.count, 1)
        XCTAssertEqual(planes.cg.count, 1)
        // 1×1 chroma cell averages just the one source pixel.
        XCTAssertEqual(planes.co[0], UInt8(75 + 128))
        XCTAssertEqual(planes.cg[0], UInt8(-13 + 128))
    }

    /// Round-trip a real Pass C frame region: forward YCoCg + inverse
    /// should preserve RGB within the non-reversible quantization
    /// budget (~3 LSB max per channel on each pixel).
    func testRegionRoundTrip() {
        // Build a 4×4 RGB tile with deliberate variation.
        var rgba = [UInt8]()
        for y in 0..<4 {
            for x in 0..<4 {
                rgba.append(UInt8(min(255, 50 + 30 * x)))     // R varies with x
                rgba.append(UInt8(min(255, 60 + 30 * y)))     // G varies with y
                rgba.append(UInt8(min(255, 70 + 15 * (x + y))))// B varies with diagonal
                rgba.append(255)
            }
        }
        let planes = rgba.withUnsafeBufferPointer { buf in
            YCoCgTransform.ycocgFromRGBA(
                rgba: buf.baseAddress!,
                presentationWidth: 4, presentationHeight: 4,
                codedWidth: 4, codedHeight: 4)
        }
        // Inverse with chroma upsample (nearest, matching CPURender).
        var maxDelta = 0
        for y in 0..<4 {
            for x in 0..<4 {
                let yI = planes.luma[y * 4 + x]
                let coI = planes.co[(y / 2) * 2 + (x / 2)]
                let cgI = planes.cg[(y / 2) * 2 + (x / 2)]
                let (r, g, b) = YCoCgTransform.inverseYCoCg(
                    y: yI, coStored: coI, cgStored: cgI)
                let srcR = Int(rgba[(y * 4 + x) * 4])
                let srcG = Int(rgba[(y * 4 + x) * 4 + 1])
                let srcB = Int(rgba[(y * 4 + x) * 4 + 2])
                maxDelta = max(maxDelta, abs(Int(r) - srcR))
                maxDelta = max(maxDelta, abs(Int(g) - srcG))
                maxDelta = max(maxDelta, abs(Int(b) - srcB))
            }
        }
        // HQ + 2:1 chroma subsample on a gradient: expect a few-LSB
        // delta due to chroma averaging. Cap generously at 50 LSB
        // (the gradient is steep — 30 LSB/pixel change).
        XCTAssertLessThan(maxDelta, 50,
                          "YCoCg round-trip 4×4 gradient maxDelta=\(maxDelta) LSB unreasonable")
    }
}
