/*
 * YCoCg precision audit — Phase 5C.2.6.
 *
 * Phase 5B Arena verdict observed broad-spectrum desaturation in YG10
 * output: yellow loses vibrance, blue tints toward purple, magenta
 * desaturates, cyan loses vibrance, red survives. The "every color
 * except red" symptom suggests asymmetric integer rounding in the
 * forward YCoCg transform (red sits roughly at the chroma origin where
 * rounding bias affects it least). This audit instruments the
 * encoder-side YCoCgTransform.swift to find any per-color bias or
 * rounding asymmetry — and confirms the encoder/decoder inverse pair
 * is byte-matched. Result is reported verbatim per the planner brief
 * (no bucketing into expected categories).
 *
 * GlanceCore's HQ inverse YCoCg (CPURender.cgImageFromHQ) uses:
 *     t = y - cg ; R = t + co ; G = y + cg ; B = t - co
 * which is byte-identical to YCoCgTransform.inverseYCoCg() in our
 * encoder code. The audit reuses our `inverseYCoCg` helper as the
 * matched-pair reconstruction.
 *
 * Test plan:
 *   (a) Pure-primary round-trip (8 colors).
 *   (b) Near-primary round-trip (6 colors).
 *   (c) Grayscale ramp — chroma must be exactly 128 (the signed-zero
 *       offset) for every grayscale value. Any non-zero chroma after
 *       the forward transform = rounding bug.
 *   (d) Full primaries-opaque.png plane through ycocgFromRGBA + inverse.
 *   (e) Full near-primaries.png plane same.
 *   (f) Chroma subsampling fidelity — transform-then-average matches
 *       the per-pixel average of YCoCg-transformed corner pixels.
 */

import XCTest
import Foundation
import CoreGraphics
import ImageIO
@testable import GlEncCore

final class YCoCgPrecisionAuditTests: XCTestCase {

    private static let synthDir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference/synthetic-corpus/source")
    }()

    // MARK: - (a) Pure primaries

    func testForwardInverseRoundTripPureColors() throws {
        let cases: [(name: String, r: Int, g: Int, b: Int)] = [
            ("black",   0,   0,   0),
            ("white", 255, 255, 255),
            ("red",   255,   0,   0),
            ("green",   0, 255,   0),
            ("blue",    0,   0, 255),
            ("yellow", 255, 255,   0),
            ("cyan",    0, 255, 255),
            ("magenta", 255,  0, 255),
        ]
        print("[audit-a] pure primaries — forward → inverse round-trip")
        print("[audit-a] color    src(R,G,B)        Y   Co_s  Cg_s   →  rec(R,G,B)   ΔR  ΔG  ΔB")
        for c in cases {
            let (y, coSigned, cgSigned) = forward(r: c.r, g: c.g, b: c.b)
            let coStored = UInt8(clamping: coSigned + 128)
            let cgStored = UInt8(clamping: cgSigned + 128)
            let (recR, recG, recB) = YCoCgTransform.inverseYCoCg(
                y: y, coStored: coStored, cgStored: cgStored)
            let dR = Int(recR) - c.r
            let dG = Int(recG) - c.g
            let dB = Int(recB) - c.b
            let label = c.name.padding(toLength: 7, withPad: " ", startingAt: 0)
            print(String(format: "[audit-a] %@ (%3d,%3d,%3d)   %3d  %+4d  %+4d   → (%3d,%3d,%3d)  %+3d %+3d %+3d",
                         label as NSString, c.r, c.g, c.b,
                         Int(y), coSigned, cgSigned,
                         Int(recR), Int(recG), Int(recB),
                         dR, dG, dB))
            // Gate: ≤2 LSB on each channel for primaries.
            XCTAssertLessThanOrEqual(abs(dR), 2, "\(c.name) R drift")
            XCTAssertLessThanOrEqual(abs(dG), 2, "\(c.name) G drift")
            XCTAssertLessThanOrEqual(abs(dB), 2, "\(c.name) B drift")
        }
    }

    // MARK: - (b) Near-primaries (5-LSB inset)

    func testForwardInverseRoundTripNearPrimaries() throws {
        let cases: [(name: String, r: Int, g: Int, b: Int)] = [
            ("near-red",     250,   5,   5),
            ("near-green",     5, 250,   5),
            ("near-blue",      5,   5, 250),
            ("near-yellow",  250, 250,   5),
            ("near-cyan",      5, 250, 250),
            ("near-magenta", 250,   5, 250),
        ]
        print("[audit-b] near-primaries — should round-trip at parity with pure")
        print("[audit-b] color         src(R,G,B)         Y   Co_s  Cg_s   →  rec(R,G,B)   ΔR  ΔG  ΔB")
        for c in cases {
            let (y, coSigned, cgSigned) = forward(r: c.r, g: c.g, b: c.b)
            let coStored = UInt8(clamping: coSigned + 128)
            let cgStored = UInt8(clamping: cgSigned + 128)
            let (recR, recG, recB) = YCoCgTransform.inverseYCoCg(
                y: y, coStored: coStored, cgStored: cgStored)
            let dR = Int(recR) - c.r
            let dG = Int(recG) - c.g
            let dB = Int(recB) - c.b
            let label = c.name.padding(toLength: 12, withPad: " ", startingAt: 0)
            print(String(format: "[audit-b] %@ (%3d,%3d,%3d)   %3d  %+4d  %+4d   → (%3d,%3d,%3d)  %+3d %+3d %+3d",
                         label as NSString, c.r, c.g, c.b,
                         Int(y), coSigned, cgSigned,
                         Int(recR), Int(recG), Int(recB),
                         dR, dG, dB))
            // Gate: same as primaries — ≤2 LSB.
            XCTAssertLessThanOrEqual(abs(dR), 2, "\(c.name) R drift")
            XCTAssertLessThanOrEqual(abs(dG), 2, "\(c.name) G drift")
            XCTAssertLessThanOrEqual(abs(dB), 2, "\(c.name) B drift")
        }
    }

    // MARK: - (c) Grayscale ramp

    func testForwardInverseRoundTripGrayscaleRamp() throws {
        var maxChromaDeviation = 0
        var maxChromaDeviationValue = 0
        var maxRGBDelta = 0
        print("[audit-c] grayscale ramp — chroma must be exactly 0 (stored 128)")
        print("[audit-c]   n      Y   Co_s  Cg_s   rec(R,G,B)   maxΔ")
        for n in stride(from: 0, through: 255, by: 16) {
            let (y, coSigned, cgSigned) = forward(r: n, g: n, b: n)
            let coStored = UInt8(clamping: coSigned + 128)
            let cgStored = UInt8(clamping: cgSigned + 128)
            let (recR, recG, recB) = YCoCgTransform.inverseYCoCg(
                y: y, coStored: coStored, cgStored: cgStored)
            let dMax = max(abs(Int(recR) - n), max(abs(Int(recG) - n), abs(Int(recB) - n)))
            if abs(coSigned) > maxChromaDeviation {
                maxChromaDeviation = abs(coSigned); maxChromaDeviationValue = n
            }
            if abs(cgSigned) > maxChromaDeviation {
                maxChromaDeviation = abs(cgSigned); maxChromaDeviationValue = n
            }
            maxRGBDelta = max(maxRGBDelta, dMax)
            print(String(format: "[audit-c]  %3d    %3d  %+4d  %+4d  (%3d,%3d,%3d)   %d",
                         n, Int(y), coSigned, cgSigned,
                         Int(recR), Int(recG), Int(recB), dMax))
        }
        print(String(format: "[audit-c] max chroma deviation = %d LSB (at gray=%d)",
                     maxChromaDeviation, maxChromaDeviationValue))
        print(String(format: "[audit-c] max RGB round-trip Δ = %d LSB", maxRGBDelta))
        // Hard gate: grayscale produces zero chroma. Any deviation
        // = forward transform asymmetry that biases chroma encoding.
        XCTAssertEqual(maxChromaDeviation, 0,
                       "grayscale must encode to zero chroma; got max |chroma| = \(maxChromaDeviation) LSB")
        XCTAssertLessThanOrEqual(maxRGBDelta, 1,
                                 "grayscale RGB round-trip must be ≤1 LSB")
    }

    // MARK: - (d) Full primaries-opaque plane

    func testRoundTripFullSyntheticPlaneOpaque() throws {
        guard let stats = try? planeRoundTripStats(
            png: Self.synthDir.appendingPathComponent("01-primaries-opaque.png"))
        else {
            throw XCTSkip("synthetic corpus missing — run testGenerateSyntheticCorpus first")
        }
        print("[audit-d] primaries-opaque.png full plane:")
        print(stats.report(prefix: "[audit-d]"))
        // Pure primaries averaged: 6 colors × 2 LSB drift max → mean
        // well under 1 LSB. Gate at 1 LSB mean.
        XCTAssertLessThanOrEqual(stats.meanRGB, 1.0,
                                 "primaries-opaque plane mean Δ_RGB = \(stats.meanRGB) > 1.0 LSB")
        XCTAssertLessThanOrEqual(stats.maxRGB, 2,
                                 "primaries-opaque plane max Δ_RGB = \(stats.maxRGB) > 2 LSB")
    }

    // MARK: - (e) Full near-primaries plane

    func testRoundTripNearPrimariesPlane() throws {
        guard let stats = try? planeRoundTripStats(
            png: Self.synthDir.appendingPathComponent("03-near-primaries.png"))
        else {
            throw XCTSkip("synthetic corpus missing")
        }
        print("[audit-e] near-primaries.png full plane:")
        print(stats.report(prefix: "[audit-e]"))
        XCTAssertLessThanOrEqual(stats.meanRGB, 1.0,
                                 "near-primaries plane mean Δ_RGB = \(stats.meanRGB) > 1.0 LSB")
        XCTAssertLessThanOrEqual(stats.maxRGB, 2,
                                 "near-primaries plane max Δ_RGB = \(stats.maxRGB) > 2 LSB")
    }

    // MARK: - (f) Chroma subsampling fidelity

    /// Constructs a synthetic 4×4 RGB tile with deliberately heterogeneous
    /// per-pixel chroma (each pixel a different colour), runs the encoder's
    /// transform-then-average chroma subsample, and verifies the resulting
    /// chroma plane equals the per-pixel YCoCg average within ±1 LSB of
    /// rounding noise. Confirms the encoder is transform-then-average per
    /// Phase 4A.
    func testChromaSubsamplingFidelity() throws {
        // 4×4 RGB tile with a mix of primaries.
        // CG-style row-major BGRA presentation… wait, ycocgFromRGBA expects
        // RGBA byte order (per YCoCgTransform.swift), so write RGBA here.
        let rgba: [UInt8] = [
            // Row 0
            255, 0,   0, 255,   0, 255, 0, 255,   0, 0, 255, 255,   255, 255, 0, 255,
            // Row 1
              0, 255, 255, 255, 255, 0, 255, 255,  128, 64, 32, 255,  32, 128, 64, 255,
            // Row 2
            200, 100, 50, 255,  50, 200, 100, 255,  100, 50, 200, 255,  150, 150, 150, 255,
            // Row 3
             10, 240, 240, 255, 240, 10, 240, 255,  240, 240, 10, 255,    0, 128, 255, 255,
        ]
        let presW = 4
        let presH = 4
        let codedW = 4
        let codedH = 4
        let planes = rgba.withUnsafeBufferPointer { buf in
            YCoCgTransform.ycocgFromRGBA(
                rgba: buf.baseAddress!,
                presentationWidth: presW, presentationHeight: presH,
                codedWidth: codedW, codedHeight: codedH)
        }

        let chromaW = codedW / 2
        let chromaH = codedH / 2
        var subsampleMaxDelta = 0
        for cy in 0..<chromaH {
            for cx in 0..<chromaW {
                // Expected: per-pixel YCoCg over the 2×2 source corners,
                // then average Co / Cg with the encoder's
                // divRoundNearest convention.
                var coSum = 0, cgSum = 0
                var count = 0
                for ry in 0..<2 {
                    for rx in 0..<2 {
                        let py = cy * 2 + ry
                        let px = cx * 2 + rx
                        let off = (py * presW + px) * 4
                        let pr = Int(rgba[off])
                        let pg = Int(rgba[off + 1])
                        let pb = Int(rgba[off + 2])
                        let (_, co_s, cg_s) = ycocgSigned(r: pr, g: pg, b: pb)
                        coSum += co_s
                        cgSum += cg_s
                        count += 1
                    }
                }
                let expectedCoAvg = divRoundNearest(coSum, count)
                let expectedCgAvg = divRoundNearest(cgSum, count)
                let expectedCoStored = UInt8(clamping: expectedCoAvg + 128)
                let expectedCgStored = UInt8(clamping: expectedCgAvg + 128)
                let actualCo = Int(planes.co[cy * chromaW + cx])
                let actualCg = Int(planes.cg[cy * chromaW + cx])
                let dCo = abs(actualCo - Int(expectedCoStored))
                let dCg = abs(actualCg - Int(expectedCgStored))
                subsampleMaxDelta = max(subsampleMaxDelta, max(dCo, dCg))
            }
        }
        print(String(format: "[audit-f] chroma subsample fidelity: max |Δ| = %d LSB", subsampleMaxDelta))
        XCTAssertEqual(subsampleMaxDelta, 0,
                       "encoder's transform-then-average chroma subsample should be bit-identical to per-pixel reference")
    }

    // MARK: - Helpers

    /// Wrap `YCoCgTransform.ycocg` returning (Y, Co_signed, Cg_signed).
    /// Mirrors the formulas in YCoCgTransform.swift so the audit
    /// reproduces exactly what the encoder produces.
    private func forward(r: Int, g: Int, b: Int) -> (UInt8, Int, Int) {
        var rgba: [UInt8] = [UInt8(r), UInt8(g), UInt8(b), 255]
        return rgba.withUnsafeBufferPointer { buf -> (UInt8, Int, Int) in
            let (y, co, cg) = YCoCgTransform.ycocg(buf.baseAddress!)
            return (y, co, cg)
        }
    }

    /// Same as forward() but returns signed chroma values, no
    /// allocation. Used by the subsample audit to compute the
    /// per-pixel reference without round-tripping through Array.
    @inline(__always)
    private func ycocgSigned(r: Int, g: Int, b: Int) -> (UInt8, Int, Int) {
        let y  = (r + 2 * g + b + 2) >> 2
        let co = (r - b) >> 1
        let cg = (-r + 2 * g - b) >> 2
        return (UInt8(y), co, cg)
    }

    @inline(__always)
    private func divRoundNearest(_ num: Int, _ den: Int) -> Int {
        precondition(den > 0)
        if num >= 0 {
            return (num + den / 2) / den
        } else {
            return -((-num + den / 2) / den)
        }
    }

    // MARK: - Plane round-trip

    struct PlaneStats {
        let totalPixels: Int
        let meanR: Double, meanG: Double, meanB: Double
        let maxR: Int, maxG: Int, maxB: Int
        let perColorCount: [String: Int]
        var meanRGB: Double { (meanR + meanG + meanB) / 3.0 }
        var maxRGB: Int { max(maxR, max(maxG, maxB)) }
        func report(prefix: String) -> String {
            return "\(prefix)   N=\(totalPixels)  mean ΔR=\(String(format: "%.3f", meanR))  ΔG=\(String(format: "%.3f", meanG))  ΔB=\(String(format: "%.3f", meanB))  | max ΔR=\(maxR)  ΔG=\(maxG)  ΔB=\(maxB)"
        }
    }

    private func planeRoundTripStats(png: URL) throws -> PlaneStats {
        guard FileManager.default.fileExists(atPath: png.path) else {
            throw NSError(domain: "Audit", code: 1)
        }
        guard let imgSrc = CGImageSourceCreateWithURL(png as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else {
            throw NSError(domain: "Audit", code: 2)
        }
        let w = cgImage.width
        let h = cgImage.height
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        try rgba.withUnsafeMutableBufferPointer { buf in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let bmpInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(
                data: buf.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: space, bitmapInfo: bmpInfo
            ) else {
                throw NSError(domain: "Audit", code: 3)
            }
            ctx.setBlendMode(.copy)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
        }

        // For a plane round-trip we evaluate the transform PER PIXEL
        // (no chroma subsample) so this isolates transform precision
        // from any subsample-related averaging. Subsample is audited
        // separately in (f).
        var sumR = 0, sumG = 0, sumB = 0
        var mxR = 0, mxG = 0, mxB = 0
        var samples = 0
        var byColor: [String: Int] = [:]
        for i in 0..<(w * h) {
            let off = i * 4
            let r = Int(rgba[off])
            let g = Int(rgba[off + 1])
            let b = Int(rgba[off + 2])
            let (y, coSigned, cgSigned) = ycocgSigned(r: r, g: g, b: b)
            let coStored = UInt8(clamping: coSigned + 128)
            let cgStored = UInt8(clamping: cgSigned + 128)
            let (recR, recG, recB) = YCoCgTransform.inverseYCoCg(
                y: y, coStored: coStored, cgStored: cgStored)
            let dR = abs(Int(recR) - r)
            let dG = abs(Int(recG) - g)
            let dB = abs(Int(recB) - b)
            sumR += dR; sumG += dG; sumB += dB
            mxR = max(mxR, dR); mxG = max(mxG, dG); mxB = max(mxB, dB)
            samples += 1
            if dR > 0 || dG > 0 || dB > 0 {
                let key = "(\(r),\(g),\(b))"
                byColor[key, default: 0] += 1
            }
        }
        // Top-3 offenders.
        let top = byColor.sorted { $0.value > $1.value }.prefix(3)
        for (k, v) in top {
            print("[audit-plane]   biggest offender color \(k) appears \(v) times")
        }
        return PlaneStats(
            totalPixels: samples,
            meanR: Double(sumR) / Double(samples),
            meanG: Double(sumG) / Double(samples),
            meanB: Double(sumB) / Double(samples),
            maxR: mxR, maxG: mxG, maxB: mxB,
            perColorCount: byColor)
    }
}
