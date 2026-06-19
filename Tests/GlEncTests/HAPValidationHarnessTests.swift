/*
 * HAPValidationHarnessTests — v0.9.1 Phase H.1 + v0.9.2 Phase E.
 *
 * End-to-end validation harness for the four HAP encoders. Encodes
 * a procedurally-generated 30-frame source through each variant
 * (Hap1 / Hap5 / HapY / HapA — last added in v0.9.2) and validates
 * the complete output artifact:
 *
 *   - Atom structure: ftyp / mdat / moov + stsd / stsz / stco present
 *   - stsd codec FourCC matches the variant ("Hap1" / "Hap5" / "HapY" / "HapA")
 *   - stsz sample_count == 30
 *   - Each frame's section header has the correct type byte
 *     (0xBB / 0xBE / 0xBF / 0xB1) and a parseable length
 *   - Each frame's Snappy-decompressed payload has the expected size
 *     (BC1 = 8 B/block, BC3 = 16 B/block, BC4 = 8 B/block, padding-aligned dims)
 *   - PSNR vs source frame ≥ variant-specific threshold (HapA: alpha-channel-only)
 *
 * Cross-frame consistency: encode the same source twice via the
 * standalone encoders, verify byte-identical output (encoder
 * determinism file-level confirmation).
 *
 * Ecosystem interop: ffprobe inspection of the output file confirms
 * the file is recognized as `codec_name == "hap"` by the FFmpeg
 * ecosystem and reports the expected frame count + dimensions. Skips
 * if ffprobe isn't on PATH.
 *
 * Procedural source: no committed binary fixture. A 64×64 RGBA
 * sequence with an animated gradient + moving square deterministically
 * exercises:
 *   - Smooth-gradient backgrounds (favors HapY's scaled YCoCg)
 *   - Hard edges (stresses BC1's 2-bit indices)
 *   - Animated alpha gradient (validates Hap5's alpha channel)
 */

import XCTest
import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
import GlanceCore
@testable import GlEncCore
import Snappy

@MainActor
final class HAPValidationHarnessTests: XCTestCase {

    // MARK: - Test constants

    /// Procedural source dimensions. 64×64 keeps the harness fast
    /// while still exercising 16×16 block grids (block walker
    /// stride coverage).
    private let sourceW = 64
    private let sourceH = 64
    private let frameCount = 30
    private let fps: Double = 30

    // MARK: - Procedural source

    /// Generate `frameCount` PixelFrames containing an animated
    /// diagonal gradient + a 16×16 square that moves across the
    /// frame each step. Alpha varies sinusoidally so Hap5's
    /// alpha plane gets meaningful content.
    private func proceduralFrames() throws -> [PixelFrame] {
        var frames: [PixelFrame] = []
        frames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let frame = try makeFrame(index: i)
            frames.append(frame)
        }
        return frames
    }

    private func makeFrame(index: Int) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, sourceW, sourceH,
            kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "HAPHarnessTest", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)

        let phase = Double(index) / Double(frameCount)
        // Square position cycles across the frame width.
        let squareX = Int(phase * Double(sourceW - 16))
        let squareY = sourceH / 4 + Int(8 * sin(phase * 2 * .pi))
        let alphaSine = UInt8(min(255, max(0, Int(128 + 127 * sin(phase * 2 * .pi)))))

        for y in 0..<sourceH {
            let row = base.advanced(by: y * bpr)
            for x in 0..<sourceW {
                let p = row.advanced(by: x * 4)
                // Gradient background: R from x, G from y, B oscillating.
                let r = UInt8((x * 4) & 0xFF)
                let g = UInt8((y * 4) & 0xFF)
                let b = UInt8((index * 8 + (x + y) * 2) & 0xFF)
                // Bright square on top: solid white-ish with sinusoidal alpha.
                if x >= squareX && x < squareX + 16
                    && y >= squareY && y < squareY + 16 {
                    p[0] = 0xF0; p[1] = 0xF0; p[2] = 0xF0; p[3] = alphaSine
                } else {
                    p[0] = b; p[1] = g; p[2] = r; p[3] = alphaSine
                }
            }
        }
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero)
    }

    // MARK: - Hap1 end-to-end

    func testHap1EndToEndHarness() throws {
        let tmp = try writeAllFrames(codec: .hap1)
        defer { try? FileManager.default.removeItem(at: tmp.url) }

        // Structural.
        try validateAtomStructure(url: tmp.url, expectedFourCC: "Hap1",
                                  expectedSampleCount: frameCount)
        // Per-frame section headers + Snappy size sanity.
        let bc1ByteCount = blockCount() * 8
        try validatePerFrameSections(url: tmp.url, expectedType: 0xBB,
                                     expectedDecompressedSize: bc1ByteCount)
        // PSNR.
        let psnr = try computeAveragePSNR(url: tmp.url, sourceFrames: tmp.source,
                                          variant: .dxt1)
        XCTAssertGreaterThan(psnr, 30.0,
                             "Hap1 average PSNR \(psnr) below 30 dB gate")
    }

    // MARK: - Hap5 end-to-end

    func testHap5EndToEndHarness() throws {
        let tmp = try writeAllFrames(codec: .hap5)
        defer { try? FileManager.default.removeItem(at: tmp.url) }

        try validateAtomStructure(url: tmp.url, expectedFourCC: "Hap5",
                                  expectedSampleCount: frameCount)
        let bc3ByteCount = blockCount() * 16
        try validatePerFrameSections(url: tmp.url, expectedType: 0xBE,
                                     expectedDecompressedSize: bc3ByteCount)
        let psnr = try computeAveragePSNR(url: tmp.url, sourceFrames: tmp.source,
                                          variant: .dxt5)
        XCTAssertGreaterThan(psnr, 30.0,
                             "Hap5 average PSNR \(psnr) below 30 dB gate")
    }

    // MARK: - HapA end-to-end (v0.9.2 Phase E)

    /// HapA's 30-frame end-to-end gate. Uses a HapA-specific procedural
    /// source with **spatial** alpha variation per frame (the standard
    /// `proceduralFrames` produces temporally-uniform-per-frame alpha,
    /// which would let BC4 trivially compress to one endpoint per
    /// block — fine for Q2 preflight but not a real exercise of the
    /// BC4 encoder's range).
    func testHapAEndToEndHarness() throws {
        let source = try proceduralAlphaFrames()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hap-harness-hapA-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let e = try HapAEncoder(width: sourceW, height: sourceH,
                                fps: fps, destURL: url)
        for (i, f) in source.enumerated() {
            try e.append(frame: f,
                         presentationTime: CMTime(value: CMTimeValue(i),
                                                  timescale: Int32(fps)))
        }
        try e.finish()

        try validateAtomStructure(url: url, expectedFourCC: "HapA",
                                  expectedSampleCount: frameCount)
        // BC4: 8 bytes per 4×4 block, same as BC1.
        let bc4ByteCount = blockCount() * 8
        try validatePerFrameSections(url: url, expectedType: 0xB1,
                                     expectedDecompressedSize: bc4ByteCount)

        // Alpha-channel PSNR. BC4 single-channel decodes high quality
        // on smooth gradients; expect > 40 dB.
        let psnr = try computeAlphaChannelPSNR(url: url, sourceFrames: source)
        XCTAssertGreaterThan(psnr, 40.0,
                             "HapA average alpha-channel PSNR \(psnr) below 40 dB gate")
    }

    // MARK: - HapY end-to-end

    func testHapYEndToEndHarness() throws {
        let tmp = try writeAllFrames(codec: .hapY)
        defer { try? FileManager.default.removeItem(at: tmp.url) }

        try validateAtomStructure(url: tmp.url, expectedFourCC: "HapY",
                                  expectedSampleCount: frameCount)
        let bc3ByteCount = blockCount() * 16
        try validatePerFrameSections(url: tmp.url, expectedType: 0xBF,
                                     expectedDecompressedSize: bc3ByteCount)
        // HapY on procedural content (sharp square + gradient) sits
        // ~25-28 dB. Lower threshold than Hap1/Hap5 because the
        // YCoCg per-block scale + DXT5 packing on the hard-edged
        // square hits both BC1 + the scale-quantization band.
        let psnr = try computeAveragePSNR(url: tmp.url, sourceFrames: tmp.source,
                                          variant: .hapY)
        XCTAssertGreaterThan(psnr, 23.0,
                             "HapY average PSNR \(psnr) below 23 dB gate")
    }

    // MARK: - Encoder determinism (file-level)

    /// Encode the procedural source twice through each variant;
    /// verify the resulting files are byte-identical. Each variant
    /// also gets its own determinism check at the per-frame level
    /// in Phase D/E/F unit tests — this one re-confirms at the
    /// `.mov` file level (catches writer non-determinism).
    func testEncoderDeterminism_Hap1() throws {
        try assertDeterministicFiles(codec: .hap1)
    }
    func testEncoderDeterminism_Hap5() throws {
        try assertDeterministicFiles(codec: .hap5)
    }
    func testEncoderDeterminism_HapY() throws {
        try assertDeterministicFiles(codec: .hapY)
    }
    func testEncoderDeterminism_HapA() throws {
        try assertDeterministicFiles(codec: .hapA)
    }
    func testEncoderDeterminism_HapM() throws {
        try assertDeterministicFiles(codec: .hapM)
    }

    private func assertDeterministicFiles(codec: HapCodec) throws {
        let r1 = try writeAllFrames(codec: codec)
        defer { try? FileManager.default.removeItem(at: r1.url) }
        let r2 = try writeAllFrames(codec: codec)
        defer { try? FileManager.default.removeItem(at: r2.url) }
        let d1 = try Data(contentsOf: r1.url)
        let d2 = try Data(contentsOf: r2.url)
        XCTAssertEqual(d1.count, d2.count,
                       "\(codec) encoder file size differs across runs")
        XCTAssertEqual(d1, d2,
                       "\(codec) encoder output not byte-identical across runs")
    }

    // MARK: - 1080p real-frame-size coverage (v0.9.1 Phase H.3 regression gate)

    /// 1920×1080 frames through each HAP variant. The 64×64 procedural
    /// source in the rest of this suite produces DXT block streams
    /// small enough that the SnappyCompressor.emitCopy chunking bug
    /// (Phase H.3) never triggered — real frames produce long match
    /// runs whose mod-64 residue lands in the previously-broken
    /// {1, 2, 3} class. This test exists to keep that regression
    /// covered at production resolution. 5 frames is enough to
    /// exercise the encode path without slowing the suite to a crawl
    /// (1080p DXT5 = ~1 MB per frame, 5 frames = ~5 MB Snappy input
    /// per variant; harness completes in seconds).
    func testRealFrameSize1080p_AllVariants() throws {
        let w = 1920
        let h = 1080
        let fc = 5
        for codec in [HapCodec.hap1, .hap5, .hapY, .hapA, .hapM] {
            try run1080pSmokeFor(codec: codec, width: w, height: h, frameCount: fc)
        }
    }

    private func run1080pSmokeFor(codec: HapCodec, width: Int, height: Int,
                                  frameCount: Int) throws {
        let frames = try procedural1080pFrames(width: width, height: height,
                                               count: frameCount)
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hap-1080p-\(codec)-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        switch codec {
        case .hap1:
            let e = try Hap1Encoder(width: width, height: height,
                                    fps: 30, destURL: url)
            for (i, f) in frames.enumerated() {
                try e.append(frame: f,
                             presentationTime: CMTime(value: CMTimeValue(i),
                                                      timescale: 30))
            }
            try e.finish()
        case .hap5:
            let e = try Hap5Encoder(width: width, height: height,
                                    fps: 30, destURL: url)
            for (i, f) in frames.enumerated() {
                try e.append(frame: f,
                             presentationTime: CMTime(value: CMTimeValue(i),
                                                      timescale: 30))
            }
            try e.finish()
        case .hapY:
            let e = try HapYEncoder(width: width, height: height,
                                    fps: 30, destURL: url)
            for (i, f) in frames.enumerated() {
                try e.append(frame: f,
                             presentationTime: CMTime(value: CMTimeValue(i),
                                                      timescale: 30))
            }
            try e.finish()
        case .hapA:
            let e = try HapAEncoder(width: width, height: height,
                                    fps: 30, destURL: url)
            for (i, f) in frames.enumerated() {
                try e.append(frame: f,
                             presentationTime: CMTime(value: CMTimeValue(i),
                                                      timescale: 30))
            }
            try e.finish()
        case .hapM:
            // v0.9.3 Phase E: pipeline path (HapFrameEncoder +
            // VariantMOVWriter) — see writeAllFrames .hapM branch.
            let enc = HapFrameEncoder(codec: .hapM)
            try enc.prepare(width: width, height: height,
                            fps: 30, hasAlpha: true)
            let writer = try VariantMOVWriter(
                destURL: url,
                format: .hapM,
                presentationWidth: width,
                presentationHeight: height,
                fps: 30,
                codecFourCC: "HapM")
            for (i, f) in frames.enumerated() {
                let packet = try enc.encode(frame: f)
                try writer.append(
                    packet: packet,
                    presentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
            }
            try enc.finish()
            try writer.finish()
        }

        // Validate atoms + per-frame section round-trip. For 1080p
        // the per-frame DXT stream is large (~1.04 MB for BC3 at
        // 4-pixel coded) — Snappy decompresses cleanly when emitCopy
        // chunking is correct (v0.9.1 Phase H.3 fix).
        //
        // v0.9.2 Phase C.5: HAP coded alignment is 4 pixels (was 16
        // in v0.9.1). For 1920×1080:
        //   16-pixel: coded 1920×1088, blocks 480×272 = 130,560
        //   4-pixel:  coded 1920×1080, blocks 480×270 = 129,600
        // The +1.5% data the v0.9.1 16-pixel padding produced was
        // tolerated by decoders but wasted bytes; v0.9.2 ships the
        // HAP-spec-correct 4-pixel.
        let codedW = (width + 3) & ~3
        let codedH = (height + 3) & ~3
        let blocks1080 = (codedW / 4) * (codedH / 4)

        // HapM has a different sample-shape (outer 0x0D wrapping two
        // inner Snappy sections) so its 1080p assertion is HapM-aware.
        if codec == .hapM {
            try validateAtomStructure1080(url: url, expectedFourCC: "HapM",
                                          expectedSampleCount: frameCount)
            try validatePerFrameHapMSections1080(
                url: url, blocks: blocks1080)
            return
        }

        let expectedFourCC: String
        let expectedType: UInt8
        let expectedDXTSize: Int
        switch codec {
        case .hap1:
            expectedFourCC = "Hap1"
            expectedType = 0xBB
            expectedDXTSize = blocks1080 * 8   // BC1
        case .hap5:
            expectedFourCC = "Hap5"
            expectedType = 0xBE
            expectedDXTSize = blocks1080 * 16  // BC3
        case .hapY:
            expectedFourCC = "HapY"
            expectedType = 0xBF
            expectedDXTSize = blocks1080 * 16  // BC3 reinterpreted
        case .hapA:
            expectedFourCC = "HapA"
            expectedType = 0xB1
            expectedDXTSize = blocks1080 * 8   // BC4 (RGTC1) — 8 B/block
        case .hapM:
            fatalError("unreachable — .hapM handled in early-return above")
        }
        try validateAtomStructure1080(url: url, expectedFourCC: expectedFourCC,
                                      expectedSampleCount: frameCount)
        try validatePerFrameSections1080(url: url, expectedType: expectedType,
                                         expectedDecompressedSize: expectedDXTSize)
    }

    private func procedural1080pFrames(width: Int, height: Int,
                                       count: Int) throws -> [PixelFrame] {
        var frames: [PixelFrame] = []
        frames.reserveCapacity(count)
        for i in 0..<count {
            var pb: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                nil, width, height,
                kCVPixelFormatType_32BGRA, nil, &pb)
            guard status == kCVReturnSuccess, let buf = pb else {
                throw NSError(domain: "HAPHarnessTest", code: Int(status))
            }
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            // Mostly-flat regions with long-match potential — drives
            // SnappyCompressor.emitCopy through the residue-{1,2,3}
            // path that pre-fix tripped UInt8(negative). Solid-ish
            // background + diagonal gradient stripe + a small varying
            // block per frame.
            //
            // v0.9.2 Phase E: alpha varies per row (top opaque 0xFF
            // → bottom transparent 0x00). Hap1/HapY ignore alpha;
            // Hap5/HapA encode it. Adding spatial variation makes
            // HapA's 1080p test actually exercise BC4's range rather
            // than degenerating to all-α=255 constant blocks. The
            // structural + Snappy round-trip gates (not PSNR) are
            // what the 1080p test asserts, so this doesn't shift any
            // Hap1/Hap5/HapY expectation.
            let stripeY = (i * 8) % height
            for y in 0..<height {
                let row = base.advanced(by: y * bpr)
                let isStripe = (y >= stripeY && y < stripeY + 8)
                // Alpha gradient: 0xFF at y=0 → 0x00 at y=height-1.
                let alpha = UInt8(255 - (255 * y / max(1, height - 1)))
                for x in 0..<width {
                    let p = row.advanced(by: x * 4)
                    if isStripe {
                        p[0] = UInt8(x & 0xFF)
                        p[1] = UInt8((x * 2) & 0xFF)
                        p[2] = UInt8((x * 3) & 0xFF)
                        p[3] = alpha
                    } else {
                        // Flat background: most of the frame is one
                        // color → DXT compresses to repeated blocks
                        // → Snappy matcher finds long runs.
                        p[0] = 0x40; p[1] = 0x80; p[2] = 0xC0
                        p[3] = alpha
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            frames.append(PixelFrame(pixelBuffer: buf, presentationTime: .zero))
        }
        return frames
    }

    private func validateAtomStructure1080(url: URL, expectedFourCC: String,
                                           expectedSampleCount: Int) throws {
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 100, "1080p file too small")
        let tree = AtomTree(data: data)
        guard let stsd = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"]),
              let stsz = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]) else {
            XCTFail("stsd/stsz missing in 1080p output")
            return
        }
        let stsdEntryType = String(bytes: data[(stsd.body.lowerBound + 12)..<(stsd.body.lowerBound + 16)],
                                   encoding: .isoLatin1)
        XCTAssertEqual(stsdEntryType, expectedFourCC,
                       "1080p stsd codec FourCC mismatch")
        let count = Int(beU32(data, at: stsz.body.lowerBound + 8))
        XCTAssertEqual(count, expectedSampleCount,
                       "1080p stsz sample_count mismatch")
    }

    private func validatePerFrameSections1080(url: URL,
                                              expectedType: UInt8,
                                              expectedDecompressedSize: Int) throws {
        let data = try Data(contentsOf: url)
        let tree = AtomTree(data: data)
        guard let stsz = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]),
              let stco = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stco"]) else {
            XCTFail("stsz/stco missing")
            return
        }
        let count = Int(beU32(data, at: stsz.body.lowerBound + 8))
        let firstOffset = Int(beU32(data, at: stco.body.lowerBound + 8))
        var cursor = firstOffset
        for i in 0..<count {
            let size = Int(beU32(data, at: stsz.body.lowerBound + 12 + i * 4))
            let sample = data.subdata(in: cursor..<(cursor + size))
            let header = try parseSectionHeader(sample: sample)
            XCTAssertEqual(header.type, expectedType,
                           "1080p frame \(i) section type")
            let snappyPayload = sample.subdata(in: header.offset..<sample.count)
            let dxt = try snappyPayload.uncompressedUsingSnappy()
            XCTAssertEqual(dxt.count, expectedDecompressedSize,
                           "1080p frame \(i): Snappy-decompressed size \(dxt.count) != expected \(expectedDecompressedSize)")
            cursor += size
        }
    }

    // MARK: - ffprobe ecosystem interop

    /// Encode each variant; run ffprobe; verify codec_name == "hap"
    /// and stream metadata matches. Skips when ffprobe isn't on PATH.
    ///
    /// FFmpeg auto-detects all three HAP variants under the unified
    /// "hap" codec name from the per-frame section type byte. Each
    /// variant's file should be recognized identically.
    func testFFmpegEcosystemInterop() throws {
        guard let ffprobe = locateFFprobe() else {
            throw XCTSkip("ffprobe not on PATH — skipping interop check")
        }
        for codec in [HapCodec.hap1, .hap5, .hapY, .hapA, .hapM] {
            let r = try writeAllFrames(codec: codec)
            defer { try? FileManager.default.removeItem(at: r.url) }
            let (codecName, width, height) = try probeStreamMetadata(
                ffprobe: ffprobe, fileURL: r.url)
            XCTAssertEqual(codecName, "hap",
                           "\(codec): ffprobe reported codec_name=\(codecName) (expected hap)")
            XCTAssertEqual(width, sourceW,
                           "\(codec): ffprobe width mismatch")
            XCTAssertEqual(height, sourceH,
                           "\(codec): ffprobe height mismatch")
        }
    }

    // MARK: - Helpers

    enum HapCodec: String, CustomStringConvertible {
        case hap1, hap5, hapY, hapA, hapM
        var description: String { rawValue }
    }

    private func writeAllFrames(codec: HapCodec) throws -> (url: URL, source: [PixelFrame]) {
        // HapA needs spatially-varying alpha to meaningfully exercise
        // BC4; the other variants use the standard procedural source
        // (Hap1/HapY ignore alpha, Hap5's existing test already
        // validates against this source's bytes).
        // HapM (v0.9.3) uses the same spatial-alpha source — its RGB
        // and alpha planes both want non-trivial content.
        let source: [PixelFrame]
        switch codec {
        case .hapA, .hapM:
            source = try proceduralAlphaFrames()
        case .hap1, .hap5, .hapY:
            source = try proceduralFrames()
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hap-harness-\(codec)-\(UUID().uuidString).mov")
        switch codec {
        case .hap1:
            let e = try Hap1Encoder(width: sourceW, height: sourceH,
                                    fps: fps, destURL: url)
            for (i, f) in source.enumerated() {
                try e.append(frame: f,
                             presentationTime: CMTime(value: CMTimeValue(i),
                                                      timescale: Int32(fps)))
            }
            try e.finish()
        case .hap5:
            let e = try Hap5Encoder(width: sourceW, height: sourceH,
                                    fps: fps, destURL: url)
            for (i, f) in source.enumerated() {
                try e.append(frame: f,
                             presentationTime: CMTime(value: CMTimeValue(i),
                                                      timescale: Int32(fps)))
            }
            try e.finish()
        case .hapY:
            let e = try HapYEncoder(width: sourceW, height: sourceH,
                                    fps: fps, destURL: url)
            for (i, f) in source.enumerated() {
                try e.append(frame: f,
                             presentationTime: CMTime(value: CMTimeValue(i),
                                                      timescale: Int32(fps)))
            }
            try e.finish()
        case .hapA:
            let e = try HapAEncoder(width: sourceW, height: sourceH,
                                    fps: fps, destURL: url)
            for (i, f) in source.enumerated() {
                try e.append(frame: f,
                             presentationTime: CMTime(value: CMTimeValue(i),
                                                      timescale: Int32(fps)))
            }
            try e.finish()
        case .hapM:
            // v0.9.3 Phase E: HapM is exercised through the PIPELINE
            // path (HapFrameEncoder + VariantMOVWriter), NOT the
            // standalone HapMEncoder convenience type (which has its
            // own dedicated tests in HapMEncoderTests). This catches
            // any pipeline-side divergence that the standalone path
            // would miss — see the Phase D.1 diagnosis.
            let enc = HapFrameEncoder(codec: .hapM)
            try enc.prepare(width: sourceW, height: sourceH,
                            fps: fps, hasAlpha: true)
            let writer = try VariantMOVWriter(
                destURL: url,
                format: .hapM,
                presentationWidth: sourceW,
                presentationHeight: sourceH,
                fps: fps,
                codecFourCC: "HapM")
            for (i, f) in source.enumerated() {
                let packet = try enc.encode(frame: f)
                try writer.append(
                    packet: packet,
                    presentationTime: CMTime(value: CMTimeValue(i),
                                             timescale: Int32(fps)))
            }
            try enc.finish()
            try writer.finish()
        }
        return (url, source)
    }

    /// HapA-specific procedural source: spatial alpha gradient per
    /// frame so BC4 actually sees per-pixel variation. RGB stays
    /// mid-grey; alpha sweeps top-to-bottom 0xFF→0x00, with the
    /// gradient direction flipping each frame to vary the BC4 endpoint
    /// distribution across the sequence.
    private func proceduralAlphaFrames() throws -> [PixelFrame] {
        var frames: [PixelFrame] = []
        frames.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            var pb: CVPixelBuffer?
            let status = CVPixelBufferCreate(
                nil, sourceW, sourceH,
                kCVPixelFormatType_32BGRA, nil, &pb)
            guard status == kCVReturnSuccess, let buf = pb else {
                throw NSError(domain: "HAPHarnessTest", code: Int(status))
            }
            CVPixelBufferLockBaseAddress(buf, [])
            let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
            let bpr = CVPixelBufferGetBytesPerRow(buf)
            let flipped = (i % 2 == 1)
            for y in 0..<sourceH {
                let row = base.advanced(by: y * bpr)
                let alphaY = flipped ? (sourceH - 1 - y) : y
                let alpha = UInt8(255 - (255 * alphaY / max(1, sourceH - 1)))
                for x in 0..<sourceW {
                    let p = row.advanced(by: x * 4)
                    p[0] = 0x80; p[1] = 0x80; p[2] = 0x80
                    p[3] = alpha
                }
            }
            CVPixelBufferUnlockBaseAddress(buf, [])
            frames.append(PixelFrame(pixelBuffer: buf, presentationTime: .zero))
        }
        return frames
    }

    /// Alpha-channel PSNR for HapA. Decodes each frame's BC4 stream
    /// via the inline BC4 unpacker, compares the decoded alpha plane
    /// to the source's alpha bytes, averages PSNR over all frames.
    private func computeAlphaChannelPSNR(url: URL,
                                          sourceFrames: [PixelFrame]) throws -> Double {
        let data = try Data(contentsOf: url)
        let tree = AtomTree(data: data)
        guard let stsz = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]),
              let stco = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stco"]) else {
            throw NSError(domain: "HAPHarnessTest", code: 1)
        }
        let count = Int(beU32(data, at: stsz.body.lowerBound + 8))
        let firstOffset = Int(beU32(data, at: stco.body.lowerBound + 8))
        var cursor = firstOffset
        var sumPSNR: Double = 0
        for i in 0..<count {
            let size = Int(beU32(data, at: stsz.body.lowerBound + 12 + i * 4))
            let sample = data.subdata(in: cursor..<(cursor + size))
            cursor += size
            let header = try parseSectionHeader(sample: sample)
            let payload = sample.subdata(in: header.offset..<sample.count)
            let bc4 = try payload.uncompressedUsingSnappy()
            let decoded = unpackBC4PlaneInline(blocks: bc4,
                                               width: sourceW, height: sourceH)
            // Source alpha extracted from BGRA byte 3 of each pixel.
            let srcBGRA = sourceFrames[i].bgraBytes()
            var sumSq: Double = 0
            srcBGRA.withUnsafeBytes { raw in
                let src = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for j in 0..<(sourceW * sourceH) {
                    let s = Int(src[j * 4 + 3])
                    let d = Int(decoded[j])
                    let delta = s - d
                    sumSq += Double(delta * delta)
                }
            }
            let mse = sumSq / Double(sourceW * sourceH)
            let psnr = mse <= 0 ? .infinity : 10.0 * log10(255.0 * 255.0 / mse)
            sumPSNR += psnr
        }
        return sumPSNR / Double(count)
    }

    /// BC4 single-channel inline decoder — mirrors GlanceCore's
    /// BC4BC5Unpack.unpackBC4Plane (internal at v0.5.0; same
    /// pattern Phase B's HapABlockPackerTests + Phase C's
    /// HapAEncoderTests use).
    private func unpackBC4PlaneInline(blocks: Data, width: Int, height: Int) -> [UInt8] {
        precondition(width % 4 == 0 && height % 4 == 0)
        let wBlocks = width / 4
        let hBlocks = height / 4
        var out = [UInt8](repeating: 0, count: width * height)
        for by in 0..<hBlocks {
            for bx in 0..<wBlocks {
                let blockOff = (by * wBlocks + bx) * 8
                let a0 = blocks[blockOff]
                let a1 = blocks[blockOff + 1]
                var pal = [UInt8](repeating: 0, count: 8)
                pal[0] = a0
                pal[1] = a1
                let a0i = Int(a0)
                let a1i = Int(a1)
                if a0 > a1 {
                    for i in 2...7 {
                        let num = a0i * (8 - i) + a1i * (i - 1)
                        pal[i] = UInt8((num + 3) / 7)
                    }
                } else {
                    for i in 2...5 {
                        let num = a0i * (6 - i) + a1i * (i - 1)
                        pal[i] = UInt8((num + 2) / 5)
                    }
                    pal[6] = 0
                    pal[7] = 255
                }
                var indices: UInt64 = 0
                for k in 0..<6 {
                    indices |= UInt64(blocks[blockOff + 2 + k]) << (k * 8)
                }
                for py in 0..<4 {
                    for px in 0..<4 {
                        let bitOff = (py * 4 + px) * 3
                        let idx = Int((indices >> bitOff) & 0x07)
                        out[(by * 4 + py) * width + (bx * 4 + px)] = pal[idx]
                    }
                }
            }
        }
        return out
    }

    private func blockCount() -> Int {
        // v0.9.2 Phase C.5: HAP-native 4-pixel coded alignment (was
        // 16-pixel in v0.9.1). For 64×64 either alignment gives 64×64,
        // so this helper's output is unchanged for the 64×64 test
        // path; the mask updates for correctness at the boundary
        // dims a future maintainer might test (e.g. 65×65 → 68×68
        // at 4-pixel vs 80×80 at 16-pixel).
        let coded = ((sourceW + 3) & ~3, (sourceH + 3) & ~3)
        return (coded.0 / 4) * (coded.1 / 4)
    }

    // MARK: - Atom + section validation

    private func validateAtomStructure(url: URL, expectedFourCC: String,
                                       expectedSampleCount: Int) throws {
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 100, "file too small")
        let tree = AtomTree(data: data)
        guard let stsd = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"]),
              let stsz = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]),
              let stco = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stco"]) else {
            XCTFail("stsd/stsz/stco missing")
            return
        }
        // stsd: codec FourCC at offset 8+4 within body (skip v+f + entry_count
        // + sample-entry size; type bytes 4..8 of each entry).
        let stsdEntryType = String(bytes: data[(stsd.body.lowerBound + 12)..<(stsd.body.lowerBound + 16)],
                                   encoding: .isoLatin1)
        XCTAssertEqual(stsdEntryType, expectedFourCC,
                       "stsd codec FourCC mismatch")
        // stsz: count at body+8.
        let count = Int(beU32(data, at: stsz.body.lowerBound + 8))
        XCTAssertEqual(count, expectedSampleCount,
                       "stsz sample_count mismatch")
        // stco: offsets within file bounds.
        let stcoCount = Int(beU32(data, at: stco.body.lowerBound + 4))
        for i in 0..<stcoCount {
            let off = Int(beU32(data, at: stco.body.lowerBound + 8 + i * 4))
            XCTAssertLessThan(off, data.count,
                              "stco offset \(off) out of bounds")
        }
    }

    private func validatePerFrameSections(url: URL,
                                          expectedType: UInt8,
                                          expectedDecompressedSize: Int) throws {
        let data = try Data(contentsOf: url)
        let tree = AtomTree(data: data)
        guard let stsz = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]),
              let stco = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stco"]) else {
            XCTFail("stsz/stco missing")
            return
        }
        let count = Int(beU32(data, at: stsz.body.lowerBound + 8))
        let firstOffset = Int(beU32(data, at: stco.body.lowerBound + 8))
        var cursor = firstOffset
        for i in 0..<count {
            let size = Int(beU32(data, at: stsz.body.lowerBound + 12 + i * 4))
            let sample = data.subdata(in: cursor..<(cursor + size))
            // Section header.
            XCTAssertGreaterThanOrEqual(sample.count, 4,
                                        "frame \(i) sample too short for HAP header")
            XCTAssertEqual(sample[3], expectedType,
                           "frame \(i) section type byte")
            // Parse length.
            let lenShort = UInt32(sample[0])
                | (UInt32(sample[1]) << 8)
                | (UInt32(sample[2]) << 16)
            let payloadOffset: Int
            let payloadLength: Int
            if lenShort == 0 {
                XCTAssertGreaterThanOrEqual(sample.count, 8,
                                            "frame \(i) extended header < 8 B")
                payloadOffset = 8
                payloadLength = Int(UInt32(sample[4])
                                    | (UInt32(sample[5]) << 8)
                                    | (UInt32(sample[6]) << 16)
                                    | (UInt32(sample[7]) << 24))
            } else {
                payloadOffset = 4
                payloadLength = Int(lenShort)
            }
            XCTAssertEqual(payloadOffset + payloadLength, sample.count,
                           "frame \(i): section length mismatch (expected payload to fill sample)")
            // Snappy round-trip → DXT block stream size.
            let snappyPayload = sample.subdata(in: payloadOffset..<sample.count)
            let dxt = try snappyPayload.uncompressedUsingSnappy()
            XCTAssertEqual(dxt.count, expectedDecompressedSize,
                           "frame \(i): Snappy-decompressed size \(dxt.count) != expected \(expectedDecompressedSize)")
            cursor += size
        }
    }

    // MARK: - PSNR oracle

    /// What kind of reconstruction the variant produces. Drives the
    /// post-Snappy decode path.
    enum DecodeVariant {
        case dxt1
        case dxt5
        case hapY
    }

    private func computeAveragePSNR(url: URL,
                                    sourceFrames: [PixelFrame],
                                    variant: DecodeVariant) throws -> Double {
        let data = try Data(contentsOf: url)
        let tree = AtomTree(data: data)
        guard let stsz = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]),
              let stco = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stco"]) else {
            throw NSError(domain: "HAPHarnessTest", code: 1)
        }
        let count = Int(beU32(data, at: stsz.body.lowerBound + 8))
        let firstOffset = Int(beU32(data, at: stco.body.lowerBound + 8))
        var cursor = firstOffset

        var sumPSNR: Double = 0
        var n = 0

        for i in 0..<count {
            let size = Int(beU32(data, at: stsz.body.lowerBound + 12 + i * 4))
            let sample = data.subdata(in: cursor..<(cursor + size))
            cursor += size

            // Parse + Snappy-decompress.
            let header = try parseSectionHeader(sample: sample)
            let payload = sample.subdata(in: header.offset..<sample.count)
            let dxt = try payload.uncompressedUsingSnappy()

            // Decode to RGBA at coded dims via CPURender (variant-aware).
            let decodedRGBA: [UInt8]
            switch variant {
            case .dxt1:
                decodedRGBA = try decodeBC1ToRGBA(dxt)
            case .dxt5:
                decodedRGBA = try decodeBC3ToRGBA(dxt)
            case .hapY:
                let intermediate = try decodeBC3ToRGBA(dxt)
                decodedRGBA = invertHapY(intermediate)
            }
            XCTAssertEqual(decodedRGBA.count, sourceW * sourceH * 4,
                           "frame \(i): decoded RGBA wrong size")
            // PSNR vs source.
            let psnr = rgbaPSNR(source: sourceFrames[i].bgraBytes(),
                                decoded: decodedRGBA,
                                variantHasAlpha: variant != .dxt1 && variant != .hapY)
            sumPSNR += psnr
            n += 1
        }
        return sumPSNR / Double(n)
    }

    private func decodeBC1ToRGBA(_ dxt: Data) throws -> [UInt8] {
        let cg = try CPURender.cgImageFromDXT(dxtBytes: dxt, variant: .dxt1,
                                              width: sourceW, height: sourceH)
        return rawRGBA(from: cg, expectedCount: sourceW * sourceH * 4)
    }

    private func decodeBC3ToRGBA(_ dxt: Data) throws -> [UInt8] {
        let cg = try CPURender.cgImageFromDXT(dxtBytes: dxt, variant: .dxt5,
                                              width: sourceW, height: sourceH)
        return rawRGBA(from: cg, expectedCount: sourceW * sourceH * 4)
    }

    /// HapY inverse formula — mirrors HapYEncoderTests' inline
    /// implementation + GlanceCore's HAPHQDecoder.unpackHapYToRGB
    /// (which lands post-v0.5.0).
    private func invertHapY(_ intermediate: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0xFF, count: sourceW * sourceH * 4)
        for i in 0..<(sourceW * sourceH) {
            let off = i * 4
            let r_in = Double(intermediate[off    ]) / 255.0
            let g_in = Double(intermediate[off + 1]) / 255.0
            let b_in = Double(intermediate[off + 2]) / 255.0
            let y    = Double(intermediate[off + 3]) / 255.0
            let s  = 1.0 / ((255.0 / 8.0) * b_in + 1.0)
            let co = (r_in - 0.5) * s
            let cg = (g_in - 0.5) * s
            let r = y + co - cg
            let g = y + cg
            let b = y - co - cg
            out[off    ] = byteClamp(r * 255.0)
            out[off + 1] = byteClamp(g * 255.0)
            out[off + 2] = byteClamp(b * 255.0)
            out[off + 3] = 0xFF
        }
        return out
    }

    private func rawRGBA(from cg: CGImage, expectedCount: Int) -> [UInt8] {
        guard let provider = cg.dataProvider,
              let cfData = provider.data,
              CFDataGetLength(cfData) >= expectedCount else {
            return []
        }
        return [UInt8](UnsafeBufferPointer(start: CFDataGetBytePtr(cfData),
                                           count: expectedCount))
    }

    private func byteClamp(_ v: Double) -> UInt8 {
        if v <= 0 { return 0 }
        if v >= 255 { return 255 }
        return UInt8(v.rounded())
    }

    /// PSNR on RGB channels (+ alpha if variantHasAlpha) between a
    /// BGRA source buffer and an RGBA decoded buffer.
    private func rgbaPSNR(source: Data, decoded: [UInt8],
                          variantHasAlpha: Bool) -> Double {
        var sumSq: Double = 0
        var samples = 0
        let pixels = sourceW * sourceH
        source.withUnsafeBytes { srcRaw in
            let src = srcRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<pixels {
                let s = i * 4
                let d = i * 4
                let sR = Int(src[s + 2])  // BGRA: R at +2
                let sG = Int(src[s + 1])
                let sB = Int(src[s    ])
                let dR = Int(decoded[d    ])
                let dG = Int(decoded[d + 1])
                let dB = Int(decoded[d + 2])
                let drR = sR - dR
                let drG = sG - dG
                let drB = sB - dB
                sumSq += Double(drR * drR + drG * drG + drB * drB)
                samples += 3
                if variantHasAlpha {
                    let sA = Int(src[s + 3])
                    let dA = Int(decoded[d + 3])
                    let drA = sA - dA
                    sumSq += Double(drA * drA)
                    samples += 1
                }
            }
        }
        let mse = sumSq / Double(samples)
        if mse <= 0 { return .infinity }
        return 10.0 * log10(255.0 * 255.0 / mse)
    }

    // MARK: - ffprobe

    private func locateFFprobe() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        return nil
    }

    private func probeStreamMetadata(ffprobe: URL, fileURL: URL)
            throws -> (codecName: String, width: Int, height: Int) {
        let proc = Process()
        proc.executableURL = ffprobe
        proc.arguments = [
            "-v", "error",
            "-select_streams", "v:0",
            "-show_entries", "stream=codec_name,width,height",
            "-of", "default=noprint_wrappers=1",
            fileURL.path
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        try proc.run()
        proc.waitUntilExit()
        let stdout = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: stdout, encoding: .utf8) ?? ""
        var codecName = ""
        var width = 0
        var height = 0
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "codec_name": codecName = String(parts[1])
            case "width":      width = Int(parts[1]) ?? 0
            case "height":     height = Int(parts[1]) ?? 0
            default: break
            }
        }
        return (codecName, width, height)
    }

    // MARK: - Section header parser + atom tree (local, mirrors Hap*EncoderTests)

    private struct SectionHeader {
        let type: UInt8
        let offset: Int
        let length: Int
    }

    private func parseSectionHeader(sample: Data) throws -> SectionHeader {
        let b0 = UInt32(sample[0])
        let b1 = UInt32(sample[1])
        let b2 = UInt32(sample[2])
        let t = sample[3]
        let lenShort = b0 | (b1 << 8) | (b2 << 16)
        if lenShort == 0 {
            let l0 = UInt32(sample[4])
            let l1 = UInt32(sample[5])
            let l2 = UInt32(sample[6])
            let l3 = UInt32(sample[7])
            return SectionHeader(type: t, offset: 8,
                                 length: Int(l0 | (l1 << 8) | (l2 << 16) | (l3 << 24)))
        }
        return SectionHeader(type: t, offset: 4, length: Int(lenShort))
    }

    private func beU32(_ data: Data, at index: Int) -> UInt32 {
        let b0 = UInt32(data[index])
        let b1 = UInt32(data[index + 1])
        let b2 = UInt32(data[index + 2])
        let b3 = UInt32(data[index + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private struct AtomNode {
        let type: String
        let range: Range<Int>
        let body: Range<Int>
        let children: [AtomNode]
    }

    private struct AtomTree {
        let children: [AtomNode]
        init(data: Data) {
            self.children = AtomTree.parse(data: data, range: 0..<data.count)
        }
        func find(path: [String]) -> AtomNode? {
            var cur = children
            var found: AtomNode?
            for type in path {
                guard let n = cur.first(where: { $0.type == type }) else { return nil }
                found = n
                cur = n.children
            }
            return found
        }
        private static func parse(data: Data, range: Range<Int>) -> [AtomNode] {
            var out: [AtomNode] = []
            var p = range.lowerBound
            while p + 8 <= range.upperBound {
                let sz = Int(readBE32(data, at: p))
                let t = String(bytes: data[(p+4)..<(p+8)], encoding: .isoLatin1) ?? "????"
                let bodyStart: Int
                let atomEnd: Int
                if sz == 0 {
                    bodyStart = p + 8
                    atomEnd = range.upperBound
                } else if sz == 1 {
                    bodyStart = p + 16
                    let l = Int(readBE64(data, at: p + 8))
                    atomEnd = p + l
                } else {
                    bodyStart = p + 8
                    atomEnd = p + sz
                }
                let kids: [AtomNode]
                if isContainer(t) {
                    kids = parse(data: data, range: bodyStart..<atomEnd)
                } else if t == "stsd" {
                    kids = parse(data: data, range: (bodyStart + 8)..<atomEnd)
                } else {
                    kids = []
                }
                out.append(AtomNode(type: t, range: p..<atomEnd,
                                    body: bodyStart..<atomEnd, children: kids))
                p = atomEnd
                if sz == 0 { break }
            }
            return out
        }
        private static func readBE32(_ data: Data, at index: Int) -> UInt32 {
            let b0 = UInt32(data[index])
            let b1 = UInt32(data[index + 1])
            let b2 = UInt32(data[index + 2])
            let b3 = UInt32(data[index + 3])
            return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
        }
        private static func readBE64(_ data: Data, at index: Int) -> UInt64 {
            var v: UInt64 = 0
            for i in 0..<8 { v = (v << 8) | UInt64(data[index + i]) }
            return v
        }
        private static func isContainer(_ t: String) -> Bool {
            switch t {
            case "moov", "trak", "mdia", "minf", "stbl", "dinf", "edts", "udta":
                return true
            default:
                return false
            }
        }
    }

    // MARK: - HapM end-to-end (v0.9.3 Phase E)

    /// HapM 30-frame end-to-end gate at 64×64, driven through the
    /// PIPELINE path (HapFrameEncoder + VariantMOVWriter), mirroring
    /// the four leaf-variant harness tests above. Asserts:
    ///   - stsd codec FourCC == "HapM"
    ///   - 30 samples in stsz
    ///   - each frame's outer section type is 0x0D
    ///   - inside the outer, inner #0 type byte ∈ {0xAF, 0xBF, 0xCF}
    ///     (HapY-kind, single-Snappy from our encoder = 0xBF), inner
    ///     #1 type byte ∈ {0xA1, 0xB1, 0xC1} (HapA-kind, single-
    ///     Snappy = 0xB1)
    ///   - Snappy round-trips of both inner sections yield the
    ///     expected raw-block sizes
    ///   - RGB PSNR ≥ 23 dB. **Tolerance derivation:** HapY's
    ///     procedural-content PSNR gate is also 23 dB
    ///     (testHapYEndToEndHarness, line 203). HapM's RGB IS HapY's
    ///     RGB by construction (the inner HapY section IS a HapY
    ///     payload), so the same gate applies.
    ///   - alpha PSNR ≥ 40 dB. **Tolerance derivation:** HapA's
    ///     alpha-channel PSNR gate is 40 dB
    ///     (testHapAEndToEndHarness, line 182). HapM's alpha IS
    ///     HapA's BC4 plane by construction (the inner HapA section
    ///     IS an HapA payload), so the same gate applies.
    func testHapMEndToEndHarness_PipelinePath() throws {
        let tmp = try writeAllFrames(codec: .hapM)
        defer { try? FileManager.default.removeItem(at: tmp.url) }

        try validateAtomStructure(url: tmp.url, expectedFourCC: "HapM",
                                  expectedSampleCount: frameCount)
        // BC3 = 16 B/block (HapY's reinterpreted), BC4 = 8 B/block (HapA).
        let blocks = blockCount()
        try validatePerFrameHapMSections(url: tmp.url,
                                         expectedInnerHapYDecompressedSize: blocks * 16,
                                         expectedInnerHapADecompressedSize: blocks * 8)

        // RGB + alpha quality vs the source.
        let psnrRGB = try computeAverageHapMRGBPSNR(url: tmp.url,
                                                    sourceFrames: tmp.source)
        let psnrAlpha = try computeAverageHapMAlphaPSNR(url: tmp.url,
                                                        sourceFrames: tmp.source)
        print("[HAPValidationHarnessTests] HapM 64x64 RGB PSNR=\(psnrRGB) dB; alpha PSNR=\(psnrAlpha) dB")
        XCTAssertGreaterThan(psnrRGB, 23.0,
                             "HapM RGB PSNR \(psnrRGB) below 23 dB (HapY precedent)")
        XCTAssertGreaterThan(psnrAlpha, 40.0,
                             "HapM alpha PSNR \(psnrAlpha) below 40 dB (HapA precedent)")
    }

    /// HapM at 1920×1080 driven by the Pass B DXT5 corpus (Q6 locked
    /// decision). Pass B is the v0.9.2 DXT5 byte-archaeology reference
    /// — straight RGBA frames in `reference/dxt5/source/*.png`. This
    /// is the same corpus HapA's v0.9.2 Phase E gated against, so
    /// HapM's results are directly comparable.
    ///
    /// Structural assertions only; PSNR is computed on the 64×64
    /// procedural test above. Pass B's PNGs are pre-multiplied per
    /// the v0.9.2 PassB lock — for HapM (straight alpha at the
    /// section level, per Phase B Q3) we load with
    /// `.premultipliedLast` and let the alpha-normalization helper
    /// un-premult during encode (the HapABlockPacker invokes
    /// AlphaNormalization itself).
    func testHapM_1080p_PassBCorpus_PipelinePath() throws {
        let w = 1920, h = 1080
        let corpusDir = repoReferenceDir.appendingPathComponent("dxt5/source")
        // Sanity: at least frame_0001.png present.
        let first = corpusDir.appendingPathComponent("frame_0001.png")
        guard FileManager.default.fileExists(atPath: first.path) else {
            throw XCTSkip("Pass B corpus missing — \(first.path)")
        }

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hap-harness-hapM-passB-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Pipeline path: HapFrameEncoder(.hapM) + VariantMOVWriter.
        let enc = HapFrameEncoder(codec: .hapM)
        try enc.prepare(width: w, height: h, fps: 30, hasAlpha: true)
        let writer = try VariantMOVWriter(
            destURL: tmp,
            format: .hapM,
            presentationWidth: w,
            presentationHeight: h,
            fps: 30,
            codecFourCC: "HapM")

        // Encode all available PNGs in the Pass B corpus (up to 30).
        var count = 0
        for i in 1...30 {
            let pngURL = corpusDir.appendingPathComponent(String(format: "frame_%04d.png", i))
            guard FileManager.default.fileExists(atPath: pngURL.path) else { break }
            let frame = try DXT5TestPNGLoader.loadPNGAsBGRAPixelFrame(
                url: pngURL, width: w, height: h,
                alphaInfo: .premultipliedLast)
            let packet = try enc.encode(frame: frame)
            try writer.append(
                packet: packet,
                presentationTime: CMTime(value: CMTimeValue(count), timescale: 30))
            count += 1
        }
        XCTAssertGreaterThanOrEqual(count, 1, "Pass B corpus must produce ≥ 1 frame")
        try enc.finish()
        try writer.finish()

        // Structural: stsd FourCC + per-frame outer 0x0D + both inner
        // sections present.
        try validateAtomStructure1080(url: tmp, expectedFourCC: "HapM",
                                      expectedSampleCount: count)
        let codedW = (w + 3) & ~3
        let codedH = (h + 3) & ~3
        let blocks1080 = (codedW / 4) * (codedH / 4)
        try validatePerFrameHapMSections1080(url: tmp, blocks: blocks1080)
    }

    // MARK: - HapM-specific structural validators (v0.9.3 Phase E)

    /// Walk every sample in the file and assert each is a structurally
    /// valid single-Snappy HapM packet: outer 0x0D, inner #0 0xBF
    /// (HapY single-Snappy per Q1), inner #1 0xB1 (HapA single-Snappy
    /// per Q1). Decompresses each inner Snappy payload and asserts
    /// the expected block-stream sizes.
    private func validatePerFrameHapMSections(
        url: URL,
        expectedInnerHapYDecompressedSize: Int,
        expectedInnerHapADecompressedSize: Int
    ) throws {
        let data = try Data(contentsOf: url)
        let tree = AtomTree(data: data)
        guard let stsz = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]),
              let stco = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stco"]) else {
            XCTFail("stsz/stco missing"); return
        }
        let count = Int(beU32(data, at: stsz.body.lowerBound + 8))
        let firstOffset = Int(beU32(data, at: stco.body.lowerBound + 8))
        var cursor = firstOffset
        for i in 0..<count {
            let size = Int(beU32(data, at: stsz.body.lowerBound + 12 + i * 4))
            let sample = data.subdata(in: cursor..<(cursor + size))
            try assertHapMSampleStructure(
                sample: sample, frameIndex: i,
                expectedInnerHapYDecompressedSize: expectedInnerHapYDecompressedSize,
                expectedInnerHapADecompressedSize: expectedInnerHapADecompressedSize)
            cursor += size
        }
    }

    /// 1080p variant — same per-frame check but with the explicit
    /// block-count input so the caller derives expected sizes from
    /// first principles (BC3 = blocks × 16, BC4 = blocks × 8).
    private func validatePerFrameHapMSections1080(url: URL, blocks: Int) throws {
        try validatePerFrameHapMSections(
            url: url,
            expectedInnerHapYDecompressedSize: blocks * 16,   // BC3
            expectedInnerHapADecompressedSize: blocks * 8)    // BC4
    }

    private func assertHapMSampleStructure(
        sample: Data,
        frameIndex i: Int,
        expectedInnerHapYDecompressedSize: Int,
        expectedInnerHapADecompressedSize: Int
    ) throws {
        let outer = try parseSectionHeader(sample: sample)
        XCTAssertEqual(outer.type, 0x0D,
                       "frame \(i): outer section type")
        let outerPayload = sample.subdata(
            in: outer.offset..<(outer.offset + outer.length))

        // Inner #0 — HapY single-Snappy 0xBF.
        let inner0 = try parseSectionHeader(sample: outerPayload)
        XCTAssertEqual(inner0.type, 0xBF,
                       "frame \(i): inner #0 type (expected 0xBF HapY single-Snappy)")
        let inner0Snappy = outerPayload.subdata(
            in: inner0.offset..<(inner0.offset + inner0.length))
        let inner0BC3 = try inner0Snappy.uncompressedUsingSnappy()
        XCTAssertEqual(inner0BC3.count, expectedInnerHapYDecompressedSize,
                       "frame \(i): inner #0 (HapY) BC3 size \(inner0BC3.count) != expected \(expectedInnerHapYDecompressedSize)")

        // Inner #1 — HapA single-Snappy 0xB1.
        let inner1Start = inner0.offset + inner0.length
        let inner1Region = outerPayload.subdata(
            in: inner1Start..<outerPayload.count)
        let inner1 = try parseSectionHeader(sample: inner1Region)
        XCTAssertEqual(inner1.type, 0xB1,
                       "frame \(i): inner #1 type (expected 0xB1 HapA single-Snappy)")
        let inner1Snappy = inner1Region.subdata(
            in: inner1.offset..<(inner1.offset + inner1.length))
        let inner1BC4 = try inner1Snappy.uncompressedUsingSnappy()
        XCTAssertEqual(inner1BC4.count, expectedInnerHapADecompressedSize,
                       "frame \(i): inner #1 (HapA) BC4 size \(inner1BC4.count) != expected \(expectedInnerHapADecompressedSize)")
    }

    // MARK: - HapM PSNR oracles (v0.9.3 Phase E)

    /// Average RGB PSNR over all frames of a HapM file, decoded
    /// through the inline HapY-inverse path. Mirrors
    /// `computeAveragePSNR(..., variant: .hapY)` but walks the outer
    /// 0x0D to find the inner HapY section first.
    private func computeAverageHapMRGBPSNR(url: URL,
                                            sourceFrames: [PixelFrame]) throws -> Double {
        let data = try Data(contentsOf: url)
        let tree = AtomTree(data: data)
        guard let stsz = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]),
              let stco = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stco"]) else {
            throw NSError(domain: "HAPHarnessTest", code: 1)
        }
        let count = Int(beU32(data, at: stsz.body.lowerBound + 8))
        let firstOffset = Int(beU32(data, at: stco.body.lowerBound + 8))
        var cursor = firstOffset
        var sumPSNR: Double = 0
        for i in 0..<count {
            let size = Int(beU32(data, at: stsz.body.lowerBound + 12 + i * 4))
            let sample = data.subdata(in: cursor..<(cursor + size))
            cursor += size
            // Pull the inner HapY section's BC3 bytes.
            let bc3 = try extractHapMInnerHapYBC3(sample: sample)
            let intermediate = try decodeBC3ToRGBA(bc3)
            let decoded = invertHapY(intermediate)
            // RGB-only comparison; HapY's RGB has no alpha component.
            let psnr = rgbaPSNR(source: sourceFrames[i].bgraBytes(),
                                decoded: decoded,
                                variantHasAlpha: false)
            sumPSNR += psnr
        }
        return sumPSNR / Double(count)
    }

    /// Average alpha PSNR over all frames of a HapM file, decoded
    /// through the inline BC4 unpacker. Mirrors
    /// `computeAlphaChannelPSNR(...)` but walks the outer 0x0D to
    /// find the inner HapA section first.
    private func computeAverageHapMAlphaPSNR(url: URL,
                                              sourceFrames: [PixelFrame]) throws -> Double {
        let data = try Data(contentsOf: url)
        let tree = AtomTree(data: data)
        guard let stsz = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]),
              let stco = tree.find(path: ["moov", "trak", "mdia", "minf", "stbl", "stco"]) else {
            throw NSError(domain: "HAPHarnessTest", code: 1)
        }
        let count = Int(beU32(data, at: stsz.body.lowerBound + 8))
        let firstOffset = Int(beU32(data, at: stco.body.lowerBound + 8))
        var cursor = firstOffset
        var sumPSNR: Double = 0
        for i in 0..<count {
            let size = Int(beU32(data, at: stsz.body.lowerBound + 12 + i * 4))
            let sample = data.subdata(in: cursor..<(cursor + size))
            cursor += size
            let bc4 = try extractHapMInnerHapABC4(sample: sample)
            let decoded = unpackBC4PlaneInline(blocks: bc4,
                                               width: sourceW, height: sourceH)
            // Source alpha extracted from BGRA byte 3.
            let srcBGRA = sourceFrames[i].bgraBytes()
            var sumSq: Double = 0
            srcBGRA.withUnsafeBytes { raw in
                let src = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for j in 0..<(sourceW * sourceH) {
                    let s = Int(src[j * 4 + 3])
                    let d = Int(decoded[j])
                    let delta = s - d
                    sumSq += Double(delta * delta)
                }
            }
            let mse = sumSq / Double(sourceW * sourceH)
            let psnr = mse <= 0 ? .infinity : 10.0 * log10(255.0 * 255.0 / mse)
            sumPSNR += psnr
        }
        return sumPSNR / Double(count)
    }

    /// Walk a HapM sample (outer 0x0D wrapping two inner sections)
    /// and return the Snappy-decompressed BC3 bytes from the HapY
    /// (0xBF) inner section.
    private func extractHapMInnerHapYBC3(sample: Data) throws -> Data {
        let outer = try parseSectionHeader(sample: sample)
        let payload = sample.subdata(in: outer.offset..<(outer.offset + outer.length))
        let inner0 = try parseSectionHeader(sample: payload)
        // Q2: HapY first.
        let snappy = payload.subdata(in: inner0.offset..<(inner0.offset + inner0.length))
        return try snappy.uncompressedUsingSnappy()
    }

    /// Walk a HapM sample and return the Snappy-decompressed BC4
    /// bytes from the HapA (0xB1) inner section.
    private func extractHapMInnerHapABC4(sample: Data) throws -> Data {
        let outer = try parseSectionHeader(sample: sample)
        let payload = sample.subdata(in: outer.offset..<(outer.offset + outer.length))
        let inner0 = try parseSectionHeader(sample: payload)
        let inner1Start = inner0.offset + inner0.length
        let inner1Region = payload.subdata(in: inner1Start..<payload.count)
        let inner1 = try parseSectionHeader(sample: inner1Region)
        let snappy = inner1Region.subdata(
            in: inner1.offset..<(inner1.offset + inner1.length))
        return try snappy.uncompressedUsingSnappy()
    }

    /// Repo `reference/` directory — same lookup pattern
    /// DXT5EncoderTests uses (`#file` three deletes up).
    private var repoReferenceDir: URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference")
    }
}
