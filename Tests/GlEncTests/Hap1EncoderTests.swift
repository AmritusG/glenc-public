/*
 * Hap1EncoderTests — v0.9.1 Phase D.
 *
 * Validates the Hap1 end-to-end encoder.
 *
 * Format-compliance oracle: section headers are parsed by an in-test
 * `parseHAPSectionHeader` that mirrors GlanceCore's
 * `HAPPacketDecoder.parseSectionHeader` (byte arithmetic — trivial
 * to replicate). Snappy decompression goes through the same
 * `lovetodream/swift-snappy` package GlanceCore uses for HAP decode,
 * so the round-trip oracle is byte-identical to what a real
 * GlanceCore decoder would produce.
 *
 * Why not use GlanceCore.HAPPacketDecoder directly: GlEnc is pinned
 * to Glance v0.5.0 which predates the HAP decoder landing. The
 * "GlanceCore: pinned at v0.5.0" invariant has held since Phase B;
 * bumping the pin for test scaffolding would couple the encoder
 * timeline to upstream releases. Local section parsing keeps the
 * tests self-contained.
 */

import XCTest
import Foundation
import CoreMedia
import CoreVideo
@testable import GlEncCore
import Snappy

@MainActor
final class Hap1EncoderTests: XCTestCase {

    // MARK: - Synthesis helpers

    /// Build a CVPixelBuffer of `width × height` filled with the
    /// given BGRA tuple. Solid-color frames compress aggressively
    /// (BC1 collapses to a single endpoint + 0-bit index per block)
    /// and round-trip losslessly within DXT1's representational gap.
    private func solidPixelFrame(
        width: Int, height: Int,
        b: UInt8, g: UInt8, r: UInt8, a: UInt8 = 0xFF
    ) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "Hap1Test", code: Int(status),
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

    // MARK: - Tests

    /// Encode a single 256×256 solid-red frame; verify the output file
    /// has the Hap1 FourCC in stsd and the per-frame section header is
    /// a valid 0xBB (Snappy + DXT1) short-form section.
    func testSingleFrameHap1Encode() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hap1-single-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let frame = try solidPixelFrame(width: 256, height: 256,
                                        b: 0x00, g: 0x00, r: 0xFF)
        let encoder = try Hap1Encoder(width: 256, height: 256, fps: 30, destURL: tmp)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()

        let data = try Data(contentsOf: tmp)
        XCTAssertGreaterThan(data.count, 100, "Hap1 file should have non-trivial size")

        // stsd carries "Hap1" sample entry.
        let tree = AtomTree(data: data, range: 0..<data.count)
        guard let stsd = findAtom(tree.children, path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"]) else {
            return XCTFail("stsd not found")
        }
        XCTAssertNotNil(stsd.children.first(where: { $0.type == "Hap1" }),
                        "Hap1 sample entry missing from stsd")

        // Parse the first frame's section header via the in-test
        // parser (mirrors GlanceCore's HAPPacketDecoder.parseSectionHeader).
        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)
        let header = try parseHAPSectionHeader(packet: firstSample)
        XCTAssertEqual(header.sectionType, 0xBB,
                       "section type must be 0xBB (Snappy + DXT1)")
        XCTAssertGreaterThan(header.payloadLength, 0)
        XCTAssertEqual(header.payloadOffset, 4,
                       "single-frame 256x256 Snappy payload should fit short form (< 16 MB)")
    }

    /// The format-compliance test. Encode a frame, parse the section
    /// header, Snappy-decompress the payload, and assert the result
    /// byte-equals what DXT1Encoder.encodeBlocks produced for the
    /// same input. This closes the encoder loop end-to-end through
    /// the same Snappy decompressor GlanceCore's HAP decoder uses.
    func testHap1RoundTripVsDecoder() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hap1-rt-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // 128×128 single frame — small enough for a fast test.
        let frame = try solidPixelFrame(width: 128, height: 128,
                                        b: 0x80, g: 0x40, r: 0xC0)
        // Re-encode independently via DXT1Encoder to get the
        // reference DXT1 byte stream.
        let refEncoder = DXT1Encoder()
        try refEncoder.prepare(width: 128, height: 128, fps: 30, hasAlpha: false)
        let referenceDXT1 = try refEncoder.encodeBlocks(frame: frame)

        // Encode via Hap1Encoder and read the file back.
        let encoder = try Hap1Encoder(width: 128, height: 128, fps: 30, destURL: tmp)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()

        let data = try Data(contentsOf: tmp)
        let tree = AtomTree(data: data, range: 0..<data.count)
        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)

        // Parse section, Snappy-decompress the payload, assert the
        // decoded DXT1 byte stream equals the reference.
        let header = try parseHAPSectionHeader(packet: firstSample)
        XCTAssertEqual(header.sectionType, 0xBB)
        let snappyPayload = firstSample.subdata(
            in: header.payloadOffset..<(header.payloadOffset + header.payloadLength))
        let decodedDXT1 = try snappyPayload.uncompressedUsingSnappy()
        XCTAssertEqual(decodedDXT1, referenceDXT1,
                       "DXT1 stream after Snappy round-trip must equal what DXT1Encoder produced")
    }

    /// Encode 30 frames of varying content. Verifies the writer
    /// records 30 samples and that the file size is in a sane
    /// ballpark (much smaller than 30× uncompressed DXT1 frames).
    func testHap1MultiFrameSequence() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hap1-multi-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let w = 128, h = 128
        let encoder = try Hap1Encoder(width: w, height: h, fps: 30, destURL: tmp)
        for i in 0..<30 {
            // Vary the color per frame so Snappy doesn't get to
            // dedupe the entire 30-frame stream — exercises real
            // multi-sample mdat layout.
            let frame = try solidPixelFrame(
                width: w, height: h,
                b: UInt8(i * 8), g: UInt8(255 - i * 8), r: UInt8((i * 17) & 0xFF))
            try encoder.append(frame: frame,
                               presentationTime: CMTime(value: CMTimeValue(i),
                                                        timescale: 30))
        }
        try encoder.finish()

        let data = try Data(contentsOf: tmp)
        // stsz sample_count must equal 30. stsz body is
        // [4 v+f][4 sample_size_constant][4 sample_count][N × 4 sample_size].
        let tree = AtomTree(data: data, range: 0..<data.count)
        guard let stsz = findAtom(tree.children, path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]) else {
            return XCTFail("stsz not found")
        }
        let body = stsz.bodyRange
        let countOffset = body.lowerBound + 8  // skip v+f + sample_size
        let sampleCount = readBE32(data, at: countOffset)
        XCTAssertEqual(sampleCount, 30, "stsz should record 30 samples")

        // Sanity on size: uncompressed DXT1 for 128×128 is
        // (128/4)² × 8 = 8192 B per frame; 30 frames = ~240 KB.
        // Snappy-compressed solid-color frames should be far less.
        XCTAssertLessThan(data.count, 240_000,
                          "30 frames of solid color should compress well below uncompressed size")
        XCTAssertGreaterThan(data.count, 500,
                             "30-frame file should still have meaningful atom overhead")
    }

    /// Section header sanity at the source: directly invoke
    /// `Hap1Encoder.makeHap1SnappySection` and round-trip through
    /// the in-test parser. Catches header-emit bugs without the
    /// full encoder pipeline.
    func testSectionHeaderShortAndExtendedForms() throws {
        // Short form: small payload.
        let small = Data(repeating: 0x42, count: 100)
        let smallSection = try Hap1Encoder.makeHap1SnappySection(payload: small)
        XCTAssertEqual(smallSection.count, 4 + 100)
        let smallHeader = try parseHAPSectionHeader(packet: smallSection)
        XCTAssertEqual(smallHeader.sectionType, 0xBB)
        XCTAssertEqual(smallHeader.payloadOffset, 4)
        XCTAssertEqual(smallHeader.payloadLength, 100)

        // Extended form: payload ≥ 16 MB. Exact-boundary test
        // (1 << 24) — first size requiring the extended header.
        let big = Data(repeating: 0x55, count: 1 << 24)
        let bigSection = try Hap1Encoder.makeHap1SnappySection(payload: big)
        XCTAssertEqual(bigSection.count, 8 + big.count)
        let bigHeader = try parseHAPSectionHeader(packet: bigSection)
        XCTAssertEqual(bigHeader.sectionType, 0xBB)
        XCTAssertEqual(bigHeader.payloadOffset, 8,
                       "extended form payload should start at offset 8")
        XCTAssertEqual(bigHeader.payloadLength, big.count)
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

    // MARK: - Atom-walking helpers (local copy — DXVMOVWriterTests' AtomTree is private)

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

    /// Locate sample 1's bytes in the mdat. stco[0] gives the file
    /// offset (we use stco32 — this writer is 32-bit only). stsz[0]
    /// gives the size. The bytes between are the Hap1 section.
    private func extractFirstSampleBytes(data: Data, tree: AtomTree) throws -> Data {
        guard let stsz = findAtom(tree.children,
                                  path: ["moov", "trak", "mdia", "minf", "stbl", "stsz"]),
              let stco = findAtom(tree.children,
                                  path: ["moov", "trak", "mdia", "minf", "stbl", "stco"]) else {
            throw NSError(domain: "Hap1Test", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "stsz/stco missing"])
        }
        // stsz body: [4 v+f][4 default_size][4 count][N × 4 size].
        // When default_size is 0, the per-sample sizes follow.
        let stszBody = stsz.bodyRange
        let firstSampleSize = Int(readBE32(data, at: stszBody.lowerBound + 12))
        // stco body: [4 v+f][4 count][N × 4 offset].
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

// MARK: - Atom tree (local copy, mirrors DXVMOVWriterTests' private AtomTree)

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
