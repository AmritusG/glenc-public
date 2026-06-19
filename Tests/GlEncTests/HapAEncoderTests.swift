/*
 * HapAEncoderTests — v0.9.2 Phase C.
 *
 * Validates HapAEncoder end-to-end: stsd "HapA" FourCC, section type
 * 0xB1 short-form, Snappy + BC4 round-trip vs HapABlockPacker
 * reference, multi-frame sequence, opaque-source reject (Q2), visual
 * PSNR via inline BC4 decoder, plus a HapFrameEncoder dispatch check.
 *
 * Mirrors the Hap1/Hap5/HapY encoder test set. Inline section parser
 * + BC4 decoder follow v0.9.1's self-contained pattern (no GlanceCore
 * post-v0.5.0 dependencies).
 */

import XCTest
import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
@testable import GlEncCore
import Snappy

@MainActor
final class HapAEncoderTests: XCTestCase {

    // MARK: - Synthesis

    /// Build a BGRA PixelFrame with per-pixel alpha given by
    /// `alphaFn(x, y)`. RGB is constant mid-grey; alphaInfo defaults
    /// to `.last` (straight alpha) so HapA's preflight accepts.
    private func framePerPixelAlpha(
        width: Int, height: Int,
        alphaInfo: CGImageAlphaInfo = .last,
        alphaFn: (Int, Int) -> UInt8
    ) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "HapATest", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            let row = base.advanced(by: y * bpr)
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                p[0] = 0x80; p[1] = 0x80; p[2] = 0x80
                p[3] = alphaFn(x, y)
            }
        }
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero,
                          alphaInfo: alphaInfo)
    }

    private func halfAlphaFrame(width: Int, height: Int) throws -> PixelFrame {
        try framePerPixelAlpha(width: width, height: height) { _, y in
            y < height / 2 ? 0xFF : 0x00
        }
    }

    // MARK: - 5.1 single-frame encode

    func testSingleFrameHapAEncode() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapa-single-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let frame = try halfAlphaFrame(width: 256, height: 256)
        let encoder = try HapAEncoder(width: 256, height: 256, fps: 30, destURL: tmp)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()

        let data = try Data(contentsOf: tmp)
        XCTAssertGreaterThan(data.count, 100, "HapA file should have non-trivial size")

        let tree = AtomTree(data: data, range: 0..<data.count)
        guard let stsd = findAtom(tree.children, path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"]) else {
            return XCTFail("stsd not found")
        }
        XCTAssertNotNil(stsd.children.first(where: { $0.type == "HapA" }),
                        "HapA sample entry missing from stsd")

        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)
        let header = try parseHAPSectionHeader(packet: firstSample)
        XCTAssertEqual(header.sectionType, 0xB1,
                       "section type must be 0xB1 (Snappy + RGTC1)")
        XCTAssertGreaterThan(header.payloadLength, 0)
        XCTAssertEqual(header.payloadOffset, 4,
                       "single-frame 256x256 Snappy payload should fit short form (< 16 MB)")
    }

    // MARK: - 5.2 round-trip vs HapABlockPacker reference

    func testHapARoundTripVsDecoder() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapa-rt-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let frame = try halfAlphaFrame(width: 128, height: 128)
        // Reference BC4 stream from the packer directly.
        let refPacker = HapABlockPacker()
        refPacker.prepare(width: 128, height: 128)
        let referenceBC4 = try refPacker.packBlocks(frame: frame)

        // Encode via HapAEncoder, read back, decompress.
        let encoder = try HapAEncoder(width: 128, height: 128, fps: 30, destURL: tmp)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()

        let data = try Data(contentsOf: tmp)
        let tree = AtomTree(data: data, range: 0..<data.count)
        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)
        let header = try parseHAPSectionHeader(packet: firstSample)
        XCTAssertEqual(header.sectionType, 0xB1)
        let snappyPayload = firstSample.subdata(
            in: header.payloadOffset..<(header.payloadOffset + header.payloadLength))
        let decodedBC4 = try snappyPayload.uncompressedUsingSnappy()

        XCTAssertEqual(decodedBC4, referenceBC4,
                       "BC4 stream after Snappy round-trip must equal HapABlockPacker reference")
    }

    // MARK: - 5.3 multi-frame sequence

    func testHapAMultiFrameSequence() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapa-multi-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let w = 128, h = 128
        let encoder = try HapAEncoder(width: w, height: h, fps: 30, destURL: tmp)
        for i in 0..<30 {
            // Alpha varies per frame; even-y rows opaque, odd transparent
            // in early frames, shifting phase as i advances.
            let frame = try framePerPixelAlpha(width: w, height: h) { _, y in
                ((y + i) % 8) < 4 ? 0xFF : 0x00
            }
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
        // BC4 1080p frame is 128/4 × 128/4 × 8 = 8192 B uncompressed;
        // 30 frames = 240 KB. Snappy on alternating-row pattern should
        // compress aggressively.
        XCTAssertLessThan(data.count, 240_000,
                          "30 frames of alternating-row alpha should compress below uncompressed BC4")
    }

    // MARK: - 5.4 opaque-source reject (Q2)

    func testHapAOpaqueSourceRejected_NoneSkipLast() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapa-reject-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let frame = try framePerPixelAlpha(width: 64, height: 64,
                                           alphaInfo: .noneSkipLast) { _, _ in 0xFF }
        let encoder = try HapAEncoder(width: 64, height: 64, fps: 30, destURL: tmp)
        XCTAssertThrowsError(try encoder.append(frame: frame, presentationTime: .zero)) { e in
            guard case HapAEncoderError.sourceHasNoAlpha = e else {
                XCTFail("expected HapAEncoderError.sourceHasNoAlpha, got \(e)")
                return
            }
        }
        try? encoder.finish()
    }

    func testHapAOpaqueSourceRejected_None() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapa-reject2-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let frame = try framePerPixelAlpha(width: 64, height: 64,
                                           alphaInfo: .none) { _, _ in 0xFF }
        let encoder = try HapAEncoder(width: 64, height: 64, fps: 30, destURL: tmp)
        XCTAssertThrowsError(try encoder.append(frame: frame, presentationTime: .zero)) { e in
            guard case HapAEncoderError.sourceHasNoAlpha = e else {
                XCTFail("expected HapAEncoderError.sourceHasNoAlpha, got \(e)")
                return
            }
        }
        try? encoder.finish()
    }

    // MARK: - 5.5 visual round-trip / PSNR

    /// Encode a smooth vertical alpha gradient, decode the BC4 stream
    /// back, compute alpha PSNR. BC4 on a smooth 4-pixel-aligned
    /// gradient typically clears 40 dB; this gate sits at 38 dB to
    /// leave headroom for snappy-induced corner cases.
    func testHapAVisualRoundTrip() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapa-psnr-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let w = 64, h = 64
        let frame = try framePerPixelAlpha(width: w, height: h) { _, y in
            UInt8((y * 4) & 0xFF)
        }
        let encoder = try HapAEncoder(width: w, height: h, fps: 30, destURL: tmp)
        try encoder.append(frame: frame, presentationTime: .zero)
        try encoder.finish()

        let data = try Data(contentsOf: tmp)
        let tree = AtomTree(data: data, range: 0..<data.count)
        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)
        let header = try parseHAPSectionHeader(packet: firstSample)
        let snappyPayload = firstSample.subdata(
            in: header.payloadOffset..<(header.payloadOffset + header.payloadLength))
        let bc4 = try snappyPayload.uncompressedUsingSnappy()

        let alphaOut = unpackBC4Plane(blocks: bc4, width: w, height: h)
        var sumSq: Double = 0
        for y in 0..<h {
            for x in 0..<w {
                let src = Int(UInt8((y * 4) & 0xFF))
                let dec = Int(alphaOut[y * w + x])
                let d = src - dec
                sumSq += Double(d * d)
            }
        }
        let mse = sumSq / Double(w * h)
        let psnr = mse <= 0 ? .infinity : 10.0 * log10(255.0 * 255.0 / mse)
        XCTAssertGreaterThan(psnr, 38.0,
                             "HapA visual round-trip PSNR \(psnr) below 38 dB")
    }

    // MARK: - 5.6 HapFrameEncoder dispatch

    func testHapFrameEncoderDispatchToHapA() throws {
        let frame = try halfAlphaFrame(width: 64, height: 64)
        let e = HapFrameEncoder(codec: .hapA)
        try e.prepare(width: 64, height: 64, fps: 30, hasAlpha: true)
        let packet = try e.encode(frame: frame)
        XCTAssertGreaterThanOrEqual(packet.count, 4)
        XCTAssertEqual(packet[3], 0xB1,
                       "HapFrameEncoder(.hapA) must emit section type 0xB1")
    }

    /// Pipeline-vs-convenience byte equality for HapA — same gate
    /// HapFrameEncoderTests covers for Hap1/Hap5/HapY.
    func testHapFrameEncoderMatchesHapAEncoder() throws {
        let w = 128, h = 128
        let frame = try halfAlphaFrame(width: w, height: h)

        let pipeline = HapFrameEncoder(codec: .hapA)
        try pipeline.prepare(width: w, height: h, fps: 30, hasAlpha: true)
        let pipelinePacket = try pipeline.encode(frame: frame)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hapa-pipe-vs-conv-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let conv = try HapAEncoder(width: w, height: h, fps: 30, destURL: tmp)
        try conv.append(frame: frame, presentationTime: .zero)
        try conv.finish()

        let data = try Data(contentsOf: tmp)
        let tree = AtomTree(data: data, range: 0..<data.count)
        let convSample = try extractFirstSampleBytes(data: data, tree: tree)

        XCTAssertEqual(pipelinePacket, convSample,
                       "HapA pipeline vs convenience must agree byte-for-byte")
    }

    /// HapFrameEncoder's .hapA path also enforces the Q2 reject.
    func testHapFrameEncoderRejectsOpaqueSource() throws {
        let frame = try framePerPixelAlpha(width: 64, height: 64,
                                           alphaInfo: .noneSkipLast) { _, _ in 0xFF }
        let e = HapFrameEncoder(codec: .hapA)
        try e.prepare(width: 64, height: 64, fps: 30, hasAlpha: true)
        XCTAssertThrowsError(try e.encode(frame: frame)) { err in
            guard case HapAEncoderError.sourceHasNoAlpha = err else {
                XCTFail("expected sourceHasNoAlpha, got \(err)")
                return
            }
        }
    }

    // MARK: - Inline section parser

    struct LocalSectionHeader {
        let sectionType: UInt8
        let payloadOffset: Int
        let payloadLength: Int
    }
    enum LocalParseError: Error { case malformed(String) }

    private func parseHAPSectionHeader(packet: Data) throws -> LocalSectionHeader {
        guard packet.count >= 4 else { throw LocalParseError.malformed("packet < 4 bytes") }
        let base = packet.startIndex
        let b0 = UInt32(packet[base])
        let b1 = UInt32(packet[base + 1])
        let b2 = UInt32(packet[base + 2])
        let type = packet[base + 3]
        let lengthShort = b0 | (b1 << 8) | (b2 << 16)
        if lengthShort == 0 {
            guard packet.count >= 8 else { throw LocalParseError.malformed("extended header < 8 B") }
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

    // MARK: - Inline BC4 decoder (mirrors Phase B's HapABlockPackerTests)

    private func unpackBC4Plane(blocks: Data, width: Int, height: Int) -> [UInt8] {
        precondition(width % 4 == 0 && height % 4 == 0)
        let wBlocks = width / 4
        let hBlocks = height / 4
        var out = [UInt8](repeating: 0, count: width * height)
        for by in 0..<hBlocks {
            for bx in 0..<wBlocks {
                let blockOff = (by * wBlocks + bx) * 8
                let a0 = blocks[blockOff]
                let a1 = blocks[blockOff + 1]
                let palette = bc4Palette(a0: a0, a1: a1)
                var indices: UInt64 = 0
                for k in 0..<6 {
                    indices |= UInt64(blocks[blockOff + 2 + k]) << (k * 8)
                }
                for py in 0..<4 {
                    for px in 0..<4 {
                        let bitOff = (py * 4 + px) * 3
                        let idx = Int((indices >> bitOff) & 0x07)
                        out[(by * 4 + py) * width + (bx * 4 + px)] = palette[idx]
                    }
                }
            }
        }
        return out
    }

    private func bc4Palette(a0: UInt8, a1: UInt8) -> [UInt8] {
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
        return pal
    }

    // MARK: - Atom helpers

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
            throw NSError(domain: "HapATest", code: 1)
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
        for i in 0..<8 { v = (v << 8) | UInt64(data[index + i]) }
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
