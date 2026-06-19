// SPDX-License-Identifier: MIT
/*
 * BC3 (DXT5) block encoder = BC4 alpha block + BC1 color block.
 *
 * Each 4×4 RGBA tile encodes to 16 bytes:
 *   - bytes 0..7   : BC4 alpha block over the tile's alpha channel
 *   - bytes 8..15  : BC1 color block over the tile's RGB channels (alpha
 *                    discarded by BC1, which encodes RGB only)
 *
 * Per DECISIONS-2026-05-10-PassB.md, RGB and alpha are stored straight
 * (NOT premultiplied) — that normalization happens in `DXT5Encoder` by
 * inspecting the source `CGImageAlphaInfo` before the block walker runs.
 *
 * Swift port: GlEnc, 2026.
 */

import Foundation

/// Encode one 4×4 RGBA tile to a 16-byte BC3 (DXT5) block.
///
/// - `block`: pointer to the top-left RGBA pixel of the 4×4 tile inside
///   a larger image. Bytes are R, G, B, A per pixel.
/// - `stride`: bytes per row of the SOURCE image (= width × 4).
/// - `dst`: 16-byte output. Layout: [BC4 alpha 8 bytes][BC1 color 8 bytes].
@inlinable
public func encodeBC3Block(
    block: UnsafePointer<UInt8>,
    stride: Int,
    dst: UnsafeMutablePointer<UInt8>
) {
    // Gather alpha into a packed 4-byte-stride buffer for BC4.
    var alpha = [UInt8](repeating: 0, count: 16)
    for y in 0..<4 {
        for x in 0..<4 {
            alpha[y * 4 + x] = block[y * stride + x * 4 + 3]
        }
    }

    alpha.withUnsafeBufferPointer { alphaBuf in
        encodeBC4Block(block: alphaBuf.baseAddress!, stride: 4, dst: dst)
    }

    // BC1 over RGB (alpha byte is read by the BC1 helpers but ignored).
    encodeBC1Block(block: block, stride: stride, dst: dst.advanced(by: 8))
}
