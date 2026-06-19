// SPDX-License-Identifier: MIT
/*
 * BC1 (DXT1) block encoder.
 *
 * Swift port of FFmpeg's libavcodec/texturedspenc.c (compress_color and
 * helpers — constant_color, optimize_colors, match_colors, refine_colors,
 * lerp13rgb, rgb5652rgb, expand5/expand6/match5/match6 lookup tables).
 *
 * Original C: Copyright (C) 2015 Vittorio Giovara <vittorio.giovara@gmail.com>,
 * based on public-domain code by Fabian Giesen, Sean Barrett, Yann Collet.
 * Distributed under the MIT license (per the texturedspenc.c header).
 *
 * Swift port: GlEnc, 2026. Faithful line-by-line translation. The float
 * math in optimize_colors / refine_colors is the byte-identity contract
 * with FFmpeg's DXT1 encoder — operation order and Float vs Double widths
 * must match the C source exactly.
 */

import Foundation

// MARK: - Lookup tables (verbatim from texturedspenc.c)

@usableFromInline
let bc1Expand5: [UInt8] = [
      0,   8,  16,  24,  33,  41,  49,  57,  66,  74,  82,  90,
     99, 107, 115, 123, 132, 140, 148, 156, 165, 173, 181, 189,
    198, 206, 214, 222, 231, 239, 247, 255,
]

@usableFromInline
let bc1Expand6: [UInt8] = [
      0,   4,   8,  12,  16,  20,  24,  28,  32,  36,  40,  44,
     48,  52,  56,  60,  65,  69,  73,  77,  81,  85,  89,  93,
     97, 101, 105, 109, 113, 117, 121, 125, 130, 134, 138, 142,
    146, 150, 154, 158, 162, 166, 170, 174, 178, 182, 186, 190,
    195, 199, 203, 207, 211, 215, 219, 223, 227, 231, 235, 239,
    243, 247, 251, 255,
]

/// match5[v] = (a, b) → for 8-bit v, the optimal (max5, min5) endpoint pair.
/// Stored flat as [a0,b0,a1,b1,...] for simpler indexing. Length = 512.
@usableFromInline
let bc1Match5: [UInt8] = [
      0,  0,   0,  0,   0,  1,   0,  1,   1,  0,   1,  0,
      1,  0,   1,  1,   1,  1,   2,  0,   2,  0,   0,  4,
      2,  1,   2,  1,   2,  1,   3,  0,   3,  0,   3,  0,
      3,  1,   1,  5,   3,  2,   3,  2,   4,  0,   4,  0,
      4,  1,   4,  1,   4,  2,   4,  2,   4,  2,   3,  5,
      5,  1,   5,  1,   5,  2,   4,  4,   5,  3,   5,  3,
      5,  3,   6,  2,   6,  2,   6,  2,   6,  3,   5,  5,
      6,  4,   6,  4,   4,  8,   7,  3,   7,  3,   7,  3,
      7,  4,   7,  4,   7,  4,   7,  5,   5,  9,   7,  6,
      7,  6,   8,  4,   8,  4,   8,  5,   8,  5,   8,  6,
      8,  6,   8,  6,   7,  9,   9,  5,   9,  5,   9,  6,
      8,  8,   9,  7,   9,  7,   9,  7,  10,  6,  10,  6,
     10,  6,  10,  7,   9,  9,  10,  8,  10,  8,   8, 12,
     11,  7,  11,  7,  11,  7,  11,  8,  11,  8,  11,  8,
     11,  9,   9, 13,  11, 10,  11, 10,  12,  8,  12,  8,
     12,  9,  12,  9,  12, 10,  12, 10,  12, 10,  11, 13,
     13,  9,  13,  9,  13, 10,  12, 12,  13, 11,  13, 11,
     13, 11,  14, 10,  14, 10,  14, 10,  14, 11,  13, 13,
     14, 12,  14, 12,  12, 16,  15, 11,  15, 11,  15, 11,
     15, 12,  15, 12,  15, 12,  15, 13,  13, 17,  15, 14,
     15, 14,  16, 12,  16, 12,  16, 13,  16, 13,  16, 14,
     16, 14,  16, 14,  15, 17,  17, 13,  17, 13,  17, 14,
     16, 16,  17, 15,  17, 15,  17, 15,  18, 14,  18, 14,
     18, 14,  18, 15,  17, 17,  18, 16,  18, 16,  16, 20,
     19, 15,  19, 15,  19, 15,  19, 16,  19, 16,  19, 16,
     19, 17,  17, 21,  19, 18,  19, 18,  20, 16,  20, 16,
     20, 17,  20, 17,  20, 18,  20, 18,  20, 18,  19, 21,
     21, 17,  21, 17,  21, 18,  20, 20,  21, 19,  21, 19,
     21, 19,  22, 18,  22, 18,  22, 18,  22, 19,  21, 21,
     22, 20,  22, 20,  20, 24,  23, 19,  23, 19,  23, 19,
     23, 20,  23, 20,  23, 20,  23, 21,  21, 25,  23, 22,
     23, 22,  24, 20,  24, 20,  24, 21,  24, 21,  24, 22,
     24, 22,  24, 22,  23, 25,  25, 21,  25, 21,  25, 22,
     24, 24,  25, 23,  25, 23,  25, 23,  26, 22,  26, 22,
     26, 22,  26, 23,  25, 25,  26, 24,  26, 24,  24, 28,
     27, 23,  27, 23,  27, 23,  27, 24,  27, 24,  27, 24,
     27, 25,  25, 29,  27, 26,  27, 26,  28, 24,  28, 24,
     28, 25,  28, 25,  28, 26,  28, 26,  28, 26,  27, 29,
     29, 25,  29, 25,  29, 26,  28, 28,  29, 27,  29, 27,
     29, 27,  30, 26,  30, 26,  30, 26,  30, 27,  29, 29,
     30, 28,  30, 28,  30, 28,  31, 27,  31, 27,  31, 27,
     31, 28,  31, 28,  31, 28,  31, 29,  31, 29,  31, 30,
     31, 30,  31, 30,  31, 31,  31, 31,
]

/// match6[v] = (a, b) → for 8-bit v, the optimal (max6, min6) endpoint pair.
@usableFromInline
let bc1Match6: [UInt8] = [
      0,  0,   0,  1,   1,  0,   1,  0,   1,  1,   2,  0,
      2,  1,   3,  0,   3,  0,   3,  1,   4,  0,   4,  0,
      4,  1,   5,  0,   5,  1,   6,  0,   6,  0,   6,  1,
      7,  0,   7,  0,   7,  1,   8,  0,   8,  1,   8,  1,
      8,  2,   9,  1,   9,  2,   9,  2,   9,  3,  10,  2,
     10,  3,  10,  3,  10,  4,  11,  3,  11,  4,  11,  4,
     11,  5,  12,  4,  12,  5,  12,  5,  12,  6,  13,  5,
     13,  6,   8, 16,  13,  7,  14,  6,  14,  7,   9, 17,
     14,  8,  15,  7,  15,  8,  11, 16,  15,  9,  15, 10,
     16,  8,  16,  9,  16, 10,  15, 13,  17,  9,  17, 10,
     17, 11,  15, 16,  18, 10,  18, 11,  18, 12,  16, 16,
     19, 11,  19, 12,  19, 13,  17, 17,  20, 12,  20, 13,
     20, 14,  19, 16,  21, 13,  21, 14,  21, 15,  20, 17,
     22, 14,  22, 15,  25, 10,  22, 16,  23, 15,  23, 16,
     26, 11,  23, 17,  24, 16,  24, 17,  27, 12,  24, 18,
     25, 17,  25, 18,  28, 13,  25, 19,  26, 18,  26, 19,
     29, 14,  26, 20,  27, 19,  27, 20,  30, 15,  27, 21,
     28, 20,  28, 21,  28, 21,  28, 22,  29, 21,  29, 22,
     24, 32,  29, 23,  30, 22,  30, 23,  25, 33,  30, 24,
     31, 23,  31, 24,  27, 32,  31, 25,  31, 26,  32, 24,
     32, 25,  32, 26,  31, 29,  33, 25,  33, 26,  33, 27,
     31, 32,  34, 26,  34, 27,  34, 28,  32, 32,  35, 27,
     35, 28,  35, 29,  33, 33,  36, 28,  36, 29,  36, 30,
     35, 32,  37, 29,  37, 30,  37, 31,  36, 33,  38, 30,
     38, 31,  41, 26,  38, 32,  39, 31,  39, 32,  42, 27,
     39, 33,  40, 32,  40, 33,  43, 28,  40, 34,  41, 33,
     41, 34,  44, 29,  41, 35,  42, 34,  42, 35,  45, 30,
     42, 36,  43, 35,  43, 36,  46, 31,  43, 37,  44, 36,
     44, 37,  44, 37,  44, 38,  45, 37,  45, 38,  40, 48,
     45, 39,  46, 38,  46, 39,  41, 49,  46, 40,  47, 39,
     47, 40,  43, 48,  47, 41,  47, 42,  48, 40,  48, 41,
     48, 42,  47, 45,  49, 41,  49, 42,  49, 43,  47, 48,
     50, 42,  50, 43,  50, 44,  48, 48,  51, 43,  51, 44,
     51, 45,  49, 49,  52, 44,  52, 45,  52, 46,  51, 48,
     53, 45,  53, 46,  53, 47,  52, 49,  54, 46,  54, 47,
     57, 42,  54, 48,  55, 47,  55, 48,  58, 43,  55, 49,
     56, 48,  56, 49,  59, 44,  56, 50,  57, 49,  57, 50,
     60, 45,  57, 51,  58, 50,  58, 51,  61, 46,  58, 52,
     59, 51,  59, 52,  62, 47,  59, 53,  60, 52,  60, 53,
     60, 53,  60, 54,  61, 53,  61, 54,  61, 54,  61, 55,
     62, 54,  62, 55,  62, 55,  62, 56,  63, 55,  63, 56,
     63, 56,  63, 57,  63, 58,  63, 59,  63, 59,  63, 60,
     63, 61,  63, 62,  63, 62,  63, 63,
]

// MARK: - Inline scalar helpers

/// Multiplication over 8-bit emulation. mul8(a,b) = ((a*b + 128 + ((a*b + 128) >> 8)) >> 8)
@inline(__always)
@usableFromInline
func bc1Mul8(_ a: Int, _ b: Int) -> Int {
    let t = a &* b &+ 128
    return (t &+ (t >> 8)) >> 8
}

/// Pack r,g,b (8-bit each) → RGB565.
@inline(__always)
@usableFromInline
func bc1Rgb2Rgb565(_ r: Int, _ g: Int, _ b: Int) -> UInt16 {
    return UInt16((bc1Mul8(r, 31) << 11) | (bc1Mul8(g, 63) << 5) | bc1Mul8(b, 31))
}

/// Linear interpolation at the 1/3 point between a and b.
@inline(__always)
@usableFromInline
func bc1Lerp13(_ a: Int, _ b: Int) -> Int {
    return (2 &* a &+ b) / 3
}

/// Unpack RGB565 → 4 bytes [r,g,b,0].
@inline(__always)
@usableFromInline
func bc1Rgb5652rgb(_ out: UnsafeMutablePointer<UInt8>, _ v: UInt16) {
    let rv = Int((v & 0xf800) >> 11)
    let gv = Int((v & 0x07e0) >> 5)
    let bv = Int((v & 0x001f) >> 0)
    out[0] = bc1Expand5[rv]
    out[1] = bc1Expand6[gv]
    out[2] = bc1Expand5[bv]
    out[3] = 0
}

/// 1/3-point lerp on three 8-bit channels.
@inline(__always)
@usableFromInline
func bc1Lerp13rgb(_ out: UnsafeMutablePointer<UInt8>,
                  _ p1: UnsafePointer<UInt8>,
                  _ p2: UnsafePointer<UInt8>) {
    out[0] = UInt8(bc1Lerp13(Int(p1[0]), Int(p2[0])))
    out[1] = UInt8(bc1Lerp13(Int(p1[1]), Int(p2[1])))
    out[2] = UInt8(bc1Lerp13(Int(p1[2]), Int(p2[2])))
}

/// Clamp to [0, (1<<p)-1] — equivalent to FFmpeg's av_clip_uintp2 for p in {5,6}.
@inline(__always)
@usableFromInline
func bc1ClipUintp2_5(_ a: Int) -> Int {
    if a < 0 { return 0 }
    if a > 31 { return 31 }
    return a
}

@inline(__always)
@usableFromInline
func bc1ClipUintp2_6(_ a: Int) -> Int {
    if a < 0 { return 0 }
    if a > 63 { return 63 }
    return a
}

// MARK: - Block-level helpers

/// constant_color(): true if every pixel in the 4×4 block has identical RGBA.
@inline(__always)
@usableFromInline
func bc1ConstantColor(_ block: UnsafePointer<UInt8>, _ stride: Int) -> Bool {
    let first = block.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
    for y in 0..<4 {
        for x in 0..<4 {
            let p = block.advanced(by: x * 4 + y * stride)
            let v = p.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
            if v != first { return false }
        }
    }
    return true
}

/// Match decoded palette colors against block pixels along the principal axis.
/// Mirrors texturedspenc.c match_colors line-by-line.
@usableFromInline
func bc1MatchColors(_ block: UnsafePointer<UInt8>,
                    _ stride: Int,
                    _ c0: UInt16,
                    _ c1: UInt16) -> UInt32 {
    var mask: UInt32 = 0
    var dots = [Int](repeating: 0, count: 16)
    var stops = [Int](repeating: 0, count: 4)
    var color = [UInt8](repeating: 0, count: 16)

    let indexMap: [UInt32] = [
        0 << 30, 2 << 30, 0 << 30, 2 << 30,
        3 << 30, 3 << 30, 1 << 30, 1 << 30,
    ]

    color.withUnsafeMutableBufferPointer { colorBuf in
        let cp = colorBuf.baseAddress!
        bc1Rgb5652rgb(cp + 0,  c0)
        bc1Rgb5652rgb(cp + 4,  c1)
        bc1Lerp13rgb(cp + 8,  cp + 0, cp + 4)
        bc1Lerp13rgb(cp + 12, cp + 4, cp + 0)
    }

    let dirr = Int(color[0 * 4 + 0]) - Int(color[1 * 4 + 0])
    let dirg = Int(color[0 * 4 + 1]) - Int(color[1 * 4 + 1])
    let dirb = Int(color[0 * 4 + 2]) - Int(color[1 * 4 + 2])

    var k = 0
    for y in 0..<4 {
        for x in 0..<4 {
            let p = block.advanced(by: x * 4 + y * stride)
            dots[k] = Int(p[0]) * dirr + Int(p[1]) * dirg + Int(p[2]) * dirb
            k += 1
        }
        stops[y] = Int(color[0 + y * 4]) * dirr +
                   Int(color[1 + y * 4]) * dirg +
                   Int(color[2 + y * 4]) * dirb
    }

    let c0_point   = (stops[1] + stops[3]) >> 1
    let half_point = (stops[3] + stops[2]) >> 1
    let c3_point   = (stops[2] + stops[0]) >> 1

    for x in 0..<16 {
        let dot = dots[x]
        let bits = ((dot < half_point) ? 4 : 0) |
                   ((dot < c0_point  ) ? 2 : 0) |
                   ((dot < c3_point  ) ? 1 : 0)
        mask >>= 2
        mask  |= indexMap[bits]
    }
    return mask
}

/// optimize_colors(): PCA + power iteration on the block, pick endpoints at
/// extreme projections. Mirrors texturedspenc.c optimize_colors.
///
/// FLOAT/DOUBLE WIDTH MATCHING NOTE: covf, vfr, vfg, vfb are float32; magn is
/// double. C does float→double promotion when mixing in `vfr * magn`. Mirror
/// that explicitly with `Double(vfr) * magn`.
@usableFromInline
func bc1OptimizeColors(_ block: UnsafePointer<UInt8>,
                       _ stride: Int,
                       _ pmax16: UnsafeMutablePointer<UInt16>,
                       _ pmin16: UnsafeMutablePointer<UInt16>) {
    let iter_power = 4
    var cov = [Int](repeating: 0, count: 6)
    var mu = [Int](repeating: 0, count: 3)
    var minc = [Int](repeating: 0, count: 3)
    var maxc = [Int](repeating: 0, count: 3)

    // Determine color distribution per channel
    for ch in 0..<3 {
        let bp0 = Int(block[ch])
        var muv = bp0
        var minv = bp0
        var maxv = bp0
        for y in 0..<4 {
            for x in 0..<4 {
                let v = Int(block[ch + x * 4 + y * stride])
                muv += v
                if v < minv { minv = v }
                else if v > maxv { maxv = v }
            }
        }
        mu[ch]   = (muv + 8) >> 4
        minc[ch] = minv
        maxc[ch] = maxv
    }

    // Determine covariance matrix
    for y in 0..<4 {
        for x in 0..<4 {
            let r = Int(block[0 + x * 4 + stride * y]) - mu[0]
            let g = Int(block[1 + x * 4 + stride * y]) - mu[1]
            let b = Int(block[2 + x * 4 + stride * y]) - mu[2]
            cov[0] += r * r
            cov[1] += r * g
            cov[2] += r * b
            cov[3] += g * g
            cov[4] += g * b
            cov[5] += b * b
        }
    }

    // Convert covariance to float, find principal axis via power iteration
    var covf = [Float](repeating: 0, count: 6)
    for x in 0..<6 {
        covf[x] = Float(cov[x]) / Float(255.0)
    }

    var vfr = Float(maxc[0] - minc[0])
    var vfg = Float(maxc[1] - minc[1])
    var vfb = Float(maxc[2] - minc[2])

    for _ in 0..<iter_power {
        // FFmpeg's release build (clang -O2) contracts these expressions
        // into FMA instructions. The instruction scheduling clang chose
        // does the standalone (un-fused) multiplication on the vfg term
        // first — vfg is loaded once into a scalar register and reused
        // across all three formulas — then FMAs the vfr and vfb terms.
        // Mirror exactly: standalone `vfg * covf[?]`, then two FMAs.
        // This is required for byte-identity with `ffmpeg.mov`. Verified
        // by disassembling clang -O2 output of texturedspenc.c.
        let rInner = vfg * covf[1]
        let rMid   = rInner.addingProduct(vfr, covf[0])
        let r      = rMid.addingProduct(vfb, covf[2])
        let gInner = vfg * covf[3]
        let gMid   = gInner.addingProduct(vfr, covf[1])
        let g      = gMid.addingProduct(vfb, covf[4])
        let bInner = vfg * covf[4]
        let bMid   = bInner.addingProduct(vfr, covf[2])
        let b      = bMid.addingProduct(vfb, covf[5])
        vfr = r
        vfg = g
        vfb = b
    }

    var magn = Double(abs(vfr))
    if Double(abs(vfg)) > magn { magn = Double(abs(vfg)) }
    if Double(abs(vfb)) > magn { magn = Double(abs(vfb)) }

    let v_r: Int
    let v_g: Int
    let v_b: Int
    // The C source compares magn (double) < 4.0f. The literal 4.0f promotes
    // to double for the comparison.
    if magn < 4.0 {
        // JPEG YCbCr luma coefs, scaled by 1000
        v_r = 299
        v_g = 587
        v_b = 114
    } else {
        magn = 512.0 / magn
        // C: v_r = (int)(vfr * magn). vfr is float, magn is double → promote
        // float to double, multiply, then cast to int (truncate toward zero).
        v_r = Int(Double(vfr) * magn)
        v_g = Int(Double(vfg) * magn)
        v_b = Int(Double(vfb) * magn)
    }

    // Pick colors at extreme projections
    var mind = Int(block[0]) * v_r + Int(block[1]) * v_g + Int(block[2]) * v_b
    var maxd = mind
    var minp: UnsafePointer<UInt8> = block
    var maxp: UnsafePointer<UInt8> = block
    for y in 0..<4 {
        for x in 0..<4 {
            let p = block.advanced(by: x * 4 + y * stride)
            let dot = Int(p[0]) * v_r + Int(p[1]) * v_g + Int(p[2]) * v_b
            if dot < mind {
                mind = dot
                minp = p
            } else if dot > maxd {
                maxd = dot
                maxp = p
            }
        }
    }

    pmax16.pointee = bc1Rgb2Rgb565(Int(maxp[0]), Int(maxp[1]), Int(maxp[2]))
    pmin16.pointee = bc1Rgb2Rgb565(Int(minp[0]), Int(minp[1]), Int(minp[2]))
}

/// refine_colors(): least-squares solve to nudge endpoints. Mirrors
/// texturedspenc.c refine_colors. Returns true if endpoints changed.
@usableFromInline
func bc1RefineColors(_ block: UnsafePointer<UInt8>,
                     _ stride: Int,
                     _ pmax16: UnsafeMutablePointer<UInt16>,
                     _ pmin16: UnsafeMutablePointer<UInt16>,
                     _ mask: UInt32) -> Bool {
    var cm = mask
    let oldMin = pmin16.pointee
    let oldMax = pmax16.pointee
    let min16: UInt16
    let max16: UInt16

    // Magic tables for least-squares accumulation
    let w1tab: [Int] = [3, 0, 2, 1]
    let prods: [Int] = [0x090000, 0x000900, 0x040102, 0x010402]

    // "all pixels have the same index" check: mask ^ (mask << 2) < 4
    // This works because if all 16 indices match, mask = II II … II II (16
    // copies of the same 2-bit value); mask << 2 shifts in two zeros at the
    // bottom and shifts off the top, so the XOR has nonzero bits only in the
    // bottom 2 (top bits cancel because identical) — value < 4.
    if (mask ^ (mask << 2)) < 4 {
        // Singular system → match the average color.
        var r = 8, g = 8, b = 8
        for y in 0..<4 {
            for x in 0..<4 {
                r += Int(block[0 + x * 4 + y * stride])
                g += Int(block[1 + x * 4 + y * stride])
                b += Int(block[2 + x * 4 + y * stride])
            }
        }
        r >>= 4
        g >>= 4
        b >>= 4
        max16 = UInt16((Int(bc1Match5[r * 2 + 0]) << 11) |
                       (Int(bc1Match6[g * 2 + 0]) <<  5) |
                        Int(bc1Match5[b * 2 + 0]))
        min16 = UInt16((Int(bc1Match5[r * 2 + 1]) << 11) |
                       (Int(bc1Match6[g * 2 + 1]) <<  5) |
                        Int(bc1Match5[b * 2 + 1]))
    } else {
        var at1_r = 0, at1_g = 0, at1_b = 0
        var at2_r = 0, at2_g = 0, at2_b = 0
        var akku = 0

        for y in 0..<4 {
            for x in 0..<4 {
                let step = Int(cm & 3)
                let w1 = w1tab[step]
                let r = Int(block[0 + x * 4 + y * stride])
                let g = Int(block[1 + x * 4 + y * stride])
                let b = Int(block[2 + x * 4 + y * stride])
                akku  += prods[step]
                at1_r += w1 * r
                at1_g += w1 * g
                at1_b += w1 * b
                at2_r += r
                at2_g += g
                at2_b += b
                cm >>= 2
            }
        }

        at2_r = 3 * at2_r - at1_r
        at2_g = 3 * at2_g - at1_g
        at2_b = 3 * at2_b - at1_b

        let xx = (akku >> 16) & 0xFF
        let yy = (akku >>  8) & 0xFF
        let xy = (akku >>  0) & 0xFF

        // C: fr = 3.0f * 31.0f / 255.0f / (xx*yy - xy*xy);
        // (xx*yy - xy*xy) is int, promoted to float for the division. The
        // operations are split into separate statements deliberately to
        // suppress FMA contraction — when `a * b + c` appears as one
        // expression Swift's optimizer may fuse to fmadd, which produces a
        // different result from the unfused C reference. ff-mpeg's reference
        // build (default Apple clang) doesn't contract here.
        let denom = Float(xx * yy - xy * xy)
        let fr1: Float = Float(3.0) * Float(31.0)
        let fr2: Float = fr1 / Float(255.0)
        let fr:  Float = fr2 / denom
        let fg1: Float = fr * Float(63.0)
        let fg:  Float = fg1 / Float(31.0)
        let fb:  Float = fr

        // av_clip_uintp2((expr) * f + 0.5f, p) — float math, then cast to int
        // (truncation toward zero), then clip. clang's -O2 fuses `x*y + 0.5f`
        // into a single fma; mirror with `addingProduct` for byte-identity.
        let mrI = at1_r * yy - at2_r * xy
        let mr2: Float = Float(0.5).addingProduct(Float(mrI), fr)
        let mr = bc1ClipUintp2_5(Int(mr2))
        let mgI = at1_g * yy - at2_g * xy
        let mg2: Float = Float(0.5).addingProduct(Float(mgI), fg)
        let mg = bc1ClipUintp2_6(Int(mg2))
        let mbI = at1_b * yy - at2_b * xy
        let mb2: Float = Float(0.5).addingProduct(Float(mbI), fb)
        let mb = bc1ClipUintp2_5(Int(mb2))
        max16 = UInt16((mr << 11) | (mg << 5) | mb)

        let nrI = at2_r * xx - at1_r * xy
        let nr2: Float = Float(0.5).addingProduct(Float(nrI), fr)
        let nr = bc1ClipUintp2_5(Int(nr2))
        let ngI = at2_g * xx - at1_g * xy
        let ng2: Float = Float(0.5).addingProduct(Float(ngI), fg)
        let ng = bc1ClipUintp2_6(Int(ng2))
        let nbI = at2_b * xx - at1_b * xy
        let nb2: Float = Float(0.5).addingProduct(Float(nbI), fb)
        let nb = bc1ClipUintp2_5(Int(nb2))
        min16 = UInt16((nr << 11) | (ng << 5) | nb)
    }

    pmin16.pointee = min16
    pmax16.pointee = max16
    return oldMin != min16 || oldMax != max16
}

// MARK: - Public API

/// Encode one 4×4 RGBA tile to an 8-byte BC1 (DXT1) block.
///
/// - `block`: pointer to the top-left RGBA pixel of the 4×4 tile inside a
///   larger image. Bytes are R, G, B, A per pixel; alpha is ignored.
/// - `stride`: bytes per row of the SOURCE image (e.g. width*4). The 4 rows
///   of the tile are at `block`, `block+stride`, `block+2*stride`, `block+3*stride`.
/// - `dst`: 8-byte output. Layout: `[max16 LE][min16 LE][indices LE32]`.
///
/// Dispatches to one of two algorithms based on `BC1Config.useClusterFit`:
///   - `true` (default, v0.5.0+): Squish-style ClusterFit endpoint search.
///     Higher fidelity to source. See `BC1BlockEncoderClusterFit.swift`.
///   - `false` (legacy, v0.2.0 contract): FFmpeg byte-identical PCA + 1×
///     refine. The Phase 2A development contract — produces output
///     bit-identical to `ffmpeg -c:v dxv -format dxt1`. Kept for A/B
///     testing and as a safety fallback.
@inlinable
public func encodeBC1Block(
    block: UnsafePointer<UInt8>,
    stride: Int,
    dst: UnsafeMutablePointer<UInt8>
) {
    if BC1Config.useClusterFit {
        encodeBC1BlockClusterFit(block: block, stride: stride, dst: dst)
    } else {
        encodeBC1BlockFFmpeg(block: block, stride: stride, dst: dst)
    }
}

/// FFmpeg `texturedspenc.c` BC1 endpoint search — the v0.2.0 development
/// contract. Byte-identical to `ffmpeg -c:v dxv -format dxt1`. Retired
/// from the default encoder path in v0.5.0 in favor of ClusterFit, but
/// kept callable for legacy byte-identity tests.
@inlinable
public func encodeBC1BlockFFmpeg(
    block: UnsafePointer<UInt8>,
    stride: Int,
    dst: UnsafeMutablePointer<UInt8>
) {
    var max16: UInt16 = 0
    var min16: UInt16 = 0
    var mask: UInt32 = 0

    if bc1ConstantColor(block, stride) {
        let r = Int(block[0])
        let g = Int(block[1])
        let b = Int(block[2])
        mask  = 0xAAAAAAAA
        max16 = UInt16((Int(bc1Match5[r * 2 + 0]) << 11) |
                       (Int(bc1Match6[g * 2 + 0]) <<  5) |
                        Int(bc1Match5[b * 2 + 0]))
        min16 = UInt16((Int(bc1Match5[r * 2 + 1]) << 11) |
                       (Int(bc1Match6[g * 2 + 1]) <<  5) |
                        Int(bc1Match5[b * 2 + 1]))
    } else {
        bc1OptimizeColors(block, stride, &max16, &min16)
        if max16 != min16 {
            mask = bc1MatchColors(block, stride, max16, min16)
        } else {
            mask = 0
        }
        let refined = bc1RefineColors(block, stride, &max16, &min16, mask)
        if refined {
            if max16 != min16 {
                mask = bc1MatchColors(block, stride, max16, min16)
            } else {
                mask = 0
            }
        }
    }

    // DXT1 4-color mode requires max16 > min16. If endpoints came out swapped,
    // swap them and flip the mask's parity so the 0/1 indices reverse.
    if max16 < min16 {
        let t = max16; max16 = min16; min16 = t
        mask ^= 0x55555555
    }

    // Write little-endian: max16, min16, mask
    dst[0] = UInt8(max16 & 0xFF)
    dst[1] = UInt8((max16 >> 8) & 0xFF)
    dst[2] = UInt8(min16 & 0xFF)
    dst[3] = UInt8((min16 >> 8) & 0xFF)
    dst[4] = UInt8(mask & 0xFF)
    dst[5] = UInt8((mask >> 8) & 0xFF)
    dst[6] = UInt8((mask >> 16) & 0xFF)
    dst[7] = UInt8((mask >> 24) & 0xFF)
}
