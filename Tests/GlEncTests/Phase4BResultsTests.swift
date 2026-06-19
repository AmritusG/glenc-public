/*
 * Phase 4B ship-readiness measurements — SSIM(GlEnc, source) on RGB
 * (via BT.709 luma) for the YCG6 path. Mirrors Phase 3B's structure
 * with HQ-specific decode (DXVHQDecoder + CPURender.cgImageFromHQ).
 *
 * Corpus: testsrc2 (Pass C PNG sequence, 1920×1080, 30 frames).
 *
 * Gate per phase4_priming.md: mean SSIM ≥ 0.995 on RGB (higher than
 * DXT1/DXT5's 0.99 — HQ should be visually lossless or near).
 *
 * Alpha gate: N/A. YCG6 is no-alpha; YG10 (Phase 5) reintroduces it.
 *
 * Real-content corpus (e.g. ShroomiesKingdom) deferred to Phase 5+.
 * v0.4.0 measures testsrc2 only.
 */

import XCTest
import Foundation
import CoreVideo
import CoreGraphics
import CoreMedia
import ImageIO
@testable import GlEncCore
import GlanceCore

final class Phase4BResultsTests: XCTestCase {

    private static let ycg6Dir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference/ycg6")
    }()

    /// Per-frame SSIM on luma (BT.709 from RGB) for the 30 testsrc2
    /// frames in reference/ycg6/glenc.mov vs reference/ycg6/source/*.png.
    /// Phase 4B gate: mean ≥ 0.995.
    func testSSIM_YCG6_TestSrc2_VsSource() throws {
        let glencMOV = Self.ycg6Dir.appendingPathComponent("glenc.mov")
        guard FileManager.default.fileExists(atPath: glencMOV.path) else {
            throw XCTSkip("reference/ycg6/glenc.mov missing (GlEnc-produced artifact, stripped from the public seed) — regenerate via YCG6EncoderTests.testFullPipelineFromPNGCorpusAndSaveReference, or scripts/make-corpus.sh")
        }

        let codedW = 1920, codedH = 1088
        let presW = 1920, presH = 1080

        let extractor = try MOVFrameExtractor(url: glencMOV)
        XCTAssertEqual(extractor.frameCount, 30)

        var perFrame: [Double] = []
        for i in 0..<30 {
            let pkt = extractor.frameData(at: i)
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)

            // Two-stage HQ decode: luma plane then chroma planes.
            let luma = try DXVHQDecoder.decompressYCG6LumaPlane(
                payload: payload, codedWidth: codedW, codedHeight: codedH)
            let chroma = try DXVHQDecoder.decompressYCG6ChromaPlane(
                payload: payload, startCursor: luma.postCursor,
                codedWidth: codedW, codedHeight: codedH)

            // YCoCg → RGB via CPURender (coded dims). The version of
            // GlanceCore wired into this build doesn't yet expose
            // `displayWidth` so we render at coded dims and crop the
            // luma to presentation dims manually below.
            let cgImage = try CPURender.cgImageFromHQ(
                y: luma.luma, co: chroma.co, cg: chroma.cg, a: nil,
                width: codedW, height: codedH,
                chromaWidth: chroma.chromaWidth,
                chromaHeight: chroma.chromaHeight)
            let glLuma = try lumaFromCGImage(cgImage,
                                             codedW: codedW, codedH: codedH,
                                             presW: presW, presH: presH)

            // Source PNG → straight RGB → luma.
            let pngURL = Self.ycg6Dir.appendingPathComponent(
                String(format: "source/frame_%04d.png", i + 1))
            let srcLuma = try lumaFromRGBPNG(url: pngURL,
                                             width: presW, height: presH)

            let s = ssim8x8(a: glLuma, b: srcLuma,
                            width: presW, height: presH)
            perFrame.append(s)
        }

        let mean = perFrame.reduce(0, +) / Double(perFrame.count)
        let minF = perFrame.min() ?? 0
        let minIdx = perFrame.firstIndex(of: minF) ?? 0
        print(String(format: "[ssim ycg6 testsrc2] mean=%.6f  min=%.6f @ frame %d", mean, minF, minIdx))
        for (i, s) in perFrame.enumerated() {
            print(String(format: "  frame %2d: %.6f", i, s))
        }
        XCTAssertGreaterThanOrEqual(mean, 0.995,
            "testsrc2 mean SSIM \(mean) below the 0.995 Phase 4B gate")
    }

    // MARK: - Helpers

    /// Render the (coded-size) CGImage into an RGBA buffer at coded
    /// dims, then crop to presentation dims for SSIM measurement.
    private func lumaFromCGImage(_ cg: CGImage,
                                  codedW: Int, codedH: Int,
                                  presW: Int, presH: Int) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: codedW * codedH * 4)
        try rgba.withUnsafeMutableBytes { ptr in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let bmp = CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: codedW, height: codedH,
                bitsPerComponent: 8, bytesPerRow: codedW * 4,
                space: space, bitmapInfo: bmp)
            else { throw NSError(domain: "P4B", code: 1) }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: codedW, height: codedH))
        }
        var luma = [UInt8](repeating: 0, count: presW * presH)
        for y in 0..<presH {
            for x in 0..<presW {
                let off = (y * codedW + x) * 4
                let r = Int(rgba[off]), g = Int(rgba[off + 1]), b = Int(rgba[off + 2])
                let yv = (13933 * r + 46871 * g + 4732 * b + 32768) >> 16
                luma[y * presW + x] = UInt8(min(255, max(0, yv)))
            }
        }
        return luma
    }

    /// Load an RGB PNG (Pass C corpus is 8-bit RGB, no alpha) as luma.
    /// CGContext rendering forces α=255 via .noneSkipLast so the RGB
    /// triple is straight (no premultiplication).
    private func lumaFromRGBPNG(url: URL, width: Int, height: Int) throws -> [UInt8] {
        guard let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil)
        else { throw NSError(domain: "P4B", code: 2) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBytes { ptr in
            let bmp = CGImageAlphaInfo.noneSkipLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: bmp)
            else { throw NSError(domain: "P4B", code: 3) }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        var luma = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let off = i * 4
            let r = Int(rgba[off]), g = Int(rgba[off + 1]), b = Int(rgba[off + 2])
            let yv = (13933 * r + 46871 * g + 4732 * b + 32768) >> 16
            luma[i] = UInt8(min(255, max(0, yv)))
        }
        return luma
    }

    /// SSIM via 8×8 non-overlapping windows, K1=0.01, K2=0.03 — same
    /// implementation as Phase 2C / Phase 3B.
    private func ssim8x8(a: [UInt8], b: [UInt8], width: Int, height: Int) -> Double {
        precondition(a.count == width * height)
        precondition(b.count == width * height)
        let L = 255.0
        let K1 = 0.01, K2 = 0.03
        let C1 = (K1 * L) * (K1 * L)
        let C2 = (K2 * L) * (K2 * L)
        let win = 8
        let N = Double(win * win)
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
                        sumA += av
                        sumB += bv
                        sumAA += av * av
                        sumBB += bv * bv
                        sumAB += av * bv
                    }
                }
                let muA = Double(sumA) / N
                let muB = Double(sumB) / N
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
