/*
 * YCG6 encoder tests — Phase 4A validation.
 *
 *   - testHeaderShape: synthesized one-frame encode, verify the 12-byte
 *     DXV3 header bytes (tag YCG6 LE, version 4.0, raw=0, unknown=0)
 *     and the LE32 payload-size field.
 *   - testPacketLayout: verify the post-header layout matches Pass C's
 *     spec — yo prelude (op_offset_Y + op_size_Y), Y BC4 data, Y opcode
 *     stream, cocg prelude, chroma BC4 data, Co + Cg opcode streams.
 *   - testRoundTripViaGlanceCore: full 30-frame encode of the Pass C
 *     reference PNGs, decode via GlanceCore.DXVHQDecoder, YCoCg inverse,
 *     compute RGB pixel-Δ stats vs source PNGs.
 */

import XCTest
import CoreVideo
import CoreGraphics
import CoreMedia
import AVFoundation
import Foundation
@testable import GlEncCore
import GlanceCore

final class YCG6EncoderTests: XCTestCase {

    private static let referenceDir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference/ycg6")
    }()

    func testHeaderShape() throws {
        let enc = YCG6Encoder()
        try enc.prepare(width: 1920, height: 1080, fps: 30, hasAlpha: false)
        let frame = synthesizeBGRAFrame(width: 1920, height: 1080,
                                        rPattern: { x, y in UInt8((x + y) & 0xFF) })
        let pkt = try enc.encode(frame: frame)
        try enc.finish()

        XCTAssertGreaterThan(pkt.count, 12)
        XCTAssertEqual([UInt8](pkt[0..<4]),
                       DXVFormat.ycg6.frameTagBytes,
                       "frame tag should be YCG6 LE = 36 47 43 59")
        XCTAssertEqual(pkt[4], 0x04, "version_major+1")
        XCTAssertEqual(pkt[5], 0x00, "version_minor")
        XCTAssertEqual(pkt[6], 0x00, "raw_flag (compressed)")
        XCTAssertEqual(pkt[7], 0x00, "unknown")

        let sizeLE = UInt32(pkt[ 8])
                  | (UInt32(pkt[ 9]) << 8)
                  | (UInt32(pkt[10]) << 16)
                  | (UInt32(pkt[11]) << 24)
        XCTAssertEqual(Int(sizeLE), pkt.count - 12,
                       "size LE32 should equal payload byte count")
    }

    /// Verify the yo + cocg sub-headers parse cleanly through
    /// GlanceCore's HQ decoder for a synthesized frame.
    func testPacketLayoutParsesThroughGlanceCore() throws {
        let enc = YCG6Encoder()
        try enc.prepare(width: 1920, height: 1080, fps: 30, hasAlpha: false)
        let frame = synthesizeBGRAFrame(width: 1920, height: 1080,
                                        rPattern: { x, y in UInt8((x ^ y) & 0xFF) })
        let pkt = try enc.encode(frame: frame)
        let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)

        let luma = try DXVHQDecoder.decompressYCG6LumaPlane(
            payload: payload, codedWidth: 1920, codedHeight: 1088)
        XCTAssertEqual(luma.luma.count, 1920 * 1088)
        let chroma = try DXVHQDecoder.decompressYCG6ChromaPlane(
            payload: payload, startCursor: luma.postCursor,
            codedWidth: 1920, codedHeight: 1088)
        XCTAssertEqual(chroma.co.count, 960 * 544)
        XCTAssertEqual(chroma.cg.count, 960 * 544)
    }

    /// Full 30-frame round-trip vs the Pass C source PNG corpus.
    /// Phase 4 priming gate: mean |Δ_RGB| ≤ 5 LSB / channel.
    func testRoundTripViaGlanceCore() throws {
        let firstPNG = Self.referenceDir
            .appendingPathComponent("source/frame_0001.png")
        guard FileManager.default.fileExists(atPath: firstPNG.path) else {
            throw XCTSkip("reference/ycg6/source/ Pass C PNG corpus missing (stripped from the public seed) — regenerate via scripts/make-corpus.sh (FFmpeg required)")
        }

        let codedW = 1920
        let codedH = 1088
        let presW = 1920
        let presH = 1080
        let chromaW = codedW / 2
        let chromaH = codedH / 2

        let enc = YCG6Encoder()
        try enc.prepare(width: presW, height: presH, fps: 30, hasAlpha: false)

        var sumDeltaR: Int64 = 0
        var sumDeltaG: Int64 = 0
        var sumDeltaB: Int64 = 0
        var maxDeltaPerChannel = 0
        var sampleCount: Int64 = 0

        for i in 0..<30 {
            let pngURL = Self.referenceDir
                .appendingPathComponent(String(format: "source/frame_%04d.png", i + 1))
            let frame = try YCG6TestPNGLoader.loadPNGAsBGRAPixelFrame(
                url: pngURL, width: presW, height: presH)
            let pkt = try enc.encode(frame: frame)
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)

            // Decode Y plane + chroma planes via GlanceCore.
            let luma = try DXVHQDecoder.decompressYCG6LumaPlane(
                payload: payload, codedWidth: codedW, codedHeight: codedH)
            let chroma = try DXVHQDecoder.decompressYCG6ChromaPlane(
                payload: payload, startCursor: luma.postCursor,
                codedWidth: codedW, codedHeight: codedH)
            XCTAssertEqual(luma.luma.count, codedW * codedH,
                           "frame \(i+1) luma plane size")
            XCTAssertEqual(chroma.co.count, chromaW * chromaH,
                           "frame \(i+1) co plane size")
            XCTAssertEqual(chroma.cg.count, chromaW * chromaH,
                           "frame \(i+1) cg plane size")

            // Inverse YCoCg with nearest-neighbor 2× chroma upsample
            // (matches CPURender). Pixel-Δ vs source presentation.
            let source = try YCG6TestPNGLoader.loadPNGAsStraightRGBA(
                url: pngURL, width: presW, height: presH)
            for y in 0..<presH {
                let cy = min(chromaH - 1, y / 2)
                for x in 0..<presW {
                    let cx = min(chromaW - 1, x / 2)
                    let yVal = luma.luma[y * codedW + x]
                    let coVal = chroma.co[cy * chromaW + cx]
                    let cgVal = chroma.cg[cy * chromaW + cx]
                    let (r, g, b) = YCoCgTransform.inverseYCoCg(
                        y: yVal, coStored: coVal, cgStored: cgVal)
                    let srcOff = (y * presW + x) * 4
                    let dR = abs(Int(r) - Int(source[srcOff]))
                    let dG = abs(Int(g) - Int(source[srcOff + 1]))
                    let dB = abs(Int(b) - Int(source[srcOff + 2]))
                    sumDeltaR += Int64(dR)
                    sumDeltaG += Int64(dG)
                    sumDeltaB += Int64(dB)
                    maxDeltaPerChannel = max(maxDeltaPerChannel,
                                             max(dR, max(dG, dB)))
                    sampleCount += 1
                }
            }
            if i == 0 {
                let pktKB = Double(pkt.count) / 1024.0
                print("[Phase4A] frame 1 packet=\(String(format: "%.1f", pktKB)) KB")
            }
        }
        try enc.finish()

        let totalSamples = max(1, sampleCount)
        let meanR = Double(sumDeltaR) / Double(totalSamples)
        let meanG = Double(sumDeltaG) / Double(totalSamples)
        let meanB = Double(sumDeltaB) / Double(totalSamples)
        let meanAll = (meanR + meanG + meanB) / 3.0
        print(String(format: "[Phase4A] round-trip 30 frames: meanΔ R=%.3f G=%.3f B=%.3f LSB; mean=%.3f LSB; max-per-channel=%d LSB",
                     meanR, meanG, meanB, meanAll, maxDeltaPerChannel))
        XCTAssertLessThan(meanAll, 5.0,
                          "mean |Δ_RGB| \(meanAll) LSB exceeds Phase 4 HQ gate (5 LSB)")
    }

    /// Encode the 30 Pass C PNG frames + the ProRes 4444 source.mov
    /// through the full pipeline. Writes two artifacts:
    ///   - reference/ycg6/glenc.mov — the PNG-encoded corpus (Phase 4B
    ///     SSIM comparison reference, matches input bytes the encoder
    ///     saw).
    ///   - /tmp/glenc-ycg6-smoke.mov — the ProRes-piped output. Proves
    ///     EncodePipeline → YCG6Encoder → DXVMOVWriter survives a real
    ///     AVAssetReader input.
    /// Verifies file size within 2× Alley's YCG6 reference (3.58 MB
    /// per Pass C) and per-frame tag is YCG6.
    func testFullPipelineFromRealMOVSourceAndSaveReference() async throws {
        let corpusURL = Self.referenceDir.appendingPathComponent("glenc.mov")
        let smokeURL  = URL(fileURLWithPath: "/tmp/glenc-ycg6-smoke.mov")
        for u in [corpusURL, smokeURL] {
            if FileManager.default.fileExists(atPath: u.path) {
                try FileManager.default.removeItem(at: u)
            }
        }

        // (1) PNG corpus → reference/ycg6/glenc.mov.
        try encodePNGCorpus(to: corpusURL)

        // (2) ProRes pipeline smoke → /tmp/glenc-ycg6-smoke.mov.
        let sourceMOV = Self.referenceDir.appendingPathComponent("source/source.mov")
        guard FileManager.default.fileExists(atPath: sourceMOV.path) else {
            throw XCTSkip("reference/ycg6/source/source.mov missing (stripped from the public seed) — regenerate via scripts/make-corpus.sh (FFmpeg required)")
        }
        let pipeline = EncodePipeline(
            sourceURL: sourceMOV,
            encoder: YCG6Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(
                    destURL: smokeURL, format: .ycg6,
                    presentationWidth: w, presentationHeight: h, fps: fps,
                    writerVersion: "GlEnc 0.4.0")
            },
            sourceAlphaInfo: .noneSkipLast)
        try await pipeline.run()

        let asset = AVURLAsset(url: smokeURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let dur = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(dur), 1.0, accuracy: 0.05)

        let extractor = try MOVFrameExtractor(url: smokeURL)
        XCTAssertEqual(extractor.frameCount, 30)
        for i in 0..<extractor.frameCount {
            let pkt = extractor.frameData(at: i)
            XCTAssertGreaterThan(pkt.count, 12)
            XCTAssertEqual([UInt8](pkt.prefix(4)), DXVFormat.ycg6.frameTagBytes,
                           "frame \(i) tag should be YCG6 LE")
        }

        let corpusSize = (try FileManager.default.attributesOfItem(atPath: corpusURL.path)[.size] as? Int) ?? 0
        let smokeSize  = (try FileManager.default.attributesOfItem(atPath: smokeURL.path)[.size] as? Int) ?? 0
        let alleySize = 3_582_843
        let corpusRatio = Double(corpusSize) / Double(alleySize)
        let smokeRatio  = Double(smokeSize)  / Double(alleySize)
        print("[ycg6 corpus] PNG-encoded  \(corpusSize) B  (ratio vs Alley = \(String(format: "%.3f", corpusRatio)))")
        print("[ycg6 smoke ] ProRes-piped \(smokeSize) B  (ratio vs Alley = \(String(format: "%.3f", smokeRatio)))")
        XCTAssertGreaterThan(corpusSize, 1_000_000, "corpus suspiciously small")
        XCTAssertGreaterThan(smokeSize,  1_000_000, "smoke suspiciously small")
        // Pass C measured Alley=3.58MB, AME=3.55MB on testsrc2. Our
        // baseline (ops 0/1/3 + raw opcode mode) should land within 2×.
        XCTAssertLessThan(corpusRatio, 2.0,
                          "PNG corpus \(corpusRatio)× Alley exceeds Phase 4 size gate (2×)")
    }

    /// PNG-encode the 30 Pass C reference frames → `dest`.
    private func encodePNGCorpus(to dest: URL) throws {
        let enc = YCG6Encoder()
        try enc.prepare(width: 1920, height: 1080, fps: 30, hasAlpha: false)
        let writer = try DXVMOVWriter(
            destURL: dest, format: .ycg6,
            presentationWidth: 1920, presentationHeight: 1080, fps: 30,
            writerVersion: "GlEnc 0.4.0")
        for i in 0..<30 {
            let pngURL = Self.referenceDir
                .appendingPathComponent(String(format: "source/frame_%04d.png", i + 1))
            let frame = try YCG6TestPNGLoader.loadPNGAsBGRAPixelFrame(
                url: pngURL, width: 1920, height: 1080)
            let pkt = try enc.encode(frame: frame)
            try writer.append(
                packet: pkt,
                presentationTime: CMTime(value: Int64(i) * 1000 / 30, timescale: 1000)
            )
        }
        try enc.finish()
        try writer.finish()
    }

    // MARK: - Helpers

    /// Build a synthetic BGRA frame where each pixel's R / G / B are
    /// determined by the supplied (x, y) closure (R = rPattern(x,y),
    /// G = (rPattern + 64), B = (rPattern + 128)). Alpha = 255.
    private func synthesizeBGRAFrame(
        width: Int, height: Int, rPattern: (Int, Int) -> UInt8
    ) -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &pb)
        precondition(status == kCVReturnSuccess, "CVPixelBufferCreate failed")
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!
            .assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            for x in 0..<width {
                let r = rPattern(x, y)
                let off = y * bpr + x * 4
                base[off + 0] = r &+ 128  // B
                base[off + 1] = r &+ 64   // G
                base[off + 2] = r         // R
                base[off + 3] = 255       // A
            }
        }
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero,
                          alphaInfo: .noneSkipLast)
    }
}

/// PNG loader scoped to YCG6 tests — RGB-only path (no premultiplied
/// alpha to invert). Pass C corpus's `frame_NNNN.png` files are 1920×1080
/// 8-bit RGB. We load through CG into a 32BGRA CVPixelBuffer with α=255.
enum YCG6TestPNGLoader {

    static func loadPNGAsBGRAPixelFrame(
        url: URL, width: Int, height: Int
    ) throws -> PixelFrame {
        guard let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil)
        else { throw NSError(domain: "YCG6L", code: 1) }
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "YCG6L", code: 2)
        }
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let space = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let cgInfo: CGImageAlphaInfo = .noneSkipFirst
        let bitmapInfo = cgInfo.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        memset(base, 0, height * bpr)
        guard let ctx = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: space, bitmapInfo: bitmapInfo)
        else {
            CVPixelBufferUnlockBaseAddress(buf, [])
            throw NSError(domain: "YCG6L", code: 3)
        }
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Force α=255 throughout (the CG draw of an RGB PNG into a 32BGRA
        // .noneSkipFirst context produces undefined alpha; YCG6 ignores
        // alpha so this is safe but cleaner to normalize).
        let basePtr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                basePtr[y * bpr + x * 4 + 3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero,
                          alphaInfo: .noneSkipLast)
    }

    static func loadPNGAsStraightRGBA(
        url: URL, width: Int, height: Int
    ) throws -> [UInt8] {
        guard let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil)
        else { throw NSError(domain: "YCG6L", code: 1) }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        rgba.withUnsafeMutableBytes { ptr in
            let bmpInfo = CGImageAlphaInfo.noneSkipLast.rawValue
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: bmpInfo)
            else { return }
            ctx.interpolationQuality = .none
            ctx.setBlendMode(.copy)
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Force α=255 in the RGBA stream so downstream comparisons
        // don't trip over "alpha was 0" artifacts.
        for i in stride(from: 3, to: rgba.count, by: 4) {
            rgba[i] = 255
        }
        return rgba
    }
}
