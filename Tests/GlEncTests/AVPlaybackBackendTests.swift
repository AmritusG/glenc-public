/*
 * AVPlaybackBackendTests — Phase v0.9.0-fix.
 *
 * Covers PreviewPlayerModel's dispatch over the two backends:
 *   - DXV3 sources stay on DXVPlayer (existing path)
 *   - Non-DXV3 sources route to AVPlaybackBackend (new path)
 *   - Backend swap when load(url:) is called with a different family
 *   - Direct AVPlaybackBackend init for a fixture
 *
 * The H.264 fixture is synthesized in the test's temp dir via
 * AVAssetWriter (same shape as PreviewPaneTests's existing
 * `writeTrivialH264`).
 *
 * NOTE: these tests intentionally live in their own XCTestCase
 * subclass rather than being added to PreviewPaneTests. An empirical
 * crash ("Not enough bits to represent the passed value", Swift
 * arm64e interface 13152) reproduces when a new async test that
 * loads an H.264 fixture is added to PreviewPaneTests, but the same
 * code runs cleanly in this separate class. Root cause not pinned;
 * isolation here is the pragmatic workaround.
 */

import XCTest
import Foundation
import AVFoundation
@testable import GlEnc

@MainActor
final class AVPlaybackBackendTests: XCTestCase {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("avbe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        return tmp
    }

    private func writeH264(at url: URL, frames: Int = 5) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320, AVVideoHeightKey: 180,
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 180,
            ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for i in 0..<frames {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            var pb: CVPixelBuffer?
            _ = CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
            if let buf = pb {
                let pts = CMTime(value: CMTimeValue(i), timescale: 30)
                adaptor.append(buf, withPresentationTime: pts)
            }
        }
        input.markAsFinished()
        await writer.finishWriting()
    }

    private func referenceFixtureURL(variant: String) -> URL {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference")
            .appendingPathComponent(variant)
            .appendingPathComponent("glenc.mov")
    }

    // MARK: - Direct AVPlaybackBackend init

    func testBackendInit_H264File() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("a.mp4")
        try await writeH264(at: url, frames: 5)
        let backend = try await AVPlaybackBackend(url: url)
        XCTAssertGreaterThan(backend.totalFrames, 0)
        XCTAssertGreaterThan(backend.frameRate, 0)
        XCTAssertEqual(backend.sourceWidth, 320)
        XCTAssertEqual(backend.sourceHeight, 180)
        XCTAssertTrue(backend.isPaused, "AVPlayer starts paused before play()")
        backend.stop()
    }

    // MARK: - PreviewPlayerModel backend dispatch

    /// DXV3 sources stay on the .dxv backend; avPlayer is nil.
    func testModel_DXV3StaysOnDXVBackend() async throws {
        let model = PreviewPlayerModel()
        model.load(url: referenceFixtureURL(variant: "dxt1"))
        XCTAssertEqual(model.backendKind, .dxv)
        XCTAssertNil(model.avPlayer, "no AVPlayer when on DXV backend")
    }

    /// Phase v0.9.0-fix — loading a non-DXV3 source routes to the
    /// AVPlaybackBackend. Verifies the backendKind flips to .av and
    /// the AVPlayer instance is exposed for the hosting layer.
    func testModel_LoadsNonDXV3() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let url = tmp.appendingPathComponent("blob.mp4")
        try await writeH264(at: url, frames: 10)
        let model = PreviewPlayerModel()
        model.load(url: url)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(model.backendKind, .av, "non-DXV3 must route to AV backend")
        XCTAssertGreaterThan(model.totalFrames, 0, "totalFrames populated from track")
        XCTAssertGreaterThan(model.frameRate, 0, "frameRate populated")
        XCTAssertGreaterThan(model.sourceWidth, 0)
        XCTAssertGreaterThan(model.sourceHeight, 0)
        XCTAssertNotNil(model.avPlayer, "avPlayer exposed for hosting layer")
    }

    /// Backend swap: load DXV → load non-DXV → backendKind flips.
    func testModel_BackendSwapDXVtoAV() async throws {
        let model = PreviewPlayerModel()
        model.load(url: referenceFixtureURL(variant: "dxt5"))
        XCTAssertEqual(model.backendKind, .dxv)

        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let h264 = tmp.appendingPathComponent("clip.mp4")
        try await writeH264(at: h264, frames: 10)

        model.load(url: h264)
        for _ in 0..<50 {
            if model.backendKind == .av { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(model.backendKind, .av, "backend swapped to AV after non-DXV3 load")
        XCTAssertNotNil(model.avPlayer)
    }
}
