// SPDX-License-Identifier: MIT
/*
 * YCoCgTransform — RGB → YCoCg forward transform + 2:1 chroma
 * subsampling for HQ DXV3 (YCG6, YG10).
 *
 * Phase 0 recon (Glance 4d.4, validated 99.82 % match vs Resolume
 * reference) and Pass C (reference/ycg6/FINDINGS.md) lock the
 * NON-REVERSIBLE YCoCg variant:
 *
 *     Y  =  R/4 + G/2 + B/4
 *     Co =  R/2       - B/2
 *     Cg = -R/4 + G/2 - B/4
 *
 * GlanceCore's CPURender HQ inverse (the spec for what our encoder must
 * produce) reads Co/Cg as straight UInt8 bytes and subtracts 128 to get
 * the signed value:
 *
 *     coI = Int(co_byte) - 128
 *     cgI = Int(cg_byte) - 128
 *     t   = Y - cgI
 *     R   = clamp(t + coI)
 *     G   = clamp(Y + cgI)
 *     B   = clamp(t - coI)
 *
 * So the encoder stores Co_signed + 128 and Cg_signed + 128 in the BC4
 * chroma planes.
 *
 * Integer arithmetic only — no float. Float-then-quantize would expose
 * the FMA-contraction trap (feedback_fma_byte_identity.md) and is
 * unnecessary here since the decoder side is integer.
 *
 * Range analysis (R, G, B ∈ [0, 255]):
 *   Y  = (R + 2G + B + 2) >> 2          → [0, 255]
 *   Co = (R - B) >> 1                    → [-128, 127]    (signed)
 *   Cg = (-R + 2G - B) >> 2              → [-128, 127]    (signed)
 *
 * The `(R - B + 1) >> 1` form proposed in the brief would push Co to
 * +128 at R=255,B=0 — out of the decoder's [-128, 127] range. Floor
 * division via Swift's arithmetic right shift on signed Int keeps Co
 * within range and round-trips cleanly through the decoder.
 *
 * Chroma subsampling: 2× per dimension. For each 2×2 RGB tile, compute
 * per-pixel Co/Cg then average to one value. "Transform-then-average"
 * preserves detail at edges slightly better than "average-then-transform"
 * for non-reversible YCoCg.
 */

import Foundation

/// Three single-channel planes after RGB → YCoCg + chroma subsampling.
/// Sizes are at coded (16-aligned) dimensions; the encoder zero-fills
/// the pad rows / cols during the BGRA copy step.
public struct YCoCgPlanes {
    /// Luma plane: codedWidth × codedHeight bytes, row-major.
    public let luma: [UInt8]
    /// Co chroma plane: (codedWidth/2) × (codedHeight/2) bytes,
    /// row-major. Stored as `Co_signed + 128` so decoder reads
    /// straight `UInt8 - 128`.
    public let co: [UInt8]
    /// Cg chroma plane: same dimensions / convention as Co.
    public let cg: [UInt8]
    /// Coded (16-aligned) dimensions of the luma plane.
    public let codedWidth: Int
    public let codedHeight: Int

    public init(luma: [UInt8], co: [UInt8], cg: [UInt8],
                codedWidth: Int, codedHeight: Int) {
        self.luma = luma
        self.co = co
        self.cg = cg
        self.codedWidth = codedWidth
        self.codedHeight = codedHeight
    }
}

public enum YCoCgTransform {

    /// Forward-transform a tightly-packed RGBA buffer (presentation
    /// dims) into Y/Co/Cg planes at coded dimensions. Coded dimensions
    /// must each be >= presentation and multiples of 2 (the chroma
    /// subsample ratio). For DXV3 HQ the caller passes 16-aligned
    /// coded dims; padding rows / cols beyond presentation are filled
    /// from RGB=(0,0,0) which transforms to Y=0, Co=0, Cg=0 — i.e.
    /// Co_stored=Cg_stored=128 over the pad region.
    public static func ycocgFromRGBA(
        rgba: UnsafePointer<UInt8>,
        presentationWidth: Int, presentationHeight: Int,
        codedWidth: Int, codedHeight: Int
    ) -> YCoCgPlanes {
        precondition(codedWidth >= presentationWidth && codedWidth % 2 == 0)
        precondition(codedHeight >= presentationHeight && codedHeight % 2 == 0)
        precondition(presentationWidth >= 0 && presentationHeight >= 0)

        var luma = [UInt8](repeating: 0, count: codedWidth * codedHeight)
        let chromaW = codedWidth / 2
        let chromaH = codedHeight / 2
        // Pre-fill chroma with 128 so unwritten pad cells encode
        // signed-zero chroma (matches the (R=0,G=0,B=0) → Co=0,Cg=0
        // value of zero-fill RGB padding). Avoids a separate pad pass.
        var co = [UInt8](repeating: 128, count: chromaW * chromaH)
        var cg = [UInt8](repeating: 128, count: chromaW * chromaH)

        // Walk source 2 rows at a time so we can fold 2×2 RGB tiles
        // into one chroma sample.
        var y = 0
        while y < presentationHeight {
            let y1 = y + 1
            let lumaRow0 = y * codedWidth
            let lumaRow1 = y1 * codedWidth
            let chromaRowBase = (y / 2) * chromaW
            // RGBA source rows. Source stride = presentationWidth * 4
            // (presentation dims, NOT coded — the buffer passed in
            // is the presentation-sized RGBA from the BGRA copy step).
            let srcRow0 = rgba.advanced(by: y * presentationWidth * 4)
            let srcRow1 = (y1 < presentationHeight)
                ? rgba.advanced(by: y1 * presentationWidth * 4)
                : nil

            var x = 0
            while x < presentationWidth {
                let x1 = x + 1
                let p00 = srcRow0.advanced(by: x * 4)
                let p10 = (x1 < presentationWidth)
                    ? srcRow0.advanced(by: x1 * 4)
                    : nil
                let p01 = srcRow1?.advanced(by: x * 4)
                let p11 = (srcRow1 != nil && x1 < presentationWidth)
                    ? srcRow1!.advanced(by: x1 * 4)
                    : nil

                // Per-pixel YCoCg for the 1..4 corners that exist.
                var co_sum = 0
                var cg_sum = 0
                var count = 0

                let (y00, co00, cg00) = ycocg(p00)
                luma[lumaRow0 + x] = y00
                co_sum += co00; cg_sum += cg00; count += 1

                if let p10 = p10 {
                    let (y10, co10, cg10) = ycocg(p10)
                    luma[lumaRow0 + x1] = y10
                    co_sum += co10; cg_sum += cg10; count += 1
                }
                if let p01 = p01 {
                    let (y01, co01, cg01) = ycocg(p01)
                    luma[lumaRow1 + x] = y01
                    co_sum += co01; cg_sum += cg01; count += 1
                }
                if let p11 = p11 {
                    let (y11, co11, cg11) = ycocg(p11)
                    luma[lumaRow1 + x1] = y11
                    co_sum += co11; cg_sum += cg11; count += 1
                }

                // Average; round-to-nearest with +count/2 bias. For
                // count=4 this is the standard `+2 >> 2`; for partial
                // tiles at the right/bottom presentation edge we
                // divide by the actual count.
                let co_avg = divRoundNearest(co_sum, count)
                let cg_avg = divRoundNearest(cg_sum, count)
                let chromaIdx = chromaRowBase + (x / 2)
                co[chromaIdx] = UInt8(clamping: co_avg + 128)
                cg[chromaIdx] = UInt8(clamping: cg_avg + 128)

                x += 2
            }
            y += 2
        }

        return YCoCgPlanes(luma: luma, co: co, cg: cg,
                           codedWidth: codedWidth, codedHeight: codedHeight)
    }

    /// Per-pixel non-reversible YCoCg transform.
    /// Returns (Y in [0,255], Co_signed in [-128,127], Cg_signed in [-128,127]).
    @inline(__always)
    public static func ycocg(_ rgba: UnsafePointer<UInt8>) -> (UInt8, Int, Int) {
        let r = Int(rgba[0])
        let g = Int(rgba[1])
        let b = Int(rgba[2])
        // Y is always non-negative; +2 bias rounds to nearest.
        let y = (r + 2 * g + b + 2) >> 2
        // Co/Cg are signed; arithmetic right shift floors negatives.
        // Range stays in [-128, 127] without explicit rounding.
        let co = (r - b) >> 1
        let cg = (-r + 2 * g - b) >> 2
        return (UInt8(y), co, cg)
    }

    /// Integer round-to-nearest division for signed numerator and
    /// positive divisor. Used to average per-pixel chroma values into
    /// the subsampled 2×2 cell. Works correctly across the sign change
    /// at zero (Swift's `/` truncates toward zero, which biases averages
    /// asymmetrically; this helper compensates).
    @inline(__always)
    static func divRoundNearest(_ num: Int, _ den: Int) -> Int {
        precondition(den > 0)
        if num >= 0 {
            return (num + den / 2) / den
        } else {
            return -((-num + den / 2) / den)
        }
    }

    /// Inverse YCoCg: stored chroma bytes + Y byte → reconstructed RGB.
    /// Same formula GlanceCore's CPURender uses. Used by tests to
    /// verify round-trip; not part of the encoder hot path.
    @inline(__always)
    public static func inverseYCoCg(
        y: UInt8, coStored: UInt8, cgStored: UInt8
    ) -> (r: UInt8, g: UInt8, b: UInt8) {
        let yI = Int(y)
        let coI = Int(coStored) - 128
        let cgI = Int(cgStored) - 128
        let t = yI - cgI
        let r = clamp255(t + coI)
        let g = clamp255(yI + cgI)
        let b = clamp255(t - coI)
        return (UInt8(r), UInt8(g), UInt8(b))
    }

    @inline(__always)
    private static func clamp255(_ v: Int) -> Int {
        return min(255, max(0, v))
    }
}
