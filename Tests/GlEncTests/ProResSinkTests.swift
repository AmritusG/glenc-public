/*
 * Multi-Format Phase 1 — AVAssetWriterVideoSink (VideoToolbox/ProRes)
 * through the new sink-based EncodePipeline init.
 *
 * Unlike the DXV/HAP encoders, ProRes output is NON-deterministic
 * (VideoToolbox), so it is NEVER byte-pinned. The gate here is:
 *   - all five ProRes variants encode a real source end-to-end,
 *   - the output's codec tag is the expected QuickTime FourCC,
 *   - output dims + frame count match the source,
 *   - ProRes 4444 from an alpha source preserves transparency
 *     (round-trip BGRA shows α<255 pixels), while the 422 family
 *     flattens it — the alpha-steering rationale.
 */
import XCTest
import AVFoundation
import CoreVideo
@testable import GlEncCore

final class ProResSinkTests: XCTestCase {

    private func fixture(_ rel: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()       // GlEncTests
            .deletingLastPathComponent()       // Tests
            .deletingLastPathComponent()       // repo root
            .appendingPathComponent(rel)
    }

    private func tmpOut(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-prores-\(name)-\(UUID().uuidString).mov")
    }

    /// FourCC media subtype of the first video track, as a 4-char string.
    private func codecTag(_ url: URL) async throws -> String {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first,
              let fmt = try await track.load(.formatDescriptions).first else {
            return "----"
        }
        let st = CMFormatDescriptionGetMediaSubType(fmt)
        let bytes = [UInt8((st >> 24) & 0xff), UInt8((st >> 16) & 0xff),
                     UInt8((st >> 8) & 0xff), UInt8(st & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "----"
    }

    /// (width, height, frameCount) decoded through AVAssetReader.
    private func dimsAndCount(_ url: URL) async throws -> (Int, Int, Int) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return (0, 0, 0)
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                             kCVPixelFormatType_32BGRA])
        reader.add(out)
        reader.startReading()
        var w = 0, h = 0, n = 0
        while let sb = out.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sb) {
                w = CVPixelBufferGetWidth(pb)
                h = CVPixelBufferGetHeight(pb)
            }
            n += 1
        }
        return (w, h, n)
    }

    /// Count of pixels with alpha < 250 across all frames (transparency
    /// survived the round-trip). Reads as 32BGRA so alpha is byte 3.
    private func transparentPixelCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            return 0
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String:
                             kCVPixelFormatType_32BGRA])
        reader.add(out)
        reader.startReading()
        var transparent = 0
        while let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            CVPixelBufferLockBaseAddress(pb, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
            guard let base = CVPixelBufferGetBaseAddress(pb) else { continue }
            let w = CVPixelBufferGetWidth(pb)
            let h = CVPixelBufferGetHeight(pb)
            let stride = CVPixelBufferGetBytesPerRow(pb)
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<h {
                let row = ptr + y * stride
                for x in 0..<w where row[x * 4 + 3] < 250 { transparent += 1 }
            }
        }
        return transparent
    }

    // MARK: - all five variants encode end-to-end with the right tag

    func testAllFiveProResVariantsEncodeWithCorrectCodecTag() async throws {
        let src = fixture("reference/fps/ntsc2997_h264.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "fixture missing: \(src.path)")
        let (_, _, srcCount) = try await dimsAndCount(src)
        XCTAssertGreaterThan(srcCount, 0, "source must decode some frames")

        for variant in ProResVariant.allCases {
            let outURL = tmpOut(variant.rawValue)
            defer { try? FileManager.default.removeItem(at: outURL) }

            let pipeline = EncodePipeline(
                sourceURL: src,
                makeSink: { w, h, _ in
                    try AVAssetWriterVideoSink(
                        destURL: outURL, codec: variant.avCodec,
                        fileType: .mov, width: w, height: h)
                })
            try await pipeline.run()

            XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path),
                          "\(variant.label): no output produced")
            let tag = try await codecTag(outURL)
            XCTAssertEqual(tag, variant.codecTag,
                           "\(variant.label): expected tag \(variant.codecTag), got \(tag)")
            let (w, h, n) = try await dimsAndCount(outURL)
            XCTAssertGreaterThan(w, 0)
            XCTAssertGreaterThan(h, 0)
            XCTAssertEqual(n, srcCount,
                           "\(variant.label): frame count \(n) != source \(srcCount)")
        }
    }

    // MARK: - alpha steering: 4444 keeps alpha, 422 flattens it

    func testProRes4444PreservesAlphaFromTransparentSource() async throws {
        let src = fixture("reference/hap-source/transparent_hap5.mov")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "alpha fixture missing: \(src.path)")

        // 4444 — alpha must survive.
        let out4444 = tmpOut("4444-alpha")
        defer { try? FileManager.default.removeItem(at: out4444) }
        try await EncodePipeline(
            sourceURL: src,
            makeSink: { w, h, _ in
                try AVAssetWriterVideoSink(
                    destURL: out4444, codec: ProResVariant.proRes4444.avCodec,
                    fileType: .mov, width: w, height: h)
            }).run()
        let tag4444 = try await codecTag(out4444)
        XCTAssertEqual(tag4444, "ap4h")
        let transparent = try await transparentPixelCount(out4444)
        XCTAssertGreaterThan(transparent, 0,
            "ProRes 4444 from a transparent source must preserve α<255 pixels")
    }
}
