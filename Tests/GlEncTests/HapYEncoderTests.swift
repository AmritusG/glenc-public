/*
 * HapYEncoderTests — v0.9.1 Phase F.
 *
 * Validates the HapY (Scaled YCoCg DXT5) encoder.
 *
 * Section-header parsing is the same in-test mirror of GlanceCore's
 * HAPPacketDecoder.parseSectionHeader used by the Hap1/Hap5 tests.
 * Snappy decompression goes through `lovetodream/swift-snappy`.
 *
 * For visual round-trip, we decode the BC3 stream via GlanceCore's
 * CPURender.cgImageFromDXT(.dxt5) (available in v0.5.0 — DXT5 was
 * Phase 3), then apply the HapY inverse formula per pixel. Compared
 * vs source RGB on a PSNR gate to confirm color accuracy.
 *
 * GlanceCore.HAPHQDecoder lands in Phase 6.b (post-v0.5.0); we
 * inline its 30-line HapY inverse here for the same reason
 * Hap1EncoderTests inlines the section parser.
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
final class HapYEncoderTests: XCTestCase {

    // MARK: - Synthesis helpers

    private func solidPixelFrame(
        width: Int, height: Int,
        b: UInt8, g: UInt8, r: UInt8, a: UInt8 = 0xFF
    ) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "HapYTest", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed"])
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            let row = base.advanced(by: y * bpr)
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                p[0] = b; p[1] = g; p[2] = r; p[3] = a
            }
        }
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero)
    }

    /// A frame whose per-pixel RGB varies enough that all three
    /// HapY scale paths get exercised — center has neutral grey
    /// (low chroma → s=4), edges have saturated red/green/blue
    /// (high chroma → s=1).
    private func chromaGradientFrame(width: Int, height: Int) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "HapYTest", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed"])
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        let cx = Double(width) / 2.0
        let cy = Double(height) / 2.0
        let maxRadius = sqrt(cx * cx + cy * cy)
        for y in 0..<height {
            let row = base.advanced(by: y * bpr)
            for x in 0..<width {
                let dx = Double(x) - cx
                let dy = Double(y) - cy
                let r = sqrt(dx * dx + dy * dy) / maxRadius  // 0 at center, 1 at corner
                // Center: mid-grey (128,128,128). Corners: pure red/green/blue
                // depending on which quadrant.
                let neutral: Double = 128.0
                let extra: Double = r * 127.0
                let red: UInt8
                let green: UInt8
                let blue: UInt8
                if x < width / 2 && y < height / 2 {
                    // top-left: extra red
                    red = UInt8(min(255, neutral + extra))
                    green = UInt8(min(255, max(0, neutral - extra * 0.5)))
                    blue = UInt8(min(255, max(0, neutral - extra * 0.5)))
                } else if x >= width / 2 && y < height / 2 {
                    // top-right: extra green
                    red = UInt8(min(255, max(0, neutral - extra * 0.5)))
                    green = UInt8(min(255, neutral + extra))
                    blue = UInt8(min(255, max(0, neutral - extra * 0.5)))
                } else if x < width / 2 && y >= height / 2 {
                    // bottom-left: extra blue
                    red = UInt8(min(255, max(0, neutral - extra * 0.5)))
                    green = UInt8(min(255, max(0, neutral - extra * 0.5)))
                    blue = UInt8(min(255, neutral + extra))
                } else {
                    // bottom-right: neutral grey gradient (low chroma)
                    let v = UInt8(min(255, neutral + extra * 0.3))
                    red = v; green = v; blue = v
                }
                let p = row.advanced(by: x * 4)
                p[0] = blue; p[1] = green; p[2] = red; p[3] = 0xFF
            }
        }
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero)
    }

    // MARK: - Tests

    func testSingleFrameHapYEncode() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapy-single-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let frame = try solidPixelFrame(width: 256, height: 256,
                                        b: 0x40, g: 0xC0, r: 0x80)
        let encoder = try HapYEncoder(width: 256, height: 256, fps: 30, destURL: tmp)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()

        let data = try Data(contentsOf: tmp)
        XCTAssertGreaterThan(data.count, 100)

        let tree = AtomTree(data: data, range: 0..<data.count)
        guard let stsd = findAtom(tree.children, path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"]) else {
            return XCTFail("stsd not found")
        }
        XCTAssertNotNil(stsd.children.first(where: { $0.type == "HapY" }),
                        "HapY sample entry missing from stsd")

        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)
        let header = try parseHAPSectionHeader(packet: firstSample)
        XCTAssertEqual(header.sectionType, 0xBF,
                       "section type must be 0xBF (Snappy + ScaledYCoCgDXT5)")
        XCTAssertGreaterThan(header.payloadLength, 0)
        XCTAssertEqual(header.payloadOffset, 4)
    }

    /// Format-compliance gate: encode → parse → Snappy-decompress →
    /// the resulting BC3 stream must agree with what HapYEncoder
    /// produced internally for the same input frame. We re-derive
    /// the reference BC3 by encoding through a parallel HapYEncoder
    /// instance and reading back the BC3 from the output file —
    /// this catches Snappy / section-header round-trip bugs.
    func testHapYRoundTripBytesEqualSnappyDecompression() throws {
        let tmp1 = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapy-rt1-\(UUID().uuidString).mov")
        let tmp2 = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapy-rt2-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: tmp1)
            try? FileManager.default.removeItem(at: tmp2)
        }

        let frame = try solidPixelFrame(width: 128, height: 128,
                                        b: 0x80, g: 0x40, r: 0xC0)

        // Encode twice to two files to confirm the encoder is
        // deterministic + the on-disk round-trip is stable.
        for url in [tmp1, tmp2] {
            let e = try HapYEncoder(width: 128, height: 128, fps: 30, destURL: url)
            try e.append(frame: frame, presentationTime: .zero)
            try e.finish()
        }

        let bc31 = try extractAndDecompressFirstSample(url: tmp1)
        let bc32 = try extractAndDecompressFirstSample(url: tmp2)
        XCTAssertEqual(bc31, bc32, "HapY encoder must be deterministic")

        // BC3 size sanity: 128/4 × 128/4 = 1024 blocks × 16 B = 16384 B.
        XCTAssertEqual(bc31.count, 16384,
                       "BC3 stream size should be (codedW/4)*(codedH/4)*16")
    }

    func testHapYMultiFrameSequence() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapy-multi-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let w = 128, h = 128
        let encoder = try HapYEncoder(width: w, height: h, fps: 30, destURL: tmp)
        for i in 0..<30 {
            let frame = try solidPixelFrame(
                width: w, height: h,
                b: UInt8(i * 8), g: UInt8(255 - i * 8),
                r: UInt8((i * 17) & 0xFF))
            try encoder.append(frame: frame,
                               presentationTime: CMTime(value: CMTimeValue(i),
                                                        timescale: 30))
        }
        try encoder.finish()

        let data = try Data(contentsOf: tmp)
        let tree = AtomTree(data: data, range: 0..<data.count)
        guard let stsz = findAtom(tree.children, path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]) else {
            return XCTFail("stsz not found")
        }
        let body = stsz.bodyRange
        let countOffset = body.lowerBound + 8
        let sampleCount = readBE32(data, at: countOffset)
        XCTAssertEqual(sampleCount, 30, "stsz should record 30 samples")
        XCTAssertLessThan(data.count, 480_000,
                          "30 solid-color HapY frames compress well below uncompressed BC3")
    }

    /// Visual round-trip + PSNR gate. Encode a chroma gradient through
    /// HapY, decode the BC3 stream via GlanceCore's CPURender (which
    /// returns raw RGBA bytes from the BC3 unpack), apply the HapY
    /// inverse formula per pixel, and compare RGB to the source.
    ///
    /// HapY is lossy (DXT5 quantization + per-block scale snapping),
    /// but on smooth gradients PSNR > 30 dB is reasonable. Threshold
    /// set conservatively at 28 dB to leave headroom for the bottom-
    /// right grey gradient (which exercises the s=4 path with
    /// sub-LSB Co/Cg precision).
    func testHapYVisualRoundTripPSNR() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapy-psnr-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let w = 64, h = 64
        let frame = try chromaGradientFrame(width: w, height: h)

        let encoder = try HapYEncoder(width: w, height: h, fps: 30, destURL: tmp)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()

        let bc3 = try extractAndDecompressFirstSample(url: tmp)

        // Decode BC3 → intermediate RGBA via GlanceCore's CPURender.
        // The result is the (Co_scaled+128, Cg_scaled+128, scale_byte,
        // Y) per-pixel buffer at coded dims.
        let cgImage = try CPURender.cgImageFromDXT(
            dxtBytes: bc3, variant: .dxt5,
            width: w, height: h)
        guard let provider = cgImage.dataProvider,
              let cfData = provider.data,
              CFDataGetLength(cfData) >= w * h * 4 else {
            return XCTFail("CPURender unavailable / wrong size")
        }
        let intermediate = [UInt8](
            UnsafeBufferPointer(start: CFDataGetBytePtr(cfData),
                                count: w * h * 4))

        // Reconstruct RGB per pixel via the HapY inverse formula.
        let reconstructed = invertHapY(intermediate: intermediate,
                                       width: w, height: h)

        // Source RGB from the source frame's BGRA bytes.
        let srcBGRA = frame.bgraBytes()
        let psnr = computeRGBPSNR(srcBGRA: srcBGRA,
                                  decodedRGB: reconstructed,
                                  width: w, height: h)
        XCTAssertGreaterThan(psnr, 28.0,
                             "HapY visual round-trip should clear 28 dB PSNR " +
                             "on a smooth chroma gradient (got \(psnr) dB)")
    }

    // MARK: - HapY inverse + PSNR (private helpers)

    /// Apply the HapY inverse formula to reconstruct per-pixel RGB
    /// (uint8) from the BC3-decoded intermediate RGBA buffer.
    /// Mirrors GlanceCore.HAPHQDecoder.unpackHapYToRGB byte-for-byte
    /// (Phase 6.b, not in v0.5.0).
    private func invertHapY(intermediate: [UInt8], width: Int, height: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: width * height * 3)
        for i in 0..<(width * height) {
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

            let dstOff = i * 3
            out[dstOff    ] = byteClamp(r * 255.0)
            out[dstOff + 1] = byteClamp(g * 255.0)
            out[dstOff + 2] = byteClamp(b * 255.0)
        }
        return out
    }

    private func byteClamp(_ v: Double) -> UInt8 {
        if v <= 0 { return 0 }
        if v >= 255 { return 255 }
        return UInt8(v.rounded())
    }

    /// Mean-squared-error PSNR over the RGB channels of two
    /// equal-size images. `srcBGRA` is BGRA8 (PixelFrame bytes);
    /// `decodedRGB` is packed RGB8. Returns ∞ for byte-equal inputs.
    private func computeRGBPSNR(srcBGRA: Data, decodedRGB: [UInt8],
                                width: Int, height: Int) -> Double {
        var sumSq: Double = 0
        let pixelCount = width * height
        srcBGRA.withUnsafeBytes { srcRaw in
            let src = srcRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for i in 0..<pixelCount {
                let bgraOff = i * 4
                let rgbOff = i * 3
                let sR = Int(src[bgraOff + 2])  // BGRA: R at byte 2
                let sG = Int(src[bgraOff + 1])
                let sB = Int(src[bgraOff    ])
                let dR = Int(decodedRGB[rgbOff    ])
                let dG = Int(decodedRGB[rgbOff + 1])
                let dB = Int(decodedRGB[rgbOff + 2])
                let drR = sR - dR
                let drG = sG - dG
                let drB = sB - dB
                sumSq += Double(drR * drR + drG * drG + drB * drB)
            }
        }
        let mse = sumSq / Double(pixelCount * 3)
        if mse <= 0 { return .infinity }
        return 10.0 * log10(255.0 * 255.0 / mse)
    }

    // MARK: - Extraction + parsing helpers (mirror Hap1/Hap5)

    private func extractAndDecompressFirstSample(url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        let tree = AtomTree(data: data, range: 0..<data.count)
        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)
        let header = try parseHAPSectionHeader(packet: firstSample)
        let snappyPayload = firstSample.subdata(
            in: header.payloadOffset..<(header.payloadOffset + header.payloadLength))
        return try snappyPayload.uncompressedUsingSnappy()
    }

    struct LocalSectionHeader {
        let sectionType: UInt8
        let payloadOffset: Int
        let payloadLength: Int
    }

    enum LocalParseError: Error { case malformed(String) }

    private func parseHAPSectionHeader(packet: Data) throws -> LocalSectionHeader {
        guard packet.count >= 4 else {
            throw LocalParseError.malformed("packet < 4 bytes")
        }
        let base = packet.startIndex
        let b0 = UInt32(packet[base])
        let b1 = UInt32(packet[base + 1])
        let b2 = UInt32(packet[base + 2])
        let type = packet[base + 3]
        let lengthShort = b0 | (b1 << 8) | (b2 << 16)
        if lengthShort == 0 {
            guard packet.count >= 8 else {
                throw LocalParseError.malformed("extended header < 8 bytes")
            }
            let l0 = UInt32(packet[base + 4])
            let l1 = UInt32(packet[base + 5])
            let l2 = UInt32(packet[base + 6])
            let l3 = UInt32(packet[base + 7])
            let lengthLong = l0 | (l1 << 8) | (l2 << 16) | (l3 << 24)
            return LocalSectionHeader(sectionType: type, payloadOffset: 8,
                                      payloadLength: Int(lengthLong))
        }
        return LocalSectionHeader(sectionType: type, payloadOffset: 4,
                                  payloadLength: Int(lengthShort))
    }

    private func findAtom(_ children: [AtomNode], path: [String]) -> AtomNode? {
        var current = children
        var found: AtomNode?
        for type in path {
            guard let node = current.first(where: { $0.type == type }) else { return nil }
            found = node
            current = node.children
        }
        return found
    }

    private func extractFirstSampleBytes(data: Data, tree: AtomTree) throws -> Data {
        guard let stsz = findAtom(tree.children,
                                  path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]),
              let stco = findAtom(tree.children,
                                  path: ["moov", "trak", "mdia", "minf", "stbl", "stco"]) else {
            throw NSError(domain: "HapYTest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "stsz/stco missing"])
        }
        let stszBody = stsz.bodyRange
        let firstSampleSize = Int(readBE32(data, at: stszBody.lowerBound + 12))
        let stcoBody = stco.bodyRange
        let firstSampleOffset = Int(readBE32(data, at: stcoBody.lowerBound + 8))
        return data.subdata(in: firstSampleOffset..<(firstSampleOffset + firstSampleSize))
    }

    private func readBE32(_ data: Data, at index: Int) -> UInt32 {
        let b0 = UInt32(data[index])
        let b1 = UInt32(data[index + 1])
        let b2 = UInt32(data[index + 2])
        let b3 = UInt32(data[index + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}

// MARK: - Atom tree (local copy)

private struct AtomNode {
    let type: String
    let range: Range<Int>
    let bodyRange: Range<Int>
    let children: [AtomNode]
}

private struct AtomTree {
    let data: Data
    let children: [AtomNode]

    init(data: Data, range: Range<Int>) {
        self.data = data
        self.children = AtomTree.parse(data: data, range: range)
    }

    private static func parse(data: Data, range: Range<Int>) -> [AtomNode] {
        var out: [AtomNode] = []
        var p = range.lowerBound
        while p + 8 <= range.upperBound {
            let sz32 = Int(readBE32(data, at: p))
            let typeStr = String(bytes: data[(p+4)..<(p+8)], encoding: .isoLatin1) ?? "????"
            let bodyStart: Int
            let atomEnd: Int
            if sz32 == 0 {
                bodyStart = p + 8
                atomEnd = range.upperBound
            } else if sz32 == 1 {
                let large = Int(readBE64(data, at: p + 8))
                bodyStart = p + 16
                atomEnd = p + large
            } else {
                bodyStart = p + 8
                atomEnd = p + sz32
            }
            let kids: [AtomNode]
            if isContainerAtomType(typeStr) {
                kids = AtomTree.parse(data: data, range: bodyStart..<atomEnd)
            } else if typeStr == "stsd" {
                let inner = bodyStart + 8
                kids = AtomTree.parse(data: data, range: inner..<atomEnd)
            } else {
                kids = []
            }
            out.append(AtomNode(type: typeStr,
                                range: p..<atomEnd,
                                bodyRange: bodyStart..<atomEnd,
                                children: kids))
            p = atomEnd
            if sz32 == 0 { break }
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
        for i in 0..<8 {
            v = (v << 8) | UInt64(data[index + i])
        }
        return v
    }

    private static func isContainerAtomType(_ type: String) -> Bool {
        switch type {
        case "moov", "trak", "mdia", "minf", "stbl", "dinf", "edts", "udta":
            return true
        default:
            return false
        }
    }
}
