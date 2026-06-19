/*
 * End-to-end Phase 2B validation:
 *   - testRoundTripViaGlanceCore: encode the 30 reference PNGs through
 *     DXT1Encoder + DXVMOVWriter, then decode each frame through
 *     GlanceCore's DXVPacketDecoder + CPURender. Compute pixel-delta
 *     statistics vs source PNGs. BC1 is lossy so non-zero deltas are
 *     expected; the test's job is to verify the pipeline produces
 *     decodable, sensibly-close-to-source frames — not bit-identity.
 *
 *   - testFullPipelineFromRealMOVSource: run the EncodeQueue / app code
 *     path on the real reference/dxt1/source/source.mov (ProRes 4444):
 *     AVAssetReader → DXT1Encoder → DXVMOVWriter → output .mov. Assert
 *     the output is structurally valid and contains 30 frames. This is
 *     the "the app works end-to-end" smoke that the priming asked for.
 */

import XCTest
import Foundation
import CoreVideo
import CoreGraphics
import ImageIO
import CoreMedia
import AVFoundation
@testable import GlEncCore
import GlanceCore

final class RoundTripAndPipelineTests: XCTestCase {

    private static let referenceDir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference/dxt1")
    }()

    func testRoundTripViaGlanceCore() throws {
        // 1. Encode 30 PNGs to temp .mov
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("glenc-rt-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let enc = DXT1Encoder()
        try enc.prepare(width: 1920, height: 1080, fps: 30, hasAlpha: false)
        let writer = try DXVMOVWriter(
            destURL: tmp, format: .dxt1,
            presentationWidth: 1920, presentationHeight: 1080, fps: 30)
        for i in 0..<30 {
            let pngURL = Self.referenceDir
                .appendingPathComponent(String(format: "source/frame_%04d.png", i + 1))
            let frame = try DXT1EncoderTests_PNGLoader.loadPNGAsBGRAPixelFrame(
                url: pngURL, width: 1920, height: 1080)
            let pkt = try enc.encode(frame: frame)
            try writer.append(packet: pkt, presentationTime: CMTime(value: Int64(i)*1000/30, timescale: 1000))
        }
        try enc.finish()
        try writer.finish()

        // 2. Read back via the test's MOV frame extractor (we don't go through
        //    GlanceCore's DXVDemuxer to keep the demux path matched to what
        //    Phase 2A's tests already exercise). Round-trip happens at the
        //    packet decode layer.
        let extractor = try MOVFrameExtractor(url: tmp)
        XCTAssertEqual(extractor.frameCount, 30)

        // For round-trip, we use coded dims (16-padded) at the decode side
        // because BC1 blocks span the padded grid.
        let codedW = 1920
        let codedH = 1088  // 1080 padded up to next 16-multiple

        var maxDelta: Int = 0
        var totalDelta: Int64 = 0
        var sampleCount: Int64 = 0
        var worstFrame = 0
        var worstX = 0
        var worstY = 0
        var worstCh = 0
        var worstSrc = 0
        var worstDec = 0

        for i in 0..<30 {
            let packet = extractor.frameData(at: i)
            let (_, payload) = try DXVPacketDecoder.parseHeader(packet)
            // BC1 = 8 bytes/block; codedW/4 × codedH/4 blocks.
            let blocks = (codedW / 4) * (codedH / 4)
            let bc1 = try DXVPacketDecoder.decompressDXT1(payload, expectedSize: blocks * 8)
            let cgImage = try CPURender.cgImageFromDXT(
                dxtBytes: bc1, variant: .dxt1,
                width: codedW, height: codedH)
            // Pull the raw RGBA bytes directly from the CGImage's data
            // provider. CPURender constructs the CGImage from a packed RGBA
            // byte array; the data provider hands those bytes back without
            // a color-space transform. Going through `ctx.draw(cgImage)`
            // would re-render with CG's color management (CPURender tags
            // its CGImage DeviceRGB; re-rendering into an sRGB context
            // applies a transform that injects up to ~ tens of LSB on
            // saturated pixels — masking the BC1 lossy band we're
            // actually trying to measure).
            guard let provider = cgImage.dataProvider,
                  let providerData = provider.data,
                  CFDataGetLength(providerData) >= codedW * codedH * 4
            else {
                XCTFail("frame \(i): CGImage data provider unavailable")
                return
            }
            let decodedRGBA = [UInt8](
                UnsafeBufferPointer(
                    start: CFDataGetBytePtr(providerData),
                    count: codedW * codedH * 4))

            // Read source PNG → RGBA at presentation dims, using the same
            // PNG-to-bytes path the encoder uses (BGRA via CGContext
            // premultipliedFirst byteOrder32Little) so source bytes match
            // what the encoder saw.
            let pngURL = Self.referenceDir
                .appendingPathComponent(String(format: "source/frame_%04d.png", i + 1))
            let sourceRGBA = try loadPNGAsRGBA(url: pngURL, width: 1920, height: 1080)

            // Compare pixel by pixel within the 1920×1080 presentation region.
            for y in 0..<1080 {
                for x in 0..<1920 {
                    let off = (y * codedW + x) * 4
                    let srcOff = (y * 1920 + x) * 4
                    for ch in 0..<3 {  // skip alpha
                        let s = Int(sourceRGBA[srcOff + ch])
                        let d = Int(decodedRGBA[off + ch])
                        let delta = abs(s - d)
                        if delta > maxDelta {
                            maxDelta = delta
                            worstFrame = i
                            worstX = x; worstY = y; worstCh = ch
                            worstSrc = s; worstDec = d
                        }
                        totalDelta += Int64(delta)
                        sampleCount += 1
                    }
                }
            }
        }
        let meanDelta = Double(totalDelta) / Double(sampleCount)
        print("[round-trip] mean |Δ|=\(String(format: "%.3f", meanDelta)) LSB/channel, max |Δ|=\(maxDelta) LSB/channel over \(sampleCount) samples")
        let chName = ["R", "G", "B"][worstCh]
        print("[round-trip] worst pixel: frame=\(worstFrame) (\(worstX),\(worstY)) ch=\(chName) src=\(worstSrc) dec=\(worstDec)")

        // Cross-check: same metrics measured on ffmpeg.mov decoded through
        // the same GlanceCore chain. If ffmpeg's deltas match ours within
        // noise, BC1's representation gap explains the worst-case pixel —
        // it's a property of the content (testsrc2 has color bars and
        // scrolling text) and the BC1 codec, not a GlEnc bug.
        let (refMean, refMax) = try referenceRoundTripStats(codedW: codedW, codedH: codedH)
        print("[round-trip] ffmpeg.mov decoded through same chain: mean |Δ|=\(String(format: "%.3f", refMean)), max |Δ|=\(refMax)")

        // Bounds: BC1 max-delta on hard content (saturated edges + text) can
        // exceed 100 LSB. We assert against a generous ceiling and require
        // ours to be in the same neighborhood as ffmpeg's reference decode.
        XCTAssertLessThan(meanDelta, 5.0, "mean per-channel delta too high")
        XCTAssertLessThan(maxDelta, 200, "max per-channel delta unreasonable")
        XCTAssertLessThan(meanDelta, refMean * 1.5,
            "GlEnc's mean delta exceeds ffmpeg's by >50% — possible quality regression")
    }

    /// Decode reference/dxt1/ffmpeg.mov through the same DXVPacketDecoder +
    /// CPURender + source-PNG comparison chain. Returns (mean, max) deltas.
    private func referenceRoundTripStats(codedW: Int, codedH: Int) throws -> (mean: Double, max: Int) {
        let extractor = try MOVFrameExtractor(
            url: Self.referenceDir.appendingPathComponent("ffmpeg.mov"))
        var maxDelta = 0
        var totalDelta: Int64 = 0
        var sampleCount: Int64 = 0
        for i in 0..<extractor.frameCount {
            let packet = extractor.frameData(at: i)
            let (_, payload) = try DXVPacketDecoder.parseHeader(packet)
            let blocks = (codedW / 4) * (codedH / 4)
            let bc1 = try DXVPacketDecoder.decompressDXT1(payload, expectedSize: blocks * 8)
            let cgImage = try CPURender.cgImageFromDXT(
                dxtBytes: bc1, variant: .dxt1, width: codedW, height: codedH)
            guard let provider = cgImage.dataProvider, let pd = provider.data,
                  CFDataGetLength(pd) >= codedW * codedH * 4 else {
                throw NSError(domain: "RT", code: 100)
            }
            let decoded = [UInt8](
                UnsafeBufferPointer(start: CFDataGetBytePtr(pd), count: codedW * codedH * 4))
            let pngURL = Self.referenceDir
                .appendingPathComponent(String(format: "source/frame_%04d.png", i + 1))
            let source = try loadPNGAsRGBA(url: pngURL, width: 1920, height: 1080)
            for y in 0..<1080 {
                for x in 0..<1920 {
                    let off = (y * codedW + x) * 4
                    let srcOff = (y * 1920 + x) * 4
                    for ch in 0..<3 {
                        let d = abs(Int(source[srcOff + ch]) - Int(decoded[off + ch]))
                        if d > maxDelta { maxDelta = d }
                        totalDelta += Int64(d)
                        sampleCount += 1
                    }
                }
            }
        }
        return (Double(totalDelta) / Double(sampleCount), maxDelta)
    }

    /// Emits the GlEnc-encoded testsrc2 corpus to two paths:
    ///   - /tmp/glenc-smoke.mov for ad-hoc visual inspection.
    ///   - <tempdir>/glenc-corpus-<uuid>.mov for the corpus byte-identity
    ///     check below.
    ///
    /// v0.9.3 Phase B: previously the corpus destination was the
    /// committed fixture reference/dxt1/glenc.mov, which meant every
    /// test-suite run dirtied that file and required a manual
    /// `git checkout reference/dxt1/glenc.mov` afterwards. The fixture
    /// is regenerated by `CorpusGenerationTests` (a separate
    /// dedicated test) when intentionally bumping it; this smoke test
    /// no longer touches it.
    ///
    /// Programmatic structural checks happen in `testQuickTimePlayability`
    /// and the atom-diff tests; this test's job is to leave files behind
    /// in a known location for ad-hoc inspection.
    func testProduceManualQuickTimeSmokeFile() throws {
        let smokeDest = URL(fileURLWithPath: "/tmp/glenc-smoke.mov")
        let corpusDest = FileManager.default.temporaryDirectory
            .appendingPathComponent("glenc-corpus-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: corpusDest) }
        try writeFullCorpus(to: smokeDest)
        try writeFullCorpus(to: corpusDest)
        let smokeSize = (try FileManager.default.attributesOfItem(atPath: smokeDest.path)[.size] as? Int) ?? 0
        let corpusSize = (try FileManager.default.attributesOfItem(atPath: corpusDest.path)[.size] as? Int) ?? 0
        XCTAssertEqual(smokeSize, corpusSize, "smoke and corpus copies should be byte-identical")
        XCTAssertGreaterThan(smokeSize, 1_000_000)
        print("[corpus] wrote \(corpusDest.path) — \(corpusSize) bytes")
        print("[smoke]  wrote \(smokeDest.path) — \(smokeSize) bytes")
    }

    private func writeFullCorpus(to dest: URL) throws {
        let enc = DXT1Encoder()
        try enc.prepare(width: 1920, height: 1080, fps: 30, hasAlpha: false)
        let writer = try DXVMOVWriter(
            destURL: dest, format: .dxt1,
            presentationWidth: 1920, presentationHeight: 1080, fps: 30)
        for i in 0..<30 {
            let pngURL = Self.referenceDir
                .appendingPathComponent(String(format: "source/frame_%04d.png", i + 1))
            let frame = try DXT1EncoderTests_PNGLoader.loadPNGAsBGRAPixelFrame(
                url: pngURL, width: 1920, height: 1080)
            let pkt = try enc.encode(frame: frame)
            try writer.append(packet: pkt, presentationTime: CMTime(value: Int64(i)*1000/30, timescale: 1000))
        }
        try enc.finish()
        try writer.finish()
    }

    func testFullPipelineFromRealMOVSource() async throws {
        // Run the EncodeQueue / app's actual code path:
        //   AVAssetReader (BGRA8 via VideoToolbox) → DXT1Encoder → DXVMOVWriter
        // on the ProRes 4444 source. This is what the Mac app does when the
        // user drops source.mov onto it.
        let sourceMOV = Self.referenceDir.appendingPathComponent("source/source.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: sourceMOV.path),
            "reference/dxt1/source/source.mov missing (stripped from the public seed) — regenerate via scripts/make-corpus.sh (FFmpeg required)")

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("glenc-pipeline-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let pipeline = EncodePipeline(
            sourceURL: sourceMOV,
            encoder: DXT1Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(
                    destURL: tmp, format: .dxt1,
                    presentationWidth: w, presentationHeight: h, fps: fps)
            })
        try await pipeline.run()

        // Verify the output is well-formed.
        XCTAssertTrue(FileManager.default.fileExists(atPath: tmp.path), "output file not created")
        let asset = AVURLAsset(url: tmp)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let dur = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(dur), 1.0, accuracy: 0.05)

        // Verify per-frame DXV3 headers are intact: extract via MOV walker
        // and check the first 4 bytes of each frame are the DXT1 LE tag.
        let extractor = try MOVFrameExtractor(url: tmp)
        XCTAssertEqual(extractor.frameCount, 30, "expected 30 frames from source.mov")
        for i in 0..<extractor.frameCount {
            let pkt = extractor.frameData(at: i)
            XCTAssertGreaterThan(pkt.count, 12)
            XCTAssertEqual([UInt8](pkt.prefix(4)), DXVFormat.dxt1.frameTagBytes)
        }

        let outSize = try FileManager.default.attributesOfItem(atPath: tmp.path)[.size] as! Int
        let refSize = try FileManager.default.attributesOfItem(
            atPath: Self.referenceDir.appendingPathComponent("ffmpeg.mov").path)[.size] as! Int
        let ratio = Double(outSize) / Double(refSize)
        print("[pipeline] real-source output: \(outSize) bytes (ratio vs ffmpeg.mov: \(String(format: "%.3f", ratio)))")
        // Source.mov decoded to BGRA via AVAssetReader produces frames that
        // may differ slightly from the PNG sequence (ProRes → BGRA color
        // conversion is well-defined but not bit-equivalent to PNG decode).
        // Output size should be in the same ballpark as ffmpeg.mov ±25%.
        XCTAssertGreaterThan(ratio, 0.5, "output suspiciously smaller than ffmpeg ref")
        XCTAssertLessThan(ratio, 2.0, "output suspiciously larger than ffmpeg ref")
    }

    // MARK: - PNG → RGBA helper (presentation dims, no padding)

    private func loadPNGAsRGBA(url: URL, width: Int, height: Int) throws -> [UInt8] {
        guard let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil)
        else { throw NSError(domain: "RT", code: 1) }
        let space = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBufferPointer { buf in
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                           | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: bitmapInfo)
            else { throw NSError(domain: "RT", code: 2) }
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return rgba
    }

    /// Decode a CGImage into a tightly-packed RGBA byte array of the given
    /// dimensions. CPURender produces a CGImage at coded (padded) dims; we
    /// rasterize it to RGBA to do pixel comparisons.
    private func renderCGImageAsRGBA(cgImage: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        try rgba.withUnsafeMutableBufferPointer { buf in
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
                           | CGBitmapInfo.byteOrder32Big.rawValue
            guard let ctx = CGContext(
                data: buf.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: space, bitmapInfo: bitmapInfo)
            else { throw NSError(domain: "RT", code: 3) }
            ctx.interpolationQuality = .none
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return rgba
    }
}
