// SPDX-License-Identifier: MIT
/*
 * BC4 single-channel block encoder.
 *
 * Encodes a 4×4 8-bit block to 8 bytes: two endpoint bytes followed by
 * 16 × 3-bit indices packed into 6 bytes (LSB-first). Used in DXT5 for
 * the 8-byte alpha block; later phases will reuse it for HQ luma/chroma
 * planes.
 *
 * Two interpolation modes (per the BC4 spec):
 *
 *   8-mode (alpha_0 > alpha_1): full palette is the two endpoints plus
 *   six interpolated values evenly spaced between them. Index 0 selects
 *   alpha_0, index 1 selects alpha_1, indices 2-7 walk the gradient.
 *
 *   6-mode (alpha_0 ≤ alpha_1): four interpolated values plus two
 *   reserved palette slots — index 6 = 0 and index 7 = 255. Useful for
 *   blocks whose source alpha clamps to 0 or 255.
 *
 * Endpoint search: this implementation evaluates two candidate pairs —
 * 8-mode (max, min) and 6-mode (min2, max2) where (min2, max2) excludes
 * any 0 / 255 pixels (those become palette[6] / palette[7]). For each
 * candidate, every source pixel picks its closest palette index and the
 * total absolute error is summed. The lower-error mode wins. This is
 * sufficient for Pass B's mostly-flat alpha plus right-third gradient
 * source — Phase 3B's pixel-Δ gate (mean ≤ 4 LSB / max ≤ 8 LSB) leaves
 * room to swap in a more exhaustive search later if needed.
 *
 * No FFmpeg port to attribute — written from the BC4 spec.
 *
 * Swift port: GlEnc, 2026.
 */

import Foundation

/// Encode one 4×4 single-channel tile to an 8-byte BC4 block.
///
/// - `block`: pointer to the top-left source byte of the 4×4 tile inside
///   a single-channel image. Reads 4 rows of 4 bytes each at `stride`
///   bytes per row.
/// - `stride`: bytes per row of the SOURCE image. For BC3 (DXT5 alpha
///   block) the alpha plane is gathered into a packed 4-stride buffer
///   first; this encoder reads contiguous 4-byte rows.
/// - `dst`: 8-byte output. Layout: [a0][a1][indices LSB-first 48 bits].
///
/// Dispatches to one of two algorithms based on `BC4Config.useRefinement`:
///   - `true` (default, v0.5.0+): rgbcx-style 7×7 endpoint refinement
///     search. Higher fidelity to source on saturated chroma.
///     See `BC4AlphaBlockEncoderRefined.swift`.
///   - `false` (legacy, Phase 3A): two-candidate (max/min) + 6-mode
///     fallback. Kept callable for A/B testing and as a safety fallback.
@inlinable
public func encodeBC4Block(
    block: UnsafePointer<UInt8>,
    stride: Int,
    dst: UnsafeMutablePointer<UInt8>
) {
    if BC4Config.useRefinement {
        encodeBC4BlockRefined(block: block, stride: stride, dst: dst)
    } else {
        encodeBC4BlockSimple(block: block, stride: stride, dst: dst)
    }
}

/// Phase 3A two-candidate BC4 endpoint search — the v0.3.0 / v0.4.0
/// algorithm. Retired from the default encoder path in v0.5.0 in favor
/// of the rgbcx-style refinement, but kept callable via
/// `BC4Config.useRefinement = false` for A/B testing.
@inlinable
public func encodeBC4BlockSimple(
    block: UnsafePointer<UInt8>,
    stride: Int,
    dst: UnsafeMutablePointer<UInt8>
) {
    var pixels = [UInt8](repeating: 0, count: 16)
    var minA: UInt8 = 255
    var maxA: UInt8 = 0
    for y in 0..<4 {
        for x in 0..<4 {
            let v = block[y * stride + x]
            pixels[y * 4 + x] = v
            if v < minA { minA = v }
            if v > maxA { maxA = v }
        }
    }

    if minA == maxA {
        bc4WriteBlock(a0: minA, a1: minA,
                      indices: [UInt8](repeating: 0, count: 16),
                      dst: dst)
        return
    }

    // 8-mode candidate: a0=max, a1=min (a0 > a1).
    let pal8 = bc4Palette(a0: maxA, a1: minA, eightMode: true)
    var idx8 = [UInt8](repeating: 0, count: 16)
    var err8 = 0
    for i in 0..<16 {
        let (k, e) = bc4ClosestIndex(pal8, value: pixels[i])
        idx8[i] = k
        err8 += e
    }

    // 6-mode candidate: a0=min2, a1=max2 (a0 ≤ a1) where min2/max2
    // exclude 0/255 (those go to palette[6]=0 / palette[7]=255).
    var min2: UInt8 = 255
    var max2: UInt8 = 0
    var hasMid = false
    for v in pixels where v != 0 && v != 255 {
        if v < min2 { min2 = v }
        if v > max2 { max2 = v }
        hasMid = true
    }
    var err6 = Int.max
    var idx6 = [UInt8](repeating: 0, count: 16)
    var pal6 = [UInt8](repeating: 0, count: 8)
    if hasMid && min2 < max2 {
        pal6 = bc4Palette(a0: min2, a1: max2, eightMode: false)
        err6 = 0
        for i in 0..<16 {
            let (k, e) = bc4ClosestIndex(pal6, value: pixels[i])
            idx6[i] = k
            err6 += e
        }
    } else if !hasMid {
        // All pixels are 0 or 255 → 6-mode with a0=0, a1=255 is exact.
        pal6 = bc4Palette(a0: 0, a1: 255, eightMode: false)
        err6 = 0
        for i in 0..<16 {
            // 0 → index 6; 255 → index 7.
            idx6[i] = (pixels[i] == 0) ? 6 : 7
        }
    }

    if err6 < err8 {
        bc4WriteBlock(a0: pal6[0], a1: pal6[1], indices: idx6, dst: dst)
    } else {
        bc4WriteBlock(a0: pal8[0], a1: pal8[1], indices: idx8, dst: dst)
    }
}

// MARK: - Helpers

@inline(__always)
@usableFromInline
func bc4Palette(a0: UInt8, a1: UInt8, eightMode: Bool) -> [UInt8] {
    var p = [UInt8](repeating: 0, count: 8)
    p[0] = a0
    p[1] = a1
    let A = Int(a0)
    let B = Int(a1)
    if eightMode {
        // 6 interpolated values
        p[2] = UInt8((6 * A + 1 * B + 3) / 7)
        p[3] = UInt8((5 * A + 2 * B + 3) / 7)
        p[4] = UInt8((4 * A + 3 * B + 3) / 7)
        p[5] = UInt8((3 * A + 4 * B + 3) / 7)
        p[6] = UInt8((2 * A + 5 * B + 3) / 7)
        p[7] = UInt8((1 * A + 6 * B + 3) / 7)
    } else {
        // 4 interpolated values + reserved 0 / 255
        p[2] = UInt8((4 * A + 1 * B + 2) / 5)
        p[3] = UInt8((3 * A + 2 * B + 2) / 5)
        p[4] = UInt8((2 * A + 3 * B + 2) / 5)
        p[5] = UInt8((1 * A + 4 * B + 2) / 5)
        p[6] = 0
        p[7] = 255
    }
    return p
}

@inline(__always)
@usableFromInline
func bc4ClosestIndex(_ palette: [UInt8], value v: UInt8) -> (UInt8, Int) {
    var bestK: UInt8 = 0
    var bestE = Int.max
    for k in 0..<8 {
        let e = abs(Int(v) - Int(palette[k]))
        if e < bestE {
            bestE = e
            bestK = UInt8(k)
        }
    }
    return (bestK, bestE)
}

@inline(__always)
@usableFromInline
func bc4WriteBlock(a0: UInt8, a1: UInt8, indices: [UInt8],
                   dst: UnsafeMutablePointer<UInt8>) {
    dst[0] = a0
    dst[1] = a1
    var bits: UInt64 = 0
    for i in 0..<16 {
        bits |= UInt64(indices[i] & 0x7) << (i * 3)
    }
    dst[2] = UInt8( bits        & 0xFF)
    dst[3] = UInt8((bits >>  8) & 0xFF)
    dst[4] = UInt8((bits >> 16) & 0xFF)
    dst[5] = UInt8((bits >> 24) & 0xFF)
    dst[6] = UInt8((bits >> 32) & 0xFF)
    dst[7] = UInt8((bits >> 40) & 0xFF)
}

/// Reverse of `encodeBC4Block` — used by tests for round-trip checking.
/// Decodes 8 BC4 bytes back into 16 alpha samples.
@inlinable
public func decodeBC4Block(src: UnsafePointer<UInt8>) -> [UInt8] {
    let a0 = src[0]
    let a1 = src[1]
    let pal = bc4Palette(a0: a0, a1: a1, eightMode: a0 > a1)
    var bits: UInt64 = 0
    for i in 0..<6 {
        bits |= UInt64(src[2 + i]) << (i * 8)
    }
    var out = [UInt8](repeating: 0, count: 16)
    for i in 0..<16 {
        let k = Int((bits >> (i * 3)) & 0x7)
        out[i] = pal[k]
    }
    return out
}
