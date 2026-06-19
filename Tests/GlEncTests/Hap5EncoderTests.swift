/*
 * Hap5EncoderTests — v0.9.1 Phase E.
 *
 * Validates the Hap5 end-to-end encoder.
 *
 * Mirrors Phase D's Hap1 test structure. Section-header parsing
 * uses an in-test `parseHAPSectionHeader` that mirrors GlanceCore's
 * `HAPPacketDecoder.parseSectionHeader`. Snappy decompression goes
 * through `lovetodream/swift-snappy`, the same package GlanceCore
 * uses for HAP decode — round-trip is byte-identical to what a real
 * GlanceCore decoder would produce.
 *
 * GlEnc remains pinned to Glance v0.5.0 (predates HAP decoder
 * landing); local parsing avoids coupling encoder development to
 * upstream releases.
 */

import XCTest
import Foundation
import CoreMedia
import CoreVideo
@testable import GlEncCore
import Snappy

@MainActor
final class Hap5EncoderTests: XCTestCase {

    // MARK: - Synthesis helpers

    /// Build a CVPixelBuffer of `width × height` filled with the
    /// given BGRA tuple. Default alpha is opaque.
    private func solidPixelFrame(
        width: Int, height: Int,
        b: UInt8, g: UInt8, r: UInt8, a: UInt8 = 0xFF
    ) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "Hap5Test", code: Int(status),
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

    /// Build a CVPixelBuffer with the top `height/2` rows opaque and
    /// the bottom `height/2` rows fully transparent. Color is mid-grey
    /// everywhere so the alpha distinction is the only signal. Used to
    /// verify that DXT5's BC4 alpha plane survives Snappy round-trip.
    private func halfAlphaPixelFrame(width: Int, height: Int) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "Hap5Test", code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "CVPixelBufferCreate failed"])
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            let row = base.advanced(by: y * bpr)
            let alpha: UInt8 = (y < height / 2) ? 0xFF : 0x00
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                p[0] = 0x80; p[1] = 0x80; p[2] = 0x80; p[3] = alpha
            }
        }
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero)
    }

    // MARK: - Tests

    /// Encode a single 256×256 solid frame; verify the file has the
    /// Hap5 FourCC in stsd and a valid 0xBE (Snappy + DXT5) section
    /// header.
    func testSingleFrameHap5Encode() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hap5-single-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let frame = try solidPixelFrame(width: 256, height: 256,
                                        b: 0x00, g: 0x80, r: 0x40, a: 0xC0)
        let encoder = try Hap5Encoder(width: 256, height: 256, fps: 30, destURL: tmp)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()

        let data = try Data(contentsOf: tmp)
        XCTAssertGreaterThan(data.count, 100, "Hap5 file should have non-trivial size")

        // stsd carries "Hap5" sample entry.
        let tree = AtomTree(data: data, range: 0..<data.count)
        guard let stsd = findAtom(tree.children, path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"]) else {
            return XCTFail("stsd not found")
        }
        XCTAssertNotNil(stsd.children.first(where: { $0.type == "Hap5" }),
                        "Hap5 sample entry missing from stsd")

        // Parse the first frame's section header.
        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)
        let header = try parseHAPSectionHeader(packet: firstSample)
        XCTAssertEqual(header.sectionType, 0xBE,
                       "section type must be 0xBE (Snappy + DXT5)")
        XCTAssertGreaterThan(header.payloadLength, 0)
        XCTAssertEqual(header.payloadOffset, 4,
                       "single-frame 256x256 Snappy payload should fit short form (< 16 MB)")
    }

    /// Format-compliance gate. Encode a frame, parse the section,
    /// Snappy-decompress, and assert the result byte-equals what
    /// DXT5Encoder.encodeBlocks produced for the same input. Closes
    /// the encoder loop end-to-end through the same Snappy
    /// decompressor GlanceCore's HAP decoder uses.
    func testHap5RoundTripVsDecoder() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hap5-rt-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let frame = try solidPixelFrame(width: 128, height: 128,
                                        b: 0x80, g: 0x40, r: 0xC0, a: 0xA0)
        // Re-encode independently via DXT5Encoder to get the
        // reference BC3 byte stream.
        let refEncoder = DXT5Encoder()
        try refEncoder.prepare(width: 128, height: 128, fps: 30, hasAlpha: true)
        let referenceDXT5 = try refEncoder.encodeBlocks(frame: frame)

        // Encode via Hap5Encoder.
        let encoder = try Hap5Encoder(width: 128, height: 128, fps: 30, destURL: tmp)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()

        let data = try Data(contentsOf: tmp)
        let tree = AtomTree(data: data, range: 0..<data.count)
        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)

        let header = try parseHAPSectionHeader(packet: firstSample)
        XCTAssertEqual(header.sectionType, 0xBE)
        let snappyPayload = firstSample.subdata(
            in: header.payloadOffset..<(header.payloadOffset + header.payloadLength))
        let decodedDXT5 = try snappyPayload.uncompressedUsingSnappy()
        XCTAssertEqual(decodedDXT5, referenceDXT5,
                       "BC3 stream after Snappy round-trip must equal DXT5Encoder reference")
    }

    /// Encode 30 frames of varying content. Verifies the writer
    /// records 30 samples and that the file size is in a sane
    /// ballpark.
    func testHap5MultiFrameSequence() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hap5-multi-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let w = 128, h = 128
        let encoder = try Hap5Encoder(width: w, height: h, fps: 30, destURL: tmp)
        for i in 0..<30 {
            let frame = try solidPixelFrame(
                width: w, height: h,
                b: UInt8(i * 8), g: UInt8(255 - i * 8),
                r: UInt8((i * 17) & 0xFF), a: UInt8(0x80 + (i * 3) & 0x7F))
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

        // Uncompressed BC3 for 128×128 is (128/4)² × 16 = 16 KB per
        // frame; 30 frames = ~480 KB. Snappy-compressed solid frames
        // should be well below that.
        XCTAssertLessThan(data.count, 480_000,
                          "30 frames of solid color should compress below uncompressed BC3 size")
        XCTAssertGreaterThan(data.count, 500,
                             "30-frame file should still have meaningful atom overhead")
    }

    /// Alpha-preservation: feed a frame with top half α=255 and
    /// bottom half α=0, encode through Hap5, decompress, and walk
    /// the BC3 block stream. BC3 layout per 4×4 tile is:
    ///
    ///     bytes 0..7   BC4 alpha block:
    ///                  byte 0 = alpha0 endpoint (8-bit)
    ///                  byte 1 = alpha1 endpoint (8-bit)
    ///                  bytes 2..7 = 16 × 3-bit indices
    ///     bytes 8..15  BC1 color block (8-bit endpoints + 2-bit indices)
    ///
    /// For tiles in fully-opaque rows we expect both endpoints near
    /// 0xFF; for fully-transparent rows we expect both endpoints near
    /// 0x00. We assert qualitatively (≥ 0xF0 / ≤ 0x10) — BC4 is
    /// lossy but a uniform tile produces near-exact endpoints.
    func testHap5AlphaPreservedRoundTrip() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hap5-alpha-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let w = 64, h = 64  // multiple of 16 so coded = presentation
        let frame = try halfAlphaPixelFrame(width: w, height: h)

        let encoder = try Hap5Encoder(width: w, height: h, fps: 30, destURL: tmp)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()

        let data = try Data(contentsOf: tmp)
        let tree = AtomTree(data: data, range: 0..<data.count)
        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)
        let header = try parseHAPSectionHeader(packet: firstSample)
        XCTAssertEqual(header.sectionType, 0xBE)
        let snappyPayload = firstSample.subdata(
            in: header.payloadOffset..<(header.payloadOffset + header.payloadLength))
        let bc3Stream = try snappyPayload.uncompressedUsingSnappy()

        // Walk blocks. wBlocks × hBlocks = 16 × 16 for 64×64. The
        // alpha boundary is at block-row 8 (pixel row 32).
        let wBlocks = w / 4
        let hBlocks = h / 4
        XCTAssertEqual(bc3Stream.count, wBlocks * hBlocks * 16,
                       "BC3 stream size should be \(wBlocks * hBlocks * 16) bytes")

        let blockRowSplit = hBlocks / 2  // 8
        for by in 0..<hBlocks {
            for bx in 0..<wBlocks {
                let blockOffset = (by * wBlocks + bx) * 16
                let alpha0 = bc3Stream[blockOffset + 0]
                let alpha1 = bc3Stream[blockOffset + 1]
                if by < blockRowSplit {
                    // Opaque rows: both endpoints near 0xFF.
                    XCTAssertGreaterThanOrEqual(alpha0, 0xF0,
                        "block (\(bx),\(by)) opaque row: alpha0=\(alpha0)")
                    XCTAssertGreaterThanOrEqual(alpha1, 0xF0,
                        "block (\(bx),\(by)) opaque row: alpha1=\(alpha1)")
                } else {
                    // Transparent rows: both endpoints near 0x00.
                    XCTAssertLessThanOrEqual(alpha0, 0x10,
                        "block (\(bx),\(by)) transparent row: alpha0=\(alpha0)")
                    XCTAssertLessThanOrEqual(alpha1, 0x10,
                        "block (\(bx),\(by)) transparent row: alpha1=\(alpha1)")
                }
            }
        }
    }

    // MARK: - Local HAP section header parser
    //
    // Mirrors GlanceCore's HAPPacketDecoder.parseSectionHeader byte-
    // for-byte. Inlined so the tests don't require the un-released
    // GlanceCore HAP decoder.

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

    // MARK: - Atom-walking helpers

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
            throw NSError(domain: "Hap5Test", code: 1,
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
