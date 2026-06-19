/*
 * BC4 single-channel block encoder tests.
 *
 * Round-trip checks (encode → decodeBC4Block) verify the encoder picks
 * sane endpoints. BC4 is a lossy codec but for flat regions the
 * round-trip should be exact; for gradients we assert max |Δ| ≤ 4 LSB
 * which is well within BC4's fundamental representation noise floor on
 * 8-bit alpha sources.
 */

import XCTest
@testable import GlEncCore

final class BC4AlphaBlockEncoderTests: XCTestCase {

    func testFlatBlockExact() throws {
        // All 16 pixels = 128. Decoded block should be all 128.
        let input = [UInt8](repeating: 128, count: 16)
        let decoded = roundTrip(input: input)
        XCTAssertEqual(decoded, input, "flat block should round-trip exactly")
    }

    func testFlatZero() throws {
        let input = [UInt8](repeating: 0, count: 16)
        let decoded = roundTrip(input: input)
        XCTAssertEqual(decoded, input)
    }

    func testFlat255() throws {
        let input = [UInt8](repeating: 255, count: 16)
        let decoded = roundTrip(input: input)
        XCTAssertEqual(decoded, input)
    }

    func testTwoToneBlock() throws {
        // Half 0, half 255. Endpoints should span the full range; result
        // should round-trip exactly via either palette index 6/7 (6-mode)
        // or by matching to endpoints (8-mode).
        var input = [UInt8](repeating: 0, count: 16)
        for i in 8..<16 { input[i] = 255 }
        let decoded = roundTrip(input: input)
        XCTAssertEqual(decoded, input, "binary {0, 255} block should round-trip exact")
    }

    func testLinearGradientUnderQuantizationFloor() throws {
        // 16-step ramp 0..240 in steps of 16. BC4 with 8 levels can
        // represent this within ~16/2 = 8 LSB at worst; with our
        // simple endpoint pick (max=240, min=0) the 8-mode palette
        // covers 0, 240, 206, 172, 137, 103, 69, 34 — error ≤ ~17.
        // We assert max delta ≤ 18 LSB (loose), mean ≤ 9 LSB.
        var input = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { input[i] = UInt8(i * 16) }
        let decoded = roundTrip(input: input)
        var maxD = 0
        var totD = 0
        for i in 0..<16 {
            let d = abs(Int(decoded[i]) - Int(input[i]))
            if d > maxD { maxD = d }
            totD += d
        }
        let meanD = Double(totD) / 16.0
        print("[bc4 grad] max=\(maxD) mean=\(meanD)")
        XCTAssertLessThanOrEqual(maxD, 18, "grad max delta higher than expected")
        XCTAssertLessThanOrEqual(meanD, 9.0, "grad mean delta higher than expected")
    }

    func testEightModeForUnclamped() throws {
        // Source has no 0 or 255 pixels — encoder should produce 8-mode
        // (a0 > a1).
        let input: [UInt8] = [
            32, 64, 96, 128,
            32, 64, 96, 128,
            32, 64, 96, 128,
            32, 64, 96, 128,
        ]
        var dst = [UInt8](repeating: 0, count: 8)
        input.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { d in
                encodeBC4Block(block: src.baseAddress!, stride: 4, dst: d.baseAddress!)
            }
        }
        XCTAssertGreaterThan(dst[0], dst[1], "expected 8-mode (a0 > a1) for unclamped source")
    }

    func testReasonableReconstructionForClampedSource() throws {
        // Source uses 0, 255, plus a few mid values. Originally this
        // test asserted that the encoder picks 6-mode (a0 ≤ a1) so
        // that 0/255 round-trip via reserved palette[6]/[7] exactly.
        // Phase 5C.3's refined encoder optimizes total squared error
        // across all 16 pixels and may pick 8-mode endpoints (255, 0)
        // — total err = 8 × (128−146)² = 2,592 — over 6-mode (0, 255)
        // — total err = 8 × (128−153)² = 5,000. The lower total error
        // wins; the cost is ~3 LSB on the 255 boundary value.
        //
        // Both behaviors produce sane reconstructions. This test now
        // gates on quality bounds rather than mode choice or exact
        // endpoint preservation.
        let input: [UInt8] = [
            0,   0,   0,   0,
            128, 128, 128, 128,
            128, 128, 128, 128,
            255, 255, 255, 255,
        ]
        var dst = [UInt8](repeating: 0, count: 8)
        input.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { d in
                encodeBC4Block(block: src.baseAddress!, stride: 4, dst: d.baseAddress!)
            }
        }
        let decoded = decodeBC4Block(src: { () -> UnsafePointer<UInt8> in
            return dst.withUnsafeBufferPointer { $0.baseAddress! }
        }())
        // Boundary values 0 and 255 within ≤ 8 LSB (refined may shift
        // endpoints inward to minimize total error).
        XCTAssertLessThanOrEqual(abs(Int(decoded[0]) -   0), 8,
                                 "0 boundary should reconstruct within 8 LSB")
        XCTAssertLessThanOrEqual(abs(Int(decoded[12]) - 255), 8,
                                 "255 boundary should reconstruct within 8 LSB")
        // Mid value (128) within ≤ 20 LSB either way.
        XCTAssertLessThanOrEqual(abs(Int(decoded[4]) - 128), 20)
    }

    // MARK: - Helpers

    private func roundTrip(input: [UInt8]) -> [UInt8] {
        precondition(input.count == 16)
        var dst = [UInt8](repeating: 0, count: 8)
        input.withUnsafeBufferPointer { src in
            dst.withUnsafeMutableBufferPointer { d in
                encodeBC4Block(block: src.baseAddress!, stride: 4, dst: d.baseAddress!)
            }
        }
        return dst.withUnsafeBufferPointer { decodeBC4Block(src: $0.baseAddress!) }
    }
}
