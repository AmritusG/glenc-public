/*
 * BC3 (DXT5) block encoder tests.
 *
 * BC3 = BC4 alpha (bytes 0..7) followed by BC1 color (bytes 8..15).
 * These tests verify the layout — the underlying BC4 / BC1 encoders are
 * exercised by their own test files.
 */

import XCTest
@testable import GlEncCore

final class BC3BlockEncoderTests: XCTestCase {

    func testLayoutAlphaThenColor() throws {
        // Construct a 4×4 RGBA tile: solid red, α = linear ramp 0..240.
        var tile = [UInt8](repeating: 0, count: 16 * 4)
        for i in 0..<16 {
            tile[i * 4 + 0] = 200    // R
            tile[i * 4 + 1] = 50     // G
            tile[i * 4 + 2] = 80     // B
            tile[i * 4 + 3] = UInt8(i * 16)
        }

        var bc3 = [UInt8](repeating: 0, count: 16)
        tile.withUnsafeBufferPointer { src in
            bc3.withUnsafeMutableBufferPointer { dst in
                encodeBC3Block(block: src.baseAddress!, stride: 16, dst: dst.baseAddress!)
            }
        }

        // Build the BC4 block independently from the alpha plane and
        // verify bytes 0..7 of the BC3 output match.
        var alpha = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 { alpha[i] = UInt8(i * 16) }
        var bc4 = [UInt8](repeating: 0, count: 8)
        alpha.withUnsafeBufferPointer { src in
            bc4.withUnsafeMutableBufferPointer { dst in
                encodeBC4Block(block: src.baseAddress!, stride: 4, dst: dst.baseAddress!)
            }
        }
        XCTAssertEqual(Array(bc3.prefix(8)), bc4,
                       "bytes 0..7 must be the BC4 alpha block")

        // Build the BC1 block independently from the RGB plane and
        // verify bytes 8..15 match.
        var bc1 = [UInt8](repeating: 0, count: 8)
        tile.withUnsafeBufferPointer { src in
            bc1.withUnsafeMutableBufferPointer { dst in
                encodeBC1Block(block: src.baseAddress!, stride: 16, dst: dst.baseAddress!)
            }
        }
        XCTAssertEqual(Array(bc3.suffix(8)), bc1,
                       "bytes 8..15 must be the BC1 color block")
    }

    func testFlatBlockHasFlatBC1Indices() throws {
        // All pixels (r=200, g=50, b=80, α=255). Constant-color path in
        // BC1 should emit a recognizable mask.
        var tile = [UInt8](repeating: 0, count: 16 * 4)
        for i in 0..<16 {
            tile[i * 4 + 0] = 200
            tile[i * 4 + 1] = 50
            tile[i * 4 + 2] = 80
            tile[i * 4 + 3] = 255
        }
        var bc3 = [UInt8](repeating: 0, count: 16)
        tile.withUnsafeBufferPointer { src in
            bc3.withUnsafeMutableBufferPointer { dst in
                encodeBC3Block(block: src.baseAddress!, stride: 16, dst: dst.baseAddress!)
            }
        }
        // Alpha endpoints both 255 (or close). BC1 indices = 0xAAAAAAAA
        // (constant-color mask, per BC1BlockEncoder.swift).
        XCTAssertEqual(bc3[0], 255, "alpha block a0 should be 255 for fully opaque")
        XCTAssertEqual(bc3[1], 255, "alpha block a1 should be 255 for fully opaque")
        let bc1Mask = UInt32(bc3[12])
                    | (UInt32(bc3[13]) << 8)
                    | (UInt32(bc3[14]) << 16)
                    | (UInt32(bc3[15]) << 24)
        XCTAssertEqual(bc1Mask, 0xAAAAAAAA, "constant-color BC1 mask")
    }
}
