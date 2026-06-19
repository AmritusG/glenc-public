/*
 * DXT1 encoder tests.
 *
 * Phase 2A's byte-identity-to-FFmpeg tests were retired in Phase 5C.2
 * when the BC1 endpoint search switched from the FFmpeg port to
 * Squish-style ClusterFit. The v0.2.0 byte-identity contract was a
 * development contract; the v0.5.0 product contract is
 * fidelity-to-source, measured by SSIM(GlEnc, source) in
 * Phase2CTests.testSSIM_GlEncVsSource.
 *
 * What's left here:
 *   - testThirtyFramesProduceNonEmptyPackets: smoke test that the
 *     encoder runs end-to-end on the Pass A corpus and emits
 *     structurally-valid DXV3 packets (header bytes, size field).
 *
 * What moved out:
 *   - testFrameZeroByteExactMatch and testAllFramesByteExactMatch
 *     compared per-frame bytes against `ffmpeg -c:v dxv -format dxt1`
 *     output. Deleted in Phase 5C.2 — see PHASE-5C-RESULTS.md or
 *     reference/endpoint-search-study/FINDINGS.md for the rationale.
 *     If you need the legacy byte-identity path for A/B testing, set
 *     `BC1Config.useClusterFit = false` and the existing test
 *     scaffolding (MOVFrameExtractor at bottom of this file) still
 *     applies. Tests can be reinstated locally with that flag flipped.
 *   - testDiagnoseFrame5BlockDivergence was a debugging aid for the
 *     Phase 2A FMA-contraction byte-identity hunt. Obsolete now that
 *     byte-identity isn't the contract.
 *
 * `MOVFrameExtractor` at the bottom of this file is still used by the
 * Phase 5A YG10 smoke test, the Phase 3B DXT5 smoke test, and any
 * test that reads per-frame DXV3 packets out of a `.mov`.
 */

import XCTest
import CoreVideo
import CoreGraphics
import ImageIO
import CoreMedia
import Foundation
@testable import GlEncCore

final class DXT1EncoderTests: XCTestCase {

    private static let referenceDir: URL = {
        let testFile = URL(fileURLWithPath: #file)
        return testFile
            .deletingLastPathComponent()  // GlEncTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // GlEnc (project root)
            .appendingPathComponent("reference/dxt1")
    }()

    /// Smoke test: verify the encoder runs through 30 frames without crashing
    /// and produces non-empty packets with valid DXV3 per-frame headers. The
    /// quality-vs-source gate lives in `Phase2CTests.testSSIM_GlEncVsSource`.
    func testThirtyFramesProduceNonEmptyPackets() throws {
        let enc = DXT1Encoder()
        try enc.prepare(width: 1920, height: 1080, fps: 30, hasAlpha: false)

        for i in 0..<30 {
            let pngURL = Self.referenceDir
                .appendingPathComponent(String(format: "source/frame_%04d.png", i + 1))
            let frame = try loadPNGAsBGRAPixelFrame(url: pngURL, width: 1920, height: 1080)
            let pkt = try enc.encode(frame: frame)
            XCTAssertGreaterThan(pkt.count, 12, "frame \(i): expected >12 bytes (header + payload)")
            // Sanity: header tag bytes
            XCTAssertEqual([UInt8](pkt.prefix(4)), DXVFormat.dxt1.frameTagBytes)
            XCTAssertEqual(pkt[4], 0x04)
            XCTAssertEqual(pkt[5], 0x00)
            XCTAssertEqual(pkt[6], 0x00)
            XCTAssertEqual(pkt[7], 0x00)
            // size LE32 at offset 8 should equal payload length
            let sizeLE = UInt32(pkt[8]) | (UInt32(pkt[9]) << 8)
                       | (UInt32(pkt[10]) << 16) | (UInt32(pkt[11]) << 24)
            XCTAssertEqual(Int(sizeLE), pkt.count - 12)
        }
        try enc.finish()
    }

    // MARK: - PNG → BGRA PixelFrame

    private func loadPNGAsBGRAPixelFrame(url: URL, width: Int, height: Int) throws -> PixelFrame {
        guard let imgSrc = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw NSError(domain: "DXT1Test", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "CGImageSourceCreateWithURL failed: \(url.path)"])
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(imgSrc, 0, nil) else {
            throw NSError(domain: "DXT1Test", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "CGImageSourceCreateImageAtIndex failed"])
        }
        XCTAssertEqual(cgImage.width, width, "PNG width mismatch")
        XCTAssertEqual(cgImage.height, height, "PNG height mismatch")

        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(nil, width, height,
                                         kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "DXT1Test", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed (status \(status))"])
        }
        CVPixelBufferLockBaseAddress(buf, [])
        let base = CVPixelBufferGetBaseAddress(buf)!
        let bpr = CVPixelBufferGetBytesPerRow(buf)

        // Use the source CGImage's color space so CGImage→CGContext is the
        // identity transform (no gamma/whitepoint reinterpretation). For
        // testsrc2 PNGs which carry no profile, CGImage typically assigns
        // sRGB by default; passing that same space to the destination
        // context guarantees verbatim pixel transfer.
        let space = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
                       | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: base, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bpr,
            space: space, bitmapInfo: bitmapInfo)
        else {
            CVPixelBufferUnlockBaseAddress(buf, [])
            throw NSError(domain: "DXT1Test", code: 4,
                userInfo: [NSLocalizedDescriptionKey: "CGContext init failed"])
        }
        ctx.interpolationQuality = .none
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        CVPixelBufferUnlockBaseAddress(buf, [])

        return PixelFrame(pixelBuffer: buf, presentationTime: .zero)
    }
}

// MARK: - Minimal MOV atom walker for frame extraction

/// Reads stco + stsz + stsc out of a Resolume-style DXV3 MOV and exposes a
/// per-frame byte-range view of mdat. End-of-file `moov` and front-of-file
/// `moov` layouts both work because we walk top-level atoms by type.
final class MOVFrameExtractor {

    enum MOVError: Error, CustomStringConvertible {
        case atomNotFound(String)
        case parseError(String)
        var description: String {
            switch self {
            case .atomNotFound(let t): return "MOV atom not found: \(t)"
            case .parseError(let s): return "MOV parse error: \(s)"
            }
        }
    }

    let data: Data
    let frameOffsets: [Int]
    let frameSizes: [Int]
    var frameCount: Int { frameSizes.count }

    init(url: URL) throws {
        self.data = try Data(contentsOf: url)
        let fileRange = 0..<data.count

        guard let moov = MOVFrameExtractor.findAtom(in: data, range: fileRange, type: "moov")
        else { throw MOVError.atomNotFound("moov") }
        guard let trak = MOVFrameExtractor.findAtom(in: data, range: moov, type: "trak")
        else { throw MOVError.atomNotFound("trak") }
        guard let mdia = MOVFrameExtractor.findAtom(in: data, range: trak, type: "mdia")
        else { throw MOVError.atomNotFound("mdia") }
        guard let minf = MOVFrameExtractor.findAtom(in: data, range: mdia, type: "minf")
        else { throw MOVError.atomNotFound("minf") }
        guard let stbl = MOVFrameExtractor.findAtom(in: data, range: minf, type: "stbl")
        else { throw MOVError.atomNotFound("stbl") }
        guard let stco = MOVFrameExtractor.findAtom(in: data, range: stbl, type: "stco")
        else { throw MOVError.atomNotFound("stco") }
        guard let stsz = MOVFrameExtractor.findAtom(in: data, range: stbl, type: "stsz")
        else { throw MOVError.atomNotFound("stsz") }
        guard let stsc = MOVFrameExtractor.findAtom(in: data, range: stbl, type: "stsc")
        else { throw MOVError.atomNotFound("stsc") }

        // stco: 4 version+flags + 4 entry_count + N×4 chunk offsets
        var p = stco.lowerBound + 4
        let stcoCount = Int(MOVFrameExtractor.readBE32(data, at: p)); p += 4
        var chunkOffsets: [Int] = []
        chunkOffsets.reserveCapacity(stcoCount)
        for _ in 0..<stcoCount {
            chunkOffsets.append(Int(MOVFrameExtractor.readBE32(data, at: p)))
            p += 4
        }

        // stsz: 4 version+flags + 4 sample_size + 4 sample_count + (N×4 if sample_size==0)
        p = stsz.lowerBound + 4
        let sampleSize = Int(MOVFrameExtractor.readBE32(data, at: p)); p += 4
        let sampleCount = Int(MOVFrameExtractor.readBE32(data, at: p)); p += 4
        var sampleSizes: [Int] = []
        if sampleSize == 0 {
            sampleSizes.reserveCapacity(sampleCount)
            for _ in 0..<sampleCount {
                sampleSizes.append(Int(MOVFrameExtractor.readBE32(data, at: p)))
                p += 4
            }
        } else {
            sampleSizes = [Int](repeating: sampleSize, count: sampleCount)
        }

        // stsc: 4 version+flags + 4 entry_count + N×(first_chunk:4, samples_per_chunk:4, sdi:4)
        p = stsc.lowerBound + 4
        let stscCount = Int(MOVFrameExtractor.readBE32(data, at: p)); p += 4
        var stscEntries: [(firstChunk: Int, spc: Int)] = []
        stscEntries.reserveCapacity(stscCount)
        for _ in 0..<stscCount {
            let fc  = Int(MOVFrameExtractor.readBE32(data, at: p)); p += 4
            let spc = Int(MOVFrameExtractor.readBE32(data, at: p)); p += 4
            p += 4 // skip sample_description_index
            stscEntries.append((fc, spc))
        }

        // Compute per-sample absolute byte offsets.
        var offs: [Int] = []
        offs.reserveCapacity(sampleCount)
        var sampleIdx = 0
        for chunk in 1...max(1, chunkOffsets.count) {
            // largest stsc entry whose first_chunk <= chunk
            var spc = 0
            for e in stscEntries {
                if e.firstChunk <= chunk { spc = e.spc } else { break }
            }
            var off = chunkOffsets[chunk - 1]
            for _ in 0..<spc {
                if sampleIdx >= sampleCount { break }
                offs.append(off)
                off += sampleSizes[sampleIdx]
                sampleIdx += 1
            }
            if sampleIdx >= sampleCount { break }
        }
        if offs.count != sampleCount {
            throw MOVError.parseError("computed \(offs.count) offsets, stsz has \(sampleCount) samples")
        }
        self.frameOffsets = offs
        self.frameSizes = sampleSizes
    }

    func frameData(at i: Int) -> Data {
        let off = frameOffsets[i]
        let sz = frameSizes[i]
        return data.subdata(in: off..<(off+sz))
    }

    /// Walk the immediate children of `range` and return the byte range of
    /// the first child whose type matches. Handles size==0 (extends to end)
    /// and size==1 (64-bit largesize) per ISO BMFF.
    static func findAtom(in data: Data, range: Range<Int>, type: String) -> Range<Int>? {
        var p = range.lowerBound
        while p + 8 <= range.upperBound {
            let size32 = Int(readBE32(data, at: p))
            // Type bytes at p+4 .. p+8
            let typeStr = String(bytes: data[(p+4)..<(p+8)], encoding: .ascii) ?? "????"
            if size32 == 0 {
                // extends to end of container
                if typeStr == type { return (p+8)..<range.upperBound }
                break
            } else if size32 == 1 {
                let largeSize = Int(readBE64(data, at: p+8))
                if typeStr == type { return (p+16)..<(p+largeSize) }
                p += largeSize
            } else {
                if typeStr == type { return (p+8)..<(p+size32) }
                p += size32
            }
        }
        return nil
    }

    static func readBE32(_ data: Data, at off: Int) -> UInt32 {
        return UInt32(data[off    ]) << 24
             | UInt32(data[off + 1]) << 16
             | UInt32(data[off + 2]) <<  8
             | UInt32(data[off + 3])
    }
    static func readBE64(_ data: Data, at off: Int) -> UInt64 {
        var r: UInt64 = 0
        for i in 0..<8 { r = (r << 8) | UInt64(data[off + i]) }
        return r
    }
}
