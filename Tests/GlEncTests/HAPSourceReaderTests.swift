/*
 * Encode-from-HAP — HAPSourceReader.
 *
 *   - dispatch: a HAP url selects HAPSourceReader; non-HAP is unaffected.
 *   - round-trip (opaque): HapM → DXT5 through the real pipeline; output
 *     demuxes at the right count/dims and decodes via GlanceCore; the HAP
 *     source's frameRate flows through.
 *   - ALPHA survival: transparent Hap5 → DXT5; the output's decoded alpha
 *     is non-trivial AND tracks the source alpha within BC4 tolerance —
 *     the gap the diagnosis could not close (all prior fixtures opaque).
 */
import XCTest
import AVFoundation
import CoreGraphics
@testable import GlEncCore
import GlanceCore

final class HAPSourceReaderTests: XCTestCase {

    private func ref(_ sub: String, _ name: String) -> URL {
        URL(fileURLWithPath: #file).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("reference").appendingPathComponent(sub).appendingPathComponent(name)
    }
    private func tmp(_ tag: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("glenc-hapsrc-\(tag)-\(UUID().uuidString).mov")
    }

    /// Decode every pixel's alpha (RGBA straight) from a HAP frame 0.
    private func hapSourceAlpha(_ url: URL) throws -> [UInt8] {
        let idx = try HAPDemuxer.demux(url: url)
        let (rgba, w, h) = try HAPThumbnail.rgbaOfFrame(at: 0, in: idx, url: url)
        var a = [UInt8](); a.reserveCapacity(w * h)
        var i = 3; while i < rgba.count { a.append(rgba[i]); i += 4 }
        return a
    }

    /// Decode frame 0 of a DXT5 DXV output to RGBA, return the alpha plane.
    private func dxt5OutputAlpha(_ url: URL) throws -> (alpha: [UInt8], w: Int, h: Int) {
        let idx = try DXVDemuxer.demux(url: url)
        let fh = try FileHandle(forReadingFrom: url); defer { try? fh.close() }
        try fh.seek(toOffset: idx.frames[0].fileOffset)
        let packet = try fh.read(upToCount: Int(idx.frames[0].size)) ?? Data()
        let (_, payload) = try DXVPacketDecoder.parseHeader(packet)
        let paddedW = (idx.width + 15) / 16 * 16
        let blocks = (paddedW / 4) * (idx.height / 4)
        let bc3 = try DXVPacketDecoder.decompressDXT5(payload, expectedSize: blocks * 16)
        let cg = try CPURender.cgImageFromDXT(dxtBytes: bc3, variant: .dxt5, width: idx.width, height: idx.height)
        guard let data = cg.dataProvider?.data as Data? else { throw NSError(domain: "t", code: 1) }
        var a = [UInt8](); a.reserveCapacity(idx.width * idx.height)
        var i = 3; while i < data.count { a.append(data[i]); i += 4 }
        return (a, idx.width, idx.height)
    }

    private func encodeToDXT5(_ src: URL, _ out: URL) async throws {
        let pipeline = EncodePipeline(
            sourceURL: src, encoder: DXT5Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(destURL: out, format: .dxt5, presentationWidth: w, presentationHeight: h, fps: fps, codecFourCC: "DXD3")
            },
            sourceAlphaInfo: .last)
        try await pipeline.run()
    }

    // MARK: - Dispatch

    func testDispatch_HAPSourceSelectsHAPSourceReader() async throws {
        let src = ref("hap-source", "opaque_hapm.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path), "missing fixture")
        let reader = try await makeSourceReader(for: src, sourceAlphaInfo: .last)
        XCTAssertTrue(reader is HAPSourceReader, "HAP source must select HAPSourceReader")
        XCTAssertGreaterThan(reader.totalFrameCount, 0)
        XCTAssertEqual(reader.sourceWidth, 512)
        XCTAssertEqual(reader.sourceHeight, 288)
    }

    // MARK: - Round-trip (opaque HapM → DXT5)

    func testRoundTrip_HapM_ToDXT5() async throws {
        let src = ref("hap-source", "opaque_hapm.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path), "missing fixture")
        let out = tmp("hapm-dxt5"); defer { try? FileManager.default.removeItem(at: out) }
        try await encodeToDXT5(src, out)
        let idx = try DXVDemuxer.demux(url: out)
        XCTAssertEqual(idx.variant, .dxt5)
        XCTAssertEqual(idx.frames.count, 6)
        XCTAssertEqual(idx.width, 512); XCTAssertEqual(idx.height, 288)
        XCTAssertEqual(idx.frameRate, 30.0, accuracy: 0.5, "HAP source frameRate must flow through")
        // Round-trip integrity: frame 0 decodes.
        _ = try dxt5OutputAlpha(out)
    }

    // MARK: - Alpha survival (transparent Hap5 → DXT5)

    func testAlphaSurvival_TransparentHap5_ToDXT5() async throws {
        let src = ref("hap-source", "transparent_hap5.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path), "missing transparent fixture")
        let out = tmp("hap5-dxt5"); defer { try? FileManager.default.removeItem(at: out) }

        let srcAlpha = try hapSourceAlpha(src)
        let srcMin = srcAlpha.min() ?? 255
        // Sanity: the fixture genuinely carries transparency.
        XCTAssertLessThan(srcMin, 200, "fixture must have real transparency (srcMin=\(srcMin))")

        try await encodeToDXT5(src, out)
        let (outAlpha, _, _) = try dxt5OutputAlpha(out)
        XCTAssertEqual(outAlpha.count, srcAlpha.count)

        // 1) Output alpha is non-trivial — transparency survived the encode.
        let outMin = outAlpha.min() ?? 255
        XCTAssertLessThan(outMin, 200, "encoded DXT5 alpha must retain transparency (outMin=\(outMin))")

        // 2) Output alpha tracks the source within BC4 (8-level) tolerance.
        var total: Int64 = 0
        for i in 0..<outAlpha.count { total += Int64(abs(Int(outAlpha[i]) - Int(srcAlpha[i]))) }
        let mean = Double(total) / Double(outAlpha.count)
        FileHandle.standardError.write(Data("[hap-alpha-test] srcMin=\(srcMin) outMin=\(outMin) meanAbsDelta=\(mean)\n".utf8))
        XCTAssertLessThan(mean, 24.0, "DXT5 alpha mean |Δ| from source \(mean) exceeds BC4 tolerance")
    }
}
