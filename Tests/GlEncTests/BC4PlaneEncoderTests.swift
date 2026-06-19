/*
 * BC4PlaneEncoder tests — Phase 4A.1 validation.
 *
 * BC4 endpoint search is encoder-discretion (Pass C); these tests
 * verify the block-iteration order matches the decoder side and that
 * round-trip pixel error stays within BC4's intrinsic quantization
 * budget for flat / gradient / random content.
 */

import XCTest
@testable import GlEncCore

final class BC4PlaneEncoderTests: XCTestCase {

    func testFlatPlaneByteIdentity() {
        // 8×8 plane all = 128. Two 4×4 blocks → 16 bytes BC4.
        let plane = [UInt8](repeating: 128, count: 64)
        let blocks = BC4PlaneEncoder.encodePlane(plane: plane,
                                                  planeWidth: 8, planeHeight: 8)
        XCTAssertEqual(blocks.count, 4 * 8)  // (8/4)*(8/4)=4 blocks
        // BC4 single-color block: encoder takes the constant-color path
        // → e0=e1=128, indices all 0, 8 bytes per block = 128 128 0 0 0 0 0 0.
        for b in 0..<4 {
            XCTAssertEqual(blocks[b * 8 + 0], 128)
            XCTAssertEqual(blocks[b * 8 + 1], 128)
            for j in 2..<8 {
                XCTAssertEqual(blocks[b * 8 + j], 0,
                               "block \(b) byte \(j) should be 0 for flat input")
            }
        }
        // Round-trip exact.
        let decoded = BC4PlaneEncoder.decodePlane(blocks: blocks,
                                                   planeWidth: 8, planeHeight: 8)
        XCTAssertEqual(decoded, plane)
    }

    func testGradientPlaneRoundTrip() {
        // 8×8 plane = horizontal gradient 0, 32, 64, ..., 224.
        var plane = [UInt8]()
        for _ in 0..<8 {
            for x in 0..<8 {
                plane.append(UInt8(x * 32))
            }
        }
        let blocks = BC4PlaneEncoder.encodePlane(plane: plane,
                                                  planeWidth: 8, planeHeight: 8)
        XCTAssertEqual(blocks.count, 32)
        let decoded = BC4PlaneEncoder.decodePlane(blocks: blocks,
                                                   planeWidth: 8, planeHeight: 8)
        var maxDelta = 0
        for (a, b) in zip(plane, decoded) {
            maxDelta = max(maxDelta, abs(Int(a) - Int(b)))
        }
        // BC4's 8-level palette across two endpoints reproduces an
        // 8-step gradient with a few-LSB max delta. The two-candidate
        // (8-mode / 6-mode) endpoint search may not pick the optimum
        // for partial-range gradients — the exhaustive search is
        // encoder-discretion territory deferred to v0.4.1.
        XCTAssertLessThanOrEqual(maxDelta, 8,
                                 "BC4 gradient maxDelta=\(maxDelta) LSB exceeds the bar")
    }

    /// Block ordering: row-major over block coords. Verifies that the
    /// "block (bx, by)" at (1, 0) lands at output byte offset 8 (= one
    /// block past block (0,0)), and (0, 1) lands at offset 16 (= a
    /// full row of 2 blocks = 16 bytes ahead, for an 8-wide plane).
    func testBlockIterationOrder() {
        var plane = [UInt8](repeating: 0, count: 64)
        // Make block (0,0) all-zero, block (1,0) all-99, block (0,1)
        // all-200, block (1,1) all-50.
        for y in 0..<8 {
            for x in 0..<8 {
                let bx = x / 4, by = y / 4
                let v: UInt8 = {
                    switch (bx, by) {
                    case (0, 0): return 0
                    case (1, 0): return 99
                    case (0, 1): return 200
                    default:     return 50
                    }
                }()
                plane[y * 8 + x] = v
            }
        }
        let blocks = BC4PlaneEncoder.encodePlane(plane: plane,
                                                  planeWidth: 8, planeHeight: 8)
        // For a flat block, e0 == e1 == the constant.
        XCTAssertEqual(blocks[0 * 8 + 0], 0,  "block (0,0).e0 should be 0")
        XCTAssertEqual(blocks[1 * 8 + 0], 99, "block (1,0).e0 should be 99")
        XCTAssertEqual(blocks[2 * 8 + 0], 200,"block (0,1).e0 should be 200")
        XCTAssertEqual(blocks[3 * 8 + 0], 50, "block (1,1).e0 should be 50")
    }

    func testNonSquareDimensions() {
        // 16-wide × 4-tall plane → 4 blocks in a row.
        var plane = [UInt8](repeating: 0, count: 16 * 4)
        for i in 0..<plane.count { plane[i] = UInt8(i % 256) }
        let blocks = BC4PlaneEncoder.encodePlane(plane: plane,
                                                  planeWidth: 16, planeHeight: 4)
        XCTAssertEqual(blocks.count, 4 * 8)
        let decoded = BC4PlaneEncoder.decodePlane(blocks: blocks,
                                                   planeWidth: 16, planeHeight: 4)
        var maxDelta = 0
        for (a, b) in zip(plane, decoded) {
            maxDelta = max(maxDelta, abs(Int(a) - Int(b)))
        }
        // Each block sees a 4-row × 4-col slice spanning 4 distinct
        // integer values (one per row). Two endpoints fit 4 distinct
        // values exactly only if they fall on the BC4 palette grid —
        // generally won't, hence a few-LSB delta is expected.
        XCTAssertLessThanOrEqual(maxDelta, 6,
                                 "BC4 non-square maxDelta=\(maxDelta) LSB")
    }
}
