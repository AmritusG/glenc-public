// SPDX-License-Identifier: MIT
// vendored from AmritusG/glance @ e134a3a (v0.7.0), GlEnc's validated pin
import Foundation

/// BC4/BC5 block decompression for HQ DXV variants.
///
/// BC4 (also called RGTC1, ATI1): single-channel 4x4 block, 8 bytes/block.
///   - Bytes 0..1: two 8-bit endpoints (e0, e1)
///   - Bytes 2..7: 16 indices × 3 bits each (48 bits total), LSB-first
///   - Palette of 8 values derived from endpoints:
///       if e0 > e1: 8 linearly-interpolated levels
///       else: 6 interpolated levels + literal 0 + literal 255
///
/// BC5 (RGTC2, ATI2): two-channel 4x4 block, 16 bytes/block (= two BC4
/// blocks side-by-side, one per channel). For YCG6's chroma (Co/Cg
/// interleaved at 16 bytes/block), and for YG10's luma+alpha pair.
///
/// HQ variants use BC4 for the luma (Y) plane and BC5 for chroma (Co+Cg)
/// and luma+alpha pairs. Both have FFmpeg reference implementations
/// in libavcodec/texturedsp.c.
public enum BC4BC5Unpack {

    /// Unpack a single BC4 8-byte block to a 4x4 array of UInt8.
    /// `output` is a row-major 4x4 grid: output[row * stride + col].
    @inline(__always)
    public static func unpackBC4Block(
        block: UnsafePointer<UInt8>,
        output: UnsafeMutablePointer<UInt8>,
        stride: Int
    ) {
        let e0 = UInt32(block[0])
        let e1 = UInt32(block[1])
        var palette: (UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0, 0, 0, 0)
        palette.0 = e0
        palette.1 = e1
        if e0 > e1 {
            // 6 interpolated values between e0 and e1.
            palette.2 = (6 * e0 + 1 * e1) / 7
            palette.3 = (5 * e0 + 2 * e1) / 7
            palette.4 = (4 * e0 + 3 * e1) / 7
            palette.5 = (3 * e0 + 4 * e1) / 7
            palette.6 = (2 * e0 + 5 * e1) / 7
            palette.7 = (1 * e0 + 6 * e1) / 7
        } else {
            // 4 interpolated values between e0 and e1, plus 0 and 255.
            palette.2 = (4 * e0 + 1 * e1) / 5
            palette.3 = (3 * e0 + 2 * e1) / 5
            palette.4 = (2 * e0 + 3 * e1) / 5
            palette.5 = (1 * e0 + 4 * e1) / 5
            palette.6 = 0
            palette.7 = 255
        }

        // Pack 6 bytes of indices into a 64-bit word for easy bit
        // extraction. Bytes 2..7 of the block are 48 bits of indices,
        // 3 bits per pixel × 16 pixels.
        var bits: UInt64 = 0
        bits |= UInt64(block[2])
        bits |= UInt64(block[3]) << 8
        bits |= UInt64(block[4]) << 16
        bits |= UInt64(block[5]) << 24
        bits |= UInt64(block[6]) << 32
        bits |= UInt64(block[7]) << 40

        // 16 pixels in row-major order. Pixel (row, col) at index
        // (row * 4 + col); 3-bit index = (bits >> (idx * 3)) & 0x7.
        for row in 0..<4 {
            for col in 0..<4 {
                let pix = row * 4 + col
                let idx = Int((bits >> (pix * 3)) & 0x7)
                let val: UInt32
                switch idx {
                case 0: val = palette.0
                case 1: val = palette.1
                case 2: val = palette.2
                case 3: val = palette.3
                case 4: val = palette.4
                case 5: val = palette.5
                case 6: val = palette.6
                default: val = palette.7
                }
                output[row * stride + col] = UInt8(truncatingIfNeeded: val)
            }
        }
    }

    /// Unpack an entire BC4-compressed plane to raw bytes.
    /// Plane dims must be multiples of 4 (HQ uses 1920×1080 → ✓).
    public static func unpackBC4Plane(
        blocks: UnsafePointer<UInt8>, blocksCount: Int,
        output: UnsafeMutablePointer<UInt8>,
        width: Int, height: Int
    ) {
        let blocksPerRow = width / 4
        let blocksPerCol = height / 4
        // Sanity: blocksCount should equal blocksPerRow * blocksPerCol.
        // We don't enforce here (caller verifies texSize math).
        _ = blocksCount

        for blockRow in 0..<blocksPerCol {
            for blockCol in 0..<blocksPerRow {
                let blockIdx = blockRow * blocksPerRow + blockCol
                let blockPtr = blocks.advanced(by: blockIdx * 8)
                // Output position: top-left pixel of this 4x4 tile.
                let pixelRow = blockRow * 4
                let pixelCol = blockCol * 4
                let outPtr = output.advanced(by: pixelRow * width + pixelCol)
                unpackBC4Block(block: blockPtr, output: outPtr, stride: width)
            }
        }
    }

    /// Unpack a BC5 plane: two BC4 blocks per 16-byte block, output two
    /// separate planes.
    /// Used for HQ chroma (Co + Cg interleaved) and YG10 (Y + alpha).
    public static func unpackBC5Plane(
        blocks: UnsafePointer<UInt8>, blocksCount: Int,
        outputChannel0: UnsafeMutablePointer<UInt8>,
        outputChannel1: UnsafeMutablePointer<UInt8>,
        width: Int, height: Int
    ) {
        let blocksPerRow = width / 4
        let blocksPerCol = height / 4
        _ = blocksCount

        for blockRow in 0..<blocksPerCol {
            for blockCol in 0..<blocksPerRow {
                let blockIdx = blockRow * blocksPerRow + blockCol
                let block0 = blocks.advanced(by: blockIdx * 16)
                let block1 = blocks.advanced(by: blockIdx * 16 + 8)
                let pixelRow = blockRow * 4
                let pixelCol = blockCol * 4
                let out0 = outputChannel0.advanced(by: pixelRow * width + pixelCol)
                let out1 = outputChannel1.advanced(by: pixelRow * width + pixelCol)
                unpackBC4Block(block: block0, output: out0, stride: width)
                unpackBC4Block(block: block1, output: out1, stride: width)
            }
        }
    }
}
