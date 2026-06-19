// SPDX-License-Identifier: MIT
/*
 * BC4AlphaBlockEncoderRefined.swift
 *
 * rgbcx-style BC4 endpoint refinement search. Algorithm reference:
 * `bc7enc_rdo` / `rgbcx` (MIT or Public Domain) by Rich Geldreich.
 * Algorithms are not copyrightable; this is a clean Swift
 * implementation written from the algorithm description in
 * `reference/endpoint-search-study/FINDINGS.md`.
 *
 * Replaces `BC4AlphaBlockEncoder`'s two-candidate (min/max) endpoint
 * picker with a small endpoint search around the (max, min) baseline.
 * Targets the Phase 5B Arena desaturation symptom — saturated chroma
 * values near ±128 edges where the simple encoder undershoots
 * saturation because BC4's 8-level palette quantizes coarsest at the
 * extremes.
 *
 * Phase 5C.3 implementation. Applies to all BC4 use sites:
 * DXT5 alpha block, YCG6 luma + chroma planes, YG10 luma + alpha +
 * chroma planes.
 *
 * Algorithm (mirrors `rgbcx::encode_bc4_hq`):
 *
 *   1. Scan block for min, max. Constant block (min == max) → trivial
 *      encoding.
 *
 *   2. For each mode (8-mode `a0 > a1`, 6-mode `a0 ≤ a1`) and each
 *      (lo_delta, hi_delta) ∈ [-radius..radius]² (radius = 3 → 49
 *      candidates per mode):
 *
 *        a) `a0 = clamp(max + hi_delta, 0, 255)`,
 *           `a1 = clamp(min + lo_delta, 0, 255)`.
 *        b) Skip degenerate `a0 == a1`.
 *        c) Force the active mode: swap if needed so that 8-mode has
 *           `a0 > a1` and 6-mode has `a0 ≤ a1`.
 *        d) Build the 8-value palette for the active mode.
 *        e) For each of the 16 source values, find the closest
 *           palette entry (squared error). Sum total error. Early-out
 *           if running total ≥ current best.
 *        f) Update best (mode, a0, a1, indices).
 *
 *   3. Pack the winning (a0, a1, indices) into the 8-byte BC4 block.
 *
 * Complexity: 49 candidates × 2 modes × 16 pixels × 8 palette
 * comparisons ≈ 12.5 K integer compare-subtract ops per block, plus
 * palette construction. Per-block cost is ~10–20× the legacy simple
 * encoder; in practice the early-out shortens many candidates so the
 * real cost is closer to ~5×. On Apple Silicon at 1080p YCG6 (Phase 4B
 * baseline ~85 s release for 30 frames), expect ~150 s with the
 * refined path.
 */

import Foundation

// MARK: - Configuration

/// Global flag selecting which BC4 endpoint search algorithm
/// `encodeBC4Block` dispatches to.
///
/// `useRefinement = true`: rgbcx-style 7×7 endpoint refinement search.
///
/// `useRefinement = false` (default, v0.5.0+): the Phase 3A two-
/// candidate (min/max + 6-mode fallback) encoder.
///
/// **Phase 5C.4 verdict — why refinement is default-off.**
/// Phase 5C.3 introduced refinement as the v0.5.0 default after
/// Phase 5B Resolume Arena observed broad-spectrum desaturation on
/// YG10 HQ content. Phase 5C.4 measured refinement against the
/// clean-methodology paired DXT5 + YG10 corpora built in Phase
/// 5C.3.5 and found:
///
///   - DXT5 paired (4K, alpha-bearing): 0 SSIM change (BC4 only
///     touches alpha plane, already near-bit-exact).
///   - YG10 (4K, alpha-bearing): -0.000124 SSIM regression, +0.03–
///     0.04 LSB per-channel mean Δ regression on every channel,
///     3× wall-clock slowdown.
///
/// Per-channel regression is symmetric across R/G/B/α — no pattern
/// matching Phase 5B's "all colors except red lack saturation"
/// observation. Refinement isn't fixing the symptom we hoped it
/// would. Same SSE-vs-SSIM mismatch as ClusterFit: the search
/// finds endpoints with lower per-block squared error but they
/// reconstruct with marginally worse structural similarity.
///
/// v0.5.0 ships with default-false (simple two-candidate path
/// active). Refinement remains callable via
/// `BC4Config.useRefinement = true` for A/B testing or future
/// quality work. See `reference/PHASE-5C-RESULTS.md`.
public enum BC4Config {
    public static var useRefinement: Bool = false
}

/// rgbcx-style BC4 endpoint refinement search. Drop-in replacement
/// for `encodeBC4BlockSimple` with the same signature.
@inlinable
public func encodeBC4BlockRefined(
    block: UnsafePointer<UInt8>,
    stride: Int,
    dst: UnsafeMutablePointer<UInt8>
) {
    // (1) Load 16 source values; track min / max.
    var pixels = [UInt8](repeating: 0, count: 16)
    var minV: Int = 255
    var maxV: Int = 0
    for y in 0..<4 {
        for x in 0..<4 {
            let v = Int(block[y * stride + x])
            pixels[y * 4 + x] = UInt8(v)
            if v < minV { minV = v }
            if v > maxV { maxV = v }
        }
    }

    // Constant-block fast path. Use 6-mode (a0 == a1) so it's a
    // proper 6-mode block; selectors all 0 reconstruct to `min_val`.
    if minV == maxV {
        bc4WriteBlock(a0: UInt8(minV), a1: UInt8(minV),
                      indices: [UInt8](repeating: 0, count: 16),
                      dst: dst)
        return
    }

    // (2) Search both modes × 7×7 endpoint grid.
    let radius = 3
    var bestErr = Int.max
    var bestA0: Int = maxV
    var bestA1: Int = minV
    var bestIndices = [UInt8](repeating: 0, count: 16)
    var trialIndices = [UInt8](repeating: 0, count: 16)
    var pal = [Int](repeating: 0, count: 8)

    // mode 0 → 8-mode (a0 > a1, 8 codes)
    // mode 1 → 6-mode (a0 ≤ a1, 6 codes + reserved 0/255)
    for mode in 0...1 {
        for loDelta in -radius...radius {
            for hiDelta in -radius...radius {
                var a0 = maxV + hiDelta
                var a1 = minV + loDelta
                if a0 < 0 { a0 = 0 } else if a0 > 255 { a0 = 255 }
                if a1 < 0 { a1 = 0 } else if a1 > 255 { a1 = 255 }
                if a0 == a1 { continue }
                // Force the mode interpretation by swapping if needed.
                if mode == 0 {
                    if a0 <= a1 { let t = a0; a0 = a1; a1 = t }
                } else {
                    if a0 >  a1 { let t = a0; a0 = a1; a1 = t }
                }
                bc4FillPaletteInt(a0: a0, a1: a1,
                                  eightMode: mode == 0, into: &pal)
                let trialErr = bc4SquaredErrorEarlyOut(
                    pixels: pixels, palette: pal,
                    indicesOut: &trialIndices, cutoff: bestErr)
                if trialErr < bestErr {
                    bestErr = trialErr
                    bestA0 = a0
                    bestA1 = a1
                    bestIndices = trialIndices
                }
            }
        }
    }

    bc4WriteBlock(a0: UInt8(bestA0), a1: UInt8(bestA1),
                  indices: bestIndices, dst: dst)
}

// MARK: - Helpers (integer-only, no allocations in the hot loop)

/// Fill an 8-entry palette buffer in-place. Matches `bc4Palette()`
/// from the simple encoder but writes into a caller-provided buffer
/// so the search loop doesn't allocate per iteration.
@inlinable
@inline(__always)
public func bc4FillPaletteInt(a0: Int, a1: Int, eightMode: Bool, into p: inout [Int]) {
    p[0] = a0
    p[1] = a1
    if eightMode {
        p[2] = (6 * a0 + 1 * a1 + 3) / 7
        p[3] = (5 * a0 + 2 * a1 + 3) / 7
        p[4] = (4 * a0 + 3 * a1 + 3) / 7
        p[5] = (3 * a0 + 4 * a1 + 3) / 7
        p[6] = (2 * a0 + 5 * a1 + 3) / 7
        p[7] = (1 * a0 + 6 * a1 + 3) / 7
    } else {
        p[2] = (4 * a0 + 1 * a1 + 2) / 5
        p[3] = (3 * a0 + 2 * a1 + 2) / 5
        p[4] = (2 * a0 + 3 * a1 + 2) / 5
        p[5] = (1 * a0 + 4 * a1 + 2) / 5
        p[6] = 0
        p[7] = 255
    }
}

/// Per-block squared-error fit. For each of 16 source pixels, find
/// the palette entry with smallest |source - palette[k]|² and emit
/// that index. Returns total squared error. Early-outs as soon as
/// the running total reaches `cutoff` — caller's current best —
/// because any partial total that already exceeds the best can't
/// produce a new winner.
@inlinable
@inline(__always)
public func bc4SquaredErrorEarlyOut(
    pixels: [UInt8],
    palette: [Int],
    indicesOut: inout [UInt8],
    cutoff: Int
) -> Int {
    var total = 0
    for i in 0..<16 {
        let v = Int(pixels[i])
        var bestE = Int.max
        var bestK = 0
        for k in 0..<8 {
            let d = v - palette[k]
            let e = d * d
            if e < bestE {
                bestE = e
                bestK = k
                if e == 0 { break }
            }
        }
        indicesOut[i] = UInt8(bestK)
        total += bestE
        if total >= cutoff { return total }
    }
    return total
}
