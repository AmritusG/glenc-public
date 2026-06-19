/*
 * TrimEncodeTests — Phase 8C-a encoder-side validation.
 *
 * Run the EncodePipeline with a frameRange against the committed
 * 30-frame DXV3 reference fixtures and assert:
 *   - Output exists, is non-empty, demuxes as the target variant
 *   - Frame count in the output matches the trim range size
 *   - Variant/dims match the source
 *
 * Defaults-on (not env-gated) because the 30-frame fixtures encode
 * in <1 s each; cheap regression coverage for the trim path.
 */

import XCTest
import Foundation
@testable import GlEncCore
import GlanceCore

final class TrimEncodeTests: XCTestCase {

    private static let referenceDir: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference")
    }()

    private func fixtureURL(variant: String) -> URL {
        Self.referenceDir
            .appendingPathComponent(variant)
            .appendingPathComponent("glenc.mov")
    }

    private func tempOutURL(_ name: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-trim-test-\(name)-\(UUID().uuidString.prefix(8)).mov")
    }

    /// Encode the middle 10 frames of a 30-frame DXT1 fixture.
    func testTrimmedEncode_MiddleRange_DXT1() async throws {
        let src = fixtureURL(variant: "dxt1")
        let out = tempOutURL("dxt1-mid")
        defer { try? FileManager.default.removeItem(at: out) }

        try await EncodePipeline(
            sourceURL: src,
            encoder: DXT1Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(destURL: out, format: .dxt1,
                                 presentationWidth: w, presentationHeight: h, fps: fps)
            },
            sourceAlphaInfo: .noneSkipLast,
            frameRange: 10..<20
        ).run()

        let idx = try DXVDemuxer.demux(url: out)
        XCTAssertEqual(idx.variant, .dxt1)
        XCTAssertEqual(idx.frames.count, 10,
                       "trim 10..<20 must produce exactly 10 frames")
        XCTAssertGreaterThan(idx.width, 0)
        XCTAssertGreaterThan(idx.height, 0)
    }

    /// Trim from frame 0 (head) — exercises the no-skip path with a
    /// short upper bound.
    func testTrimmedEncode_HeadOnly_DXT5() async throws {
        let src = fixtureURL(variant: "dxt5")
        let out = tempOutURL("dxt5-head")
        defer { try? FileManager.default.removeItem(at: out) }

        try await EncodePipeline(
            sourceURL: src,
            encoder: DXT5Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(destURL: out, format: .dxt5,
                                 presentationWidth: w, presentationHeight: h, fps: fps)
            },
            sourceAlphaInfo: .last,
            frameRange: 0..<5
        ).run()

        let idx = try DXVDemuxer.demux(url: out)
        XCTAssertEqual(idx.variant, .dxt5)
        XCTAssertEqual(idx.frames.count, 5)
    }

    /// Trim to end (tail) — exercises the read-and-discard prefix
    /// path with a full-source upper bound.
    func testTrimmedEncode_TailOnly_YCG6() async throws {
        let src = fixtureURL(variant: "ycg6")
        let out = tempOutURL("ycg6-tail")
        defer { try? FileManager.default.removeItem(at: out) }

        try await EncodePipeline(
            sourceURL: src,
            encoder: YCG6Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(destURL: out, format: .ycg6,
                                 presentationWidth: w, presentationHeight: h, fps: fps)
            },
            sourceAlphaInfo: .noneSkipLast,
            frameRange: 20..<30
        ).run()

        let idx = try DXVDemuxer.demux(url: out)
        XCTAssertEqual(idx.variant, .ycg6)
        XCTAssertEqual(idx.frames.count, 10)
    }

    /// Trim with upper bound past totalFrames — clamps cleanly.
    func testTrimmedEncode_UpperBoundClamps_YG10() async throws {
        let src = fixtureURL(variant: "yg10")
        let out = tempOutURL("yg10-clamp")
        defer { try? FileManager.default.removeItem(at: out) }

        try await EncodePipeline(
            sourceURL: src,
            encoder: YG10Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(destURL: out, format: .yg10,
                                 presentationWidth: w, presentationHeight: h, fps: fps)
            },
            sourceAlphaInfo: .last,
            frameRange: 25..<10_000  // way past 30 frames
        ).run()

        let idx = try DXVDemuxer.demux(url: out)
        XCTAssertEqual(idx.variant, .yg10)
        XCTAssertEqual(idx.frames.count, 5,
                       "upper bound past totalFrames clamps to source length")
    }

    /// Trim with single-frame range produces a 1-frame output.
    func testTrimmedEncode_SingleFrame_DXT1() async throws {
        let src = fixtureURL(variant: "dxt1")
        let out = tempOutURL("dxt1-single")
        defer { try? FileManager.default.removeItem(at: out) }

        try await EncodePipeline(
            sourceURL: src,
            encoder: DXT1Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(destURL: out, format: .dxt1,
                                 presentationWidth: w, presentationHeight: h, fps: fps)
            },
            sourceAlphaInfo: .noneSkipLast,
            frameRange: 7..<8
        ).run()

        let idx = try DXVDemuxer.demux(url: out)
        XCTAssertEqual(idx.frames.count, 1)
    }

    /// nil frameRange = full-source encode (regression check that
    /// the trim plumbing doesn't break the non-trim path).
    func testTrimmedEncode_NilFrameRangeMatchesFullSource_DXT1() async throws {
        let src = fixtureURL(variant: "dxt1")
        let out = tempOutURL("dxt1-full")
        defer { try? FileManager.default.removeItem(at: out) }

        try await EncodePipeline(
            sourceURL: src,
            encoder: DXT1Encoder(),
            makeWriter: { w, h, fps in
                try DXVMOVWriter(destURL: out, format: .dxt1,
                                 presentationWidth: w, presentationHeight: h, fps: fps)
            },
            sourceAlphaInfo: .noneSkipLast,
            frameRange: nil
        ).run()

        let srcIdx = try DXVDemuxer.demux(url: src)
        let outIdx = try DXVDemuxer.demux(url: out)
        XCTAssertEqual(outIdx.frames.count, srcIdx.frames.count,
                       "nil frameRange must encode every source frame")
    }
}
