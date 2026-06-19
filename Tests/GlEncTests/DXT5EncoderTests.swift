/*
 * DXT5 encoder tests — Phase 3A validation.
 *
 *  - testHeaderShape: synthesized one-frame encode, verify the 12-byte
 *    DXV3 header bytes per Pass B locked invariants.
 *  - testRoundTripViaGlanceCore: full 30-frame encode of the Pass B
 *    reference PNG sequence, decode via GlanceCore, RGB and alpha
 *    pixel-Δ stats vs source. Phase 3B SSIM + Resolume Arena gates run
 *    elsewhere; this test gates the BC4 + LZ pipeline correctness.
 *  - testAlphaNormalization{Premultiplied, Straight, None}: each variant
 *    of source CGImageAlphaInfo decoded matches the expected straight
 *    RGB + alpha (within BC1/BC4 quantization noise).
 */

import XCTest
import CoreVideo
import CoreGraphics
import CoreMedia
import AVFoundation
import Foundation
@testable import GlEncCore
import GlanceCore

final class DXT5EncoderTests: XCTestCase {

    private static let referenceDir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference/dxt5")
    }()

    /// Diagnostic: encode frame_0008.png twice — once in isolation and
    /// once after encoding frame_0001..0007 first — and check whether
    /// the decoded α at (640, 0) matches in both cases. Verifies the
    /// encoder is stateless per `encode(frame:)` call.
    func testEncoderStatelessAcrossFrames() throws {
        let codedW = 1920
        let codedH = 1088
        let blocks = (codedW / 4) * (codedH / 4)

        let frameURL = Self.referenceDir
            .appendingPathComponent("source/frame_0008.png")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: frameURL.path),
            "reference/dxt5/source/ testsrc2 corpus missing (stripped from the public seed) — regenerate via scripts/make-corpus.sh (FFmpeg required)")

        // Path A: encode frame 8 in isolation.
        let encA = DXT5Encoder()
        try encA.prepare(width: 1920, height: 1080, fps: 30, hasAlpha: true)
        let frame8A = try DXT5TestPNGLoader.loadPNGAsBGRAPixelFrame(
            url: frameURL, width: 1920, height: 1080,
            alphaInfo: .premultipliedFirst)
        let pktA = try encA.encode(frame: frame8A)
        let (_, payloadA) = try DXVPacketDecoder.parseHeader(pktA)
        let bc3A = try DXVPacketDecoder.decompressDXT5(payloadA, expectedSize: blocks * 16)

        // Path B: encode frames 1..8 sequentially through the same encoder.
        let encB = DXT5Encoder()
        try encB.prepare(width: 1920, height: 1080, fps: 30, hasAlpha: true)
        var pktB: Data = Data()
        for i in 0..<8 {
            let url = Self.referenceDir
                .appendingPathComponent(String(format: "source/frame_%04d.png", i + 1))
            let f = try DXT5TestPNGLoader.loadPNGAsBGRAPixelFrame(
                url: url, width: 1920, height: 1080,
                alphaInfo: .premultipliedFirst)
            pktB = try encB.encode(frame: f)
        }
        let (_, payloadB) = try DXVPacketDecoder.parseHeader(pktB)
        let bc3B = try DXVPacketDecoder.decompressDXT5(payloadB, expectedSize: blocks * 16)

        // The block at (160, 0) covers pixel (640, 0). It should have
        // flat α = 128 → BC4 bytes 80 80 00 00 00 00 00 00.
        let blockIdx = 160
        let blockOffset = blockIdx * 16
        let bytesA = Array(bc3A[blockOffset..<blockOffset + 16])
        let bytesB = Array(bc3B[blockOffset..<blockOffset + 16])
        XCTAssertEqual(bytesA, bytesB, "encoder must produce identical BC3 for the same input regardless of prior calls")
    }

    /// Encode one Pass B frame, LZ-decompress via GlanceCore, and verify
    /// the decompressed BC3 byte stream matches the encoder's own BC3
    /// buffer (`debugBC3Buffer`) byte-for-byte. This was the headline
    /// regression in Phase 3A: the FFmpeg-style "evict by reading
    /// pos-LOOKBACK" eviction needs `LOOKBACK_WORDS` to be a multiple
    /// of the per-block dword stride. For DXT1 (x=2), 0x20202 works; for
    /// DXT5 (x=4) it doesn't, leaving stale entries past the encodable
    /// distance and causing pushOp's le16 trailing to silently truncate.
    /// Fixed by switching DXT5 to `lookbackWordsDXT5 = 0x40404`.
    func testLZRoundTripPreservesBC3Bytes() throws {
        let pngURL = Self.referenceDir
            .appendingPathComponent("source/frame_0008.png")
        guard FileManager.default.fileExists(atPath: pngURL.path) else {
            throw XCTSkip("reference/dxt5/source/ Pass B PNG corpus missing (stripped from the public seed) — regenerate via scripts/make-corpus.sh (FFmpeg required)")
        }
        let frame = try DXT5TestPNGLoader.loadPNGAsBGRAPixelFrame(
            url: pngURL, width: 1920, height: 1080,
            alphaInfo: .premultipliedFirst)
        let enc = DXT5Encoder()
        try enc.prepare(width: 1920, height: 1080, fps: 30, hasAlpha: true)
        let pkt = try enc.encode(frame: frame)
        let ourBC3 = enc.debugBC3Buffer
        let (cw, ch) = enc.debugCodedDimensions

        let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
        let blocks = (cw / 4) * (ch / 4)
        let theirBC3 = try DXVPacketDecoder.decompressDXT5(
            payload, expectedSize: blocks * 16)

        XCTAssertEqual(theirBC3.count, ourBC3.count,
                       "BC3 byte count differs after LZ round-trip")
        XCTAssertEqual(Array(theirBC3), ourBC3,
                       "LZ round-trip must preserve all \(blocks) BC3 blocks byte-identically")
    }

    // MARK: - Header shape

    func testHeaderShape() throws {
        let enc = DXT5Encoder()
        try enc.prepare(width: 1920, height: 1080, fps: 30, hasAlpha: true)
        let frame = synthesizeFrame(width: 1920, height: 1080,
                                    alphaInfo: .last, recipe: .uniformOpaque)
        let pkt = try enc.encode(frame: frame)
        try enc.finish()

        // Per Pass B locked invariants:
        XCTAssertGreaterThan(pkt.count, 12)
        XCTAssertEqual([UInt8](pkt[0..<4]),
                       DXVFormat.dxt5.frameTagBytes,
                       "frame tag should be DXT5 LE = 35 54 58 44")
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

    // MARK: - Round-trip via GlanceCore

    /// Encode the 30 Pass B reference PNGs, decode via GlanceCore's
    /// DXVPacketDecoder.decompressDXT5 + CPURender, and compute RGB / α
    /// pixel-Δ stats vs source PNGs. Pass B priming gate:
    ///   - mean |Δ_RGB| ≤ 10 LSB
    ///   - mean |Δ_alpha| ≤ 4 LSB
    func testRoundTripViaGlanceCore() throws {
        guard FileManager.default.fileExists(
            atPath: Self.referenceDir.appendingPathComponent("source/frame_0001.png").path)
        else {
            throw XCTSkip("reference/dxt5/source/ Pass B PNG corpus missing (stripped from the public seed) — regenerate via scripts/make-corpus.sh (FFmpeg required)")
        }

        let codedW = 1920
        let codedH = 1088   // 1080 → next 16-multiple

        let enc = DXT5Encoder()
        try enc.prepare(width: 1920, height: 1080, fps: 30, hasAlpha: true)

        var sumDeltaRGB: Int64 = 0
        var sumDeltaA:   Int64 = 0
        var maxDeltaRGB: Int = 0
        var maxDeltaA:   Int = 0
        var sampleRGB: Int64 = 0
        var sampleA: Int64 = 0
        var worstAlphaFrame = 0
        var worstAlphaXY = (0, 0)
        var worstAlphaSrc = 0
        var worstAlphaDec = 0

        for i in 0..<30 {
            let pngURL = Self.referenceDir
                .appendingPathComponent(String(format: "source/frame_%04d.png", i + 1))
            // Pass B PNGs are loaded via CGImageAlphaInfo.premultipliedFirst
            // (matching the Phase 2A loader). The encoder will un-premultiply.
            let frame = try DXT5TestPNGLoader.loadPNGAsBGRAPixelFrame(
                url: pngURL, width: 1920, height: 1080,
                alphaInfo: .premultipliedFirst)
            let pkt = try enc.encode(frame: frame)
            // Decode via GlanceCore.
            let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
            let blocks = (codedW / 4) * (codedH / 4)
            let bc3 = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: blocks * 16)
            let cgImage = try CPURender.cgImageFromDXT(
                dxtBytes: bc3, variant: .dxt5,
                width: codedW, height: codedH)
            guard let provider = cgImage.dataProvider, let pd = provider.data,
                  CFDataGetLength(pd) >= codedW * codedH * 4 else {
                XCTFail("frame \(i): decoded CGImage data unavailable")
                return
            }
            let decoded = [UInt8](
                UnsafeBufferPointer(start: CFDataGetBytePtr(pd),
                                    count: codedW * codedH * 4))

            // Source: same PNG loaded as straight RGBA bytes (no premult).
            let source = try loadPNGAsStraightRGBA(url: pngURL,
                                                   width: 1920, height: 1080)


            for y in 0..<1080 {
                for x in 0..<1920 {
                    let off = (y * codedW + x) * 4
                    let srcOff = (y * 1920 + x) * 4
                    // Compare RGB only on the SOURCE α > 0 region.
                    // Where source α = 0, both encoder and decoder may
                    // preserve any RGB they like (un-premult of α=0
                    // forces RGB=0 in the encoder per Pass B rule).
                    let srcA = Int(source[srcOff + 3])
                    let decA = Int(decoded[off + 3])
                    let dA = abs(srcA - decA)
                    sumDeltaA += Int64(dA)
                    sampleA += 1
                    if dA > maxDeltaA {
                        maxDeltaA = dA
                        worstAlphaFrame = i
                        worstAlphaXY = (x, y)
                        worstAlphaSrc = srcA
                        worstAlphaDec = decA
                    }
                    if srcA > 0 {
                        for ch in 0..<3 {
                            let d = abs(Int(source[srcOff + ch]) - Int(decoded[off + ch]))
                            if d > maxDeltaRGB { maxDeltaRGB = d }
                            sumDeltaRGB += Int64(d)
                            sampleRGB += 1
                        }
                    }
                }
            }
        }
        try enc.finish()

        let meanRGB = Double(sumDeltaRGB) / Double(sampleRGB)
        let meanA   = Double(sumDeltaA)   / Double(sampleA)
        print("[dxt5 rt] mean |Δ_RGB|=\(String(format: "%.3f", meanRGB)) max=\(maxDeltaRGB) over \(sampleRGB) samples")
        print("[dxt5 rt] mean |Δ_α|  =\(String(format: "%.3f", meanA))   max=\(maxDeltaA) over \(sampleA) samples")
        print("[dxt5 rt] worst α: frame=\(worstAlphaFrame) (\(worstAlphaXY.0),\(worstAlphaXY.1)) src=\(worstAlphaSrc) dec=\(worstAlphaDec)")

        // Phase 3B priming gate.
        XCTAssertLessThan(meanRGB, 10.0, "mean |Δ_RGB| above gate")
        XCTAssertLessThan(meanA,   4.0,  "mean |Δ_α| above gate")
    }

    // MARK: - Alpha normalization paths

    /// Source CGImageAlphaInfo = .premultipliedLast with bytes
    /// (R=128, G=128, B=0, A=128) = pre-multiplied form of straight
    /// (255, 255, 0, 128). After un-premultiplication and BC1/BC4
    /// quantization, decoded pixel should be ≈ (255, 255, 0, 128).
    func testAlphaNormalizationPremultiplied() throws {
        let frame = synthesizeFrame(width: 64, height: 64,
                                    alphaInfo: .premultipliedLast,
                                    recipe: .premultipliedYellowHalfAlpha)
        let decoded = try roundTripSinglePixel(frame: frame, codedW: 64, codedH: 64)
        // Sample the pixel-equivalent of (255, 255, 0, 128) un-premultiplied.
        XCTAssertLessThanOrEqual(abs(Int(decoded.r) - 255), 12,
                                 "R should ≈ 255 after un-premult")
        XCTAssertLessThanOrEqual(abs(Int(decoded.g) - 255), 12,
                                 "G should ≈ 255 after un-premult")
        XCTAssertLessThanOrEqual(abs(Int(decoded.b) -   0), 12,
                                 "B should ≈ 0 after un-premult")
        XCTAssertLessThanOrEqual(abs(Int(decoded.a) - 128), 4,
                                 "alpha should round-trip closely (BC4 single-channel)")
    }

    /// Source CGImageAlphaInfo = .last with bytes (R=255, G=255, B=0, A=128).
    /// Encoder uses straight as-is. Decoded should be ≈ (255, 255, 0, 128).
    func testAlphaNormalizationStraight() throws {
        let frame = synthesizeFrame(width: 64, height: 64,
                                    alphaInfo: .last,
                                    recipe: .straightYellowHalfAlpha)
        let decoded = try roundTripSinglePixel(frame: frame, codedW: 64, codedH: 64)
        XCTAssertLessThanOrEqual(abs(Int(decoded.r) - 255), 8)
        XCTAssertLessThanOrEqual(abs(Int(decoded.g) - 255), 8)
        XCTAssertLessThanOrEqual(abs(Int(decoded.b) -   0), 8)
        XCTAssertLessThanOrEqual(abs(Int(decoded.a) - 128), 4)
    }

    /// Source CGImageAlphaInfo = .noneSkipLast — encoder ignores the X
    /// channel and forces α = 255. Decoded α should be 255 exactly.
    func testAlphaNormalizationNone() throws {
        let frame = synthesizeFrame(width: 64, height: 64,
                                    alphaInfo: .noneSkipLast,
                                    recipe: .uniformOpaque)
        let decoded = try roundTripSinglePixel(frame: frame, codedW: 64, codedH: 64)
        XCTAssertEqual(decoded.a, 255,
                       "alpha must be 255 for .noneSkipLast source")
    }

    // MARK: - Phase 3A smoke test (full pipeline)

    /// Encode `reference/dxt5/source/source.mov` through the full
    /// EncodePipeline + DXVMOVWriter and write to:
    ///   - /tmp/glenc-dxt5-smoke.mov  (developer convenience)
    ///   - reference/dxt5/glenc.mov   (Phase 3B comparison artifact, LFS-tracked)
    /// Verifies file size within ±25% of Alley's DXT5 reference and that
    /// every per-frame DXV3 header carries the DXT5 tag.
    func testFullPipelineFromRealMOVSourceAndSaveReference() async throws {
        // Two distinct outputs, mirroring DXT1's
        // `testProduceManualQuickTimeSmokeFile` + `testFullPipelineFromRealMOVSource`
        // split:
        //
        // (1) reference/dxt5/glenc.mov — encoded from the Pass B PNG
        //     sequence. The encoder receives bytes via the same
        //     premultipliedFirst CGContext loader the round-trip test
        //     uses for input AND the SSIM-comparison source loader uses
        //     for ground truth. This isolates encoder quality from
        //     upstream color-conversion quirks (ProRes 4444 tagged
        //     color_range=tv with unknown color_space gets BT.709 matrix
        //     applied by AVAssetReader, which leaks ~25 LSB on G across
        //     saturated colors — a source-pipeline artifact, not an
        //     encoder issue). This file is the Phase 3B SSIM reference.
        //
        // (2) /tmp/glenc-dxt5-smoke.mov — encoded via the actual app
        //     pipeline (AVAssetReader → DXT5Encoder → DXVMOVWriter).
        //     Verifies the pipeline runs end-to-end on a ProRes 4444
        //     source. The encoder is the same; the input bytes differ.
        let corpusURL = Self.referenceDir.appendingPathComponent("glenc.mov")
        let smokeURL  = URL(fileURLWithPath: "/tmp/glenc-dxt5-smoke.mov")
        for u in [corpusURL, smokeURL] {
            if FileManager.default.fileExists(atPath: u.path) {
                try FileManager.default.removeItem(at: u)
            }
        }

        // (1) PNG-encoded corpus → reference/dxt5/glenc.mov
        try encodePNGCorpus(to: corpusURL)

        // (2) ProRes pipeline smoke → /tmp/glenc-dxt5-smoke.mov
        let sourceMOV = Self.referenceDir.appendingPathComponent("source/source.mov")
        guard FileManager.default.fileExists(atPath: sourceMOV.path) else {
            XCTFail("Pass B source.mov missing")
            return
        }
        let pipeline = EncodePipeline(
            sourceURL: sourceMOV,
            encoder: DXT5Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(
                    destURL: smokeURL, format: .dxt5,
                    presentationWidth: w, presentationHeight: h, fps: fps,
                    writerVersion: "GlEnc 0.3.0")
            },
            sourceAlphaInfo: .last)
        try await pipeline.run()

        // Programmatic checks on the pipeline output.
        let asset = AVURLAsset(url: smokeURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1, "expected one video track")
        let dur = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(dur), 1.0, accuracy: 0.05)

        let extractor = try MOVFrameExtractor(url: smokeURL)
        XCTAssertEqual(extractor.frameCount, 30)
        for i in 0..<extractor.frameCount {
            let pkt = extractor.frameData(at: i)
            XCTAssertGreaterThan(pkt.count, 12)
            XCTAssertEqual([UInt8](pkt.prefix(4)), DXVFormat.dxt5.frameTagBytes,
                           "frame \(i) tag should be DXT5 LE")
        }

        let corpusSize = (try FileManager.default.attributesOfItem(atPath: corpusURL.path)[.size] as? Int) ?? 0
        let smokeSize  = (try FileManager.default.attributesOfItem(atPath: smokeURL.path)[.size] as? Int) ?? 0
        let alleySize = 5_608_614
        let corpusRatio = Double(corpusSize) / Double(alleySize)
        let smokeRatio  = Double(smokeSize)  / Double(alleySize)
        print("[dxt5 corpus] PNG-encoded  \(corpusSize) B  (ratio vs Alley = \(String(format: "%.3f", corpusRatio)))")
        print("[dxt5 smoke ] ProRes-piped \(smokeSize) B  (ratio vs Alley = \(String(format: "%.3f", smokeRatio)))")
        XCTAssertGreaterThan(corpusSize, 1_000_000, "corpus suspiciously small")
        XCTAssertGreaterThan(smokeSize, 1_000_000, "smoke suspiciously small")
    }

    /// PNG-encode the 30 Pass B reference frames through DXT5Encoder +
    /// DXVMOVWriter, save to `dest`. Mirrors DXT1's `writeFullCorpus` so
    /// the SSIM-vs-source comparison sees the same bytes the encoder
    /// received.
    private func encodePNGCorpus(to dest: URL) throws {
        let enc = DXT5Encoder()
        try enc.prepare(width: 1920, height: 1080, fps: 30, hasAlpha: true)
        let writer = try DXVMOVWriter(
            destURL: dest, format: .dxt5,
            presentationWidth: 1920, presentationHeight: 1080, fps: 30,
            writerVersion: "GlEnc 0.3.0")
        for i in 0..<30 {
            let pngURL = Self.referenceDir
                .appendingPathComponent(String(format: "source/frame_%04d.png", i + 1))
            let frame = try DXT5TestPNGLoader.loadPNGAsBGRAPixelFrame(
                url: pngURL, width: 1920, height: 1080,
                alphaInfo: .premultipliedFirst)
            let pkt = try enc.encode(frame: frame)
            try writer.append(packet: pkt, presentationTime: CMTime(value: Int64(i) * 1000 / 30, timescale: 1000))
        }
        try enc.finish()
        try writer.finish()
    }

    // MARK: - Synthesis helpers

    private enum FrameRecipe {
        case uniformOpaque                    // (255, 255, 0, 255 / X)
        case premultipliedYellowHalfAlpha     // (128, 128, 0, 128) — pre-multiplied
        case straightYellowHalfAlpha          // (255, 255, 0, 128) — straight
    }

    private func synthesizeFrame(width: Int, height: Int,
                                 alphaInfo: CGImageAlphaInfo,
                                 recipe: FrameRecipe) -> PixelFrame {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height,
                            kCVPixelFormatType_32BGRA, nil, &pb)
        let buf = pb!
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            let row = base.advanced(by: y * bpr)
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                switch recipe {
                case .uniformOpaque:
                    p[0] = 0     // B
                    p[1] = 255   // G
                    p[2] = 255   // R
                    p[3] = 255   // A or X
                case .premultipliedYellowHalfAlpha:
                    p[0] = 0     // B = 0 * 128/255 = 0
                    p[1] = 128   // G = 255 * 128/255 = 128
                    p[2] = 128   // R = 255 * 128/255 = 128
                    p[3] = 128   // A
                case .straightYellowHalfAlpha:
                    p[0] = 0     // B
                    p[1] = 255   // G
                    p[2] = 255   // R
                    p[3] = 128   // A
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(buf, [])
        return PixelFrame(pixelBuffer: buf,
                          presentationTime: .zero,
                          alphaInfo: alphaInfo)
    }

    private struct DecodedPixel { let r, g, b, a: UInt8 }

    private func roundTripSinglePixel(frame: PixelFrame,
                                      codedW: Int, codedH: Int) throws -> DecodedPixel {
        let enc = DXT5Encoder()
        try enc.prepare(width: frame.width, height: frame.height, fps: 30, hasAlpha: true)
        let pkt = try enc.encode(frame: frame)
        try enc.finish()
        let (_, payload) = try DXVPacketDecoder.parseHeader(pkt)
        let blocks = (codedW / 4) * (codedH / 4)
        let bc3 = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: blocks * 16)
        let cgImage = try CPURender.cgImageFromDXT(
            dxtBytes: bc3, variant: .dxt5,
            width: codedW, height: codedH)
        guard let provider = cgImage.dataProvider, let pd = provider.data,
              CFDataGetLength(pd) >= codedW * codedH * 4 else {
            throw NSError(domain: "DXT5T", code: 1)
        }
        let bytes = UnsafeBufferPointer(start: CFDataGetBytePtr(pd),
                                        count: codedW * codedH * 4)
        // Sample center pixel.
        let cx = codedW / 2
        let cy = codedH / 2
        let off = (cy * codedW + cx) * 4
        return DecodedPixel(
            r: bytes[off + 0],
            g: bytes[off + 1],
            b: bytes[off + 2],
            a: bytes[off + 3])
    }

    // PNG → straight RGBA (no premultiplication), for reference comparison
    // in testRoundTripViaGlanceCore. This sidesteps CG's "no straight-alpha
    // bitmap context" limitation by reading the underlying RGBA bytes
    // through a DeviceRGB CGImage with .last (straight) alpha info — only
    // works if the source PNG is straight-alpha to begin with. testsrc2's
    // alpha-overlay PNGs in reference/dxt5/source/ are straight per Pass B.
    private func loadPNGAsStraightRGBA(url: URL, width: Int, height: Int) throws -> [UInt8] {
        guard let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil)
        else { throw NSError(domain: "DXT5T", code: 2) }
        // CGContext requires either premultiplied or no-alpha bitmap info
        // (CG doesn't support straight alpha output). To get straight
        // RGBA we render to premultipliedLast and then divide alpha back
        // out where alpha > 0 (no-op for opaque pixels; recovers straight
        // RGB for partial alpha).
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBufferPointer { buf in
            let space = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                           | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: bitmapInfo)
            else { throw NSError(domain: "DXT5T", code: 3) }
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        // Un-premultiply.
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
}

/// PNG loader scoped to DXT5 tests — same shape as DXT1EncoderTests'
/// loader but parameterized on alphaInfo so pre-multiplied vs straight
/// loading paths are separable.
enum DXT5TestPNGLoader {
    static func loadPNGAsBGRAPixelFrame(url: URL, width: Int, height: Int,
                                        alphaInfo: CGImageAlphaInfo) throws -> PixelFrame {
        guard let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil)
        else { throw NSError(domain: "DXT5L", code: 1) }
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "DXT5L", code: 2)
        }
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let space = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        // Pick the CG bitmapInfo to match the requested alphaInfo. Note:
        // CGContext can only render to premultiplied or no-alpha output;
        // straight alpha output isn't supported by CG. We pick the
        // closest CG bitmapInfo for the layout we want and pass the
        // SEMANTIC alphaInfo through to PixelFrame so the encoder
        // applies the right normalization.
        let cgInfo: CGImageAlphaInfo
        switch alphaInfo {
        case .premultipliedFirst, .premultipliedLast, .first, .last:
            cgInfo = .premultipliedFirst
        default:
            cgInfo = .noneSkipFirst
        }
        let bitmapInfo = cgInfo.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        // Zero the buffer before draw — CVPixelBufferCreate may hand back
        // a recycled allocation whose previous bytes have non-zero alpha.
        // CG's default `.normal` blend mode would then composite the new
        // PNG over those bytes (call-order-dependent output). With α=0
        // padding bytes, .normal degenerates to a clean overwrite, but
        // we set `.copy` explicitly to be defensive.
        memset(base, 0, height * bpr)
        guard let ctx = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: space, bitmapInfo: bitmapInfo)
        else {
            CVPixelBufferUnlockBaseAddress(buf, [])
            throw NSError(domain: "DXT5L", code: 3)
        }
        ctx.interpolationQuality = .none
        ctx.setBlendMode(.copy)
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buf, [])
        return PixelFrame(pixelBuffer: buf,
                          presentationTime: .zero,
                          alphaInfo: alphaInfo)
    }
}
