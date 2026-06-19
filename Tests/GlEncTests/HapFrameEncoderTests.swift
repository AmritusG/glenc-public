/*
 * HapFrameEncoderTests — v0.9.1 Phase G.
 *
 * The `HapFrameEncoder` is the pipeline-driven encoder used by
 * `EncodeQueue` for HAP jobs. Tests here confirm that its per-frame
 * output (section header + Snappy-compressed BC stream) matches what
 * the standalone Hap1/Hap5/HapY encoders write to disk, byte-exactly
 * — i.e. the two code paths produce identical sample bytes for the
 * same input.
 *
 * If this test passes, EncodeQueue's HAP jobs land samples that are
 * indistinguishable from running the standalone HapXEncoder
 * convenience APIs.
 */

import XCTest
import Foundation
import CoreMedia
import CoreVideo
@testable import GlEncCore
import Snappy

@MainActor
final class HapFrameEncoderTests: XCTestCase {

    private func solidPixelFrame(
        width: Int, height: Int,
        b: UInt8, g: UInt8, r: UInt8, a: UInt8 = 0xFF
    ) throws -> PixelFrame {
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil, width, height,
            kCVPixelFormatType_32BGRA, nil, &pb)
        guard status == kCVReturnSuccess, let buf = pb else {
            throw NSError(domain: "HapFETest", code: Int(status))
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

    /// HapFrameEncoder(.hap1).encode(frame) should byte-equal the
    /// first sample of an Hap1Encoder-written .mov for the same
    /// input. Same proof for Hap5 and HapY in their respective
    /// tests below.
    func testHap1MatchesConvenienceEncoder() throws {
        let frame = try solidPixelFrame(width: 128, height: 128,
                                        b: 0x10, g: 0x80, r: 0xC0)

        // Pipeline path: HapFrameEncoder.encode → section packet.
        let pipelineEnc = HapFrameEncoder(codec: .hap1)
        try pipelineEnc.prepare(width: 128, height: 128, fps: 30, hasAlpha: false)
        let pipelinePacket = try pipelineEnc.encode(frame: frame)

        // Convenience path: Hap1Encoder writes to disk; extract the
        // first sample bytes.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hapfetest-hap1-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let convEnc = try Hap1Encoder(width: 128, height: 128, fps: 30, destURL: tmp)
        try convEnc.append(frame: frame, presentationTime: .zero)
        try convEnc.finish()
        let convSample = try firstSampleBytes(url: tmp)

        XCTAssertEqual(pipelinePacket, convSample,
                       "Hap1: pipeline vs convenience must agree byte-for-byte")
    }

    func testHap5MatchesConvenienceEncoder() throws {
        let frame = try solidPixelFrame(width: 128, height: 128,
                                        b: 0x80, g: 0x40, r: 0xC0, a: 0xA0)

        let pipelineEnc = HapFrameEncoder(codec: .hap5)
        try pipelineEnc.prepare(width: 128, height: 128, fps: 30, hasAlpha: true)
        let pipelinePacket = try pipelineEnc.encode(frame: frame)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hapfetest-hap5-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let convEnc = try Hap5Encoder(width: 128, height: 128, fps: 30, destURL: tmp)
        try convEnc.append(frame: frame, presentationTime: .zero)
        try convEnc.finish()
        let convSample = try firstSampleBytes(url: tmp)

        XCTAssertEqual(pipelinePacket, convSample,
                       "Hap5: pipeline vs convenience must agree byte-for-byte")
    }

    func testHapYMatchesConvenienceEncoder() throws {
        let frame = try solidPixelFrame(width: 128, height: 128,
                                        b: 0x40, g: 0x80, r: 0xC0)

        let pipelineEnc = HapFrameEncoder(codec: .hapY)
        try pipelineEnc.prepare(width: 128, height: 128, fps: 30, hasAlpha: false)
        let pipelinePacket = try pipelineEnc.encode(frame: frame)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hapfetest-hapy-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let convEnc = try HapYEncoder(width: 128, height: 128, fps: 30, destURL: tmp)
        try convEnc.append(frame: frame, presentationTime: .zero)
        try convEnc.finish()
        let convSample = try firstSampleBytes(url: tmp)

        XCTAssertEqual(pipelinePacket, convSample,
                       "HapY: pipeline vs convenience must agree byte-for-byte")
    }

    /// Section-type bytes per codec — sanity that HapFrameEncoder
    /// emits the right HAP variant.
    func testSectionTypePerCodec() throws {
        let frame = try solidPixelFrame(width: 64, height: 64,
                                        b: 0x00, g: 0xFF, r: 0x00)
        let pairs: [(HapFrameEncoder.Codec, UInt8)] = [
            (.hap1, 0xBB),
            (.hap5, 0xBE),
            (.hapY, 0xBF),
        ]
        for (codec, expectedType) in pairs {
            let e = HapFrameEncoder(codec: codec)
            try e.prepare(width: 64, height: 64, fps: 30,
                          hasAlpha: codec == .hap5)
            let packet = try e.encode(frame: frame)
            XCTAssertGreaterThanOrEqual(packet.count, 4)
            XCTAssertEqual(packet[3], expectedType,
                           "codec \(codec) section type")
        }
    }

    // MARK: - Helpers

    /// Walk the MOV atoms and pull bytes for sample 1 (size from
    /// stsz, file offset from stco). Local copy of Hap*EncoderTests'
    /// helper; tight scope so we don't pull AtomTree across files.
    private func firstSampleBytes(url: URL) throws -> Data {
        let data = try Data(contentsOf: url)
        // Walk top-level atoms to find moov.
        guard let moovRange = findAtomRange(in: data, type: "moov") else {
            throw NSError(domain: "HapFETest", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "moov not found"])
        }
        // moov is a container; recurse into it.
        guard let stsz = nestedAtom(in: data, outer: moovRange,
                                    path: ["trak", "mdia", "minf", "stbl", "stsz"]),
              let stco = nestedAtom(in: data, outer: moovRange,
                                    path: ["trak", "mdia", "minf", "stbl", "stco"]) else {
            throw NSError(domain: "HapFETest", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "stsz/stco not found"])
        }
        // stsz body: [4 v+f][4 default_size][4 count][N × 4 size].
        let stszBodyStart = stsz.lowerBound + 8
        let firstSampleSize = Int(readBE32(data, at: stszBodyStart + 12))
        // stco body: [4 v+f][4 count][N × 4 offset].
        let stcoBodyStart = stco.lowerBound + 8
        let firstSampleOffset = Int(readBE32(data, at: stcoBodyStart + 8))
        return data.subdata(in: firstSampleOffset..<(firstSampleOffset + firstSampleSize))
    }

    private func findAtomRange(in data: Data, type: String) -> Range<Int>? {
        var p = data.startIndex
        while p + 8 <= data.endIndex {
            let sz = Int(readBE32(data, at: p))
            let t = String(bytes: data[(p+4)..<(p+8)], encoding: .isoLatin1) ?? "????"
            if t == type {
                return p..<(p + sz)
            }
            if sz <= 0 { break }
            p += sz
        }
        return nil
    }

    /// Walk a sequence of container atoms inside `outer` (which
    /// includes its 8-byte header) and return the range of the
    /// deepest atom in the path.
    private func nestedAtom(in data: Data, outer: Range<Int>,
                            path: [String]) -> Range<Int>? {
        // Outer's body starts at outer.lowerBound + 8.
        var cursor = outer.lowerBound + 8
        let end = outer.upperBound
        for type in path {
            var found: Range<Int>?
            var p = cursor
            while p + 8 <= end {
                let sz = Int(readBE32(data, at: p))
                let t = String(bytes: data[(p+4)..<(p+8)], encoding: .isoLatin1) ?? "????"
                if t == type {
                    found = p..<(p + sz)
                    break
                }
                if sz <= 0 { break }
                p += sz
            }
            guard let f = found else { return nil }
            cursor = f.lowerBound + 8
            // If we just found the leaf, return its full range.
            if type == path.last {
                return f
            }
        }
        return nil
    }

    private func readBE32(_ data: Data, at index: Int) -> UInt32 {
        let b0 = UInt32(data[index])
        let b1 = UInt32(data[index + 1])
        let b2 = UInt32(data[index + 2])
        let b3 = UInt32(data[index + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }
}
