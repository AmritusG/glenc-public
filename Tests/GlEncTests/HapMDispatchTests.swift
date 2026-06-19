/*
 * HapMDispatchTests — v0.9.3 Phase C.
 *
 * Proves the HapM wiring lands the right encoder, the right MOV
 * codec FourCC, and a structurally valid HapM frame on disk. Encoder
 * correctness (PSNR / alpha Δ) is already covered by
 * HapMEncoderTests; this file is the dispatch-only gate.
 *
 * The end-to-end test drives a single encode through HapFrameEncoder
 * (the same Codec-parameterized type EncodeQueue dispatches through
 * — see `EncodeQueue.encodeOne` switch around line 417) plus
 * VariantMOVWriter with `codecFourCC: format.streamFourCC`. This
 * reaches the exact code path the GUI uses, just with the queue
 * abstraction removed so the test is deterministic and synchronous.
 */

import XCTest
import Foundation
import CoreMedia
import CoreVideo
import CoreGraphics
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class HapMDispatchTests: XCTestCase {

    // MARK: - HapFrameEncoder.Codec.hapM exists + dispatches

    /// HapFrameEncoder constructed with `.hapM`, prepared at 256×256,
    /// produces a single packet per frame whose outer section type is
    /// 0x0D. This is the same encoder EncodeQueue.encodeOne hands to
    /// EncodePipeline for `.hapM` jobs.
    func testHapFrameEncoderDispatchesHapM() throws {
        let w = 256, h = 256
        let encoder = HapFrameEncoder(codec: .hapM)
        try encoder.prepare(width: w, height: h, fps: 30, hasAlpha: true)

        let frame = try makeFrame(width: w, height: h) { _, y in
            y < h / 2 ? 0xFF : 0x00
        }
        let packet = try encoder.encode(frame: frame)

        // Outer must be 0x0D, derived from the HapM spec (HAPM_PLAN.md
        // §1.2 — outer wrapper carries section type 0x0D, NOT a
        // single-section type byte like the four leaf HAP variants).
        let outer = try parseHAPSectionHeader(packet: packet)
        XCTAssertEqual(outer.sectionType, 0x0D,
                       "HapFrameEncoder(.hapM) must emit an outer 0x0D section")

        // First inner must be HapY single-Snappy (0xBF) per Q1 + Q2.
        // Q2: HapY first.
        let outerPayload = packet.subdata(
            in: outer.payloadOffset..<(outer.payloadOffset + outer.payloadLength))
        let inner0 = try parseHAPSectionHeader(packet: outerPayload)
        XCTAssertEqual(inner0.sectionType, 0xBF,
                       "inner #0 must be HapY single-Snappy (0xBF) — Q1 + Q2")

        // Second inner must be HapA single-Snappy (0xB1).
        let inner1Start = inner0.payloadOffset + inner0.payloadLength
        let inner1Region = outerPayload.subdata(
            in: inner1Start..<outerPayload.count)
        let inner1 = try parseHAPSectionHeader(packet: inner1Region)
        XCTAssertEqual(inner1.sectionType, 0xB1,
                       "inner #1 must be HapA single-Snappy (0xB1)")
    }

    /// Q3 — HapFrameEncoder(.hapM) does NOT reject opaque sources.
    /// `.hapA` rejects (alpha-only standalone is meaningless without
    /// signal); HapM emits an opaque alpha section. The Phase C dispatch
    /// path inherits this Q3 behavior from the encoder.
    func testHapMDispatchAcceptsOpaqueSource() throws {
        let w = 64, h = 64
        let encoder = HapFrameEncoder(codec: .hapM)
        try encoder.prepare(width: w, height: h, fps: 30, hasAlpha: true)

        // Opaque source: alpha info indicates no alpha, but HapM
        // encodes regardless (HapABlockPacker handles the
        // force-opaque case via AlphaNormalization).
        let opaque = try makeFrame(width: w, height: h,
                                   alphaInfo: .noneSkipLast) { _, _ in 0xFF }
        let packet = try encoder.encode(frame: opaque)
        let outer = try parseHAPSectionHeader(packet: packet)
        XCTAssertEqual(outer.sectionType, 0x0D,
                       "opaque source must still produce a HapM outer 0x0D — Q3")
    }

    // MARK: - End-to-end through the pipeline + writer factory

    /// Drives an encode through the same seam EncodeQueue uses —
    /// HapFrameEncoder + VariantMOVWriter via the writer factory
    /// pattern. Asserts the output file is structurally a valid HapM
    /// (stsd FourCC "HapM", outer 0x0D, HapY-kind first, HapA-kind
    /// second). Reuses an inline section parser — same pattern
    /// HapMEncoderTests + HapAEncoderTests use; tests stay
    /// GlanceCore v0.5.0-pinned.
    func testEndToEnd_DispatchProducesValidHapM() throws {
        let w = 256, h = 256
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-hapm-dispatch-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Mirror EncodeQueue's runOneJob path: HapFrameEncoder +
        // VariantMOVWriter, codecFourCC from DXVFormat.hapM.streamFourCC.
        let encoder = HapFrameEncoder(codec: .hapM)
        try encoder.prepare(width: w, height: h, fps: 30, hasAlpha: true)
        let writer = try VariantMOVWriter(
            destURL: tmp,
            format: .hapM,  // v0.9.3 Phase C
            presentationWidth: w,
            presentationHeight: h,
            fps: 30,
            codecFourCC: DXVFormat.hapM.streamFourCC)

        // One frame is enough to prove the wiring; encoder-correctness
        // PSNR is covered by HapMEncoderTests.
        let frame = try makeFrame(width: w, height: h) { _, y in
            y < h / 2 ? 0xFF : 0x00
        }
        let packet = try encoder.encode(frame: frame)
        try writer.append(packet: packet, presentationTime: .zero)
        try encoder.finish()
        try writer.finish()

        // The output file's stsd must declare FourCC "HapM" — proves
        // VariantMOVWriter routed the FourCC end-to-end via the
        // codecFourCC parameter only (Q7: no writer-side branching).
        let data = try Data(contentsOf: tmp)
        XCTAssertGreaterThan(data.count, 100, "HapM dispatch file empty")
        let tree = AtomTree(data: data, range: 0..<data.count)
        guard let stsd = findAtom(tree.children,
                                  path: ["moov", "trak", "mdia", "minf", "stbl", "stsd"]) else {
            return XCTFail("stsd not found in dispatch output")
        }
        XCTAssertNotNil(stsd.children.first(where: { $0.type == "HapM" }),
                        "stsd FourCC must be HapM — got \(stsd.children.map { $0.type })")

        // First sample structural check — outer 0x0D, inner #0 0xBF,
        // inner #1 0xB1. This proves the encoder dispatched to the
        // HapM composition, not to .hapY or .hapA singly.
        let firstSample = try extractFirstSampleBytes(data: data, tree: tree)
        let outer = try parseHAPSectionHeader(packet: firstSample)
        XCTAssertEqual(outer.sectionType, 0x0D,
                       "dispatch output's first frame must have outer 0x0D")
        let outerPayload = firstSample.subdata(
            in: outer.payloadOffset..<(outer.payloadOffset + outer.payloadLength))
        let inner0 = try parseHAPSectionHeader(packet: outerPayload)
        XCTAssertEqual(inner0.sectionType, 0xBF,
                       "dispatch output inner #0 must be HapY-kind (0xBF)")
        let inner1Region = outerPayload.subdata(
            in: (inner0.payloadOffset + inner0.payloadLength)..<outerPayload.count)
        let inner1 = try parseHAPSectionHeader(packet: inner1Region)
        XCTAssertEqual(inner1.sectionType, 0xB1,
                       "dispatch output inner #1 must be HapA-kind (0xB1)")
    }

    /// EncodeQueue's snapshot.format → encoder switch (see
    /// EncodeQueue.swift around line 417) must route `.hapM` to a
    /// HapFrameEncoder(.hapM). This is the user-facing entry point;
    /// the test invokes the same construction.
    func testEncodeQueueDispatchSlotsHapM() throws {
        // Directly invoke the dispatch we'd hit for a real .hapM job
        // — there's no public injection point for the switch itself,
        // so this is a structural-equivalence test: build the same
        // encoder that the switch would build and confirm it works.
        let encoder = HapFrameEncoder(codec: .hapM)
        XCTAssertEqual(encoder.codec, .hapM,
                       "constructed encoder must report .hapM as its codec")
        // The streamFourCC string the writer factory uses.
        XCTAssertEqual(DXVFormat.hapM.streamFourCC, "HapM",
                       "DXVFormat.hapM.streamFourCC must be the writer's input")
    }

    // MARK: - Helpers (inline section parser; mirrors HapMEncoderTests)

    private func makeFrame(
        width: Int, height: Int,
        alphaInfo: CGImageAlphaInfo = .last,
        alphaFn: (Int, Int) -> UInt8
    ) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "HapMDispatchTest", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        let base = CVPixelBufferGetBaseAddress(buf)!.assumingMemoryBound(to: UInt8.self)
        let bpr = CVPixelBufferGetBytesPerRow(buf)
        for y in 0..<height {
            let row = base.advanced(by: y * bpr)
            for x in 0..<width {
                let p = row.advanced(by: x * 4)
                p[0] = UInt8((x &+ y) & 0xFF)
                p[1] = UInt8(((x &* 2) &+ y) & 0xFF)
                p[2] = UInt8((x &+ (y &* 2)) & 0xFF)
                p[3] = alphaFn(x, y)
            }
        }
        return PixelFrame(pixelBuffer: buf, presentationTime: .zero,
                          alphaInfo: alphaInfo)
    }

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
            throw NSError(domain: "HapMDispatchTest", code: 1)
        }
        let stszBody = stsz.bodyRange
        let constSize = readBE32(data, at: stszBody.lowerBound + 4)
        let firstSampleSize: Int
        if constSize != 0 {
            firstSampleSize = Int(constSize)
        } else {
            firstSampleSize = Int(readBE32(data, at: stszBody.lowerBound + 12))
        }
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

// MARK: - Atom tree (private to this file; same shape as HapMEncoderTests)

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
