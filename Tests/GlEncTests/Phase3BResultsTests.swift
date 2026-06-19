/*
 * Phase 3B ship-readiness measurements — SSIM(GlEnc, source) on RGB
 * (via BT.709 luma) + alpha pixel-Δ vs source. Mirrors Phase 2C's
 * structure (Phase2CTests.swift) with DXT5-specific decode paths.
 *
 * Two corpora:
 *   - testsrc2 + alpha (Pass B), encoded into reference/dxt5/glenc.mov
 *   - ShroomiesKingdom 5 s @ 4K, encoded into reference/dxt5/realworld-glenc.mov
 *
 * Gates per priming:
 *   - mean SSIM ≥ 0.99 on RGB (BT.709 luma, 8×8 non-overlap)
 *   - mean |Δ_α| ≤ 2 LSB,  max |Δ_α| ≤ 8 LSB
 *
 * The ShroomiesKingdom tests need reference/dxt5/realworld-glenc.mov plus
 * reference/dxt5/realworld-source/ShroomiesKingdom_5s.mov present; they
 * skip cleanly if missing.
 */

import XCTest
import Foundation
import CoreVideo
import CoreGraphics
import CoreMedia
import AVFoundation
import ImageIO
@testable import GlEncCore
import GlanceCore

final class Phase3BResultsTests: XCTestCase {

    private static let dxt5Dir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference/dxt5")
    }()

    // ============================================================
    // testsrc2 corpus (Pass B PNG sequence, 1920×1080, 30 frames)
    // ============================================================

    /// Diagnostic: sample pixels in left / mid / right thirds of frame 0,
    /// print (source RGB, decoded RGB, |Δ|) for each. Lets us see whether
    /// SSIM dips come from a specific region or are uniform.
    func testDiagnose_DXT5_TestSrc2_LumaDelta() throws {
        let glencMOV = Self.dxt5Dir.appendingPathComponent("glenc.mov")
        guard FileManager.default.fileExists(atPath: glencMOV.path) else {
            throw XCTSkip("glenc.mov missing")
        }
        let codedW = 1920, codedH = 1088
        let presW = 1920, presH = 1080
        let extractor = try MOVFrameExtractor(url: glencMOV)
        let pkt = extractor.frameData(at: 0)
        let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
        let blocks = (codedW / 4) * (codedH / 4)
        let bc3 = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: blocks * 16)
        let cgImage = try CPURender.cgImageFromDXT(
            dxtBytes: bc3, variant: .dxt5,
            width: codedW, height: codedH)
        let dec = try rgbaBytesFromCGImage(cgImage, width: codedW, height: codedH)

        let pngURL = Self.dxt5Dir.appendingPathComponent("source/frame_0001.png")
        let src = try rgbaStraightFromPNG(url: pngURL, width: presW, height: presH)

        let samples: [(Int, Int)] = [
            (50, 50), (200, 100), (500, 500), (600, 1000),    // left third
            (700, 100), (800, 500), (1000, 800), (1200, 100), // middle
            (1300, 100), (1500, 500), (1700, 800), (1900, 1000), // right
        ]
        print("[diag pixel] frame 0 sample pixels (left/mid/right):")
        var maxRgbDelta = 0
        for (x, y) in samples {
            let dOff = (y * codedW + x) * 4
            let sOff = (y * presW + x) * 4
            let dR = Int(dec[dOff]), dG = Int(dec[dOff+1]), dB = Int(dec[dOff+2]), dA = Int(dec[dOff+3])
            let sR = Int(src[sOff]), sG = Int(src[sOff+1]), sB = Int(src[sOff+2]), sA = Int(src[sOff+3])
            let dr = abs(dR - sR), dg = abs(dG - sG), db = abs(dB - sB), da = abs(dA - sA)
            let m = max(dr, dg, db)
            if m > maxRgbDelta { maxRgbDelta = m }
            print(String(format: "  (%4d,%4d) src=(%3d,%3d,%3d,%3d)  dec=(%3d,%3d,%3d,%3d)  ΔRGB=(%d,%d,%d) Δα=%d",
                         x, y, sR, sG, sB, sA, dR, dG, dB, dA, dr, dg, db, da))
        }
        print("[diag pixel] max RGB Δ across samples = \(maxRgbDelta)")

        // Aggregate per-channel deltas in the active region.
        var sumR: Int64 = 0, sumG: Int64 = 0, sumB: Int64 = 0
        var maxR = 0, maxG = 0, maxB = 0
        for y in 0..<presH {
            for x in 0..<presW {
                let dOff = (y * codedW + x) * 4
                let sOff = (y * presW + x) * 4
                let r = abs(Int(dec[dOff]) - Int(src[sOff]))
                let g = abs(Int(dec[dOff+1]) - Int(src[sOff+1]))
                let b = abs(Int(dec[dOff+2]) - Int(src[sOff+2]))
                sumR += Int64(r); sumG += Int64(g); sumB += Int64(b)
                if r > maxR { maxR = r }
                if g > maxG { maxG = g }
                if b > maxB { maxB = b }
            }
        }
        let n = Double(presW * presH)
        print(String(format: "[diag pixel] frame 0 mean per-channel Δ: R=%.3f G=%.3f B=%.3f", Double(sumR)/n, Double(sumG)/n, Double(sumB)/n))
        print(String(format: "[diag pixel] frame 0 max  per-channel Δ: R=%d G=%d B=%d", maxR, maxG, maxB))
    }

    func testSSIM_DXT5_TestSrc2_VsSource() throws {
        let glencMOV = Self.dxt5Dir.appendingPathComponent("glenc.mov")
        guard FileManager.default.fileExists(atPath: glencMOV.path) else {
            throw XCTSkip("reference/dxt5/glenc.mov missing (GlEnc-produced artifact, stripped from the public seed) — regenerate via DXT5EncoderTests.testFullPipelineFromRealMOVSourceAndSaveReference, or scripts/make-corpus.sh")
        }

        let codedW = 1920, codedH = 1088
        let presW  = 1920, presH  = 1080
        let extractor = try MOVFrameExtractor(url: glencMOV)
        XCTAssertEqual(extractor.frameCount, 30)

        var perFrame: [Double] = []
        for i in 0..<30 {
            let pkt = extractor.frameData(at: i)
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
            let blocks = (codedW / 4) * (codedH / 4)
            let bc3 = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: blocks * 16)
            let cgImage = try CPURender.cgImageFromDXT(
                dxtBytes: bc3, variant: .dxt5,
                width: codedW, height: codedH)
            let glLuma = try lumaFromCGImage(cgImage,
                                              codedW: codedW, codedH: codedH,
                                              presW: presW, presH: presH)

            // Source: testsrc2+alpha PNG, un-premult'd to straight RGB.
            let pngURL = Self.dxt5Dir.appendingPathComponent(
                String(format: "source/frame_%04d.png", i + 1))
            let srcLuma = try lumaFromStraightPNG(url: pngURL, width: presW, height: presH)

            let s = ssim8x8(a: glLuma, b: srcLuma, width: presW, height: presH)
            perFrame.append(s)
        }
        let mean = perFrame.reduce(0, +) / Double(perFrame.count)
        let minF = perFrame.min() ?? 0
        print("[ssim dxt5 testsrc2] mean=\(String(format: "%.6f", mean)) min=\(String(format: "%.6f", minF))")
        for (i, s) in perFrame.enumerated() {
            print(String(format: "  frame %2d: %.6f", i, s))
        }
        XCTAssertGreaterThanOrEqual(mean, 0.99,
            "testsrc2 mean SSIM below the 0.99 gate")
    }

    func testAlphaDelta_DXT5_TestSrc2() throws {
        let glencMOV = Self.dxt5Dir.appendingPathComponent("glenc.mov")
        guard FileManager.default.fileExists(atPath: glencMOV.path) else {
            throw XCTSkip("reference/dxt5/glenc.mov missing (GlEnc-produced artifact, stripped from the public seed) — regenerate via DXT5EncoderTests.testFullPipelineFromRealMOVSourceAndSaveReference, or scripts/make-corpus.sh")
        }
        let codedW = 1920, codedH = 1088
        let presW  = 1920, presH  = 1080
        let extractor = try MOVFrameExtractor(url: glencMOV)

        var sumDelta: Int64 = 0
        var maxDelta = 0
        var samples: Int64 = 0
        for i in 0..<extractor.frameCount {
            let pkt = extractor.frameData(at: i)
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
            let blocks = (codedW / 4) * (codedH / 4)
            let bc3 = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: blocks * 16)
            let cgImage = try CPURender.cgImageFromDXT(
                dxtBytes: bc3, variant: .dxt5,
                width: codedW, height: codedH)
            let decoded = try rgbaBytesFromCGImage(cgImage,
                                                    width: codedW, height: codedH)

            let pngURL = Self.dxt5Dir.appendingPathComponent(
                String(format: "source/frame_%04d.png", i + 1))
            let source = try rgbaStraightFromPNG(url: pngURL, width: presW, height: presH)
            for y in 0..<presH {
                for x in 0..<presW {
                    let dOff = (y * codedW + x) * 4 + 3
                    let sOff = (y * presW  + x) * 4 + 3
                    let d = abs(Int(decoded[dOff]) - Int(source[sOff]))
                    if d > maxDelta { maxDelta = d }
                    sumDelta += Int64(d)
                    samples += 1
                }
            }
        }
        let mean = Double(sumDelta) / Double(samples)
        print("[alpha-Δ dxt5 testsrc2] mean=\(String(format: "%.4f", mean)) LSB  max=\(maxDelta) LSB  samples=\(samples)")
        XCTAssertLessThanOrEqual(mean, 2.0, "mean |Δ_α| above the 2-LSB gate")
        XCTAssertLessThanOrEqual(maxDelta, 8, "max |Δ_α| above the 8-LSB gate")
    }

    // ============================================================
    // ShroomiesKingdom corpus (4K, 150 frames, real motion graphic)
    // ============================================================

    func testSSIM_DXT5_ShroomiesKingdom_VsSource() async throws {
        let glencMOV = Self.dxt5Dir.appendingPathComponent("realworld-glenc.mov")
        let srcMOV = Self.dxt5Dir.appendingPathComponent(
            "realworld-source/ShroomiesKingdom_5s.mov")
        guard FileManager.default.fileExists(atPath: glencMOV.path),
              FileManager.default.fileExists(atPath: srcMOV.path) else {
            throw XCTSkip("realworld-{glenc,source}.mov missing — Phase 3B prep artifacts required")
        }

        let codedW = 3840, codedH = 2160
        let presW = 3840, presH = 2160

        // Stream the source (AVAssetReader, BGRA → luma per ProRes 4444 /
        // yuva444p convention) in LOCKSTEP with the GlEnc DXT5 frames: decode
        // source frame i, compare against GlEnc frame i, discard. This keeps
        // peak memory at ~2 frames instead of retaining all 150 (1.24 GB at
        // 4K — the cause of the previous full-suite swap-thrash). Verification
        // is unchanged: every frame, full 4K, identical SSIM math.
        let extractor = try MOVFrameExtractor(url: glencMOV)
        let stream = try await BGRASourceStream.make(
            url: srcMOV, width: presW, height: presH)

        let total = extractor.frameCount
        let sampled = Self.sampledFrameIndices(total)
        var perFrame: [(frame: Int, ssim: Double)] = []
        var i = 0
        while i < total {
            if sampled.contains(i) {
                guard let srcLuma = try stream.nextLuma() else {
                    XCTFail("source ended early at frame \(i) (GlEnc has \(total))")
                    break
                }
                let pkt = extractor.frameData(at: i)
                let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
                let blocks = (codedW / 4) * (codedH / 4)
                let bc3 = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: blocks * 16)
                let cgImage = try CPURender.cgImageFromDXT(
                    dxtBytes: bc3, variant: .dxt5,
                    width: codedW, height: codedH)
                let glLuma = try lumaFromCGImage(cgImage,
                                                  codedW: codedW, codedH: codedH,
                                                  presW: presW, presH: presH)
                let s = ssim8x8(a: glLuma, b: srcLuma,
                                width: presW, height: presH)
                perFrame.append((i, s))
            } else {
                guard try stream.skip() else {
                    XCTFail("source ended early at frame \(i) (GlEnc has \(total))")
                    break
                }
            }
            i += 1
        }
        XCTAssertFalse(try stream.skip(),
                       "source has more frames than GlEnc (\(total))")
        XCTAssertEqual(perFrame.count, sampled.count, "missed a sampled frame")
        let mean = perFrame.map(\.ssim).reduce(0, +) / Double(perFrame.count)
        let worst = perFrame.min { $0.ssim < $1.ssim }!
        print("[ssim dxt5 shroomies] sampled \(perFrame.count)/\(total) frames — mean=\(String(format: "%.6f", mean)) min=\(String(format: "%.6f", worst.ssim)) @ frame \(worst.frame)")
        // Show worst 5 sampled frames for inspection.
        let worstFive = perFrame.sorted { $0.ssim < $1.ssim }.prefix(5)
        print("[ssim dxt5 shroomies] worst 5 sampled frames:")
        for f in worstFive {
            print(String(format: "  frame %3d: %.6f", f.frame, f.ssim))
        }
        XCTAssertGreaterThanOrEqual(mean, 0.99,
            "ShroomiesKingdom mean SSIM below the 0.99 gate")
    }

    func testAlphaDelta_DXT5_ShroomiesKingdom() async throws {
        let glencMOV = Self.dxt5Dir.appendingPathComponent("realworld-glenc.mov")
        let srcMOV = Self.dxt5Dir.appendingPathComponent(
            "realworld-source/ShroomiesKingdom_5s.mov")
        guard FileManager.default.fileExists(atPath: glencMOV.path),
              FileManager.default.fileExists(atPath: srcMOV.path) else {
            throw XCTSkip("realworld-{glenc,source}.mov missing")
        }

        let codedW = 3840, codedH = 2160
        let presW = 3840, presH = 2160

        // Lockstep streaming (see testSSIM_DXT5_ShroomiesKingdom_VsSource):
        // one source-alpha frame in flight at a time, not all 150.
        let extractor = try MOVFrameExtractor(url: glencMOV)
        let stream = try await BGRASourceStream.make(
            url: srcMOV, width: presW, height: presH)

        let total = extractor.frameCount
        let sampledIdx = Self.sampledFrameIndices(total)
        var sumDelta: Int64 = 0
        var maxDelta = 0
        var samples: Int64 = 0
        var sampledFrames = 0
        var i = 0
        while i < total {
            guard sampledIdx.contains(i) else {
                guard try stream.skip() else {
                    XCTFail("source ended early at frame \(i) (GlEnc has \(total))")
                    break
                }
                i += 1
                continue
            }
            guard let srcAlpha = try stream.nextAlpha() else {
                XCTFail("source ended early at frame \(i) (GlEnc has \(total))")
                break
            }
            let pkt = extractor.frameData(at: i)
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
            let blocks = (codedW / 4) * (codedH / 4)
            let bc3 = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: blocks * 16)
            let cgImage = try CPURender.cgImageFromDXT(
                dxtBytes: bc3, variant: .dxt5,
                width: codedW, height: codedH)
            let decoded = try rgbaBytesFromCGImage(cgImage,
                                                    width: codedW, height: codedH)
            decoded.withUnsafeBufferPointer { dp in
                srcAlpha.withUnsafeBufferPointer { sp in
                    let D = dp.baseAddress!, S = sp.baseAddress!
                    for y in 0..<presH {
                        let dRow = y &* codedW
                        let sRow = y &* presW
                        for x in 0..<presW {
                            let d = abs(Int(D[(dRow &+ x) &* 4 &+ 3]) - Int(S[sRow &+ x]))
                            if d > maxDelta { maxDelta = d }
                            sumDelta &+= Int64(d)
                            samples &+= 1
                        }
                    }
                }
            }
            sampledFrames += 1
            i += 1
        }
        XCTAssertFalse(try stream.skip(),
                       "source has more frames than GlEnc (\(total))")
        XCTAssertEqual(sampledFrames, sampledIdx.count, "missed a sampled frame")
        let mean = Double(sumDelta) / Double(samples)
        print("[alpha-Δ dxt5 shroomies] sampled \(sampledFrames)/\(total) frames — mean=\(String(format: "%.4f", mean)) LSB  max=\(maxDelta) LSB  samples=\(samples)")
        XCTAssertLessThanOrEqual(mean, 2.0, "mean |Δ_α| above the 2-LSB gate")
        XCTAssertLessThanOrEqual(maxDelta, 8, "max |Δ_α| above the 8-LSB gate")
    }

    // MARK: - CGImage / PNG helpers

    private func rgbaBytesFromCGImage(_ cg: CGImage,
                                      width: Int, height: Int) throws -> [UInt8] {
        guard let provider = cg.dataProvider, let pd = provider.data,
              CFDataGetLength(pd) >= width * height * 4 else {
            throw NSError(domain: "P3B", code: 1)
        }
        return [UInt8](UnsafeBufferPointer(start: CFDataGetBytePtr(pd),
                                           count: width * height * 4))
    }

    private func lumaFromCGImage(_ cg: CGImage,
                                  codedW: Int, codedH: Int,
                                  presW: Int, presH: Int) throws -> [UInt8] {
        let rgba = try rgbaBytesFromCGImage(cg, width: codedW, height: codedH)
        var luma = [UInt8](repeating: 0, count: presW * presH)
        // Unsafe + wrapping arithmetic: drops -Onone bounds/overflow checks
        // from this 4K×N hot loop. Math is identical — the BT.601 dot product
        // peaks near 16.7M, far under Int.max, so &* / &+ never wrap.
        rgba.withUnsafeBufferPointer { src in
            luma.withUnsafeMutableBufferPointer { dst in
                let s = src.baseAddress!, d = dst.baseAddress!
                for y in 0..<presH {
                    let sRow = y &* codedW &* 4
                    let dRow = y &* presW
                    for x in 0..<presW {
                        let off = sRow &+ x &* 4
                        let r = Int(s[off]), g = Int(s[off &+ 1]), b = Int(s[off &+ 2])
                        let yv = (13933 &* r &+ 46871 &* g &+ 4732 &* b &+ 32768) >> 16
                        d[dRow &+ x] = UInt8(min(255, max(0, yv)))
                    }
                }
            }
        }
        return luma
    }

    /// Load PNG as straight RGBA. CG renders into a premultipliedLast
    /// context, then we un-premultiply (no-op for opaque pixels,
    /// recovers straight RGB for partial alpha).
    private func rgbaStraightFromPNG(url: URL, width: Int, height: Int) throws -> [UInt8] {
        guard let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil)
        else { throw NSError(domain: "P3B", code: 2) }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBufferPointer { buf in
            let space = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                           | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: bitmapInfo)
            else { throw NSError(domain: "P3B", code: 3) }
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for i in 0..<(width * height) {
            let off = i * 4
            let a = Int(rgba[off + 3])
            if a > 0 && a < 255 {
                rgba[off + 0] = UInt8(min(255, (Int(rgba[off + 0]) * 255 + a / 2) / a))
                rgba[off + 1] = UInt8(min(255, (Int(rgba[off + 1]) * 255 + a / 2) / a))
                rgba[off + 2] = UInt8(min(255, (Int(rgba[off + 2]) * 255 + a / 2) / a))
            }
        }
        return rgba
    }

    private func lumaFromStraightPNG(url: URL,
                                     width: Int, height: Int) throws -> [UInt8] {
        let rgba = try rgbaStraightFromPNG(url: url, width: width, height: height)
        var luma = [UInt8](repeating: 0, count: width * height)
        for i in 0..<(width * height) {
            let off = i * 4
            let r = Int(rgba[off]), g = Int(rgba[off + 1]), b = Int(rgba[off + 2])
            let yv = (13933 * r + 46871 * g + 4732 * b + 32768) >> 16
            luma[i] = UInt8(min(255, max(0, yv)))
        }
        return luma
    }

    // MARK: - ProRes source decode (AVAssetReader → BGRA → luma / alpha)

    /// Streaming source-frame reader. Pulls one BGRA frame at a time off the
    /// AVAssetReader and extracts a single channel, so a 4K × 150-frame SSIM
    /// run holds ~one frame instead of all 150 (was 1.24 GB → swap-thrash).
    /// Channel extraction uses unsafe pointers + wrapping arithmetic; the
    /// luma math is byte-identical to the previous per-pixel loop.
    private final class BGRASourceStream {
        private let reader: AVAssetReader
        private let output: AVAssetReaderTrackOutput
        let width: Int
        let height: Int

        static func make(url: URL, width: Int, height: Int) async throws -> BGRASourceStream {
            let asset = AVURLAsset(url: url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let track = tracks.first else {
                throw NSError(domain: "P3B", code: 10)
            }
            let reader = try AVAssetReader(asset: asset)
            let settings: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else {
                throw NSError(domain: "P3B", code: 11,
                              userInfo: [NSLocalizedDescriptionKey: "reader start failed: \(String(describing: reader.error))"])
            }
            return BGRASourceStream(reader: reader, output: output, width: width, height: height)
        }

        private init(reader: AVAssetReader, output: AVAssetReaderTrackOutput,
                     width: Int, height: Int) {
            self.reader = reader
            self.output = output
            self.width = width
            self.height = height
        }

        /// Pull the next frame; `extract` receives the locked BGRA base
        /// pointer + bytesPerRow. Returns nil at end-of-stream.
        private func next<T>(_ extract: (UnsafePointer<UInt8>, Int) -> T) throws -> T? {
            while reader.status == .reading {
                guard let sample = output.copyNextSampleBuffer() else { break }
                guard let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                CVPixelBufferLockBaseAddress(pb, .readOnly)
                defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
                let base = CVPixelBufferGetBaseAddress(pb)!
                    .assumingMemoryBound(to: UInt8.self)
                let bpr = CVPixelBufferGetBytesPerRow(pb)
                return extract(base, bpr)
            }
            if reader.status == .failed {
                throw NSError(domain: "P3B", code: 12,
                              userInfo: [NSLocalizedDescriptionKey: "reader failed: \(String(describing: reader.error))"])
            }
            return nil
        }

        func nextLuma() throws -> [UInt8]? {
            try next { base, bpr in
                var luma = [UInt8](repeating: 0, count: width * height)
                luma.withUnsafeMutableBufferPointer { out in
                    let o = out.baseAddress!
                    for y in 0..<height {
                        let row = base + y &* bpr
                        let oRow = o + y &* width
                        for x in 0..<width {
                            let p = row + x &* 4
                            let b = Int(p[0]), g = Int(p[1]), r = Int(p[2])
                            let yv = (13933 &* r &+ 46871 &* g &+ 4732 &* b &+ 32768) >> 16
                            oRow[x] = UInt8(min(255, max(0, yv)))
                        }
                    }
                }
                return luma
            }
        }

        func nextAlpha() throws -> [UInt8]? {
            try next { base, bpr in
                var a = [UInt8](repeating: 0, count: width * height)
                a.withUnsafeMutableBufferPointer { out in
                    let o = out.baseAddress!
                    for y in 0..<height {
                        let row = base + y &* bpr
                        let oRow = o + y &* width
                        for x in 0..<width {
                            oRow[x] = row[x &* 4 &+ 3]
                        }
                    }
                }
                return a
            }
        }

        /// Advance past one frame without extracting a channel (used to keep
        /// the sequential reader aligned with the GlEnc track while only the
        /// sampled frames pay the expensive BC3 decode). Returns false at EOF.
        func skip() throws -> Bool {
            (try next { _, _ in true }) ?? false
        }
    }

    /// Temporal subsample for the 4K real-world gates. The per-frame BC3
    /// *decode* (in the frozen GlanceCore pin, debug build) is the wall-clock
    /// floor, so the gates measure a representative slice of the clip rather
    /// than all 150 frames. This stays honest: an encoder/decoder regression
    /// (endpoint quantization, LZ, the YCoCg/colour transform) is *systematic*
    /// — it shows on every frame, not one hidden one — so a SSIM/Δ gate over
    /// frames spanning the whole clip catches it identically. Resolution is
    /// unchanged (full 3840×2160 per sampled frame); only the frame count is
    /// reduced. Full-150-frame numbers (mean SSIM 0.999517, mean |Δα| 0.0014
    /// LSB) are recorded in CC_PROGRESS_LOG for reference.
    private static let realworldFrameSampleTarget = 30

    /// Indices to sample from `frameCount` frames: an even stride spanning the
    /// clip, always including the first and last frame.
    private static func sampledFrameIndices(_ frameCount: Int) -> Set<Int> {
        guard frameCount > 0 else { return [] }
        let stride = max(1, frameCount / realworldFrameSampleTarget)
        var idx = Set<Int>()
        var i = 0
        while i < frameCount { idx.insert(i); i += stride }
        idx.insert(frameCount - 1)
        return idx
    }

    // MARK: - SSIM (copy of Phase 2C's; non-overlapping 8×8, K1=0.01, K2=0.03)

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
        // Unsafe + wrapping inner loop: identical integer math (per-window
        // sums peak at 64·255² ≈ 4.2M, never wrap), just without the -Onone
        // per-pixel bounds/overflow checks that dominate at 4K.
        a.withUnsafeBufferPointer { ap in
            b.withUnsafeBufferPointer { bp in
                let A = ap.baseAddress!, B = bp.baseAddress!
                for by in 0..<rowBlocks {
                    for bx in 0..<colBlocks {
                        var sumA = 0, sumB = 0, sumAA = 0, sumBB = 0, sumAB = 0
                        for ly in 0..<win {
                            let rowBase = (by &* win &+ ly) &* width &+ (bx &* win)
                            for lx in 0..<win {
                                let idx = rowBase &+ lx
                                let av = Int(A[idx]), bv = Int(B[idx])
                                sumA &+= av
                                sumB &+= bv
                                sumAA &+= av &* av
                                sumBB &+= bv &* bv
                                sumAB &+= av &* bv
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
            }
        }
        return sum / Double(count)
    }
}
