// SPDX-License-Identifier: MIT
/*
 * BC1BlockEncoderClusterFit.swift
 *
 * Squish-style ClusterFit BC1 endpoint search. Algorithm reference:
 * libsquish (MIT) by Simon Brown / Ignacio Castano. Algorithms are
 * not copyrightable; this is a clean Swift implementation written
 * from the algorithm description in `clusterfit.cpp`.
 *
 * BT.709 luma-weighted error metric (0.2126, 0.7152, 0.0722) per
 * Phase 5B Resolume Arena observation that green / cyan saturation
 * gaps are most visible to the eye. See `reference/endpoint-search-
 * study/FINDINGS.md` for the full discussion.
 *
 * Phase 5C.2 implementation. Replaces BC1BlockEncoder.swift's
 * FFmpeg-port algorithm (which produced visibly desaturated green /
 * cyan on saturated content). v0.5.0 intentionally retires v0.2.0's
 * byte-identity-to-FFmpeg contract in favor of fidelity-to-source.
 *
 * Algorithm outline:
 *
 *   1. Constant-color fast path. Reuse the FFmpeg-path lookup tables
 *      (`bc1Match5` / `bc1Match6` in `BC1BlockEncoder.swift`) — same
 *      bytes that hardware-emulating DXT1 decoders expect.
 *
 *   2. Extract the 16 RGB pixels as normalized Float [0, 1] (alpha
 *      is ignored — DXT1 forces α = 255 at decode).
 *
 *   3. Compute the principal axis of the (R, G, B) color cloud via
 *      power iteration on the per-channel covariance matrix.
 *
 *   4. Sort the 16 pixel indices along the axis.
 *
 *   5. Triple-loop partition search. For each `(i, j, k)` with
 *      `0 ≤ i ≤ j ≤ k ≤ 16`, the sorted pixel sequence partitions
 *      into four contiguous clusters mapped to BC1 palette indices
 *      `0, 2, 3, 1` (in that order along the axis):
 *
 *          sorted[0 ..< i]   →  palette[0] = endpoint A   (α=1, β=0)
 *          sorted[i ..< j]   →  palette[2] = 2/3 A + 1/3 B (α=2/3, β=1/3)
 *          sorted[j ..< k]   →  palette[3] = 1/3 A + 2/3 B (α=1/3, β=2/3)
 *          sorted[k ..< 16]  →  palette[1] = endpoint B   (α=0, β=1)
 *
 *      Solve the 2×2 normal-equation system for the least-squares-
 *      optimal `(A, B)` RGB endpoint pair under this cluster
 *      assignment. Clamp to [0, 1], snap to the RGB565 grid via the
 *      `bc1Expand5` / `bc1Expand6` decoder lookup tables, compute
 *      residual error under BT.709 luma weights, keep the winner.
 *
 *   6. Pack the BC1 block: endpoint0 (RGB565 LE) + endpoint1 (RGB565
 *      LE) + 32-bit index mask (LE). Force 4-color mode (endpoint0 >
 *      endpoint1) by swapping if needed and XORing the mask by
 *      `0x55555555`.
 *
 * Complexity: O(16³) = O(4096) partition evaluations per block,
 * dominated by the LS solve + RGB565 quantization + error tally.
 * On Apple Silicon (Float arithmetic, no SIMD), expect a wall-clock
 * cost of ~5–10× the FFmpeg path. Acceptable for an offline encoder
 * — the FINDINGS.md study estimated 8–15 min for a 30-frame 1920×1080
 * corpus that the FFmpeg path encodes in ~85 s.
 */

import Foundation

// MARK: - Public API — algorithm dispatcher

/// Global flag selecting which BC1 endpoint search algorithm
/// `encodeBC1Block` dispatches to.
///
/// `useClusterFit = true`: Squish-style ClusterFit.
///
/// `useClusterFit = false` (default, v0.5.0+): the Phase 2A
/// FFmpeg-port path — byte-identical to `ffmpeg -c:v dxv -format dxt1`.
///
/// **Phase 5C.4.5 verdict — why ClusterFit is default-off.**
/// Phase 5C.2 introduced ClusterFit as the v0.5.0 default after
/// Phase 5B Resolume Arena observed broad-spectrum desaturation on
/// YG10 HQ content. Phase 5C.4.5 measured ClusterFit against the
/// clean-methodology real-content corpora built in Phase 5C.2.5 +
/// 5C.3.5 and found:
///
///   - DXT1 ShroomiesKingdom_29 (4K, no alpha): -0.0008 SSIM,
///     -0.04 LSB per-channel mean Δ, 12× wall-clock slowdown.
///   - DXT5 paired (4K, alpha-bearing): -0.0006 SSIM, -0.04 LSB
///     per-channel mean Δ, 4× wall-clock slowdown.
///
/// ClusterFit minimizes its design objective (per-pixel squared
/// error, which goes down measurably) but SSIM goes down too — the
/// classic SSE-vs-perceptual-similarity mismatch. SSIM measures local
/// mean / variance / covariance structure, which the FFmpeg path
/// preserves slightly better via "endpoints picked from actual
/// block pixels" rather than from LS-optimal grid points.
///
/// Both deltas are sub-perceptual in absolute magnitude (-0.0008
/// SSIM ≈ 0.08 %) but consistently in the wrong direction across
/// two independent real-content corpora at two DXV3 variants. The
/// Phase 5B Arena desaturation symptom doesn't live in BC1
/// endpoint search.
///
/// v0.5.0 ships with default-false (FFmpeg path active). ClusterFit
/// remains callable via `BC1Config.useClusterFit = true` for A/B
/// testing or future content types where its trade-off might
/// invert. See `reference/PHASE-5C-RESULTS.md`.
public enum BC1Config {
    public static var useClusterFit: Bool = false
}

// MARK: - ClusterFit BC1 encoder

@inlinable
public func encodeBC1BlockClusterFit(
    block: UnsafePointer<UInt8>,
    stride: Int,
    dst: UnsafeMutablePointer<UInt8>
) {
    // (1) Constant-color fast path. Identical to the FFmpeg path —
    // the `match5` / `match6` tables encode the optimal (max5/6, min5/6)
    // endpoint pair for a constant-color block of any 8-bit value.
    if bc1ConstantColor(block, stride) {
        let r = Int(block[0])
        let g = Int(block[1])
        let b = Int(block[2])
        let max16 = UInt16((Int(bc1Match5[r * 2 + 0]) << 11) |
                           (Int(bc1Match6[g * 2 + 0]) <<  5) |
                            Int(bc1Match5[b * 2 + 0]))
        let min16 = UInt16((Int(bc1Match5[r * 2 + 1]) << 11) |
                           (Int(bc1Match6[g * 2 + 1]) <<  5) |
                            Int(bc1Match5[b * 2 + 1]))
        bc1cfWritePacked(max16, min16, 0xAAAAAAAA, dst)
        return
    }

    // (2) Extract the 16 RGB pixels.
    var pR = [Float](repeating: 0, count: 16)
    var pG = [Float](repeating: 0, count: 16)
    var pB = [Float](repeating: 0, count: 16)
    for y in 0..<4 {
        for x in 0..<4 {
            let p = block.advanced(by: x * 4 + y * stride)
            let idx = y * 4 + x
            pR[idx] = Float(p[0]) / 255.0
            pG[idx] = Float(p[1]) / 255.0
            pB[idx] = Float(p[2]) / 255.0
        }
    }

    // (3) Principal axis via covariance + power iteration.
    var muR: Float = 0, muG: Float = 0, muB: Float = 0
    for i in 0..<16 { muR += pR[i]; muG += pG[i]; muB += pB[i] }
    muR /= 16; muG /= 16; muB /= 16

    var cxx: Float = 0, cxy: Float = 0, cxz: Float = 0
    var cyy: Float = 0, cyz: Float = 0, czz: Float = 0
    for i in 0..<16 {
        let dr = pR[i] - muR
        let dg = pG[i] - muG
        let db = pB[i] - muB
        cxx += dr * dr
        cxy += dr * dg
        cxz += dr * db
        cyy += dg * dg
        cyz += dg * db
        czz += db * db
    }

    var axR: Float = 1, axG: Float = 1, axB: Float = 1
    for _ in 0..<8 {
        let nR = cxx * axR + cxy * axG + cxz * axB
        let nG = cxy * axR + cyy * axG + cyz * axB
        let nB = cxz * axR + cyz * axG + czz * axB
        let mag = (nR * nR + nG * nG + nB * nB).squareRoot()
        if mag > 1e-10 {
            axR = nR / mag
            axG = nG / mag
            axB = nB / mag
        } else {
            // Degenerate axis (block is uniform along all three channels).
            // Use a luma-like axis as a fallback so the sort is stable.
            axR = 0.2126; axG = 0.7152; axB = 0.0722
            break
        }
    }

    // (4) Sort indices by projection onto the axis.
    var order = [Int](0..<16)
    var dots = [Float](repeating: 0, count: 16)
    for i in 0..<16 {
        dots[i] = pR[i] * axR + pG[i] * axG + pB[i] * axB
    }
    order.sort { dots[$0] < dots[$1] }

    // Sorted view of the pixels (for prefix-sum updates in the loop).
    var sR = [Float](repeating: 0, count: 16)
    var sG = [Float](repeating: 0, count: 16)
    var sB = [Float](repeating: 0, count: 16)
    for i in 0..<16 {
        sR[i] = pR[order[i]]
        sG[i] = pG[order[i]]
        sB[i] = pB[order[i]]
    }

    // (5) Triple-loop partition search.
    //
    // BT.709 luma weights on the per-channel residual sum-of-squared
    // errors. Squish's "old perceptual" metric — drives saturation
    // accuracy on green / cyan / magenta (the channels with the
    // largest luma contributions).
    let metricR: Float = 0.2126
    let metricG: Float = 0.7152
    let metricB: Float = 0.0722

    // Coefficient constants for the alpha/beta accumulators.
    //   palette idx 0 → (α=1,    β=0)   → α²=1,   β²=0,   αβ=0
    //   palette idx 2 → (α=2/3,  β=1/3) → α²=4/9, β²=1/9, αβ=2/9
    //   palette idx 3 → (α=1/3,  β=2/3) → α²=1/9, β²=4/9, αβ=2/9
    //   palette idx 1 → (α=0,    β=1)   → α²=0,   β²=1,   αβ=0
    let oneNinth: Float = 1.0 / 9.0
    let fourNinths: Float = 4.0 / 9.0
    let twoNinths: Float = 2.0 / 9.0
    let oneThird: Float = 1.0 / 3.0
    let twoThirds: Float = 2.0 / 3.0

    // Running prefix sums for the four cluster accumulators. Each
    // `part` carries the per-channel sum and the point count. `part3`
    // is implicit (= total − part0 − part1 − part2).
    var totalR: Float = 0, totalG: Float = 0, totalB: Float = 0
    for i in 0..<16 { totalR += sR[i]; totalG += sG[i]; totalB += sB[i] }
    let totalW: Float = 16

    var bestError: Float = .greatestFiniteMagnitude
    var bestStartR: Float = 0, bestStartG: Float = 0, bestStartB: Float = 0
    var bestEndR: Float = 0, bestEndG: Float = 0, bestEndB: Float = 0
    var bestI = 0, bestJ = 0, bestK = 0
    var bestFound = false

    var part0R: Float = 0, part0G: Float = 0, part0B: Float = 0, part0W: Float = 0
    for i in 0...16 {
        var part1R: Float = 0, part1G: Float = 0, part1B: Float = 0, part1W: Float = 0
        for j in i...16 {
            var part2R: Float = 0, part2G: Float = 0, part2B: Float = 0, part2W: Float = 0
            for k in j...16 {
                let part3R = totalR - part0R - part1R - part2R
                let part3G = totalG - part0G - part1G - part2G
                let part3B = totalB - part0B - part1B - part2B
                let part3W = totalW - part0W - part1W - part2W

                // Skip degenerate "all in cluster 0" / "all in cluster 3"
                // assignments — the LS system would be singular.
                if part0W < 16 && part3W < 16 {
                    let alpha2W = part0W + fourNinths * part1W + oneNinth * part2W
                    let beta2W  = part3W + oneNinth * part1W + fourNinths * part2W
                    let alphabetaW = twoNinths * (part1W + part2W)
                    let det = alpha2W * beta2W - alphabetaW * alphabetaW
                    if det > 1e-9 {
                        let invDet = 1.0 / det

                        // Right-hand-side x sums.
                        let alphaxR = part0R + twoThirds * part1R + oneThird * part2R
                        let alphaxG = part0G + twoThirds * part1G + oneThird * part2G
                        let alphaxB = part0B + twoThirds * part1B + oneThird * part2B
                        let betaxR = part3R + oneThird * part1R + twoThirds * part2R
                        let betaxG = part3G + oneThird * part1G + twoThirds * part2G
                        let betaxB = part3B + oneThird * part1B + twoThirds * part2B

                        // LS solve.
                        var sR_ = (alphaxR * beta2W - betaxR * alphabetaW) * invDet
                        var sG_ = (alphaxG * beta2W - betaxG * alphabetaW) * invDet
                        var sB_ = (alphaxB * beta2W - betaxB * alphabetaW) * invDet
                        var eR_ = (betaxR * alpha2W - alphaxR * alphabetaW) * invDet
                        var eG_ = (betaxG * alpha2W - alphaxG * alphabetaW) * invDet
                        var eB_ = (betaxB * alpha2W - alphaxB * alphabetaW) * invDet

                        // Clamp + snap to the RGB565 grid → quantized
                        // (5, 6, 5) integer endpoint, then decode back
                        // through the FFmpeg-path `expand5` / `expand6`
                        // tables. This matches the bits that BC1 hardware
                        // and software decoders actually produce.
                        let sR5 = bc1cfClamp(0, 31, Int((max(0, min(1, sR_)) * 31).rounded()))
                        let sG6 = bc1cfClamp(0, 63, Int((max(0, min(1, sG_)) * 63).rounded()))
                        let sB5 = bc1cfClamp(0, 31, Int((max(0, min(1, sB_)) * 31).rounded()))
                        let eR5 = bc1cfClamp(0, 31, Int((max(0, min(1, eR_)) * 31).rounded()))
                        let eG6 = bc1cfClamp(0, 63, Int((max(0, min(1, eG_)) * 63).rounded()))
                        let eB5 = bc1cfClamp(0, 31, Int((max(0, min(1, eB_)) * 31).rounded()))

                        sR_ = Float(bc1Expand5[sR5]) / 255
                        sG_ = Float(bc1Expand6[sG6]) / 255
                        sB_ = Float(bc1Expand5[sB5]) / 255
                        eR_ = Float(bc1Expand5[eR5]) / 255
                        eG_ = Float(bc1Expand6[eG6]) / 255
                        eB_ = Float(bc1Expand5[eB5]) / 255

                        // Residual squared error per channel under the
                        // current partition + quantized endpoints. The
                        // formula is the standard expansion of
                        // ||a·α + b·β − x||² minus the constant ‖x‖² term:
                        //     e = a² α²  +  b² β²  +  2 a b αβ
                        //       − 2 a αx − 2 b βx
                        let aaR = sR_ * sR_ * alpha2W + eR_ * eR_ * beta2W
                        let aaG = sG_ * sG_ * alpha2W + eG_ * eG_ * beta2W
                        let aaB = sB_ * sB_ * alpha2W + eB_ * eB_ * beta2W
                        let cR = sR_ * eR_ * alphabetaW - sR_ * alphaxR - eR_ * betaxR
                        let cG = sG_ * eG_ * alphabetaW - sG_ * alphaxG - eG_ * betaxG
                        let cB = sB_ * eB_ * alphabetaW - sB_ * alphaxB - eB_ * betaxB
                        let errR = 2 * cR + aaR
                        let errG = 2 * cG + aaG
                        let errB = 2 * cB + aaB
                        let err = metricR * errR + metricG * errG + metricB * errB

                        if err < bestError {
                            bestError = err
                            bestStartR = sR_; bestStartG = sG_; bestStartB = sB_
                            bestEndR = eR_;   bestEndG = eG_;   bestEndB = eB_
                            bestI = i; bestJ = j; bestK = k
                            bestFound = true
                        }
                    }
                }

                if k < 16 {
                    part2R += sR[k]; part2G += sG[k]; part2B += sB[k]; part2W += 1
                }
            }
            if j < 16 {
                part1R += sR[j]; part1G += sG[j]; part1B += sB[j]; part1W += 1
            }
        }
        if i < 16 {
            part0R += sR[i]; part0G += sG[i]; part0B += sB[i]; part0W += 1
        }
    }

    // Should always find at least one valid partition for non-constant
    // blocks. Defensive fallback: if not (e.g. all-singular partitions
    // from a numerically tiny axis), use the FFmpeg path.
    if !bestFound {
        encodeBC1BlockFFmpeg(block: block, stride: stride, dst: dst)
        return
    }

    // (6) Pack the BC1 block.
    var startEP = bc1cfFloatToRGB565(bestStartR, bestStartG, bestStartB)
    var endEP   = bc1cfFloatToRGB565(bestEndR,   bestEndG,   bestEndB)

    // Map sorted-cluster index → BC1 palette index, then reorder back
    // to the original pixel layout.
    var sortedMask = [UInt8](repeating: 0, count: 16)
    for m in 0..<bestI    { sortedMask[m] = 0 }
    for m in bestI..<bestJ { sortedMask[m] = 2 }
    for m in bestJ..<bestK { sortedMask[m] = 3 }
    for m in bestK..<16   { sortedMask[m] = 1 }

    var mask32: UInt32 = 0
    for m in 0..<16 {
        let origIdx = order[m]
        mask32 |= UInt32(sortedMask[m]) << (origIdx * 2)
    }

    // Force 4-color mode (endpoint0 > endpoint1). Swap + XOR flips the
    // index parity per pixel (0 ↔ 1, 2 ↔ 3).
    if startEP < endEP {
        let t = startEP
        startEP = endEP
        endEP = t
        mask32 ^= 0x55555555
    }

    bc1cfWritePacked(startEP, endEP, mask32, dst)
}

// MARK: - Small helpers

@inline(__always)
@usableFromInline
func bc1cfClamp(_ lo: Int, _ hi: Int, _ v: Int) -> Int {
    return min(hi, max(lo, v))
}

/// Quantize a normalized RGB float triple ∈ [0, 1] to the closest
/// RGB565 codepoint. Returns the packed 16-bit endpoint.
@inline(__always)
@usableFromInline
func bc1cfFloatToRGB565(_ r: Float, _ g: Float, _ b: Float) -> UInt16 {
    let r5 = bc1cfClamp(0, 31, Int((max(0, min(1, r)) * 31).rounded()))
    let g6 = bc1cfClamp(0, 63, Int((max(0, min(1, g)) * 63).rounded()))
    let b5 = bc1cfClamp(0, 31, Int((max(0, min(1, b)) * 31).rounded()))
    return UInt16((r5 << 11) | (g6 << 5) | b5)
}

/// Write the 8-byte BC1 packed output: endpoint0 LE16, endpoint1 LE16,
/// 32-bit index mask LE.
@inline(__always)
@usableFromInline
func bc1cfWritePacked(
    _ max16: UInt16,
    _ min16: UInt16,
    _ mask: UInt32,
    _ dst: UnsafeMutablePointer<UInt8>
) {
    dst[0] = UInt8(max16 & 0xFF)
    dst[1] = UInt8((max16 >> 8) & 0xFF)
    dst[2] = UInt8(min16 & 0xFF)
    dst[3] = UInt8((min16 >> 8) & 0xFF)
    dst[4] = UInt8(mask & 0xFF)
    dst[5] = UInt8((mask >> 8) & 0xFF)
    dst[6] = UInt8((mask >> 16) & 0xFF)
    dst[7] = UInt8((mask >> 24) & 0xFF)
}
