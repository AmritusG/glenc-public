/*
 * ProbeTimeDimsTests — Fix-Brief B.
 *
 * Source dims now come from the add-time probe (authoritative, persistent
 * on EncodeJob) instead of the live preview's async decode. Coverage:
 *   (i)   probeSourceTiming captures real dims for a valid source, and
 *         probeAndStoreTiming writes them onto the job.
 *   (ii)  the crop clamp sources its bounds from job.sourceWidth/Height
 *         (via cropClampSourceDims) and still clamps oversize → source.
 *   (iii) a malformed source surfaces the reader error → the job lands
 *         status == .failed with a reason (no longer try?-swallowed into a
 *         silently-added normal row).
 *   (iv)  the live preview is gated off for a .failed job.
 */

import XCTest
import CoreGraphics
@testable import GlEnc
@testable import GlEncCore

final class ProbeTimeDimsTests: XCTestCase {

    /// reference/dxt1/ffmpeg.mov — a real 1920×1080, 30fps, 30-frame DXV3.
    private static let referenceMOV: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()   // GlEncTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("reference/dxt1/ffmpeg.mov")
    }()

    private func requireReference() throws -> URL {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.referenceMOV.path),
                          "reference DXV not present: \(Self.referenceMOV.path)")
        return Self.referenceMOV
    }

    // MARK: - (i) probe captures dims

    func testProbeCapturesDimsForValidSource() async throws {
        let url = try requireReference()
        let t = try await EncodeJob.probeSourceTiming(url)
        XCTAssertEqual(t.width, 1920)
        XCTAssertEqual(t.height, 1080)
        XCTAssertEqual(t.frameCount, 30)
        XCTAssertGreaterThan(t.fps, 0)
    }

    @MainActor
    func testProbeAndStoreTiming_writesJobDims() async throws {
        let url = try requireReference()
        let queue = EncodeQueue()
        let job = EncodeJob(sourceURL: url)
        queue.jobs.append(job)
        XCTAssertNil(queue.jobs[0].sourceWidth, "dims start nil before probe")
        await queue.probeAndStoreTiming(jobID: job.id, url: url)
        XCTAssertEqual(queue.jobs[0].sourceWidth, 1920)
        XCTAssertEqual(queue.jobs[0].sourceHeight, 1080)
        XCTAssertEqual(queue.jobs[0].status, .queued, "valid source stays queued")
        XCTAssertNil(queue.jobs[0].errorMessage)
    }

    // MARK: - (ii) crop clamp sources its bounds from the job dims

    func testCropClampSourcesFromJobDims_ClampsOversize() {
        var job = EncodeJob(sourceURL: URL(fileURLWithPath: "/tmp/none.mov"))
        job.sourceWidth = 1920
        job.sourceHeight = 1080
        // The crop editor resolves its clamp dims from job.sourceWidth/Height.
        guard let dims = cropClampSourceDims(sourceWidth: job.sourceWidth,
                                             sourceHeight: job.sourceHeight) else {
            return XCTFail("known job dims must resolve")
        }
        XCTAssertEqual(dims.width, 1920)
        XCTAssertEqual(dims.height, 1080)
        // Re-pin: oversize typed value clamps to the (job-sourced) width.
        let r = commitCropFieldValue(
            field: .width, typedValue: 2000,
            currentRect: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            sourceWidth: dims.width, sourceHeight: dims.height, alignment: 4)
        XCTAssertEqual(r.correctedValue, 1920)
        XCTAssertTrue(r.wasCorrected)
    }

    func testCropClampNilWhenJobDimsUnprobed() {
        let job = EncodeJob(sourceURL: URL(fileURLWithPath: "/tmp/none.mov"))
        // Probe not yet resolved → dims nil → clamp refuses (Brief A idiom).
        XCTAssertNil(cropClampSourceDims(sourceWidth: job.sourceWidth,
                                         sourceHeight: job.sourceHeight))
    }

    // MARK: - (iii) malformed source → failed-with-reason (not silently added)

    @MainActor
    func testMalformedSourceLandsFailedWithReason() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: MalformedDXVFixtures.referenceURL.path),
                          "fuzz-corpus reference DXV not present")
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-probefail-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }
        try MalformedDXVFixtures.make(.dimensions(width: 0, height: 0), into: dest)

        let queue = EncodeQueue()
        let job = EncodeJob(sourceURL: dest)
        queue.jobs.append(job)
        await queue.probeAndStoreTiming(jobID: job.id, url: dest)

        XCTAssertEqual(queue.jobs[0].status, .failed,
                       "malformed source must land .failed, not a normal row")
        XCTAssertNotNil(queue.jobs[0].errorMessage)
        XCTAssertNil(queue.jobs[0].sourceWidth, "no dims captured from a malformed source")
    }

    @MainActor
    func testProbeSourceTimingThrowsOnMalformed() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: MalformedDXVFixtures.referenceURL.path),
                          "fuzz-corpus reference DXV not present")
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("glenc-probethrow-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: dest) }
        try MalformedDXVFixtures.make(.dimensions(width: 0, height: 0), into: dest)
        do {
            _ = try await EncodeJob.probeSourceTiming(dest)
            XCTFail("expected probeSourceTiming to surface (throw) the reader error")
        } catch is SourceReaderError {
            // expected — the error is observable, not swallowed
        } catch {
            // any thrown error is acceptable; the point is it's not swallowed
        }
    }

    // MARK: - (iv) preview-load gate

    func testPreviewLoadGate() {
        XCTAssertFalse(previewShouldLoad(jobStatus: .failed), "failed job must not load preview")
        XCTAssertTrue(previewShouldLoad(jobStatus: .queued))
        XCTAssertTrue(previewShouldLoad(jobStatus: .encoding))
        XCTAssertTrue(previewShouldLoad(jobStatus: .done))
    }
}
