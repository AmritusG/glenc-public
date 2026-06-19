/*
 * #14 part 1 — rational frame-rate read.
 *
 * AVAssetReaderSourceReader now derives the source rate from the
 * track's exact `minFrameDuration` (CMTime) instead of AVFoundation's
 * `nominalFrameRate` Float, which misreads a clean integer-rate H.264
 * as e.g. 29.999998 and trips VariantMOVWriter's integer-fps
 * precondition.
 *
 *   - testClean30: a clean-30 H.264 whose container makes AVFoundation
 *     report nominalFrameRate=29.999998 (the #14 misread — verified in
 *     the [GlEnc/fps] diagnostic) now reads exactly 30 via the rational
 *     path and encodes through the real pipeline. Pre-fix this exact
 *     fixture threw WriterError.nonIntegerFPS.
 *   (The former testGenuine2997 boundary test was removed when #14 part 2
 *   made 29.97 a valid rate; see RationalTimescaleWriterTests.)
 *
 * Fixtures committed under reference/fps/ (no scratch-dir dependency).
 */
import XCTest
import AVFoundation
@testable import GlEncCore
import GlanceCore

final class FpsRationalReadTests: XCTestCase {

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference")
            .appendingPathComponent("fps")
            .appendingPathComponent(name)
    }

    private func tempOut(_ tag: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-fps-\(tag)-\(UUID().uuidString).mov")
    }

    func testClean30H264_ReadsExact30_EncodesWithoutTrippingPrecondition() async throws {
        let src = fixtureURL("clean30_h264.mp4")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src.path),
                          "missing reference/fps/clean30_h264.mp4")
        let out = tempOut("clean30")
        defer { try? FileManager.default.removeItem(at: out) }

        let pipeline = EncodePipeline(
            sourceURL: src,
            encoder: DXT1Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(
                    destURL: out, format: .dxt1,
                    presentationWidth: w, presentationHeight: h,
                    fps: fps, codecFourCC: "DXD3")
            },
            sourceAlphaInfo: .last)
        // Must NOT throw WriterError.nonIntegerFPS — the rational read
        // recovers exactly 30 from the clean source.
        try await pipeline.run()

        let idx = try DXVDemuxer.demux(url: out)
        XCTAssertEqual(idx.frameRate, 30.0, accuracy: 0.001,
                       "clean-30 H.264 must encode at exactly 30 fps")
        XCTAssertEqual(idx.frames.count, 150,
                       "5s @ 30fps must produce 150 frames")
    }

    // NOTE: the former testGenuine2997…_DocumentsPart1Boundary (which
    // asserted a genuine 29.97 source was *rejected*) was removed when
    // #14 part 2 shipped — part 2 makes 29.97 a valid rate (NTSC snap to
    // 30000/1001). The current behaviour is covered by
    // RationalTimescaleWriterTests: testRoundTrip_2997_H264_ToDXV (29.97
    // now encodes) and testDeriveTimescale_NearMiss295_Throws (non-NTSC
    // non-integer still rejected).
}
