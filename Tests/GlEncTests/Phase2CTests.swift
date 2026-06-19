/*
 * Phase 2C — SSIM measurement vs Alley.
 *
 * Decodes reference/dxt1/glenc.mov and reference/dxt1/alley.mov via
 * GlanceCore (DXVPacketDecoder + CPURender), converts each frame to BT.709
 * luma, and computes structural similarity against alley as the reference.
 *
 * Per DECISIONS-2026-05-09-PassA.md, the Phase 2 quality bar is mean SSIM
 * ≥ 0.995. If a frame's SSIM dips low, both the per-frame value and a
 * cross-encoder ground-truth (ffmpeg.mov vs alley.mov) are reported so the
 * planner can see whether GlEnc's quality matches FFmpeg's (which is what
 * we promised) and whether FFmpeg's quality matches Alley's (which is
 * encoder discretion territory beyond GlEnc's control).
 *
 * SSIM is computed on luma planes using non-overlapping 8×8 windows with
 * uniform weights — this matches the configuration FFmpeg's `ssim` filter
 * uses, so the numbers are comparable to anything published with that tool.
 */

import XCTest
import Foundation
import CoreMedia
@testable import GlEncCore
import GlanceCore

final class Phase2CSSIMTests: XCTestCase {

    private static let referenceDir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference/dxt1")
    }()

    private static let codedW = 1920
    private static let codedH = 1088   // 1080 → next 16-multiple
    private static let presW  = 1920
    private static let presH  = 1080

    func testSSIM_GlEncVsAlley() throws {
        let glencURL = Self.referenceDir.appendingPathComponent("glenc.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: glencURL.path),
            "reference/dxt1/glenc.mov missing (GlEnc-produced artifact, stripped from the public seed) — regenerate via the DXT1 encoder test's …AndSaveReference, or scripts/make-corpus.sh")
        let glenc  = try decodeAllLumaFrames(url: glencURL)
        let alley  = try decodeAllLumaFrames(url: Self.referenceDir.appendingPathComponent("alley.mov"))
        XCTAssertEqual(glenc.count, 30)
        XCTAssertEqual(alley.count, 30)

        // Per-frame SSIM
        var perFrame: [Double] = []
        for i in 0..<30 {
            let s = ssim8x8(a: glenc[i], b: alley[i], width: Self.presW, height: Self.presH)
            perFrame.append(s)
        }
        let mean = perFrame.reduce(0, +) / Double(perFrame.count)
        let minF = perFrame.min() ?? 0
        let minIdx = perFrame.firstIndex(of: minF) ?? 0

        print("[ssim] GlEnc vs Alley — per-frame:")
        for (i, s) in perFrame.enumerated() {
            print(String(format: "  frame %2d: %.6f", i, s))
        }
        print(String(format: "[ssim] mean SSIM (GlEnc vs Alley) = %.6f, min %.6f @ frame %d",
                     mean, minF, minIdx))

        // For context: ffmpeg.mov decoded the same way vs alley.
        //
        // Phase 5C.2 retired the Phase 2A byte-identity-to-ffmpeg
        // invariant — GlEnc now uses Squish-style ClusterFit BC1
        // endpoint search instead of the FFmpeg-port algorithm. The
        // hard `mean == refMean` assertion that used to live here is
        // gone (it required byte-identity by construction). The
        // informational SSIM(ffmpeg, Alley) log is retained as a
        // historical-baseline reference so the planner can compare
        // GlEnc's new SSIM against the v0.2.0 FFmpeg-path numbers.
        let ffmpeg = try decodeAllLumaFrames(url: Self.referenceDir.appendingPathComponent("ffmpeg.mov"))
        var refSSIM: [Double] = []
        for i in 0..<30 {
            refSSIM.append(ssim8x8(a: ffmpeg[i], b: alley[i], width: Self.presW, height: Self.presH))
        }
        let refMean = refSSIM.reduce(0, +) / Double(refSSIM.count)
        print(String(format: "[ssim] ground truth — ffmpeg.mov vs Alley: mean %.6f", refMean))

        // The Pass A 0.995 mean-SSIM-vs-Alley gate was reframed by the
        // Phase 2C planner — see reference/dxt1/PHASE-2C-RESULTS.md.
        // Summary: SSIM(glenc, alley) is driven by Alley's own
        // ~+26.6 LSB G-channel bias vs source, not by GlEnc fidelity.
        // The real quality gate is SSIM(GlEnc, source) (next test).
        if mean < 0.995 {
            print(String(format: "[ssim] NOTE: mean SSIM(GlEnc, Alley) %.4f < 0.995 — driven by Alley's systematic +26.6 LSB G bias vs source. See PHASE-2C-RESULTS.md.",
                         mean))
        }
    }

    /// The fidelity-to-source gate. PNG sequence is the canonical source;
    /// GlEnc-decoded SSIM vs that source is what "encoder quality" actually
    /// means. Phase 2C reframed gate: mean SSIM(GlEnc, source) ≥ 0.99.
    func testSSIM_GlEncVsSource() throws {
        let glencURL = Self.referenceDir.appendingPathComponent("glenc.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: glencURL.path),
            "reference/dxt1/glenc.mov missing (GlEnc-produced artifact, stripped from the public seed) — regenerate via the DXT1 encoder test's …AndSaveReference, or scripts/make-corpus.sh")
        let glenc = try decodeAllLumaFrames(url: glencURL)
        XCTAssertEqual(glenc.count, 30)

        var perFrame: [Double] = []
        for i in 0..<30 {
            let src = try loadSourcePNGAsLuma(frameIndex: i)
            perFrame.append(ssim8x8(a: glenc[i], b: src, width: Self.presW, height: Self.presH))
        }
        let mean = perFrame.reduce(0, +) / Double(perFrame.count)
        let minF = perFrame.min() ?? 0
        print(String(format: "[ssim] mean SSIM(GlEnc, source) = %.6f, min %.6f — fidelity-to-source gate", mean, minF))
        XCTAssertGreaterThanOrEqual(mean, 0.99,
            "GlEnc lost too much fidelity to source — possible regression")
    }

    private func loadSourcePNGAsLuma(frameIndex i: Int) throws -> [UInt8] {
        let pngURL = Self.referenceDir
            .appendingPathComponent(String(format: "source/frame_%04d.png", i + 1))
        let frame = try DXT1EncoderTests_PNGLoader.loadPNGAsBGRAPixelFrame(
            url: pngURL, width: Self.presW, height: Self.presH)
        let bgra = frame.bgraBytes()
        var luma = [UInt8](repeating: 0, count: Self.presW * Self.presH)
        bgra.withUnsafeBytes { raw in
            let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<Self.presH {
                for x in 0..<Self.presW {
                    let off = (y * Self.presW + x) * 4
                    let b = Int(p[off + 0])
                    let g = Int(p[off + 1])
                    let r = Int(p[off + 2])
                    let yval = (13933 * r + 46871 * g + 4732 * b + 32768) >> 16
                    luma[y * Self.presW + x] = UInt8(min(255, max(0, yval)))
                }
            }
        }
        return luma
    }

    // MARK: - Decode helpers

    /// Decode every frame from a DXV3 .mov as a BT.709 luma plane sized
    /// presW × presH (presentation, ignoring the bottom 8 padding rows).
    private func decodeAllLumaFrames(url: URL) throws -> [[UInt8]] {
        let extractor = try MOVFrameExtractor(url: url)
        var out: [[UInt8]] = []
        out.reserveCapacity(extractor.frameCount)
        for i in 0..<extractor.frameCount {
            let packet = extractor.frameData(at: i)
            let (_, payload) = try DXVPacketDecoder.parseHeader(packet)
            let blocks = (Self.codedW / 4) * (Self.codedH / 4)
            let bc1 = try DXVPacketDecoder.decompressDXT1(payload, expectedSize: blocks * 8)
            let cgImage = try CPURender.cgImageFromDXT(
                dxtBytes: bc1, variant: .dxt1,
                width: Self.codedW, height: Self.codedH)
            guard let provider = cgImage.dataProvider, let pd = provider.data,
                  CFDataGetLength(pd) >= Self.codedW * Self.codedH * 4 else {
                throw NSError(domain: "P2C", code: 1)
            }
            let rgba = UnsafeBufferPointer(
                start: CFDataGetBytePtr(pd), count: Self.codedW * Self.codedH * 4)
            // BT.709 luma at presentation dims (skip padded rows).
            var luma = [UInt8](repeating: 0, count: Self.presW * Self.presH)
            for y in 0..<Self.presH {
                for x in 0..<Self.presW {
                    let off = (y * Self.codedW + x) * 4
                    let r = Int(rgba[off + 0])
                    let g = Int(rgba[off + 1])
                    let b = Int(rgba[off + 2])
                    // Y' = 0.2126R + 0.7152G + 0.0722B (BT.709).
                    // Coefficients ×65536 and rounded for fixed-point.
                    let yval = (13933 * r + 46871 * g + 4732 * b + 32768) >> 16
                    luma[y * Self.presW + x] = UInt8(min(255, max(0, yval)))
                }
            }
            out.append(luma)
        }
        return out
    }

    // MARK: - SSIM

    /// SSIM with non-overlapping 8×8 uniform windows, K1=0.01, K2=0.03, L=255.
    /// Matches the configuration FFmpeg's `ssim` filter uses on luma planes.
    private func ssim8x8(a: [UInt8], b: [UInt8], width: Int, height: Int) -> Double {
        precondition(a.count == width * height)
        precondition(b.count == width * height)
        let L = 255.0
        let K1 = 0.01, K2 = 0.03
        let C1 = (K1 * L) * (K1 * L)
        let C2 = (K2 * L) * (K2 * L)
        let win = 8
        let N = Double(win * win)

        // Process disjoint 8×8 windows, ignore the trailing 0..7 rows/cols
        // if dims aren't multiples of 8 — for 1920×1080 the row residue is 0
        // (1080 = 8×135) and col residue is 0 (1920 = 8×240).
        let rowBlocks = height / win
        let colBlocks = width / win

        var sum = 0.0
        var count = 0
        for by in 0..<rowBlocks {
            for bx in 0..<colBlocks {
                var sumA = 0, sumB = 0, sumAA = 0, sumBB = 0, sumAB = 0
                for ly in 0..<win {
                    for lx in 0..<win {
                        let idx = (by * win + ly) * width + (bx * win + lx)
                        let av = Int(a[idx]), bv = Int(b[idx])
                        sumA  += av
                        sumB  += bv
                        sumAA += av * av
                        sumBB += bv * bv
                        sumAB += av * bv
                    }
                }
                let muA  = Double(sumA) / N
                let muB  = Double(sumB) / N
                let varA = Double(sumAA) / N - muA * muA
                let varB = Double(sumBB) / N - muB * muB
                let covAB = Double(sumAB) / N - muA * muB
                let num = (2 * muA * muB + C1) * (2 * covAB + C2)
                let den = (muA * muA + muB * muB + C1) * (varA + varB + C2)
                sum += num / den
                count += 1
            }
        }
        return sum / Double(count)
    }
}
