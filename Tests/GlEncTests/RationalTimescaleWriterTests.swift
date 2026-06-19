/*
 * #14 part 2 — rational-timescale writer (NTSC snap).
 *
 * VariantMOVWriter now emits genuine 29.97 (30000/1001) and 23.976
 * (24000/1001) via the standard NTSC media timescale, while the integer
 * path stays byte-identical (proved by the 8 named byte tests, not here).
 *
 *   - deriveTimescale unit checks: integer → (N×512, 512); NTSC →
 *     (N×1000, 1001); near-miss (29.5) throws.
 *   - Round-trip: encode the committed NTSC H.264 fixtures → DXV, demux
 *     back at ~29.97 / ~23.976, assert the emitted (timescale, delta),
 *     and decode frame 0 through GlanceCore (round-trip integrity).
 *
 * These are round-trip / convention tests, NOT structural-diff — the
 * vs_ffmpeg/vs_alley references are 30fps integer and a non-integer clip
 * can't use them.
 */
import XCTest
import AVFoundation
@testable import GlEncCore
import GlanceCore

final class RationalTimescaleWriterTests: XCTestCase {

    // MARK: - deriveTimescale unit checks

    func testDeriveTimescale_Integer30() throws {
        let (ts, d) = try VariantMOVWriter.deriveTimescale(fps: 30.0)
        XCTAssertEqual(ts, 15360); XCTAssertEqual(d, 512)
    }

    func testDeriveTimescale_2997() throws {
        let (ts, d) = try VariantMOVWriter.deriveTimescale(fps: Double(30000) / Double(1001))
        XCTAssertEqual(ts, 30000); XCTAssertEqual(d, 1001)
    }

    func testDeriveTimescale_23976() throws {
        let (ts, d) = try VariantMOVWriter.deriveTimescale(fps: Double(24000) / Double(1001))
        XCTAssertEqual(ts, 24000); XCTAssertEqual(d, 1001)
    }

    func testDeriveTimescale_NearMiss295_Throws() {
        XCTAssertThrowsError(try VariantMOVWriter.deriveTimescale(fps: 29.5)) { err in
            guard case VariantMOVWriter.WriterError.nonIntegerFPS = err else {
                return XCTFail("expected nonIntegerFPS for 29.5, got \(err)")
            }
        }
    }

    // MARK: - Pipeline round-trips

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference").appendingPathComponent("fps")
            .appendingPathComponent(name)
    }

    /// Read mdhd timescale + stts sample_delta out of a written MOV.
    private func readMediaTiming(_ url: URL) throws -> (timescale: UInt32, delta: UInt32) {
        let d = try Data(contentsOf: url)
        func be32(_ o: Int) -> UInt32 {
            (UInt32(d[o]) << 24) | (UInt32(d[o+1]) << 16) | (UInt32(d[o+2]) << 8) | UInt32(d[o+3])
        }
        func find(_ tag: String) -> Int? {
            let t = Array(tag.utf8)
            for i in 0..<(d.count - 4) where Array(d[i..<i+4]) == t { return i }
            return nil
        }
        guard let m = find("mdhd"), let s = find("stts") else {
            throw NSError(domain: "test", code: 1)
        }
        return (be32(m + 4 + 12), be32(s + 4 + 12))
    }

    private func roundTrip(fixture: String, expectedRate: Double,
                           expectedTimescale: UInt32, expectedDelta: UInt32,
                           expectedFrames: Int) async throws {
        let src = fixtureURL(fixture)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "missing reference/fps/\(fixture)")
        let out = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-p2-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: out) }

        let pipeline = EncodePipeline(
            sourceURL: src,
            encoder: DXT1Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(destURL: out, format: .dxt1,
                                 presentationWidth: w, presentationHeight: h,
                                 fps: fps, codecFourCC: "DXD3")
            },
            sourceAlphaInfo: .last)
        try await pipeline.run()   // NTSC branch — must not throw

        // Emitted NTSC convention (the ecosystem-correctness assertion).
        let timing = try readMediaTiming(out)
        XCTAssertEqual(timing.timescale, expectedTimescale, "mdhd timescale")
        XCTAssertEqual(timing.delta, expectedDelta, "stts sample_delta")

        // Round-trip via GlEnc's own demuxer.
        let idx = try DXVDemuxer.demux(url: out)
        XCTAssertEqual(idx.frameRate, expectedRate, accuracy: 1e-3)
        XCTAssertEqual(idx.frames.count, expectedFrames)

        // Decode frame 0 through GlanceCore (round-trip integrity).
        let fh = try FileHandle(forReadingFrom: out)
        defer { try? fh.close() }
        let f0 = idx.frames[0]
        try fh.seek(toOffset: f0.fileOffset)
        let packet = try fh.read(upToCount: Int(f0.size)) ?? Data()
        let (_, payload) = try DXVPacketDecoder.parseHeader(packet)
        let paddedW = (idx.width + 15) / 16 * 16
        let blocks = (paddedW / 4) * (idx.height / 4)
        let bc1 = try DXVPacketDecoder.decompressDXT1(payload, expectedSize: blocks * 8)
        let cg = try CPURender.cgImageFromDXT(dxtBytes: bc1, variant: .dxt1,
                                              width: idx.width, height: idx.height)
        XCTAssertEqual(cg.width, idx.width)
        XCTAssertEqual(cg.height, idx.height)
    }

    func testRoundTrip_2997_H264_ToDXV() async throws {
        try await roundTrip(fixture: "ntsc2997_h264.mp4",
                            expectedRate: 30000.0 / 1001.0,
                            expectedTimescale: 30000, expectedDelta: 1001,
                            expectedFrames: 60)
    }

    func testRoundTrip_23976_H264_ToDXV() async throws {
        try await roundTrip(fixture: "ntsc23976_h264.mp4",
                            expectedRate: 24000.0 / 1001.0,
                            expectedTimescale: 24000, expectedDelta: 1001,
                            expectedFrames: 48)
    }
}
