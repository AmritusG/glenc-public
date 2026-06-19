// SPDX-License-Identifier: MIT
/*
 * BC4PlaneEncoder — multi-block BC4 wrapper for HQ (YCG6/YG10) planes.
 *
 * Phase 3A's `encodeBC4Block` handles one 4×4 tile. This file walks an
 * entire single-channel plane in row-major 4×4 blocks, calling that
 * primitive for each tile. Output buffer is `(planeW/4) * (planeH/4)`
 * blocks × 8 bytes each, with block (bx, by) at byte offset
 * `(by * (planeW/4) + bx) * 8`.
 *
 * Block iteration order matches `BC4BC5Unpack.unpackBC4Plane` in
 * GlanceCore: outer loop over block rows (`by` from 0), inner over
 * block cols (`bx` from 0). Verified by Phase 3A's BC3 path (same
 * outer-y / inner-x walk over BGRA tiles).
 *
 * Pass C (reference/ycg6/FINDINGS.md): BC4 endpoint search is encoder
 * discretion. Reusing `encodeBC4Block`'s two-candidate (8-mode + 6-mode)
 * search; Phase 3B showed it produces ≤4 LSB mean error on the alpha
 * plane and is fast enough for video encoding.
 */

import Foundation

public enum BC4PlaneEncoder {

    /// Encode an entire BC4 plane.
    ///
    /// - `plane`: single-channel input, `planeWidth * planeHeight` bytes,
    ///   row-major. Both dimensions must be multiples of 4 (caller
    ///   handles 16-pixel alignment + chroma half-resolution).
    /// - Returns: `(planeWidth/4) * (planeHeight/4) * 8` bytes of BC4
    ///   block data.
    public static func encodePlane(
        plane: [UInt8], planeWidth: Int, planeHeight: Int
    ) -> [UInt8] {
        precondition(planeWidth % 4 == 0 && planeHeight % 4 == 0,
                     "BC4 plane dims must be multiples of 4")
        precondition(plane.count == planeWidth * planeHeight,
                     "BC4 plane buffer size mismatch")

        let blocksPerRow = planeWidth / 4
        let blocksPerCol = planeHeight / 4
        let blockCount = blocksPerRow * blocksPerCol
        var output = [UInt8](repeating: 0, count: blockCount * 8)

        plane.withUnsafeBufferPointer { planeBuf in
            let src = planeBuf.baseAddress!
            output.withUnsafeMutableBufferPointer { outBuf in
                let dst = outBuf.baseAddress!
                for by in 0..<blocksPerCol {
                    let topRow = by * 4
                    let blockRowOffset = by * blocksPerRow
                    for bx in 0..<blocksPerRow {
                        let leftCol = bx * 4
                        let blockSrc = src.advanced(by: topRow * planeWidth + leftCol)
                        let blockDst = dst.advanced(by: (blockRowOffset + bx) * 8)
                        encodeBC4Block(block: blockSrc, stride: planeWidth, dst: blockDst)
                    }
                }
            }
        }
        return output
    }

    /// Decode-side companion used by tests: BC4-unpack an entire plane
    /// back into single-channel pixels. Mirrors
    /// `BC4BC5Unpack.unpackBC4Plane` from GlanceCore (factored here to
    /// avoid pulling GlanceCore into low-level test targets).
    public static func decodePlane(
        blocks: [UInt8], planeWidth: Int, planeHeight: Int
    ) -> [UInt8] {
        precondition(planeWidth % 4 == 0 && planeHeight % 4 == 0)
        let blocksPerRow = planeWidth / 4
        let blocksPerCol = planeHeight / 4
        precondition(blocks.count == blocksPerRow * blocksPerCol * 8)

        var out = [UInt8](repeating: 0, count: planeWidth * planeHeight)
        for by in 0..<blocksPerCol {
            for bx in 0..<blocksPerRow {
                let blockIdx = by * blocksPerRow + bx
                blocks.withUnsafeBufferPointer { buf in
                    let blockPtr = buf.baseAddress!.advanced(by: blockIdx * 8)
                    let decoded = decodeBC4Block(src: blockPtr)
                    for ry in 0..<4 {
                        for rx in 0..<4 {
                            out[(by * 4 + ry) * planeWidth + (bx * 4 + rx)] = decoded[ry * 4 + rx]
                        }
                    }
                }
            }
        }
        return out
    }
}
