/*
 * EncodeQueueForwardsCropRectTests — Crop Release Phase F.1.
 *
 * Phase F built the EncodePipeline crop stage and validated it
 * byte-exact end-to-end via CropPipelineIntegrationTests, but the
 * queue's EncodePipeline construction did NOT forward the job's
 * cropRect — the user-set crop had no effect at encode time.
 *
 * F.1 adds `cropRect: snapshot.cropRect` to the queue's
 * EncodePipeline init call. This file is the regression test that
 * proves the forward actually happens.
 *
 * Why end-to-end (not via the test hook)
 * ──────────────────────────────────────
 * EncodeQueue has one test hook — `_testEncodeJobHook` — which
 * short-circuits the ENTIRE encode (the queue calls the closure with
 * the snapshot and uses the returned URL, never constructing
 * `EncodePipeline` at all). That hook fires BEFORE the F.1 forward
 * line is reached, so a hook-based assertion on `snapshot.cropRect`
 * would pass regardless of whether F.1 is in place. To validate the
 * forward, the pipeline must actually run.
 *
 * Discriminator
 * ─────────────
 * The output's `naturalSize`:
 *   - F.1 applied   → cropRect dims (1280×720 for our chosen rect)
 *   - F.1 reverted  → source dims (1920×1080) — the queue's
 *                     EncodePipeline init runs with cropRect=nil and
 *                     the encode emits the full frame
 *
 * A single dim check distinguishes the two. Pixel-level correctness
 * is already covered by CropPipelineIntegrationTests; this file only
 * validates the wiring.
 *
 * Cost
 * ────
 * One real encode of the 30-frame 1080p ProRes source.mov, DXT1 —
 * ~20s wall (mirrors the Phase F integration test's per-encode time).
 *
 * Verified discriminative: with the F.1 forward line removed the
 * test FAILS (output naturalSize.width == 1920, asserted ==
 * 1280); with the forward in place it PASSES. See the commit
 * message for the manual revert-and-retest evidence.
 */

import XCTest
import Foundation
import AVFoundation
@testable import GlEnc
@testable import GlEncCore

@MainActor
final class EncodeQueueForwardsCropRectTests: XCTestCase {

    private static let sourceMOV: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("reference/dxt1/source/source.mov")
    }()

    override func setUp() {
        super.setUp()
        AppSettings.shared.resetToDefaults()
    }
    override func tearDown() {
        AppSettings.shared.resetToDefaults()
        super.tearDown()
    }

    /// Spin-poll for a MainActor predicate until it's true or timeout.
    /// Mirrors `EncodeQueueTests.waitUntil` — same shape so a reader
    /// who knows one knows the other.
    private func waitUntil(
        _ predicate: @escaping @MainActor () -> Bool,
        timeoutSec: Double = 60.0,
        pollMs: UInt64 = 50
    ) async {
        let deadline = Date().addingTimeInterval(timeoutSec)
        while Date() < deadline {
            if predicate() { return }
            try? await Task.sleep(nanoseconds: pollMs * 1_000_000)
        }
    }

    func testEncodeQueue_ForwardsCropRect_OutputDimsMatchCropRect() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.sourceMOV.path),
            "reference/dxt1/source/source.mov missing (stripped from the public seed) — regenerate via scripts/make-corpus.sh (FFmpeg required)")

        // Direct the encode output to a temp dir we control (and
        // clean up). Uses the AppSettings `.fixed` outputLocation
        // path the queue already supports.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("glenc-f1-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        AppSettings.shared.outputLocation = .fixed
        AppSettings.shared.fixedOutputPath = tmpDir.path

        // Build the queue + a single job with a known, 4-pixel-aligned
        // sub-rect of the 1920×1080 source. Same rect as Phase F's
        // integration test — coded dims = presentation (both 16-mult).
        let cropW = 1280, cropH = 720
        let crop = CGRect(x: 320, y: 180, width: cropW, height: cropH)
        let job = EncodeJob(
            sourceURL: Self.sourceMOV,
            format: .dxt1,
            cropRect: crop)
        let queue = EncodeQueue()
        queue.jobs = [job]
        let jobID = job.id

        // Run the encode through the queue's real path. encodeAll
        // spawns one Task per queued job; isEncoding flips false
        // when the loop finishes.
        queue.encodeAll()
        await waitUntil({ !queue.isEncoding }, timeoutSec: 90.0)

        // The job must have completed (not failed mid-encode — that
        // would point to a wiring bug deeper than the F.1 forward
        // line; surface it with the status + error message so the
        // diagnostic is useful).
        guard let done = queue.jobs.first(where: { $0.id == jobID }) else {
            XCTFail("encoded job missing from queue after encode"); return
        }
        XCTAssertEqual(done.status, .done,
                       "encode failed: status=\(done.status) "
                       + "error=\(done.errorMessage ?? "<none>")")
        guard let outURL = done.outputURL else {
            XCTFail("done job has no outputURL"); return
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outURL.path),
                      "output file not created at \(outURL.path)")

        // Load the output mov and check its presentation dims. This
        // is the load-bearing assertion: without F.1, the queue's
        // EncodePipeline init runs with cropRect=nil so the encode
        // emits source dims (1920×1080) instead of the cropped dims.
        let asset = AVURLAsset(url: outURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1, "expected exactly one video track")
        let natSize = try await tracks[0].load(.naturalSize)
        XCTAssertEqual(
            Int(natSize.width), cropW,
            "output naturalSize.width must equal cropRect.width (\(cropW)); "
            + "got \(Int(natSize.width)). If this equals source width (1920), "
            + "EncodeQueue is not forwarding job.cropRect to EncodePipeline "
            + "(the Phase F.1 gap).")
        XCTAssertEqual(
            Int(natSize.height), cropH,
            "output naturalSize.height must equal cropRect.height (\(cropH)); "
            + "got \(Int(natSize.height)).")
    }
}
